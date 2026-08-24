import Foundation
import Testing
@testable import LATCHShared

@Suite("Bounded process runner")
struct BoundedProcessRunnerTests {
    @Test func capturesStandardOutputAndErrorWithoutDeadlocking() async throws {
        let result = try await BoundedProcessRunner.run(
            executable: "/bin/sh",
            arguments: ["-c", "yes output | head -n 20000; yes error | head -n 20000 >&2"],
            timeout: .seconds(5)
        )

        #expect(result.terminationStatus == 0)
        #expect(result.standardOutput.hasPrefix("output\n"))
        #expect(result.standardError.hasPrefix("error\n"))
        #expect(result.standardOutput.count > 100_000)
        #expect(result.standardError.count > 100_000)
    }

    @Test func passesTheExactEnvironment() async throws {
        let result = try await BoundedProcessRunner.run(
            executable: "/bin/sh",
            arguments: ["-c", "printf %s \"$LATCH_PROCESS_TEST\""],
            environment: ["LATCH_PROCESS_TEST": "ready"],
            timeout: .seconds(2)
        )

        #expect(result.standardOutput == "ready")
    }

    @Test func terminatesAProcessAtTheDeadline() async {
        await #expect(throws: BoundedProcessError.timedOut) {
            _ = try await BoundedProcessRunner.run(
                executable: "/bin/sleep",
                arguments: ["10"],
                timeout: .milliseconds(30)
            )
        }
    }

    @Test func deadlineKillsADescendantThatRetainsTheOutputPipes() async {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("latch-descendant-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let clock = ContinuousClock()
        let started = clock.now

        await #expect(throws: BoundedProcessError.timedOut) {
            _ = try await BoundedProcessRunner.run(
                executable: "/bin/sh",
                arguments: [
                    "-c",
                    "(/bin/sleep 0.25; /usr/bin/touch \"$LATCH_DESCENDANT_MARKER\") & wait",
                ],
                environment: ["LATCH_DESCENDANT_MARKER": marker.path],
                timeout: .milliseconds(30)
            )
        }

        #expect(started.duration(to: clock.now) < .milliseconds(200))
        try? await Task.sleep(for: .milliseconds(300))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func deadlineDoesNotWaitForAnEscapedDescendantThatRetainsTheOutputPipes() async {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("latch-escaped-descendant-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let clock = ContinuousClock()
        let started = clock.now

        await #expect(throws: BoundedProcessError.timedOut) {
            _ = try await BoundedProcessRunner.run(
                executable: "/bin/sh",
                arguments: [
                    "-c",
                    #"/usr/bin/perl -MPOSIX=setsid -e 'setsid() >= 0 or die; select undef, undef, undef, 0.3; open my $handle, ">", $ENV{LATCH_ESCAPED_MARKER} or die $!; close $handle' &"#,
                ],
                environment: ["LATCH_ESCAPED_MARKER": marker.path],
                timeout: .milliseconds(30)
            )
        }

        #expect(started.duration(to: clock.now) < .milliseconds(200))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        try? await Task.sleep(for: .milliseconds(350))
        #expect(FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func pipeRelocationConsumesStandardDescriptorsAndReturnsOnlySafeEndpoints() throws {
        let recorder = DescriptorRelocationRecorder(replacements: [1: 7, 2: 8])

        let relocated = try PipeDescriptorRelocator.relocate(
            [1, 2],
            duplicate: recorder.duplicate,
            close: recorder.close
        )

        #expect(relocated == [7, 8])
        #expect(recorder.duplications == [
            .init(source: 1, minimum: 3),
            .init(source: 2, minimum: 3),
        ])
        #expect(recorder.closed == [1, 2])
    }

    @Test func failedPipeRelocationClosesEveryDescriptorItStillOwns() {
        let recorder = DescriptorRelocationRecorder(
            replacements: [1: 7],
            failureSource: 2
        )

        #expect(throws: POSIXError(.EMFILE)) {
            _ = try PipeDescriptorRelocator.relocate(
                [1, 2],
                duplicate: recorder.duplicate,
                close: recorder.close
            )
        }

        #expect(Set(recorder.closed) == Set([1, 2, 7]))
    }

    @Test func terminationSignalsNeitherProcessGroupNorPIDAfterSynchronizedPollReapsChild() {
        let recorder = ChildLifecycleSyscallRecorder(waitResults: [.reaped(0)])
        let lifecycle = ChildProcessLifecycle(
            processIdentifier: 4_242,
            poll: recorder.poll,
            signal: recorder.signal
        )

        lifecycle.terminateIfLive()

        #expect(recorder.signaledProcessIdentifiers.isEmpty)
        #expect(lifecycle.pollExit() == 0)
        #expect(recorder.pollCount == 1)
    }

    @Test func terminationSignalsOriginalProcessGroupAndPIDAndWaiterStillReapsChild() {
        let recorder = ChildLifecycleSyscallRecorder(
            waitResults: [.running, .reaped(9 << 8)]
        )
        let lifecycle = ChildProcessLifecycle(
            processIdentifier: 4_242,
            poll: recorder.poll,
            signal: recorder.signal
        )

        lifecycle.terminateIfLive()

        #expect(recorder.signaledProcessIdentifiers == [-4_242, 4_242])
        #expect(lifecycle.pollExit() == 9 << 8)
    }

    @Test func parentTaskCancellationTerminatesTheProcess() async {
        let task = Task {
            try await BoundedProcessRunner.run(
                executable: "/bin/sleep",
                arguments: ["10"],
                timeout: .seconds(20)
            )
        }
        try? await Task.sleep(for: .milliseconds(30))
        task.cancel()

        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    @Test(arguments: [("true\n", true), ("false\n", false)])
    func dockerRunningStateAcceptsOnlyCanonicalBooleanOutput(_ output: String, expected: Bool) throws {
        #expect(try DockerInspectionPolicy.runningState(from: output) == expected)
    }

    @Test(arguments: ["", "0", "yes", "true\nfalse"])
    func dockerRunningStateRejectsMissingOrAmbiguousOutput(_ output: String) {
        #expect(throws: DockerInspectionError.self) {
            _ = try DockerInspectionPolicy.runningState(from: output)
        }
    }

    @Test func dockerCommandUsesTheFirstDiscoveredExecutableAndExactEnvironment() async throws {
        let recorder = DockerInvocationRecorder(
            result: .init(terminationStatus: 0, standardOutput: "container-id\n", standardError: "")
        )
        let executor = DockerCommandExecutor(
            candidatePaths: ["/missing/docker", "/test/docker", "/later/docker"],
            isExecutable: { $0 == "/test/docker" || $0 == "/later/docker" },
            processRunner: recorder.run
        )
        let dependency = DockerContainerDependency(
            containerName: "media",
            dockerSocketPath: "/Users/test/.docker/run/docker.sock",
            composeFilePath: "/Users/test/compose.yaml"
        )

        let output = try await executor.execute(
            arguments: ["inspect", "--format", "{{.Id}}", "media"],
            dependency: dependency,
            timeout: .seconds(3)
        )

        #expect(output == "container-id\n")
        #expect(recorder.invocation == .init(
            executable: "/test/docker",
            arguments: ["inspect", "--format", "{{.Id}}", "media"],
            environment: [
                "DOCKER_HOST": "unix:///Users/test/.docker/run/docker.sock",
                "PATH": DockerCommandExecutor.restrictedPath,
                "COMPOSE_FILE": "/Users/test/compose.yaml",
            ],
            timeout: .seconds(3)
        ))
    }

    @Test func dockerCommandOmitsComposeEnvironmentWhenItIsNotConfigured() async throws {
        let recorder = DockerInvocationRecorder(
            result: .init(terminationStatus: 0, standardOutput: "", standardError: "")
        )
        let executor = DockerCommandExecutor(
            candidatePaths: ["/test/docker"],
            isExecutable: { _ in true },
            processRunner: recorder.run
        )

        _ = try await executor.execute(
            arguments: ["start", "media"],
            dependency: .init(
                containerName: "media",
                dockerSocketPath: "/var/run/docker.sock",
                composeFilePath: nil
            ),
            timeout: .seconds(5)
        )

        #expect(recorder.invocation?.environment == [
            "DOCKER_HOST": "unix:///var/run/docker.sock",
            "PATH": DockerCommandExecutor.restrictedPath,
        ])
    }

    @Test func missingDockerExecutableFailsBeforeProcessDispatch() async {
        let recorder = DockerInvocationRecorder(
            result: .init(terminationStatus: 0, standardOutput: "", standardError: "")
        )
        let executor = DockerCommandExecutor(
            candidatePaths: ["/missing/docker"],
            isExecutable: { _ in false },
            processRunner: recorder.run
        )

        await #expect(throws: DockerCommandExecutionError.missingRuntime) {
            _ = try await executor.execute(
                arguments: ["start", "media"],
                dependency: .init(containerName: "media", dockerSocketPath: "/var/run/docker.sock", composeFilePath: nil),
                timeout: .seconds(5)
            )
        }
        #expect(recorder.invocation == nil)
    }

    @Test func dockerTimeoutIsReportedAsATypedExecutionFailure() async {
        let executor = DockerCommandExecutor(
            candidatePaths: ["/test/docker"],
            isExecutable: { _ in true },
            processRunner: { _, _, _, _ in throw BoundedProcessError.timedOut }
        )

        await #expect(throws: DockerCommandExecutionError.timedOut) {
            _ = try await executor.execute(
                arguments: ["inspect", "media"],
                dependency: .init(containerName: "media", dockerSocketPath: "/var/run/docker.sock", composeFilePath: nil),
                timeout: .milliseconds(20)
            )
        }
    }

    @Test(arguments: [
        ("daemon unavailable", "daemon unavailable"),
        ("", "The Docker command failed."),
    ])
    func dockerFailurePreservesStderrOrUsesTheExistingFallback(
        standardError: String,
        expectedDetail: String
    ) async {
        let executor = DockerCommandExecutor(
            candidatePaths: ["/test/docker"],
            isExecutable: { _ in true },
            processRunner: { _, _, _, _ in
                .init(terminationStatus: 1, standardOutput: "", standardError: standardError)
            }
        )

        await #expect(throws: DockerCommandExecutionError.failed(expectedDetail)) {
            _ = try await executor.execute(
                arguments: ["stop", "media"],
                dependency: .init(containerName: "media", dockerSocketPath: "/var/run/docker.sock", composeFilePath: nil),
                timeout: .seconds(5)
            )
        }
    }
}

private struct DockerProcessInvocation: Equatable {
    let executable: String
    let arguments: [String]
    let environment: [String: String]
    let timeout: Duration
}

private struct DescriptorDuplication: Equatable {
    let source: Int32
    let minimum: Int32
}

private final class DescriptorRelocationRecorder: @unchecked Sendable {
    private let replacements: [Int32: Int32]
    private let failureSource: Int32?
    private(set) var duplications: [DescriptorDuplication] = []
    private(set) var closed: [Int32] = []

    init(replacements: [Int32: Int32], failureSource: Int32? = nil) {
        self.replacements = replacements
        self.failureSource = failureSource
    }

    func duplicate(_ source: Int32, _ minimum: Int32) throws -> Int32 {
        duplications.append(.init(source: source, minimum: minimum))
        if source == failureSource { throw POSIXError(.EMFILE) }
        return replacements[source]!
    }

    func close(_ descriptor: Int32) {
        closed.append(descriptor)
    }
}

private final class ChildLifecycleSyscallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var waitResults: [NonblockingChildWaitResult]
    private var signals: [pid_t] = []
    private var polls = 0

    init(waitResults: [NonblockingChildWaitResult]) {
        self.waitResults = waitResults
    }

    var signaledProcessIdentifiers: [pid_t] { lock.withLock { signals } }
    var pollCount: Int { lock.withLock { polls } }

    func poll(_ processIdentifier: pid_t) -> NonblockingChildWaitResult {
        lock.withLock {
            polls += 1
            return waitResults.removeFirst()
        }
    }

    func signal(_ processIdentifier: pid_t) {
        lock.withLock { signals.append(processIdentifier) }
    }
}

private final class DockerInvocationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let result: BoundedProcessResult
    private var storedInvocation: DockerProcessInvocation?

    init(result: BoundedProcessResult) {
        self.result = result
    }

    var invocation: DockerProcessInvocation? {
        lock.withLock { storedInvocation }
    }

    func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: Duration
    ) async throws -> BoundedProcessResult {
        lock.withLock {
            storedInvocation = .init(
                executable: executable,
                arguments: arguments,
                environment: environment,
                timeout: timeout
            )
        }
        return result
    }
}
