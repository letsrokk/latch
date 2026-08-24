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
}
