import Darwin
import Foundation

public enum ProbeOperation: String, Codable, Sendable {
    case metadata
    case directoryOpen
    case directoryRead
}

public struct ProbeResult: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var version: Int
    public var metadataErrno: Int32?
    public var directoryErrno: Int32?
    public var failedOperation: ProbeOperation?
    public var timedOut: Bool
    public var networkUnavailable: Bool
    public var tccDenied: Bool
    /// `nil` preserves compatibility with probe payloads produced before this
    /// transport condition was represented explicitly.
    public var executionUnavailable: Bool?

    public init(
        version: Int = currentVersion,
        metadataErrno: Int32? = nil,
        directoryErrno: Int32? = nil,
        failedOperation: ProbeOperation? = nil,
        timedOut: Bool = false,
        networkUnavailable: Bool = false,
        tccDenied: Bool = false,
        executionUnavailable: Bool = false
    ) {
        self.version = version
        self.metadataErrno = metadataErrno
        self.directoryErrno = directoryErrno
        self.failedOperation = failedOperation
        self.timedOut = timedOut
        self.networkUnavailable = networkUnavailable
        self.tccDenied = tccDenied
        self.executionUnavailable = executionUnavailable
    }

    public func annotatingNetworkVolumesDenial(permissionVerified: Bool) -> ProbeResult {
        guard !permissionVerified,
              metadataErrno == EACCES || metadataErrno == EPERM || directoryErrno == EACCES || directoryErrno == EPERM else {
            return self
        }
        var annotated = self
        annotated.tccDenied = true
        return annotated
    }
}

public struct ProbeClassification: Sendable, Equatable {
    public let state: MountState
    public let code: LATCHErrorCode
    public let detail: String
    public let shouldAutomaticallyRecover: Bool
}

public enum ProbeClassifier {
    public static func classify(_ result: ProbeResult) -> ProbeClassification {
        if result.timedOut {
            return .init(state: .probeTimedOut, code: .probeTimeout, detail: "The native probe exceeded its deadline.", shouldAutomaticallyRecover: false)
        }
        if result.networkUnavailable {
            return .init(state: .networkUnavailable, code: .networkUnavailable, detail: "The NFS server is not reachable.", shouldAutomaticallyRecover: false)
        }
        if result.executionUnavailable == true {
            return .init(state: .mounting, code: .none, detail: "Mounted. Waiting for the login agent to perform the health check.", shouldAutomaticallyRecover: false)
        }

        let errors = [result.metadataErrno, result.directoryErrno].compactMap { $0 }
        if errors.contains(ESTALE) {
            return .init(state: .stale, code: .staleHandle, detail: "The server returned numeric ESTALE.", shouldAutomaticallyRecover: true)
        }
        if result.tccDenied {
            return .init(state: .probeError, code: .tccDenied, detail: "Network Volumes access is denied.", shouldAutomaticallyRecover: false)
        }
        if errors.contains(EACCES) || errors.contains(EPERM) {
            return .init(state: .probeError, code: .permissionDenied, detail: "The native probe was denied permission.", shouldAutomaticallyRecover: false)
        }
        if let error = errors.first {
            return .init(state: .probeError, code: .verificationFailed, detail: "The native probe failed with errno \(error).", shouldAutomaticallyRecover: false)
        }
        return .init(state: .healthy, code: .none, detail: "Metadata and directory probes succeeded.", shouldAutomaticallyRecover: false)
    }
}

/// Runtime health probes report mount health, not whether the daemon passed the
/// explicit Network Volumes permission check. A previously verified gate stays
/// open across ESTALE, timeouts, and ordinary I/O failures. Only an explicit TCC
/// denial observed at runtime can revoke it.
public enum NetworkVolumesPermissionPolicy {
    public static func afterRuntimeProbe(
        current: NetworkVolumesVerificationState,
        result: ProbeResult
    ) -> NetworkVolumesVerificationState {
        result.tccDenied ? .failed : current
    }
}

public protocol ProbeRunning: Sendable {
    func run(mountPoint: String, timeoutSeconds: Int) async -> ProbeResult
}

public struct NativeProbeRunner: ProbeRunning, Sendable {
    public let executableURL: URL

    public init(executableURL: URL) { self.executableURL = executableURL }

    public func run(mountPoint: String, timeoutSeconds: Int) async -> ProbeResult {
        await Task.detached {
            runProcess(mountPoint: mountPoint, timeoutSeconds: timeoutSeconds)
        }.value
    }

    private func runProcess(mountPoint: String, timeoutSeconds: Int) -> ProbeResult {
        let process = Process()
        let output = Pipe()
        process.executableURL = executableURL
        process.arguments = [mountPoint]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let deadline = Date().addingTimeInterval(Double(timeoutSeconds))
            while process.isRunning && Date() < deadline { usleep(25_000) }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
                return ProbeResult(timedOut: true)
            }
            process.waitUntilExit()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            return try JSONDecoder().decode(ProbeResult.self, from: data)
        } catch {
            if process.isRunning { process.terminate() }
            return ProbeResult(metadataErrno: EIO, failedOperation: .metadata)
        }
    }
}
