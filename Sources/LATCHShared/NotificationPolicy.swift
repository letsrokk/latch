import Foundation

public enum LATCHNotificationEvent: Sendable, Equatable {
    case recoverySucceeded
    case recoveryFailed
    case prolongedUnavailable
}

public enum NotificationPolicy {
    public static func event(previous: MountState?, current: MountState, unavailableSince: Date?, now: Date, unavailableThreshold: TimeInterval = 300) -> LATCHNotificationEvent? {
        if current == .failedClosed && previous != .failedClosed { return .recoveryFailed }
        if current == .healthy && previous == .recovering { return .recoverySucceeded }
        if [.networkUnavailable, .probeTimedOut].contains(current),
           let unavailableSince,
           now.timeIntervalSince(unavailableSince) >= unavailableThreshold {
            return .prolongedUnavailable
        }
        return nil
    }
}

/// Computes the bounded event-window transition used by the login agent.
/// The daemon response is authoritative: the returned window is exactly the
/// IDs in the current response, rather than an ever-growing cache.
public enum EventWindowTransition {
    public static func newEventIDs(previous: Set<UUID>, current: [LATCHEvent]) -> Set<UUID> {
        Set(current.map(\.id)).subtracting(previous)
    }

    public static func currentIDs(_ events: [LATCHEvent]) -> Set<UUID> {
        Set(events.map(\.id))
    }
}
