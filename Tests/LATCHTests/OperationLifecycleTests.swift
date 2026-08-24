import Foundation
import Testing
@testable import LATCHShared

@Suite("Queued operation lifecycle")
struct OperationLifecycleTests {
    @Test func onlyTerminalStatesAreTerminal() {
        #expect(!OperationState.accepted.isTerminal)
        #expect(!OperationState.running.isTerminal)
        #expect(OperationState.succeeded.isTerminal)
        #expect(OperationState.failed.isTerminal)
        #expect(OperationState.cancelled.isTerminal)
    }

    @Test func activeOperationOnTheSameMountConflicts() {
        let mountID = UUID()
        let active = snapshot(mountID: mountID, state: .running)

        #expect(OperationLifecycle.conflict(for: mountID, in: [active]) == active)
        #expect(OperationLifecycle.conflict(for: UUID(), in: [active]) == nil)
    }

    @Test func terminalOperationOnTheSameMountDoesNotConflict() {
        let mountID = UUID()

        #expect(OperationLifecycle.conflict(for: mountID, in: [snapshot(mountID: mountID, state: .failed)]) == nil)
    }

    @Test func failedResponseTakesPrecedenceOverObservedCancellation() {
        let completion = OperationLifecycle.completion(
            response: .failure(.verificationFailed, "Dependencies remain stopped."),
            interruption: .cancellationObserved
        )

        #expect(completion == .failed(.verificationFailed, "Dependencies remain stopped."))
    }

    @Test func cancellationWithoutFailurePublishesCancelled() {
        #expect(OperationLifecycle.completion(response: .accepted, interruption: .cancellationObserved) == .cancelled)
    }

    @Test func supersessionPublishesCancelled() {
        #expect(OperationLifecycle.completion(response: .accepted, interruption: .supersessionObserved) == .cancelled)
    }

    @Test func cancellationStopsManualWorkBeforeAnotherSideEffect() {
        #expect(!OperationLifecycle.workMayContinue(mountWorkIsCurrent: true, cancellationRequested: true))
        #expect(!OperationLifecycle.workMayContinue(mountWorkIsCurrent: false, cancellationRequested: false))
        #expect(OperationLifecycle.workMayContinue(mountWorkIsCurrent: true, cancellationRequested: false))
    }

    @Test func recoveryCancellationIsCancelledUnlessItFailedClosed() {
        #expect(OperationLifecycle.recoveryResponse(
            state: .stale,
            code: .verificationFailed,
            detail: "Cancelled before unmounting.",
            interruption: .cancellationObserved
        ) == .accepted)
        #expect(OperationLifecycle.recoveryResponse(
            state: .failedClosed,
            code: .verificationFailed,
            detail: "Dependencies remain stopped.",
            interruption: .cancellationObserved
        ) == .failure(.verificationFailed, "Dependencies remain stopped."))
    }

    @Test func unobservedLateCancellationCannotSuppressRecoveryFailure() {
        #expect(OperationLifecycle.recoveryResponse(
            state: .stale,
            code: .verificationFailed,
            detail: "Recovery failed.",
            interruption: .none
        ) == .failure(.verificationFailed, "Recovery failed."))
    }

    @Test func successfulResponsePublishesSucceeded() {
        #expect(OperationLifecycle.completion(response: .accepted, interruption: .none) == .succeeded)
    }

    @Test func retentionNeverPrunesActiveCancellationRequests() {
        let oldestActive = snapshot(state: .running, canCancel: false, updatedAt: Date(timeIntervalSince1970: 1))
        let oldestTerminal = snapshot(state: .cancelled, canCancel: false, updatedAt: Date(timeIntervalSince1970: 2))
        let newestTerminal = snapshot(state: .succeeded, canCancel: false, updatedAt: Date(timeIntervalSince1970: 3))

        let pruned = OperationLifecycle.pruningIDs(
            from: [oldestActive, oldestTerminal, newestTerminal],
            limit: 2
        )

        #expect(pruned == [oldestTerminal.id])
    }

    @Test func monitoringContinuesForEveryNonterminalState() {
        #expect(OperationMonitoringPolicy.shouldMonitor(.accepted))
        #expect(OperationMonitoringPolicy.shouldMonitor(.running))
        #expect(!OperationMonitoringPolicy.shouldMonitor(.succeeded))
        #expect(!OperationMonitoringPolicy.shouldMonitor(.failed))
        #expect(!OperationMonitoringPolicy.shouldMonitor(.cancelled))
    }

    @Test func transportRetryBackoffIsBoundedWithoutAnOverallDeadline() {
        #expect(OperationMonitoringPolicy.retryDelayMilliseconds(afterConsecutiveFailure: 1) == 250)
        #expect(OperationMonitoringPolicy.retryDelayMilliseconds(afterConsecutiveFailure: 5) == 4_000)
        #expect(OperationMonitoringPolicy.retryDelayMilliseconds(afterConsecutiveFailure: 20) == 5_000)
    }

    @Test func authoritativeSnapshotsReplaceStaleClientState() {
        let stale = snapshot(state: .running)
        let current = snapshot(state: .accepted)

        #expect(Set(OperationMonitoringPolicy.reconcile([current]).keys) == [current.id])
        #expect(OperationMonitoringPolicy.reconcile([current])[stale.id] == nil)
    }

    @Test func activeSnapshotIgnoresRetainedTerminalHistoryForTheMount() {
        let mountID = UUID()
        let terminal = snapshot(mountID: mountID, state: .succeeded)
        let active = snapshot(mountID: mountID, state: .running)

        #expect(OperationMonitoringPolicy.activeSnapshot(for: mountID, in: [terminal, active]) == active)
    }

    private func snapshot(
        mountID: UUID = UUID(),
        state: OperationState,
        canCancel: Bool = true,
        updatedAt: Date = Date()
    ) -> OperationSnapshot {
        OperationSnapshot(
            id: UUID(),
            mountID: mountID,
            action: .recover,
            state: state,
            canCancel: canCancel,
            updatedAt: updatedAt
        )
    }
}
