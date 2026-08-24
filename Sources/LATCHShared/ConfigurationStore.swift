import Darwin
import Foundation
import OSLog

public protocol RecoveryStateWriting: Sendable {
    func write(_ data: Data, to url: URL) throws
}

public enum RuntimePersistencePolicy {
    public static func requiresImmediateWrite(previous: MountStatus?, next: MountStatus) -> Bool {
        previous?.state != next.state || previous?.errorCode != next.errorCode
    }
}

struct AtomicRecoveryStateWriter: RecoveryStateWriting {
    func write(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        _ = chmod(directory.path, mode_t(0o700))
        try data.write(to: url, options: [.atomic])
        guard chmod(url.path, mode_t(0o600)) == 0 else { throw POSIXError(.EACCES) }
    }
}

private let persistenceLogger = Logger(subsystem: LATCHIdentity.bundleIdentifier, category: "persistence")

public struct ConfigurationStore: Sendable {
    public let directory: URL
    public var configurationURL: URL { directory.appendingPathComponent("config.json") }
    public var lastKnownGoodURL: URL { directory.appendingPathComponent("config.last-known-good.json") }
    public var schema1RollbackURL: URL { directory.appendingPathComponent("config.schema-1-rollback.json") }

    public init() {
        self.init(directory: LATCHIdentity.applicationSupportDirectory)
    }

    public init(directory: URL) {
        self.directory = directory
    }

    public func load() throws -> LATCHConfiguration {
        do {
            return try loadConfiguration(from: configurationURL)
        } catch {
            return try loadConfiguration(from: lastKnownGoodURL)
        }
    }

    private func loadConfiguration(from url: URL) throws -> LATCHConfiguration {
        let data = try Data(contentsOf: url)
        let configuration = try decodeAndValidate(data)
        let decoder = JSONDecoder()
        let version = try decoder.decode(SchemaVersion.self, from: data).schemaVersion
        if version == 1 { try writeMigration(configuration, legacyData: data) }
        return configuration
    }

    private func decodeAndValidate(_ data: Data) throws -> LATCHConfiguration {
        let decoder = JSONDecoder()
        let version = try decoder.decode(SchemaVersion.self, from: data).schemaVersion
        let configuration: LATCHConfiguration
        switch version {
        case 2: configuration = try decoder.decode(LATCHConfiguration.self, from: data)
        case 1: configuration = try migrate(try decoder.decode(LegacyConfiguration.self, from: data))
        default: throw ConfigurationValidationError.unsupportedSchemaVersion
        }
        try ConfigurationValidator().validate(configuration, liveMounts: [])
        return configuration
    }

    private func migrate(_ legacy: LegacyConfiguration) throws -> LATCHConfiguration {
        var servers: [NFSServerProfile] = []
        var identifiersByHostname: [String: UUID] = [:]
        let mounts = legacy.mounts.map { mount -> MountDefinition in
            let identifier: UUID
            if let existing = identifiersByHostname[mount.host] {
                identifier = existing
            } else {
                identifier = UUID()
                identifiersByHostname[mount.host] = identifier
                servers.append(.init(id: identifier, name: mount.host, hostname: mount.host))
            }
            return .init(id: mount.id, displayName: mount.displayName, serverID: identifier, exportPath: mount.exportPath, mountPoint: mount.mountPoint, mountOptions: mount.mountOptions, enabled: mount.enabled, probeIntervalSeconds: mount.probeIntervalSeconds, probeTimeoutSeconds: mount.probeTimeoutSeconds, recoveryCooldownSeconds: mount.recoveryCooldownSeconds, recoveryDependencies: mount.recoveryDependencies)
        }
        return .init(servers: servers, mounts: mounts)
    }

    private func writeMigration(_ configuration: LATCHConfiguration, legacyData: Data) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if !manager.fileExists(atPath: schema1RollbackURL.path) {
            try legacyData.write(to: schema1RollbackURL, options: [.atomic])
            _ = chmod(schema1RollbackURL.path, mode_t(0o600))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(configuration)
        try data.write(to: configurationURL, options: [.atomic])
        try data.write(to: lastKnownGoodURL, options: [.atomic])
        _ = chmod(configurationURL.path, mode_t(0o600))
        _ = chmod(lastKnownGoodURL.path, mode_t(0o600))
    }

    public func save(_ configuration: LATCHConfiguration) throws {
        guard configuration.schemaVersion == 2 else { throw ConfigurationValidationError.unsupportedSchemaVersion }
        try ConfigurationValidator().validate(configuration, liveMounts: [])
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        _ = chmod(directory.path, mode_t(0o700))

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(configuration)
        let temporary = directory.appendingPathComponent(".config.\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: [.atomic])
        guard chmod(temporary.path, mode_t(0o600)) == 0 else {
            try? manager.removeItem(at: temporary)
            throw POSIXError(.EACCES)
        }

        if let validatedPrimary = validatedData(at: configurationURL) {
            try validatedPrimary.write(to: lastKnownGoodURL, options: [.atomic])
            _ = chmod(lastKnownGoodURL.path, mode_t(0o600))
        } else if validatedData(at: lastKnownGoodURL) == nil {
            try data.write(to: lastKnownGoodURL, options: [.atomic])
            _ = chmod(lastKnownGoodURL.path, mode_t(0o600))
        }

        if manager.fileExists(atPath: configurationURL.path) {
            _ = try manager.replaceItemAt(configurationURL, withItemAt: temporary)
        } else {
            try manager.moveItem(at: temporary, to: configurationURL)
        }
        _ = chmod(configurationURL.path, mode_t(0o600))
    }

    private func validatedData(at url: URL) -> Data? {
        guard let data = try? Data(contentsOf: url), (try? decodeAndValidate(data)) != nil else { return nil }
        return data
    }

    public func removeAllState() throws {
        let manager = FileManager.default
        let quarantineURLs = (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?.filter {
            $0.lastPathComponent.hasPrefix("state.corrupt-") && $0.pathExtension == "json"
        } ?? []
        for url in [configurationURL, lastKnownGoodURL, schema1RollbackURL, directory.appendingPathComponent("state.json")] + quarantineURLs where manager.fileExists(atPath: url.path) {
            try manager.removeItem(at: url)
        }
    }
}

private struct SchemaVersion: Decodable { let schemaVersion: Int }

private struct LegacyConfiguration: Decodable {
    let schemaVersion: Int
    let mounts: [LegacyMountDefinition]
}

private struct LegacyMountDefinition: Decodable {
    let id: UUID
    let displayName: String
    let host: String
    let exportPath: String
    let mountPoint: String
    let mountOptions: NFSOptions
    let enabled: Bool
    let probeIntervalSeconds: Int
    let probeTimeoutSeconds: Int
    let recoveryCooldownSeconds: Int
    let recoveryDependencies: [RecoveryDependency]
}

public protocol RecoveryCooldownStoring: Sendable {
    func lastRecovery(for mountID: UUID) async -> Date?
    func recordRecovery(_ date: Date, for mountID: UUID, cancellation: MountOperationCancellation) async throws
}

public extension RecoveryCooldownStoring {
    func recordRecovery(_ date: Date, for mountID: UUID) async throws {
        try await recordRecovery(date, for: mountID, cancellation: .never)
    }
}

public actor InMemoryRecoveryCooldownStore: RecoveryCooldownStoring {
    private var values: [UUID: Date] = [:]
    public init() {}
    public func lastRecovery(for mountID: UUID) -> Date? { values[mountID] }
    public func recordRecovery(_ date: Date, for mountID: UUID, cancellation: MountOperationCancellation) throws {
        try cancellation.throwIfCancelled()
        let previous = values[mountID]
        values[mountID] = date
        do {
            try cancellation.throwIfCancelled()
        } catch {
            values[mountID] = previous
            throw error
        }
    }
}

public actor RecoveryStateStore: RecoveryCooldownStoring, WakeOnLANStateStoring {
    private struct State: Codable {
        var lastRecovery: [UUID: Date] = [:]
        var networkVolumesVerification: NetworkVolumesVerificationState = .notChecked
        var statuses: [UUID: MountStatus] = [:]
        var events: [LATCHEvent] = []
        var pausedMounts: Set<UUID> = []
        var automaticRetries: [UUID: AutomaticRetryState] = [:]
        var lastWakes: [UUID: Date] = [:]
        var postMountActionSources: [UUID: String] = [:]
        var pendingPostMountActionDeliveries: [UUID: PostMountActionDelivery] = [:]

        private enum CodingKeys: String, CodingKey { case lastRecovery, networkVolumesVerification, networkVolumesPermissionVerified, statuses, events, pausedMounts, automaticRetries, lastWakes, postMountActionSources, pendingPostMountActionDeliveries }
        init() {}
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            lastRecovery = try values.decodeIfPresent([UUID: Date].self, forKey: .lastRecovery) ?? [:]
            if let verification = try values.decodeIfPresent(NetworkVolumesVerificationState.self, forKey: .networkVolumesVerification) {
                networkVolumesVerification = verification
            } else {
                let verified = try values.decodeIfPresent(Bool.self, forKey: .networkVolumesPermissionVerified) ?? false
                networkVolumesVerification = verified ? .verified : .notChecked
            }
            statuses = try values.decodeIfPresent([UUID: MountStatus].self, forKey: .statuses) ?? [:]
            events = try values.decodeIfPresent([LATCHEvent].self, forKey: .events) ?? []
            pausedMounts = try values.decodeIfPresent(Set<UUID>.self, forKey: .pausedMounts) ?? []
            automaticRetries = try values.decodeIfPresent([UUID: AutomaticRetryState].self, forKey: .automaticRetries) ?? [:]
            lastWakes = try values.decodeIfPresent([UUID: Date].self, forKey: .lastWakes) ?? [:]
            postMountActionSources = try values.decodeIfPresent([UUID: String].self, forKey: .postMountActionSources) ?? [:]
            pendingPostMountActionDeliveries = try values.decodeIfPresent([UUID: PostMountActionDelivery].self, forKey: .pendingPostMountActionDeliveries) ?? [:]
        }

        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(lastRecovery, forKey: .lastRecovery)
            try values.encode(networkVolumesVerification, forKey: .networkVolumesVerification)
            try values.encode(networkVolumesVerification.isVerified, forKey: .networkVolumesPermissionVerified)
            try values.encode(statuses, forKey: .statuses)
            try values.encode(events, forKey: .events)
            try values.encode(pausedMounts, forKey: .pausedMounts)
            try values.encode(automaticRetries, forKey: .automaticRetries)
            try values.encode(lastWakes, forKey: .lastWakes)
            try values.encode(postMountActionSources, forKey: .postMountActionSources)
            try values.encode(pendingPostMountActionDeliveries, forKey: .pendingPostMountActionDeliveries)
        }
    }

    private let directory: URL
    private let stateURL: URL
    private var state: State
    private let writer: RecoveryStateWriting
    private var persistenceHealthState = PersistenceHealthSnapshot.healthy

    public init() {
        self.init(directory: LATCHIdentity.applicationSupportDirectory, writer: nil)
    }

    public init(directory: URL, writer: RecoveryStateWriting? = nil) {
        self.directory = directory
        let stateURL = directory.appendingPathComponent("state.json")
        self.stateURL = stateURL
        self.writer = writer ?? AtomicRecoveryStateWriter()
        let loaded = Self.loadState(at: stateURL)
        state = loaded.state
        persistenceHealthState = loaded.health
    }

    public func persistenceHealthSnapshot() -> PersistenceHealthSnapshot { persistenceHealthState }

    public func lastRecovery(for mountID: UUID) -> Date? { state.lastRecovery[mountID] }

    public func recordRecovery(_ date: Date, for mountID: UUID, cancellation: MountOperationCancellation) throws {
        try cancellation.throwIfCancelled()
        var candidate = state
        candidate.lastRecovery[mountID] = date
        try persist(candidate)
        do {
            try cancellation.throwIfCancelled()
        } catch {
            try persist(state)
            throw error
        }
        state = candidate
    }

    public func networkVolumesVerification() -> NetworkVolumesVerificationState { state.networkVolumesVerification }

    public func networkVolumesPermissionVerified() -> Bool { state.networkVolumesVerification.isVerified }

    public func setNetworkVolumesPermissionVerified(_ verified: Bool) throws {
        try mutateState {
            $0.networkVolumesVerification = verified ? .verified : .notChecked
        }
    }

    public func setNetworkVolumesVerification(_ verification: NetworkVolumesVerificationState) throws {
        try mutateState { $0.networkVolumesVerification = verification }
    }

    public func statuses() -> [UUID: MountStatus] { state.statuses }
    public func events() -> [LATCHEvent] { state.events }

    public func setRuntime(statuses: [UUID: MountStatus], events: [LATCHEvent]) throws {
        try mutateState {
            $0.statuses = statuses
            $0.events = events
        }
    }

    public func clearEvents() throws {
        try mutateState { $0.events.removeAll() }
    }

    public func isPaused(_ mountID: UUID) -> Bool { state.pausedMounts.contains(mountID) }

    public func setPaused(_ paused: Bool, for mountID: UUID) throws {
        try mutateState {
            if paused { $0.pausedMounts.insert(mountID) } else { $0.pausedMounts.remove(mountID) }
        }
    }

    public func automaticRetryState(for mountID: UUID) -> AutomaticRetryState? { state.automaticRetries[mountID] }

    public func setAutomaticRetryState(_ retry: AutomaticRetryState?, for mountID: UUID) throws {
        guard state.automaticRetries[mountID] != retry else { return }
        try mutateState { $0.automaticRetries[mountID] = retry }
    }

    /// Commits the pause flag and retry state as one generation-owned update.
    /// If ownership changes during persistence, the previous in-memory state is
    /// written back before another actor operation can observe the candidate.
    @discardableResult
    public func setMonitoringState(
        paused: Bool,
        automaticRetry: AutomaticRetryState?,
        for mountID: UUID,
        ifCurrent: @Sendable () -> Bool
    ) throws -> Bool {
        guard ifCurrent() else { return false }
        var candidate = state
        if paused { candidate.pausedMounts.insert(mountID) }
        else { candidate.pausedMounts.remove(mountID) }
        candidate.automaticRetries[mountID] = automaticRetry
        try persist(candidate)
        guard ifCurrent() else {
            try persist(state)
            return false
        }
        state = candidate
        return true
    }

    /// Commits retry state only while its owning mount generation is current.
    /// The second check removes a write if the generation changed during the
    /// atomic file replacement, before another state-store operation can run.
    @discardableResult
    public func setAutomaticRetryState(
        _ retry: AutomaticRetryState?,
        for mountID: UUID,
        ifCurrent: @Sendable () -> Bool
    ) throws -> Bool {
        guard ifCurrent() else { return false }
        guard state.automaticRetries[mountID] != retry else { return ifCurrent() }
        var candidate = state
        candidate.automaticRetries[mountID] = retry
        try persist(candidate)
        guard ifCurrent() else {
            try persist(state)
            return false
        }
        state = candidate
        return true
    }

    public func lastWake(for serverID: UUID) -> Date? { state.lastWakes[serverID] }

    public func recordWake(_ date: Date, for serverID: UUID) throws {
        try mutateState { $0.lastWakes[serverID] = date }
    }

    public func postMountActionSource(for mountID: UUID) -> String? { state.postMountActionSources[mountID] }

    public func pendingPostMountActionDelivery(for mountID: UUID) -> PostMountActionDelivery? {
        state.pendingPostMountActionDeliveries[mountID]
    }

    public func preparePostMountActionDelivery(
        mountID: UUID,
        source: String,
        mountPoint: String,
        actions: [PostMountAction]
    ) throws -> PostMountActionDelivery {
        if let existing = state.pendingPostMountActionDeliveries[mountID],
           existing.source == source,
           existing.mountPoint == mountPoint,
           existing.items.map(\.action) == actions {
            return existing
        }
        let delivery = PostMountActionDelivery(
            mountID: mountID,
            source: source,
            mountPoint: mountPoint,
            actions: actions
        )
        try mutateState {
            $0.pendingPostMountActionDeliveries[mountID] = delivery
        }
        return delivery
    }

    public func acknowledgePostMountActionDelivery(_ deliveryID: UUID) throws {
        guard let (mountID, delivery) = state.pendingPostMountActionDeliveries.first(where: { $0.value.id == deliveryID }) else {
            throw PostMountActionLedgerError.unknownDelivery
        }
        try mutateState {
            $0.pendingPostMountActionDeliveries[mountID] = nil
            $0.postMountActionSources[mountID] = delivery.source
        }
    }

    public func recordPostMountActions(for mountID: UUID, source: String) throws {
        try mutateState {
            $0.pendingPostMountActionDeliveries[mountID] = nil
            $0.postMountActionSources[mountID] = source
        }
    }

    public func clearPostMountActions(for mountID: UUID) throws {
        try mutateState {
            $0.pendingPostMountActionDeliveries[mountID] = nil
            $0.postMountActionSources[mountID] = nil
        }
    }

    public func removeMountState(for mountID: UUID) throws {
        try mutateState {
            $0.lastRecovery[mountID] = nil
            $0.statuses[mountID] = nil
            $0.pausedMounts.remove(mountID)
            $0.automaticRetries[mountID] = nil
            $0.postMountActionSources[mountID] = nil
            $0.pendingPostMountActionDeliveries[mountID] = nil
        }
    }

    private func persist() throws {
        try persist(state)
    }

    private static func loadState(at url: URL) -> (state: State, health: PersistenceHealthSnapshot) {
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path) else { return (State(), .healthy) }

        do {
            return (try JSONDecoder().decode(State.self, from: Data(contentsOf: url)), .healthy)
        } catch {
            let nsError = error as NSError
            let quarantineURL = url.deletingLastPathComponent()
                .appendingPathComponent("state.corrupt-\(UUID().uuidString).json")
            do {
                try manager.moveItem(at: url, to: quarantineURL)
                _ = chmod(quarantineURL.path, mode_t(0o600))
                persistenceLogger.error("Quarantined corrupt recovery state at \(quarantineURL.path, privacy: .private(mask: .hash))")
            } catch {
                persistenceLogger.error("Could not quarantine corrupt recovery state: \(error.localizedDescription, privacy: .private)")
            }
            return (
                State(),
                PersistenceHealthSnapshot(
                    isDegraded: true,
                    lastFailureAt: Date(),
                    lastErrorDomain: nsError.domain,
                    lastErrorCode: nsError.code
                )
            )
        }
    }

    private func persist(_ candidate: State) throws {
        do {
            let data = try JSONEncoder().encode(candidate)
            try writer.write(data, to: stateURL)
            persistenceHealthState.isDegraded = false
            persistenceHealthState.lastSuccessfulWriteAt = Date()
        } catch {
            reportPersistenceFailure(error)
            throw error
        }
    }

    private func reportPersistenceFailure(_ error: Error) {
        persistenceHealthState.isDegraded = true
        persistenceHealthState.lastFailureAt = Date()
        let nsError = error as NSError
        persistenceHealthState.lastErrorDomain = nsError.domain
        persistenceHealthState.lastErrorCode = nsError.code
        persistenceLogger.notice("Recovery-state write failed: \(nsError.domain, privacy: .private) / \(nsError.code, privacy: .private)")
    }

    private func mutateState(_ mutation: (inout State) -> Void) throws {
        var candidate = state
        mutation(&candidate)
        try persist(candidate)
        state = candidate
    }
}
