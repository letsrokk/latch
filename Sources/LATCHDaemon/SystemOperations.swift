import Darwin
import Foundation
import LATCHNative
import LATCHShared
import OSLog

enum SystemOperationError: Error { case unavailable, conflict, nonEmptyMountPoint, invalidDependency }

protocol ApplicationCoordinatorRequesting: AgentRequesting {}

struct FixedProcess {
    static func run(executable: String, arguments: [String], environment: [String: String]? = nil, timeout: Int = 30) async throws {
        let result: BoundedProcessResult
        do {
            result = try await BoundedProcessRunner.run(
                executable: executable,
                arguments: arguments,
                environment: environment,
                timeout: .seconds(timeout)
            )
        } catch BoundedProcessError.timedOut {
            throw SystemCommandError(executable: executable, status: SIGKILL, detail: "The command timed out.")
        }
        guard result.terminationStatus == 0 else {
            throw SystemCommandError(
                executable: executable,
                status: result.terminationStatus,
                detail: result.standardError
            )
        }
    }
}

actor SystemMountOperator: MountOperating {
    private struct TargetBinding {
        let identity: MountTargetIdentity
        let allowedRoots: [String]
        let requiredOwnerID: uid_t?
        let requireEmpty: Bool
    }

    private let table = DarwinMountTable()
    private let probeRunner: any ProbeRunning
    private let mountLogger = Logger(subsystem: LATCHIdentity.bundleIdentifier, category: "mount")
    private let probeLogger = Logger(subsystem: LATCHIdentity.bundleIdentifier, category: "probe")

    init(probeRunner: any ProbeRunning) { self.probeRunner = probeRunner }

    func networkAvailable(for host: String) async -> Bool {
        await Task.detached { latch_tcp_check(host, 2049, 2_000) == 1 }.value
    }

    func currentSource(at mountPoint: String) async throws -> String? {
        try table.snapshots().first { $0.mountPoint == mountPoint }?.source
    }

    func forceUnmount(
        _ mountPoint: String,
        expectedSource: String,
        cancellation: MountOperationCancellation
    ) async throws {
        try cancellation.throwIfCancelled()
        let target = try validatedUnmountPath(mountPoint)
        try cancellation.throwIfCancelled()
        guard try table.snapshots().contains(where: {
            $0.mountPoint == target && $0.source == expectedSource
        }) else {
            throw SystemOperationError.conflict
        }
        try cancellation.throwIfCancelled()
        mountLogger.notice("Force-unmounting source-verified mountpoint \(target, privacy: .private(mask: .hash))")
        try await FixedProcess.run(executable: "/sbin/umount", arguments: ["-f", target], timeout: 20)
    }

    func validateEmptyMountPoint(_ mountPoint: String, cancellation: MountOperationCancellation) async throws {
        try cancellation.throwIfCancelled()
        _ = try bindTarget(mountPoint, requireEmpty: true, requireTargetOwner: true)
        try cancellation.throwIfCancelled()
    }

    func mount(_ definition: MountDefinition, cancellation: MountOperationCancellation) async throws {
        try cancellation.throwIfCancelled()
        let binding = try bindTarget(definition.mountPoint, requireEmpty: true, requireTargetOwner: true)
        try cancellation.throwIfCancelled()
        mountLogger.notice("Mounting definition \(definition.id.uuidString, privacy: .public)")
        try revalidate(binding)
        try cancellation.throwIfCancelled()
        try await FixedProcess.run(
            executable: "/sbin/mount",
            arguments: ["-t", "nfs", "-o", definition.mountOptions.encoded, definition.source, definition.mountPoint],
            timeout: 30
        )
    }

    private func bindTarget(_ path: String, requireEmpty: Bool, requireTargetOwner: Bool) throws -> TargetBinding {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        let validator = ExistingMountTargetValidator()
        if standardized.hasPrefix("/Volumes/Media/") {
            _ = try validator.inspect(
                "/Volumes/Media",
                allowedRoots: ["/Volumes"],
                requiredOwnerID: nil,
                requireEmpty: false
            )
            let preliminary = try validator.inspect(
                standardized,
                allowedRoots: ["/Volumes/Media"],
                requiredOwnerID: nil,
                requireEmpty: requireEmpty
            )
            let ownerID: uid_t? = if requireTargetOwner {
                try localUserOwner(preliminary.ownerID)
            } else {
                nil
            }
            let identity = try validator.inspect(
                standardized,
                allowedRoots: ["/Volumes/Media"],
                requiredOwnerID: ownerID,
                requireEmpty: requireEmpty
            )
            return .init(identity: identity, allowedRoots: ["/Volumes/Media"], requiredOwnerID: ownerID, requireEmpty: requireEmpty)
        }

        let components = standardized.split(separator: "/")
        guard components.count >= 3, components[0] == "Users" else {
            throw MountTargetValidationError.outsideAllowedRoots
        }
        let userName = String(components[1])
        guard let account = getpwnam(userName), let homePointer = account.pointee.pw_dir else {
            throw MountTargetValidationError.wrongOwner
        }
        let ownerID = account.pointee.pw_uid
        let home = URL(fileURLWithPath: String(cString: homePointer)).standardizedFileURL.path
        guard standardized.hasPrefix(home + "/") else { throw MountTargetValidationError.outsideAllowedRoots }
        _ = try validator.inspect(home, allowedRoots: ["/Users"], requiredOwnerID: ownerID, requireEmpty: false)
        let requiredOwnerID = requireTargetOwner ? ownerID : nil
        let identity = try validator.inspect(
            standardized,
            allowedRoots: [home],
            requiredOwnerID: requiredOwnerID,
            requireEmpty: requireEmpty
        )
        return .init(identity: identity, allowedRoots: [home], requiredOwnerID: requiredOwnerID, requireEmpty: requireEmpty)
    }

    private func validatedUnmountPath(_ path: String) throws -> String {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard standardized == path else { throw MountTargetValidationError.outsideAllowedRoots }
        if standardized.hasPrefix("/Volumes/Media/") { return standardized }

        let components = standardized.split(separator: "/")
        guard components.count >= 3, components[0] == "Users" else {
            throw MountTargetValidationError.outsideAllowedRoots
        }
        let userName = String(components[1])
        guard let account = getpwnam(userName), let homePointer = account.pointee.pw_dir else {
            throw MountTargetValidationError.wrongOwner
        }
        let home = URL(fileURLWithPath: String(cString: homePointer)).standardizedFileURL.path
        guard standardized.hasPrefix(home + "/") else {
            throw MountTargetValidationError.outsideAllowedRoots
        }
        return standardized
    }

    private func localUserOwner(_ ownerID: uid_t) throws -> uid_t {
        guard ownerID != 0, let account = getpwuid(ownerID), account.pointee.pw_dir != nil else {
            throw MountTargetValidationError.wrongOwner
        }
        return ownerID
    }

    private func revalidate(_ binding: TargetBinding) throws {
        try ExistingMountTargetValidator().revalidate(
            binding.identity,
            allowedRoots: binding.allowedRoots,
            requiredOwnerID: binding.requiredOwnerID,
            requireEmpty: binding.requireEmpty
        )
    }

    func verifySource(_ source: String, at mountPoint: String, cancellation: MountOperationCancellation) async throws {
        try cancellation.throwIfCancelled()
        let isExpectedSource = try table.snapshots().contains { $0.source == source && $0.mountPoint == mountPoint }
        try cancellation.throwIfCancelled()
        guard isExpectedSource else {
            throw SystemOperationError.conflict
        }
    }

    func probe(_ definition: MountDefinition, cancellation: MountOperationCancellation) async throws -> ProbeResult {
        try cancellation.throwIfCancelled()
        let result = await probeRunner.run(mountPoint: definition.mountPoint, timeoutSeconds: definition.probeTimeoutSeconds)
        try cancellation.throwIfCancelled()
        if ProbeClassifier.classify(result).state != .healthy {
            probeLogger.error("Probe for \(definition.id.uuidString, privacy: .public) failed: \(String(describing: result), privacy: .public)")
        }
        return result
    }
}

struct NativeIPv4BroadcastProvider: WakeOnLANBroadcastProviding {
    func activeIPv4BroadcastAddresses() async -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let head else { return [] }
        defer { freeifaddrs(head) }
        var addresses = Set<String>()
        var cursor: UnsafeMutablePointer<ifaddrs>? = head
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let flags = entry.pointee.ifa_flags
            guard let address = entry.pointee.ifa_addr,
                  let netmask = entry.pointee.ifa_netmask,
                  address.pointee.sa_family == UInt8(AF_INET),
                  (flags & UInt32(IFF_UP)) != 0,
                  (flags & UInt32(IFF_RUNNING)) != 0,
                  (flags & UInt32(IFF_BROADCAST)) != 0,
                  (flags & UInt32(IFF_LOOPBACK)) == 0,
                  (flags & UInt32(IFF_POINTOPOINT)) == 0 else { continue }
            let ip = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr.bigEndian }
            let mask = netmask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr.bigEndian }
            let broadcast = (ip & mask) | ~mask
            addresses.insert("\((broadcast >> 24) & 255).\((broadcast >> 16) & 255).\((broadcast >> 8) & 255).\(broadcast & 255)")
        }
        return addresses.sorted()
    }
}

struct NativeWakeOnLANPacketSender: WakeOnLANPacketSending {
    func send(_ packet: Data, to broadcastAddress: String, port: UInt16) async throws {
        let descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        var enabled: Int32 = 1
        guard setsockopt(descriptor, SOL_SOCKET, SO_BROADCAST, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled))) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        var destination = sockaddr_in()
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = port.bigEndian
        guard inet_pton(AF_INET, broadcastAddress, &destination.sin_addr) == 1 else { throw WakeOnLANError.invalidBroadcastAddress }
        let sent = packet.withUnsafeBytes { buffer in
            withUnsafePointer(to: &destination) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.sendto(descriptor, buffer.baseAddress, buffer.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent == packet.count else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    }
}

struct NativeNFSReachability: WakeOnLANReachabilityChecking {
    func isReachable(hostname: String, port: UInt16) async -> Bool {
        await Task.detached { latch_tcp_check(hostname, port, 2_000) == 1 }.value
    }
}

actor TypedDependencyOperator: DependencyOperating {
    private let dependencyLogger = Logger(subsystem: LATCHIdentity.bundleIdentifier, category: "dependencies")
    private let applicationCoordinator: any ApplicationCoordinatorRequesting

    init(applicationCoordinator: any ApplicationCoordinatorRequesting) {
        self.applicationCoordinator = applicationCoordinator
    }

    func prepare(_ dependency: RecoveryDependency) async throws {
        switch dependency.kind {
        case .dockerContainer:
            _ = try await requireResponse(
                .dependencyPrepare(dependency),
                matching: .ready,
                timeout: .seconds(15)
            )
        case .macApplication(let app):
            guard case .ready = try await applicationCoordinator.request(.prepare(app)) else { throw SystemOperationError.unavailable }
        }
    }

    func isRunning(_ dependency: RecoveryDependency) async throws -> Bool {
        switch dependency.kind {
        case .dockerContainer:
            let response = try await requestDependency(
                .dependencyIsRunning(dependency),
                timeout: .seconds(15)
            )
            guard case .running(let running) = response else { throw SystemOperationError.unavailable }
            return running
        case .macApplication(let app):
            guard case .running(let running) = try await applicationCoordinator.request(.isRunning(app)) else { throw SystemOperationError.unavailable }
            return running
        }
    }

    func stop(_ dependency: RecoveryDependency, cancellation: MountOperationCancellation) async throws {
        try cancellation.throwIfCancelled()
        dependencyLogger.notice("Stopping dependency \(dependency.id.uuidString, privacy: .public)")
        switch dependency.kind {
        case .dockerContainer:
            try cancellation.throwIfCancelled()
            _ = try await requireResponse(
                .dependencyStop(dependency, timeoutSeconds: dependency.stopTimeoutSeconds),
                matching: .succeeded,
                timeout: .seconds(dependency.stopTimeoutSeconds + 10)
            )
        case .macApplication(let app):
            try cancellation.throwIfCancelled()
            guard case .succeeded = try await applicationCoordinator.request(.stop(app, timeoutSeconds: dependency.stopTimeoutSeconds)) else { throw SystemOperationError.unavailable }
        }
    }

    func start(_ dependency: RecoveryDependency, cancellation: MountOperationCancellation) async throws {
        try cancellation.throwIfCancelled()
        dependencyLogger.notice("Starting dependency \(dependency.id.uuidString, privacy: .public)")
        switch dependency.kind {
        case .dockerContainer:
            try cancellation.throwIfCancelled()
            _ = try await requireResponse(
                .dependencyStart(dependency),
                matching: .succeeded,
                timeout: .seconds(35)
            )
        case .macApplication(let app):
            try cancellation.throwIfCancelled()
            guard case .succeeded = try await applicationCoordinator.request(.start(app)) else { throw SystemOperationError.unavailable }
        }
    }

    func verifyRunning(_ dependency: RecoveryDependency, cancellation: MountOperationCancellation) async throws {
        try cancellation.throwIfCancelled()
        switch dependency.kind {
        case .dockerContainer:
            _ = try await requireResponse(
                .dependencyVerifyRunning(dependency, timeoutSeconds: 30),
                matching: .succeeded,
                timeout: .seconds(35)
            )
        case .macApplication(let app):
            guard case .succeeded = try await applicationCoordinator.request(.verifyRunning(app, timeoutSeconds: 30)) else { throw SystemOperationError.unavailable }
        }
        try cancellation.throwIfCancelled()
    }

    private func requestDependency(
        _ request: AgentRequest,
        timeout: Duration
    ) async throws -> AgentResponse {
        let applicationCoordinator = self.applicationCoordinator
        // A dependency side effect must be joined after local cancellation so recovery can
        // record and compensate it before the queued operation becomes terminal.
        return try await ResponseDeadline.wait(for: timeout, cancellationBehavior: .awaitResponse) { completion in
            Task {
                do {
                    completion(.success(try await applicationCoordinator.request(request)))
                } catch {
                    completion(.failure(error))
                }
            }
        }
    }

    private func requireResponse(
        _ request: AgentRequest,
        matching expected: AgentResponse,
        timeout: Duration
    ) async throws -> AgentResponse {
        let response = try await requestDependency(request, timeout: timeout)
        if case .ready = expected, case .ready = response { return response }
        if case .succeeded = expected, case .succeeded = response { return response }
        if case .running = expected, case .running = response { return response }
        throw SystemOperationError.unavailable
    }
}
