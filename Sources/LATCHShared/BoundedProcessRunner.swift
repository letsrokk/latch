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
        let process = try SpawnedProcess(
            executable: executable,
            arguments: arguments,
            environment: environment
        )
        let ioStop = ProcessIOStop()

        let capture = try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: ProcessWaitEvent.self) { group in
                group.addTask { .exited(process.waitUntilExit()) }
                group.addTask { .standardOutput(process.drainStandardOutput(until: ioStop)) }
                group.addTask { .standardError(process.drainStandardError(until: ioStop)) }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    return .timedOut
                }

                var capture = ProcessCapture()
                while let event = try await group.next() {
                    switch event {
                    case .exited(let status):
                        capture.terminationStatus = status
                    case .standardOutput(let data):
                        capture.standardOutput = data
                    case .standardError(let data):
                        capture.standardError = data
                    case .timedOut:
                        capture.timedOut = true
                        ioStop.stop()
                        process.terminate()
                    }
                    if capture.isComplete {
                        group.cancelAll()
                        while await group.nextResult() != nil {}
                        return capture
                    }
                }
                ioStop.stop()
                process.terminate()
                throw BoundedProcessError.timedOut
            }
        } onCancel: {
            ioStop.stop()
            process.terminate()
        }

        try Task.checkCancellation()
        guard !capture.timedOut else { throw BoundedProcessError.timedOut }
        return BoundedProcessResult(
            terminationStatus: capture.terminationStatus ?? -1,
            standardOutput: String(decoding: capture.standardOutput ?? Data(), as: UTF8.self),
            standardError: String(decoding: capture.standardError ?? Data(), as: UTF8.self)
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

enum PipeDescriptorRelocator {
    static func relocate(
        _ descriptors: [Int32],
        duplicate: (Int32, Int32) throws -> Int32,
        close: (Int32) -> Void
    ) throws -> [Int32] {
        var relocated = descriptors
        var owned = Set(descriptors)

        do {
            for index in relocated.indices where relocated[index] <= STDERR_FILENO {
                let source = relocated[index]
                let replacement = try duplicate(source, STDERR_FILENO + 1)
                guard replacement > STDERR_FILENO, !owned.contains(replacement) else {
                    if !owned.contains(replacement) { close(replacement) }
                    throw POSIXError(.EINVAL)
                }
                owned.insert(replacement)
                close(source)
                owned.remove(source)
                relocated[index] = replacement
            }
            return relocated
        } catch {
            for descriptor in owned { close(descriptor) }
            throw error
        }
    }
}

private enum ProcessWaitEvent: Sendable {
    case exited(Int32)
    case standardOutput(Data)
    case standardError(Data)
    case timedOut
}

private struct ProcessCapture {
    var terminationStatus: Int32?
    var standardOutput: Data?
    var standardError: Data?
    var timedOut = false

    var isComplete: Bool {
        terminationStatus != nil && standardOutput != nil && standardError != nil
    }
}

private final class ProcessIOStop: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false

    var isStopped: Bool { lock.withLock { stopped } }

    func stop() {
        lock.withLock { stopped = true }
    }
}

enum NonblockingChildWaitResult: Sendable, Equatable {
    case running
    case reaped(Int32)
}

final class ChildProcessLifecycle: @unchecked Sendable {
    private enum State {
        case running
        case reaped(Int32)
    }

    private let lock = NSLock()
    private let processIdentifier: pid_t
    private let poll: @Sendable (pid_t) -> NonblockingChildWaitResult
    private let signal: @Sendable (pid_t) -> Void
    private var state = State.running

    convenience init(processIdentifier: pid_t) {
        self.init(
            processIdentifier: processIdentifier,
            poll: { processIdentifier in
                var status: Int32 = 0
                let result = Darwin.waitpid(processIdentifier, &status, WNOHANG)
                if result == processIdentifier { return .reaped(status) }
                if result == 0 || (result == -1 && errno == EINTR) { return .running }
                return .reaped(-1)
            },
            signal: { processIdentifier in
                _ = Darwin.kill(processIdentifier, SIGKILL)
            }
        )
    }

    init(
        processIdentifier: pid_t,
        poll: @escaping @Sendable (pid_t) -> NonblockingChildWaitResult,
        signal: @escaping @Sendable (pid_t) -> Void
    ) {
        self.processIdentifier = processIdentifier
        self.poll = poll
        self.signal = signal
    }

    func pollExit() -> Int32? {
        lock.withLock {
            switch state {
            case .reaped(let status):
                return status
            case .running:
                switch poll(processIdentifier) {
                case .running:
                    return nil
                case .reaped(let status):
                    state = .reaped(status)
                    return status
                }
            }
        }
    }

    func terminateIfLive() {
        lock.withLock {
            guard case .running = state else { return }
            switch poll(processIdentifier) {
            case .running:
                signal(-processIdentifier)
                signal(processIdentifier)
            case .reaped(let status):
                state = .reaped(status)
            }
        }
    }
}

private final class SpawnedProcess: @unchecked Sendable {
    private let standardOutput: Int32
    private let standardError: Int32
    private let lifecycle: ChildProcessLifecycle

    init(executable: String, arguments: [String], environment: [String: String]?) throws {
        var outputPipe = try DescriptorPipe()
        do {
            var errorPipe = try DescriptorPipe()
            do {
                let spawnedProcessIdentifier = try Self.spawn(
                    executable: executable,
                    arguments: arguments,
                    environment: environment,
                    outputPipe: outputPipe,
                    errorPipe: errorPipe
                )
                lifecycle = ChildProcessLifecycle(processIdentifier: spawnedProcessIdentifier)
                outputPipe.closeWritingEnd()
                errorPipe.closeWritingEnd()
                standardOutput = outputPipe.takeReadingEnd()
                standardError = errorPipe.takeReadingEnd()
            } catch {
                errorPipe.close()
                throw error
            }
        } catch {
            outputPipe.close()
            throw error
        }
    }

    deinit {
        Darwin.close(standardOutput)
        Darwin.close(standardError)
    }

    func terminate() {
        lifecycle.terminateIfLive()
    }

    func drainStandardOutput(until stop: ProcessIOStop) -> Data {
        Self.drain(standardOutput, until: stop)
    }

    func drainStandardError(until stop: ProcessIOStop) -> Data {
        Self.drain(standardError, until: stop)
    }

    func waitUntilExit() -> Int32 {
        var status: Int32?
        while status == nil {
            status = lifecycle.pollExit()
            if status == nil { usleep(10_000) }
        }
        guard let status, status >= 0 else { return -1 }

        let terminationSignal = status & 0x7f
        return terminationSignal == 0 ? (status >> 8) & 0xff : terminationSignal
    }

    private static func drain(_ descriptor: Int32, until stop: ProcessIOStop) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)

        while !stop.isStopped {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count > 0 {
                data.append(contentsOf: buffer.prefix(Int(count)))
                continue
            }
            if count == 0 { return data }
            if errno == EINTR { continue }
            guard errno == EAGAIN || errno == EWOULDBLOCK else { return data }

            var pollDescriptor = pollfd(
                fd: descriptor,
                events: Int16(POLLIN | POLLHUP | POLLERR),
                revents: 0
            )
            var pollResult: Int32
            repeat {
                pollResult = Darwin.poll(&pollDescriptor, 1, 10)
            } while pollResult == -1 && errno == EINTR && !stop.isStopped
        }
        return data
    }

    private static func spawn(
        executable: String,
        arguments: [String],
        environment: [String: String]?,
        outputPipe: DescriptorPipe,
        errorPipe: DescriptorPipe
    ) throws -> pid_t {
        var fileActions: posix_spawn_file_actions_t?
        try check(posix_spawn_file_actions_init(&fileActions))
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        try check(posix_spawn_file_actions_adddup2(&fileActions, outputPipe.writingEnd, STDOUT_FILENO))
        try check(posix_spawn_file_actions_adddup2(&fileActions, errorPipe.writingEnd, STDERR_FILENO))
        let redirectedDescriptors = [
            outputPipe.readingEnd,
            errorPipe.readingEnd,
            outputPipe.writingEnd,
            errorPipe.writingEnd,
        ]
        guard redirectedDescriptors.allSatisfy({ $0 > STDERR_FILENO }) else {
            throw POSIXError(.EINVAL)
        }
        for descriptor in Set(redirectedDescriptors) {
            try check(posix_spawn_file_actions_addclose(&fileActions, descriptor))
        }

        var attributes: posix_spawnattr_t?
        try check(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        try check(posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)
        ))
        try check(posix_spawnattr_setpgroup(&attributes, 0))

        var processIdentifier: pid_t = 0
        let arguments = [executable] + arguments
        let result = executable.withCString { executablePointer in
            withCStringArray(arguments) { argumentPointers in
                if let environment {
                    let values = environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
                    return withCStringArray(values) { environmentPointers in
                        posix_spawn(
                            &processIdentifier,
                            executablePointer,
                            &fileActions,
                            &attributes,
                            argumentPointers,
                            environmentPointers
                        )
                    }
                }
                return posix_spawn(
                    &processIdentifier,
                    executablePointer,
                    &fileActions,
                    &attributes,
                    argumentPointers,
                    Darwin.environ
                )
            }
        }
        try check(result)
        return processIdentifier
    }

    private static func check(_ result: Int32) throws {
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EINVAL)
        }
    }

    private static func withCStringArray<Result>(
        _ values: [String],
        body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Result
    ) -> Result {
        var pointers: [UnsafeMutablePointer<CChar>?] = values.map { strdup($0) }
        pointers.append(nil)
        defer {
            for pointer in pointers where pointer != nil { free(pointer) }
        }
        return pointers.withUnsafeMutableBufferPointer { buffer in
            body(buffer.baseAddress!)
        }
    }
}

private struct DescriptorPipe {
    private var descriptors: [Int32]

    init() throws {
        descriptors = [0, 0]
        let result = descriptors.withUnsafeMutableBufferPointer { buffer in
            Darwin.pipe(buffer.baseAddress!)
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL) }
        do {
            descriptors = try PipeDescriptorRelocator.relocate(
                descriptors,
                duplicate: { source, minimum in
                    let replacement = fcntl(source, F_DUPFD_CLOEXEC, minimum)
                    guard replacement != -1 else {
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL)
                    }
                    return replacement
                },
                close: { descriptor in _ = Darwin.close(descriptor) }
            )
        } catch {
            descriptors = [-1, -1]
            throw error
        }
        do {
            let readFlags = fcntl(readingEnd, F_GETFL)
            guard readFlags != -1, fcntl(readingEnd, F_SETFL, readFlags | O_NONBLOCK) != -1 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL)
            }
            for descriptor in descriptors {
                guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) != -1 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL)
                }
            }
        } catch {
            close()
            throw error
        }
    }

    var readingEnd: Int32 { descriptors[0] }
    var writingEnd: Int32 { descriptors[1] }

    mutating func takeReadingEnd() -> Int32 {
        defer { descriptors[0] = -1 }
        return readingEnd
    }

    mutating func closeWritingEnd() {
        guard writingEnd >= 0 else { return }
        Darwin.close(writingEnd)
        descriptors[1] = -1
    }

    mutating func close() {
        if readingEnd >= 0 { Darwin.close(readingEnd) }
        if writingEnd >= 0 { Darwin.close(writingEnd) }
        descriptors = [-1, -1]
    }
}
