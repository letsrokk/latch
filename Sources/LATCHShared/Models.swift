import Foundation

public struct LATCHConfiguration: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var servers: [NFSServerProfile]
    public var mounts: [MountDefinition]

    public init(schemaVersion: Int = 2, servers: [NFSServerProfile] = [], mounts: [MountDefinition] = []) {
        self.schemaVersion = schemaVersion
        self.servers = servers
        self.mounts = mounts
    }

    public func resolve(_ mount: MountDefinition) -> ResolvedMount? {
        guard let server = servers.first(where: { $0.id == mount.serverID }) else { return nil }
        return .init(definition: mount, server: server)
    }
}

public enum NetworkRuleCombinator: String, Codable, Sendable, Equatable {
    case all, any
}

public enum NetworkInterfaceType: String, Codable, Sendable, Equatable {
    case wifi, ethernet, other
}

public enum NetworkMountRule: Sendable, Equatable {
    case nfsServiceReachable
    case routeAvailable(String)
    case interfaceType(NetworkInterfaceType)
    case interfaceName(String)
    case tunnelInterfaceActive

    public var summary: String {
        switch self {
        case .nfsServiceReachable: "NFS service reachable on TCP port 2049"
        case .routeAvailable(let cidr): "Route available for \(cidr)"
        case .interfaceType(.wifi): "Active Wi-Fi interface"
        case .interfaceType(.ethernet): "Active Ethernet interface"
        case .interfaceType(.other): "Active other network interface"
        case .interfaceName(let name): "Active interface \(name)"
        case .tunnelInterfaceActive: "Active tunnel interface"
        }
    }
}

extension NetworkMountRule: Codable {
    private enum CodingKeys: String, CodingKey { case kind, value }
    private enum Kind: String, Codable { case nfsServiceReachable, routeAvailable, interfaceType, interfaceName, tunnelInterfaceActive }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(Kind.self, forKey: .kind) {
        case .nfsServiceReachable: self = .nfsServiceReachable
        case .routeAvailable: self = .routeAvailable(try values.decode(String.self, forKey: .value))
        case .interfaceType: self = .interfaceType(try values.decode(NetworkInterfaceType.self, forKey: .value))
        case .interfaceName: self = .interfaceName(try values.decode(String.self, forKey: .value))
        case .tunnelInterfaceActive: self = .tunnelInterfaceActive
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .nfsServiceReachable: try values.encode(Kind.nfsServiceReachable, forKey: .kind)
        case .routeAvailable(let cidr):
            try values.encode(Kind.routeAvailable, forKey: .kind)
            try values.encode(cidr, forKey: .value)
        case .interfaceType(let type):
            try values.encode(Kind.interfaceType, forKey: .kind)
            try values.encode(type, forKey: .value)
        case .interfaceName(let name):
            try values.encode(Kind.interfaceName, forKey: .kind)
            try values.encode(name, forKey: .value)
        case .tunnelInterfaceActive: try values.encode(Kind.tunnelInterfaceActive, forKey: .kind)
        }
    }
}

public struct NetworkMountRuleSet: Codable, Sendable, Equatable {
    public var combinator: NetworkRuleCombinator
    public var rules: [NetworkMountRule]

    public init(combinator: NetworkRuleCombinator = .all, rules: [NetworkMountRule] = []) {
        self.combinator = combinator
        self.rules = rules
    }

    private enum CodingKeys: String, CodingKey { case combinator, rules, requiredNetworkNames }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        combinator = try values.decodeIfPresent(NetworkRuleCombinator.self, forKey: .combinator) ?? .all
        if let rules = try values.decodeIfPresent([NetworkMountRule].self, forKey: .rules) {
            self.rules = rules
        } else {
            // The retired placeholder was not enforceable and could contain arbitrary SSIDs.
            // Preserve schema-v2 readability without treating those values as interface names.
            _ = try values.decodeIfPresent([String].self, forKey: .requiredNetworkNames)
            self.rules = []
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(combinator, forKey: .combinator)
        try values.encode(rules, forKey: .rules)
    }
}

public struct WakeOnLANSettings: Codable, Sendable, Equatable {
    public var macAddress: String
    public var broadcastAddress: String?
    public var port: UInt16

    public init(macAddress: String, broadcastAddress: String? = nil, port: UInt16 = 9) {
        self.macAddress = macAddress
        self.broadcastAddress = broadcastAddress
        self.port = port
    }
}

public struct NFSServerProfile: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var hostname: String
    public var networkMountRules: NetworkMountRuleSet
    public var wakeOnLAN: WakeOnLANSettings?

    public init(id: UUID = UUID(), name: String, hostname: String, networkMountRules: NetworkMountRuleSet = .init(), wakeOnLAN: WakeOnLANSettings? = nil) {
        self.id = id
        self.name = name
        self.hostname = hostname
        self.networkMountRules = networkMountRules
        self.wakeOnLAN = wakeOnLAN
    }
}

public enum PostMountAction: Codable, Sendable, Equatable {
    case revealInFinder
    case openApplication(bundleIdentifier: String, applicationURL: String?)
    case openRelativePath(String)
}

public struct ResolvedMount: Sendable, Equatable, Identifiable {
    public let definition: MountDefinition
    public let server: NFSServerProfile
    public var id: UUID { definition.id }
    public var hostname: String { server.hostname }
    public var source: String { "\(hostname):\(definition.exportPath)" }
}

public extension LATCHEvent {
    static func newestFirst(_ events: [LATCHEvent]) -> [LATCHEvent] {
        events.sorted { lhs, rhs in
            if lhs.date == rhs.date { return lhs.id.uuidString < rhs.id.uuidString }
            return lhs.date > rhs.date
        }
    }
}

public struct MountDefinition: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var displayName: String
    public var serverID: UUID
    public var exportPath: String
    public var mountPoint: String
    public var mountOptions: NFSOptions
    public var enabled: Bool
    public var probeIntervalSeconds: Int
    public var probeTimeoutSeconds: Int
    public var recoveryCooldownSeconds: Int
    public var recoveryDependencies: [RecoveryDependency]
    public var postMountActions: [PostMountAction]
    // This is a source-compatibility bridge for in-memory legacy callers only. It is never encoded.
    private var legacyHostname: String?

    public init(
        id: UUID = UUID(),
        displayName: String,
        serverID: UUID,
        exportPath: String,
        mountPoint: String,
        mountOptions: NFSOptions = .recommended,
        enabled: Bool = true,
        probeIntervalSeconds: Int = 30,
        probeTimeoutSeconds: Int = 3,
        recoveryCooldownSeconds: Int = 600,
        recoveryDependencies: [RecoveryDependency] = [],
        postMountActions: [PostMountAction] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.serverID = serverID
        self.exportPath = exportPath
        self.mountPoint = mountPoint
        self.mountOptions = mountOptions
        self.enabled = enabled
        self.probeIntervalSeconds = probeIntervalSeconds
        self.probeTimeoutSeconds = probeTimeoutSeconds
        self.recoveryCooldownSeconds = recoveryCooldownSeconds
        self.recoveryDependencies = recoveryDependencies
        self.postMountActions = postMountActions
        legacyHostname = nil
    }

    public init(
        id: UUID = UUID(),
        displayName: String,
        host: String,
        exportPath: String,
        mountPoint: String,
        mountOptions: NFSOptions = .recommended,
        enabled: Bool = true,
        probeIntervalSeconds: Int = 30,
        probeTimeoutSeconds: Int = 3,
        recoveryCooldownSeconds: Int = 600,
        recoveryDependencies: [RecoveryDependency] = [],
        postMountActions: [PostMountAction] = []
    ) {
        self.init(id: id, displayName: displayName, serverID: UUID(), exportPath: exportPath, mountPoint: mountPoint, mountOptions: mountOptions, enabled: enabled, probeIntervalSeconds: probeIntervalSeconds, probeTimeoutSeconds: probeTimeoutSeconds, recoveryCooldownSeconds: recoveryCooldownSeconds, recoveryDependencies: recoveryDependencies, postMountActions: postMountActions)
        legacyHostname = host
    }

    public var host: String { legacyHostname ?? "" }
    public var source: String { legacyHostname.map { "\($0):\(exportPath)" } ?? "" }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, serverID, exportPath, mountPoint, mountOptions, enabled, probeIntervalSeconds, probeTimeoutSeconds, recoveryCooldownSeconds, recoveryDependencies, postMountActions
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        displayName = try values.decode(String.self, forKey: .displayName)
        serverID = try values.decode(UUID.self, forKey: .serverID)
        exportPath = try values.decode(String.self, forKey: .exportPath)
        mountPoint = try values.decode(String.self, forKey: .mountPoint)
        mountOptions = try values.decode(NFSOptions.self, forKey: .mountOptions)
        enabled = try values.decode(Bool.self, forKey: .enabled)
        probeIntervalSeconds = try values.decode(Int.self, forKey: .probeIntervalSeconds)
        probeTimeoutSeconds = try values.decode(Int.self, forKey: .probeTimeoutSeconds)
        recoveryCooldownSeconds = try values.decode(Int.self, forKey: .recoveryCooldownSeconds)
        recoveryDependencies = try values.decodeIfPresent([RecoveryDependency].self, forKey: .recoveryDependencies) ?? []
        postMountActions = try values.decodeIfPresent([PostMountAction].self, forKey: .postMountActions) ?? []
        legacyHostname = nil
    }

    public func resolved(using server: NFSServerProfile) -> MountDefinition {
        var resolved = self
        resolved.legacyHostname = server.hostname
        return resolved
    }

    public static func == (lhs: MountDefinition, rhs: MountDefinition) -> Bool {
        lhs.id == rhs.id && lhs.displayName == rhs.displayName && lhs.serverID == rhs.serverID && lhs.exportPath == rhs.exportPath && lhs.mountPoint == rhs.mountPoint && lhs.mountOptions == rhs.mountOptions && lhs.enabled == rhs.enabled && lhs.probeIntervalSeconds == rhs.probeIntervalSeconds && lhs.probeTimeoutSeconds == rhs.probeTimeoutSeconds && lhs.recoveryCooldownSeconds == rhs.recoveryCooldownSeconds && lhs.recoveryDependencies == rhs.recoveryDependencies && lhs.postMountActions == rhs.postMountActions
    }
}

public enum AutomaticRetryKind: String, Codable, Sendable, Equatable {
    case missingMount
    case staleRecovery
}

public enum AutomaticRetryDisposition: Sendable, Equatable {
    case schedule
    case preserve
    case clear
}

public struct AutomaticRetryState: Codable, Sendable, Equatable {
    public var kind: AutomaticRetryKind
    public var failures: Int
    public var nextAttempt: Date

    public init(kind: AutomaticRetryKind, failures: Int, nextAttempt: Date) {
        self.kind = kind
        self.failures = failures
        self.nextAttempt = nextAttempt
    }

    public static func missingMountInterval(afterFailures failures: Int) -> TimeInterval {
        [60, 120, 300, 600, 1_800][min(max(failures, 0), 4)]
    }

    public static func staleInterval(recoveryCooldownSeconds: Int, afterFailures failures: Int) -> TimeInterval {
        min(Double(max(recoveryCooldownSeconds, 1)) * pow(2, Double(max(failures, 0))), 3_600)
    }

    public static func shouldSchedule(after code: LATCHErrorCode) -> Bool {
        disposition(after: code) == .schedule
    }

    public static func disposition(after code: LATCHErrorCode) -> AutomaticRetryDisposition {
        switch code {
        case .networkUnavailable: .preserve
        case .permissionDenied, .tccDenied, .sourceMismatch, .mountConflict: .clear
        case .none: .preserve
        default: .schedule
        }
    }

    public static func recoveryDisposition(state: MountState, code: LATCHErrorCode) -> AutomaticRetryDisposition {
        if state == .healthy { return .clear }
        if state == .cooldown && code == .none { return .schedule }
        return disposition(after: code)
    }
}

public struct RecoveryDependency: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var enabled: Bool
    public var stopTimeoutSeconds: Int
    public var kind: RecoveryDependencyKind

    public init(id: UUID = UUID(), enabled: Bool = true, stopTimeoutSeconds: Int = 30, kind: RecoveryDependencyKind) {
        self.id = id
        self.enabled = enabled
        self.stopTimeoutSeconds = stopTimeoutSeconds
        self.kind = kind
    }
}

public enum RecoveryDependencyKind: Codable, Sendable, Equatable {
    case dockerContainer(DockerContainerDependency)
    case macApplication(MacApplicationDependency)
}

public struct DockerContainerDependency: Codable, Sendable, Equatable {
    public var containerName: String
    public var dockerSocketPath: String
    public var composeFilePath: String?

    public init(containerName: String, dockerSocketPath: String, composeFilePath: String?) {
        self.containerName = containerName
        self.dockerSocketPath = dockerSocketPath
        self.composeFilePath = composeFilePath
    }
}

public struct MacApplicationDependency: Codable, Sendable, Equatable {
    public var bundleIdentifier: String
    public var applicationURL: String?
    public var forceQuitAfterTimeout: Bool

    public init(bundleIdentifier: String, applicationURL: String?, forceQuitAfterTimeout: Bool) {
        self.bundleIdentifier = bundleIdentifier
        self.applicationURL = applicationURL
        self.forceQuitAfterTimeout = forceQuitAfterTimeout
    }
}

public struct ExternalMountSnapshot: Codable, Sendable, Equatable, Identifiable {
    public var source: String
    public var mountPoint: String
    public var fileSystemType: String
    public var options: [String]
    public var id: String { "\(source)@\(mountPoint)" }

    public init(source: String, mountPoint: String, fileSystemType: String, options: [String]) {
        self.source = source
        self.mountPoint = mountPoint
        self.fileSystemType = fileSystemType
        self.options = options
    }
}

/// A local `_nfs._tcp` Bonjour announcement. It is a suggestion only; it never creates configuration.
public struct DiscoveredNFSServer: Codable, Sendable, Equatable, Identifiable {
    public var name: String
    /// Kept optional for backward-compatible decoding. Live discovery publishes only resolved hosts.
    public var hostname: String?
    public var port: UInt16
    public var id: String { "\(name.lowercased())@\(hostname?.lowercased() ?? "service"):\(port)" }

    public init(name: String, hostname: String? = nil, port: UInt16 = 2049) {
        self.name = name
        self.hostname = hostname
        self.port = port
    }
}

public enum MountState: String, Codable, Sendable, CaseIterable {
    case disabled, unmounted, mounting, healthy, networkUnavailable, probeTimedOut
    case probeError, stale, recovering, cooldown, failedClosed, waitingForRules, waking, retryScheduled
}

public enum LATCHErrorCode: String, Codable, Sendable {
    case none, daemonOffline, unauthorized, networkUnavailable, probeTimeout
    case permissionDenied, tccDenied, staleHandle, sourceMismatch, mountConflict
    case dependencyUnavailable, dependencyStopFailed, unmountFailed, remountFailed
    case verificationFailed, malformedRequest, oversizedRequest, unsupportedVersion
}

public struct MountStatus: Codable, Sendable, Equatable, Identifiable {
    public var definitionID: UUID
    public var observedSource: String?
    public var observedMountPoint: String
    public var state: MountState
    public var lastProbe: Date?
    public var lastStateChange: Date
    public var lastHealthyTime: Date?
    public var lastRecoveryTime: Date?
    public var detail: String
    public var errorCode: LATCHErrorCode
    public var nextAutomaticAttempt: Date?
    public var unmetRuleSummaries: [String]
    public var id: UUID { definitionID }

    public init(definitionID: UUID, observedSource: String?, observedMountPoint: String, state: MountState, lastProbe: Date?, lastStateChange: Date, lastHealthyTime: Date?, lastRecoveryTime: Date?, detail: String, errorCode: LATCHErrorCode, nextAutomaticAttempt: Date? = nil, unmetRuleSummaries: [String] = []) {
        self.definitionID = definitionID
        self.observedSource = observedSource
        self.observedMountPoint = observedMountPoint
        self.state = state
        self.lastProbe = lastProbe
        self.lastStateChange = lastStateChange
        self.lastHealthyTime = lastHealthyTime
        self.lastRecoveryTime = lastRecoveryTime
        self.detail = detail
        self.errorCode = errorCode
        self.nextAutomaticAttempt = nextAutomaticAttempt
        self.unmetRuleSummaries = unmetRuleSummaries
    }

    private enum CodingKeys: String, CodingKey {
        case definitionID, observedSource, observedMountPoint, state, lastProbe, lastStateChange, lastHealthyTime, lastRecoveryTime, detail, errorCode, nextAutomaticAttempt, unmetRuleSummaries
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        definitionID = try values.decode(UUID.self, forKey: .definitionID)
        observedSource = try values.decodeIfPresent(String.self, forKey: .observedSource)
        observedMountPoint = try values.decode(String.self, forKey: .observedMountPoint)
        state = try values.decode(MountState.self, forKey: .state)
        lastProbe = try values.decodeIfPresent(Date.self, forKey: .lastProbe)
        lastStateChange = try values.decode(Date.self, forKey: .lastStateChange)
        lastHealthyTime = try values.decodeIfPresent(Date.self, forKey: .lastHealthyTime)
        lastRecoveryTime = try values.decodeIfPresent(Date.self, forKey: .lastRecoveryTime)
        detail = try values.decode(String.self, forKey: .detail)
        errorCode = try values.decode(LATCHErrorCode.self, forKey: .errorCode)
        nextAutomaticAttempt = try values.decodeIfPresent(Date.self, forKey: .nextAutomaticAttempt)
        unmetRuleSummaries = try values.decodeIfPresent([String].self, forKey: .unmetRuleSummaries) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(definitionID, forKey: .definitionID)
        try values.encodeIfPresent(observedSource, forKey: .observedSource)
        try values.encode(observedMountPoint, forKey: .observedMountPoint)
        try values.encode(state, forKey: .state)
        try values.encodeIfPresent(lastProbe, forKey: .lastProbe)
        try values.encode(lastStateChange, forKey: .lastStateChange)
        try values.encodeIfPresent(lastHealthyTime, forKey: .lastHealthyTime)
        try values.encodeIfPresent(lastRecoveryTime, forKey: .lastRecoveryTime)
        try values.encode(detail, forKey: .detail)
        try values.encode(errorCode, forKey: .errorCode)
        try values.encodeIfPresent(nextAutomaticAttempt, forKey: .nextAutomaticAttempt)
        try values.encode(unmetRuleSummaries, forKey: .unmetRuleSummaries)
    }
}

public struct LATCHEvent: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var date: Date
    public var mountID: UUID?
    public var state: MountState?
    public var code: LATCHErrorCode
    public var detail: String

    public init(id: UUID = UUID(), date: Date, mountID: UUID?, state: MountState?, code: LATCHErrorCode, detail: String) {
        self.id = id
        self.date = date
        self.mountID = mountID
        self.state = state
        self.code = code
        self.detail = detail
    }
}
