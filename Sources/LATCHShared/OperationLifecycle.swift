import Foundation

public extension OperationState {
    var isTerminal: Bool {
        switch self {
        case .accepted, .running: false
        case .succeeded, .failed, .cancelled: true
        }
    }
}

public enum OperationCompletion: Sendable, Equatable {
    case succeeded
    case failed(LATCHErrorCode, String)
    case cancelled
}

public enum OperationInterruption: Sendable, Equatable {
    case none
    case cancellationObserved
    case supersessionObserved
}

public enum OperationLifecycle {
    public static func workMayContinue(
        mountWorkIsCurrent: Bool,
        cancellationRequested: Bool
    ) -> Bool {
        mountWorkIsCurrent && !cancellationRequested
    }

    public static func recoveryResponse(
        state: MountState,
        code: LATCHErrorCode,
        detail: String,
        interruption: OperationInterruption
    ) -> LATCHResponse {
        if interruption != .none && state != .failedClosed { return .accepted }
        return state == .healthy ? .accepted : .failure(code, detail)
    }

    public static func conflict(
        for mountID: UUID,
        in snapshots: some Sequence<OperationSnapshot>
    ) -> OperationSnapshot? {
        snapshots.first { $0.mountID == mountID && !$0.state.isTerminal }
    }

    public static func completion(
        response: LATCHResponse,
        interruption: OperationInterruption
    ) -> OperationCompletion {
        if case .failure(let code, let detail) = response {
            return .failed(code, detail)
        }
        return interruption == .none ? .succeeded : .cancelled
    }

    public static func pruningIDs(
        from snapshots: some Collection<OperationSnapshot>,
        limit: Int
    ) -> [UUID] {
        guard snapshots.count > limit else { return [] }
        return snapshots
            .filter { $0.state.isTerminal }
            .sorted { $0.updatedAt < $1.updatedAt }
            .prefix(snapshots.count - limit)
            .map(\.id)
    }
}

public enum OperationMonitoringPolicy {
    public static func shouldMonitor(_ state: OperationState) -> Bool {
        !state.isTerminal
    }

    public static func retryDelayMilliseconds(afterConsecutiveFailure failureCount: Int) -> Int {
        guard failureCount > 0 else { return 0 }
        let exponent = min(failureCount - 1, 5)
        return min(250 * (1 << exponent), 5_000)
    }

    public static func reconcile(_ snapshots: some Sequence<OperationSnapshot>) -> [UUID: OperationSnapshot] {
        Dictionary(snapshots.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
    }

    public static func activeSnapshot(
        for mountID: UUID,
        in snapshots: some Sequence<OperationSnapshot>
    ) -> OperationSnapshot? {
        snapshots.first { $0.mountID == mountID && shouldMonitor($0.state) }
    }
}
