import Foundation
import Testing
@testable import LATCHShared

@Suite("Response deadlines")
struct ResponseDeadlineTests {
    @Test func returnsAReplyThatArrivesBeforeTimeout() async throws {
        let value: String = try await ResponseDeadline.wait(for: .seconds(1)) { reply in
            reply(.success("saved"))
        }

        #expect(value == "saved")
    }

    @Test func failsWhenAServiceNeverReplies() async {
        await #expect(throws: ResponseDeadlineError.timedOut) {
            let _: String = try await ResponseDeadline.wait(for: .milliseconds(20)) { _ in }
        }
    }

    @Test func cancelsThePendingServiceRequestOnTimeout() async {
        let cancelled = LockedFlag()

        await #expect(throws: ResponseDeadlineError.timedOut) {
            let _: String = try await ResponseDeadline.wait(
                for: .milliseconds(20),
                onTimeout: { cancelled.set() }
            ) { _ in }
        }
        #expect(cancelled.value)
    }

    @Test func cancelsThePendingServiceRequestWhenItsParentTaskIsCancelled() async {
        let cancelled = LockedFlag()
        let task = Task {
            let _: String = try await ResponseDeadline.wait(
                for: .seconds(10),
                onTimeout: { cancelled.set() }
            ) { _ in }
        }
        try? await Task.sleep(for: .milliseconds(20))
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(cancelled.value)
    }

    @Test func canJoinABoundedSideEffectAfterParentCancellation() async throws {
        let task = Task {
            try await ResponseDeadline.wait(
                for: .seconds(1),
                cancellationBehavior: .awaitResponse
            ) { reply in
                Task.detached {
                    try? await Task.sleep(for: .milliseconds(40))
                    reply(.success("completed"))
                }
            } as String
        }
        try? await Task.sleep(for: .milliseconds(10))
        task.cancel()

        #expect(try await task.value == "completed")
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool { lock.withLock { storage } }
    func set() { lock.withLock { storage = true } }
}
