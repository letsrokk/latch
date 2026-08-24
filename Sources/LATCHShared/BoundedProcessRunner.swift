import Darwin
import Foundation

public struct BoundedProcessResult: Sendable, Equatable {
    public let terminationStatus: Int32
    public let standardOutput: String
    public let standardError: String

    public init(terminationStatus: Int32, standardOutput: String, standardError: String) {
        self.terminationStatus = terminationStatus
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

public enum BoundedProcessError: Error, Sendable, Equatable {
    case timedOut
}

public enum BoundedProcessRunner {
    public static func run(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        timeout: Duration
    ) async throws -> BoundedProcessResult {
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        let control = ProcessControl(process)
        let exitSignal = ProcessExitSignal()
        process.terminationHandler = { _ in exitSignal.signal() }
        try process.run()
        outputPipe.fileHandleForWriting.closeFile()
        errorPipe.fileHandleForWriting.closeFile()
        let outputDrain = Task.detached {
            outputPipe.fileHandleForReading.readDataToEndOfFile()
        }
        let errorDrain = Task.detached {
            errorPipe.fileHandleForReading.readDataToEndOfFile()
        }

        do {
            let outcome = try await withTaskCancellationHandler {
                try await withThrowingTaskGroup(of: ProcessWaitOutcome.self) { group in
                    group.addTask {
                        await exitSignal.wait()
                        try Task.checkCancellation()
                        return .exited
                    }
                    group.addTask {
                        try await Task.sleep(for: timeout)
                        return .timedOut
                    }
                    let first = try await group.next() ?? .timedOut
                    if first == .timedOut { control.kill() }
                    group.cancelAll()
                    while await group.nextResult() != nil {}
                    return first
                }
            } onCancel: {
                control.kill()
            }

            control.waitUntilExit()
            let result = await collectResult(
                process: process,
                outputDrain: outputDrain,
                errorDrain: errorDrain
            )
            guard outcome != .timedOut else { throw BoundedProcessError.timedOut }
            return result
        } catch {
            control.kill()
            control.waitUntilExit()
            _ = await collectResult(
                process: process,
                outputDrain: outputDrain,
                errorDrain: errorDrain
            )
            throw error
        }
    }

    private static func collectResult(
        process: Process,
        outputDrain: Task<Data, Never>,
        errorDrain: Task<Data, Never>
    ) async -> BoundedProcessResult {
        let standardOutput = await outputDrain.value
        let standardError = await errorDrain.value
        return BoundedProcessResult(
            terminationStatus: process.terminationStatus,
            standardOutput: String(decoding: standardOutput, as: UTF8.self),
            standardError: String(decoding: standardError, as: UTF8.self)
        )
    }
}

public enum DockerInspectionError: Error, Sendable, Equatable {
    case invalidRunningState(String)
}

public enum DockerInspectionPolicy {
    public static func runningState(from output: String) throws -> Bool {
        switch output.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "true": true
        case "false": false
        case let value: throw DockerInspectionError.invalidRunningState(value)
        }
    }
}

private enum ProcessWaitOutcome: Equatable {
    case exited
    case timedOut
}

private final class ProcessControl: @unchecked Sendable {
    private let process: Process

    init(_ process: Process) { self.process = process }

    var isRunning: Bool { process.isRunning }

    func kill() {
        guard process.isRunning else { return }
        Darwin.kill(process.processIdentifier, SIGKILL)
    }

    func waitUntilExit() { process.waitUntilExit() }
}

private final class ProcessExitSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var didExit = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeImmediately = lock.withLock {
                if didExit { return true }
                self.continuation = continuation
                return false
            }
            if resumeImmediately { continuation.resume() }
        }
    }

    func signal() {
        let continuation = lock.withLock {
            didExit = true
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume()
    }
}
