import Foundation
import Testing
@testable import LATCHShared

@Suite("Schema v2 configuration and retry state")
struct SchemaV2Tests {
    @Test func xpcUsesSchemaV2ProtocolVersion() {
        #expect(XPCCodec.currentVersion == 2)
    }

    @Test func defaultConfigurationUsesServerReferences() {
        let configuration = LATCHConfiguration()

        #expect(configuration.schemaVersion == 2)
        #expect(configuration.servers.isEmpty)
        #expect(configuration.mounts.isEmpty)
    }

    @Test func storeRefusesToWriteLegacySchema() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(throws: ConfigurationValidationError.unsupportedSchemaVersion) {
            try ConfigurationStore(directory: root).save(.init(schemaVersion: 1))
        }
    }

    @Test func legacyConfigurationMigratesUniqueHostsAndPreservesMountIdentifiers() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let firstID = UUID()
        let secondID = UUID()
        let legacy = """
        {
          "schemaVersion": 1,
          "mounts": [
            {"id":"\(firstID.uuidString)","displayName":"Music","host":"nas.local","exportPath":"/music","mountPoint":"/Volumes/Media/Music","mountOptions":{"readOnly":false,"reservedPort":true,"requireTCP":true,"interruptible":true,"disableLocking":false,"hideFromFinder":true,"noExecutableFiles":false,"ignoreSetuid":true,"ignoreDeviceFiles":true},"enabled":true,"probeIntervalSeconds":60,"probeTimeoutSeconds":5,"recoveryCooldownSeconds":600,"recoveryDependencies":[]},
            {"id":"\(secondID.uuidString)","displayName":"Films","host":"nas.local","exportPath":"/films","mountPoint":"/Volumes/Media/Films","mountOptions":{"readOnly":false,"reservedPort":true,"requireTCP":true,"interruptible":true,"disableLocking":false,"hideFromFinder":true,"noExecutableFiles":false,"ignoreSetuid":true,"ignoreDeviceFiles":true},"enabled":true,"probeIntervalSeconds":60,"probeTimeoutSeconds":5,"recoveryCooldownSeconds":600,"recoveryDependencies":[]}
          ]
        }
        """
        let store = ConfigurationStore(directory: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(legacy.utf8).write(to: store.configurationURL)

        let migrated = try store.load()

        #expect(migrated.schemaVersion == 2)
        #expect(migrated.servers.count == 1)
        #expect(migrated.mounts.map(\.id) == [firstID, secondID])
        #expect(migrated.mounts.allSatisfy { $0.serverID == migrated.servers[0].id })
        #expect(FileManager.default.fileExists(atPath: store.schema1RollbackURL.path))
    }

    @Test func resolutionBuildsHostnameQualifiedSource() {
        let server = NFSServerProfile(name: "NAS", hostname: "nas.local")
        let mount = MountDefinition(displayName: "Music", serverID: server.id, exportPath: "/music", mountPoint: "/Volumes/Media/Music")
        let resolved = LATCHConfiguration(servers: [server], mounts: [mount]).resolve(mount)

        #expect(resolved?.hostname == "nas.local")
        #expect(resolved?.source == "nas.local:/music")
    }

    @Test(arguments: [
        (0, 60.0), (1, 120.0), (2, 300.0), (3, 600.0), (4, 1_800.0), (5, 1_800.0),
    ])
    func missingMountRetryUsesProgressiveIntervals(_ failures: Int, _ expected: TimeInterval) {
        #expect(AutomaticRetryState.missingMountInterval(afterFailures: failures) == expected)
    }

    @Test func staleRetryStartsAtCooldownAndCapsAtOneHour() {
        #expect(AutomaticRetryState.staleInterval(recoveryCooldownSeconds: 600, afterFailures: 0) == 600)
        #expect(AutomaticRetryState.staleInterval(recoveryCooldownSeconds: 600, afterFailures: 1) == 1_200)
        #expect(AutomaticRetryState.staleInterval(recoveryCooldownSeconds: 600, afterFailures: 10) == 3_600)
    }

    @Test(arguments: [
        (LATCHErrorCode.networkUnavailable, false),
        (.permissionDenied, false),
        (.tccDenied, false),
        (.sourceMismatch, false),
        (.mountConflict, false),
        (.remountFailed, true),
    ])
    func retryPolicyExcludesUnavailableAndTerminalErrors(_ code: LATCHErrorCode, _ expected: Bool) {
        #expect(AutomaticRetryState.shouldSchedule(after: code) == expected)
    }

    @Test(arguments: [
        (LATCHErrorCode.networkUnavailable, AutomaticRetryDisposition.preserve),
        (.permissionDenied, .clear),
        (.tccDenied, .clear),
        (.sourceMismatch, .clear),
        (.mountConflict, .clear),
        (.none, .preserve),
        (.remountFailed, .schedule),
    ])
    func retryTransitionClearsTerminalFailures(_ code: LATCHErrorCode, _ expected: AutomaticRetryDisposition) {
        #expect(AutomaticRetryState.disposition(after: code) == expected)
    }

    @Test(arguments: [
        (MountState.healthy, LATCHErrorCode.none, AutomaticRetryDisposition.clear),
        (.cooldown, .none, .schedule),
        (.networkUnavailable, .networkUnavailable, .preserve),
        (.probeError, .sourceMismatch, .clear),
    ])
    func recoveryRetryTransitionUsesResultState(_ state: MountState, _ code: LATCHErrorCode, _ expected: AutomaticRetryDisposition) {
        #expect(AutomaticRetryState.recoveryDisposition(state: state, code: code) == expected)
    }

    @Test func pauseAndRetryStatePersistPerMount() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let store = RecoveryStateStore(directory: root)

        try await store.setPaused(true, for: id)
        try await store.setAutomaticRetryState(.init(kind: .missingMount, failures: 2, nextAttempt: date), for: id)
        let reloaded = RecoveryStateStore(directory: root)

        #expect(await reloaded.isPaused(id))
        #expect(await reloaded.automaticRetryState(for: id)?.nextAttempt == date)
    }

    @Test func generationChangeDuringRetryPersistenceRestoresThePreviousState() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let original = AutomaticRetryState(kind: .missingMount, failures: 1, nextAttempt: .distantPast)
        let stale = AutomaticRetryState(kind: .staleRecovery, failures: 4, nextAttempt: .distantFuture)
        let predicate = TwoPhaseGenerationPredicate()
        let store = RecoveryStateStore(directory: root)
        try await store.setAutomaticRetryState(original, for: id)

        let committed = try await store.setAutomaticRetryState(stale, for: id, ifCurrent: { predicate.isCurrent() })

        #expect(!committed)
        #expect(await store.automaticRetryState(for: id) == original)
        #expect(await RecoveryStateStore(directory: root).automaticRetryState(for: id) == original)
    }

    @Test func statusDecodesDataWrittenBeforeRetryMetadata() throws {
        let id = UUID()
        let data = """
        {"definitionID":"\(id.uuidString)","observedMountPoint":"/Volumes/Media/Music","state":"healthy","lastStateChange":0,"detail":"Healthy","errorCode":"none"}
        """
        let status = try JSONDecoder().decode(MountStatus.self, from: Data(data.utf8))

        #expect(status.unmetRuleSummaries == [])
        #expect(status.nextAutomaticAttempt == nil)
    }
}

private final class TwoPhaseGenerationPredicate: @unchecked Sendable {
    private let lock = NSLock()
    private var checks = 0

    func isCurrent() -> Bool {
        lock.withLock {
            checks += 1
            return checks == 1
        }
    }
}
