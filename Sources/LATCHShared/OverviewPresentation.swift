import Foundation

public enum LATCHSetupRequirement: String, Sendable, Equatable, CaseIterable {
    case privilegedDaemon
    case loginAgent

    public var title: String {
        switch self {
        case .privilegedDaemon: "Approve privileged daemon"
        case .loginAgent: "Enable login agent"
        }
    }
}

public struct LATCHOverview: Sendable, Equatable {
    public let setupRequirements: [LATCHSetupRequirement]
    public let daemonOnline: Bool
    public let totalManaged: Int
    public let healthy: Int
    public let needsAttention: Int
    public let paused: Int
    public let activeManaged: Int

    public init(definitions: [MountDefinition], statuses: [MountStatus], services: ServiceStatusSnapshot) {
        var requirements: [LATCHSetupRequirement] = []
        if !services.daemonAuthorized { requirements.append(.privilegedDaemon) }
        if !services.agentAuthorized { requirements.append(.loginAgent) }
        setupRequirements = requirements
        daemonOnline = services.daemonOnline
        totalManaged = definitions.count

        let states = Dictionary(uniqueKeysWithValues: statuses.map { ($0.definitionID, $0.state) })
        healthy = definitions.count { states[$0.id] == .healthy }
        paused = definitions.count { !$0.enabled || states[$0.id] == .disabled }
        activeManaged = totalManaged - paused
        needsAttention = definitions.count {
            guard let state = states[$0.id] else { return false }
            return [.networkUnavailable, .probeTimedOut, .probeError, .stale, .failedClosed].contains(state)
        }
    }
}

public struct LATCHMenuHeaderPresentation: Sendable, Equatable {
    public let text: String

    public init(overview: LATCHOverview) {
        if !overview.daemonOnline {
            text = "Daemon offline"
        } else if overview.needsAttention > 0 {
            let noun = overview.needsAttention == 1 ? "volume needs" : "volumes need"
            text = "\(overview.needsAttention) \(noun) attention"
        } else if overview.totalManaged == 0 {
            text = "Ready for a managed volume"
        } else {
            let activeNoun = overview.activeManaged == 1 ? "volume is" : "volumes are"
            let health = "\(overview.healthy) of \(overview.activeManaged) \(activeNoun) healthy."
            if overview.paused == 0 {
                text = health
            } else {
                let pausedNoun = overview.paused == 1 ? "volume is" : "volumes are"
                text = "\(health) \(overview.paused) \(pausedNoun) paused."
            }
        }
    }
}

public struct LATCHMenuBarPresentation: Sendable, Equatable {
    public let symbol: String

    public init(
        services: ServiceStatusSnapshot,
        statuses: [MountStatus],
        hasLoadedServiceStatus: Bool
    ) {
        if services.daemonAuthorized && !hasLoadedServiceStatus {
            symbol = "externaldrive"
        } else if !services.daemonOnline || !services.daemonAuthorized {
            symbol = "externaldrive.badge.xmark"
        } else if statuses.contains(where: { [.stale, .recovering, .failedClosed].contains($0.state) }) {
            symbol = "exclamationmark.arrow.triangle.2.circlepath"
        } else if statuses.contains(where: { [.networkUnavailable, .probeTimedOut, .probeError].contains($0.state) }) {
            symbol = "exclamationmark.triangle"
        } else {
            symbol = "externaldrive.connected.to.line.below"
        }
    }
}

public enum LATCHActivitySectionPresentation: Sendable, Equatable {
    case empty
    case events([LATCHEvent])

    public init(events: [LATCHEvent]) {
        self = events.isEmpty ? .empty : .events(Array(events.prefix(3)))
    }
}

public enum LATCHActivityIndicator: Sendable, Equatable {
    case healthy
    case paused
    case progress
    case waiting
    case issue
}

public struct LATCHActivityEventPresentation: Sendable, Equatable {
    public let summary: String
    public let stateDetail: String
    public let indicator: LATCHActivityIndicator

    public init(summary: String, stateDetail: String, indicator: LATCHActivityIndicator) {
        self.summary = summary
        self.stateDetail = stateDetail
        self.indicator = indicator
    }

    public init(event: LATCHEvent) {
        summary = event.detail
        switch event.state {
        case .healthy:
            stateDetail = "Metadata and directory probes succeeded."
            indicator = .healthy
        case .networkUnavailable:
            stateDetail = "The NFS server did not respond to the latest check."
            indicator = .issue
        case .disabled:
            stateDetail = "Paused by configuration."
            indicator = .paused
        case .recovering:
            stateDetail = "Guarded recovery is in progress."
            indicator = .progress
        case .failedClosed:
            stateDetail = "Dependencies remain stopped for safety."
            indicator = .issue
        case .mounting, .waking:
            stateDetail = event.state?.displayName ?? "LATCH service event"
            indicator = .progress
        case .waitingForRules:
            stateDetail = event.state?.displayName ?? "LATCH service event"
            indicator = .waiting
        case let state?:
            stateDetail = state.displayName
            indicator = .issue
        case nil:
            stateDetail = "LATCH service event"
            indicator = .issue
        }
    }
}

public struct LATCHEmptyStatePresentation: Sendable, Equatable {
    public let symbol: String
    public let title: String
    public let detail: String

    public init(symbol: String, title: String, detail: String) {
        self.symbol = symbol
        self.title = title
        self.detail = detail
    }

    public static let managedMounts = Self(
        symbol: "externaldrive.badge.plus",
        title: "No managed mounts",
        detail: "Add a managed NFS mount to begin monitoring and automatic recovery."
    )

    public static let servers = Self(
        symbol: "server.rack",
        title: "No servers",
        detail: "Add an NFS server before configuring managed mounts."
    )

    public static let externalMounts = Self(
        symbol: "eye.slash",
        title: "No external NFS mounts",
        detail: "External mounts appear here automatically when macOS reports them."
    )

    public static let activity = Self(
        symbol: "clock.arrow.circlepath",
        title: "No recent activity",
        detail: "Health checks and recovery events will appear here."
    )
}

public enum MountCheckSchedule {
    public static func isDue(lastCheck: Date?, mountedAt: Date?, now: Date, interval: Int, mountGrace: TimeInterval) -> Bool {
        if let mountedAt, lastCheck == nil {
            return now.timeIntervalSince(mountedAt) >= mountGrace
        }
        return lastCheck.map { now.timeIntervalSince($0) >= Double(interval) } ?? true
    }
}

public extension MountState {
    var displayName: String {
        switch self {
        case .disabled: "Monitoring paused"
        case .unmounted: "Not mounted"
        case .mounting: "Mounting"
        case .healthy: "Healthy"
        case .networkUnavailable: "Server unavailable"
        case .probeTimedOut: "Check timed out"
        case .probeError: "Check failed"
        case .stale: "Stale file handle"
        case .recovering: "Recovering"
        case .cooldown: "Recovery cooldown"
        case .failedClosed: "Recovery failed closed"
        case .waitingForRules: "Waiting for network rules"
        case .waking: "Waking server"
        case .retryScheduled: "Retry scheduled"
        }
    }
}

#if DEBUG
public struct LATCHPreviewFixture: Sendable {
    public let serviceStatus: ServiceStatusSnapshot
    public let configuration: LATCHConfiguration
    public let statuses: [MountStatus]
    public let externalMounts: [ExternalMountSnapshot]
    public let events: [LATCHEvent]

    public static func operationalOverview(at date: Date = Date()) -> LATCHPreviewFixture {
        let nas = NFSServerProfile(name: "Media NAS", hostname: "192.168.1.20")
        let downloadsServer = NFSServerProfile(name: "Downloads NAS", hostname: "192.168.1.30")
        let media = MountDefinition(displayName: "Media", serverID: nas.id, exportPath: "/exports/media", mountPoint: "/Volumes/Media")
        let music = MountDefinition(displayName: "Music", serverID: nas.id, exportPath: "/exports/music", mountPoint: "/Volumes/Music")
        let downloads = MountDefinition(displayName: "Downloads", serverID: downloadsServer.id, exportPath: "/exports/downloads", mountPoint: "/Volumes/Downloads", enabled: false)
        let definitions = [media, music, downloads]
        let states: [(MountDefinition, MountState, LATCHErrorCode, String)] = [
            (media, .healthy, .none, "Metadata and directory probes succeeded."),
            (music, .networkUnavailable, .networkUnavailable, "The NFS server is not reachable."),
            (downloads, .disabled, .none, "Monitoring is disabled."),
        ]
        let statuses = states.map { definition, state, code, detail in
            MountStatus(
                definitionID: definition.id,
                observedSource: state == .disabled ? nil : (definition.id == downloads.id ? "192.168.1.30:\(definition.exportPath)" : "192.168.1.20:\(definition.exportPath)"),
                observedMountPoint: definition.mountPoint,
                state: state,
                lastProbe: date.addingTimeInterval(-120),
                lastStateChange: date.addingTimeInterval(-600),
                lastHealthyTime: state == .healthy ? date.addingTimeInterval(-120) : date.addingTimeInterval(-3_600),
                lastRecoveryTime: nil,
                detail: detail,
                errorCode: code
            )
        }
        let events = [
            LATCHEvent(date: date.addingTimeInterval(-120), mountID: music.id, state: .networkUnavailable, code: .networkUnavailable, detail: "Music became unavailable."),
            LATCHEvent(date: date.addingTimeInterval(-300), mountID: media.id, state: .healthy, code: .none, detail: "Media is healthy."),
            LATCHEvent(date: date.addingTimeInterval(-1_200), mountID: downloads.id, state: .disabled, code: .none, detail: "Monitoring paused for Downloads."),
        ]
        return LATCHPreviewFixture(
            serviceStatus: .init(daemonOnline: true, daemonAuthorized: true, agentAuthorized: true, agentOnline: true, networkVolumesPermissionVerified: false),
            configuration: LATCHConfiguration(servers: [nas, downloadsServer], mounts: definitions),
            statuses: statuses,
            externalMounts: [],
            events: events
        )
    }
}
#endif
