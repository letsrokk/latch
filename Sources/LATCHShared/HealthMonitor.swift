import Foundation

public struct HealthDecision: Sendable, Equatable {
    public let status: MountStatus
    public let shouldRecover: Bool
}

public enum HealthMonitor {
    public static func decision(
        definition: MountDefinition,
        observedSource: String?,
        result: ProbeResult,
        previous: MountStatus?,
        at date: Date
    ) -> HealthDecision {
        let classification = ProbeClassifier.classify(result)
        let sourceMatches = observedSource == definition.source
        let sourceConflicts = observedSource != nil && !sourceMatches
        let state = sourceConflicts ? MountState.probeError : classification.state
        let code: LATCHErrorCode = sourceConflicts ? .sourceMismatch : classification.code
        let detail = sourceConflicts ? "A different source owns the configured mountpoint." : classification.detail
        let status = MountStatus(
            definitionID: definition.id,
            observedSource: observedSource,
            observedMountPoint: definition.mountPoint,
            state: definition.enabled ? state : .disabled,
            lastProbe: date,
            lastStateChange: previous?.state == state ? (previous?.lastStateChange ?? date) : date,
            lastHealthyTime: state == .healthy ? date : previous?.lastHealthyTime,
            lastRecoveryTime: previous?.lastRecoveryTime,
            detail: detail,
            errorCode: code
        )
        return .init(status: status, shouldRecover: definition.enabled && !sourceConflicts && classification.shouldAutomaticallyRecover)
    }
}
