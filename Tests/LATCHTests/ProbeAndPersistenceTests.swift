import Foundation
import Darwin
import Testing
@testable import LATCHShared

@Suite("Probe classification and persistence")
struct ProbeAndPersistenceTests {
    @Test func parsesEffectiveNFSOptionsFromMountOutput() {
        let parsed = MountOutputParser.optionsByMount(from: """
        /dev/disk3s1 on /System/Volumes/Data (apfs, local, journaled)
        nas.local:/media on /Volumes/Media (nfs, nodev, nosuid, vers=4, rsize=65536)
        """)

        #expect(parsed[MountOutputParser.key(source: "nas.local:/media", mountPoint: "/Volumes/Media")] == ["nodev", "nosuid", "vers=4", "rsize=65536"])
        #expect(parsed.count == 1)
    }

    @Test func unverifiedPermissionDenialIsAnnotatedAsTCC() {
        let denied = ProbeResult(metadataErrno: EACCES, failedOperation: .metadata)

        #expect(denied.annotatingNetworkVolumesDenial(permissionVerified: false).tccDenied)
        #expect(!denied.annotatingNetworkVolumesDenial(permissionVerified: true).tccDenied)
        #expect(!ProbeResult(metadataErrno: EIO).annotatingNetworkVolumesDenial(permissionVerified: false).tccDenied)
    }

    @Test func runtimeESTALEPreservesVerifiedPermissionAndRemainsRecoverable() {
        let stale = ProbeResult(metadataErrno: ESTALE, failedOperation: .metadata)

        let verification = NetworkVolumesPermissionPolicy.afterRuntimeProbe(
            current: .verified,
            result: stale
        )
        let annotated = stale.annotatingNetworkVolumesDenial(permissionVerified: verification.isVerified)

        #expect(verification == .verified)
        #expect(ProbeClassifier.classify(annotated).shouldAutomaticallyRecover)
    }

    @Test func onlyExplicitTCCDenialChangesVerifiedPermissionDuringRuntimeMonitoring() {
        #expect(NetworkVolumesPermissionPolicy.afterRuntimeProbe(
            current: .verified,
            result: ProbeResult(metadataErrno: EIO, failedOperation: .metadata)
        ) == .verified)
        #expect(NetworkVolumesPermissionPolicy.afterRuntimeProbe(
            current: .verified,
            result: ProbeResult(tccDenied: true)
        ) == .failed)
        #expect(NetworkVolumesPermissionPolicy.afterRuntimeProbe(
            current: .notChecked,
            result: ProbeResult()
        ) == .notChecked)
    }

    @Test(arguments: [
        (ProbeResult(metadataErrno: ESTALE), MountState.stale, true),
        (ProbeResult(directoryErrno: ESTALE), MountState.stale, true),
        (ProbeResult(timedOut: true), MountState.probeTimedOut, false),
        (ProbeResult(networkUnavailable: true), MountState.networkUnavailable, false),
        (ProbeResult(executionUnavailable: true), MountState.mounting, false),
        (ProbeResult(metadataErrno: EACCES), MountState.probeError, false),
        (ProbeResult(directoryErrno: EPERM), MountState.probeError, false),
        (ProbeResult(tccDenied: true), MountState.probeError, false),
        (ProbeResult(metadataErrno: EIO), MountState.probeError, false),
        (ProbeResult(), MountState.healthy, false),
    ])
    func classifiesNativeResults(_ result: ProbeResult, _ state: MountState, _ recovers: Bool) {
        let classification = ProbeClassifier.classify(result)
        #expect(classification.state == state)
        #expect(classification.shouldAutomaticallyRecover == recovers)
    }

    @Test func storeFallsBackToLastKnownGoodAfterPrimaryCorruption() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ConfigurationStore(directory: root)
        let expected = makeConfiguration()

        try store.save(expected)
        try Data("not-json".utf8).write(to: store.configurationURL)

        #expect(try store.load() == expected)
    }

    @Test func saveDoesNotPromoteACorruptPrimaryOverLastKnownGood() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ConfigurationStore(directory: root)
        let original = makeConfiguration()
        let replacement = LATCHConfiguration()
        try store.save(original)
        try Data("corrupt-primary".utf8).write(to: store.configurationURL)

        try store.save(replacement)
        try Data("corrupt-replacement".utf8).write(to: store.configurationURL)

        #expect(try store.load() == original)
    }

    @Test func loadRejectsDecodableButInvalidPrimaryBeforeFallback() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ConfigurationStore(directory: root)
        let expected = LATCHConfiguration()
        try store.save(expected)
        let invalid = LATCHConfiguration(servers: [.init(name: "Invalid", hostname: "not a host")])
        try JSONEncoder().encode(invalid).write(to: store.configurationURL, options: [.atomic])

        #expect(try store.load() == expected)
    }

    @Test func storeWritesOwnerOnlyPermissions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ConfigurationStore(directory: root)

        try store.save(LATCHConfiguration())

        let attributes = try FileManager.default.attributesOfItem(atPath: store.configurationURL.path)
        #expect(attributes[.posixPermissions] as? Int == 0o600)
    }

    @Test func recoveryStatePersistsCooldownAndPermissionGate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let mountID = UUID()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let store = RecoveryStateStore(directory: root)

        try await store.recordRecovery(date, for: mountID)
        try await store.setNetworkVolumesPermissionVerified(true)
        let reloaded = RecoveryStateStore(directory: root)

        #expect(await reloaded.lastRecovery(for: mountID) == date)
        #expect(await reloaded.networkVolumesPermissionVerified())
    }

    @Test func recoveryStatePersistsNetworkVolumesFailureSeparatelyFromNotChecked() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = RecoveryStateStore(directory: directory)

        try await store.setNetworkVolumesVerification(.failed)

        let reloaded = RecoveryStateStore(directory: directory)
        #expect(await reloaded.networkVolumesVerification() == .failed)
    }

    @Test func latchStoresPersistConfigurationAndRecoveryStateWithoutLegacyDirectory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let server = NFSServerProfile(name: "NAS", hostname: "nas.local")
        let definition = MountDefinition(displayName: "Music", serverID: server.id, exportPath: "/music", mountPoint: "/Users/test/Music")
        let configuration = LATCHConfiguration(servers: [server], mounts: [definition])
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let configurationStore = ConfigurationStore(directory: root)
        let recoveryStore = RecoveryStateStore(directory: root)

        try configurationStore.save(configuration)
        try await recoveryStore.recordRecovery(date, for: definition.id)

        #expect(try ConfigurationStore(directory: root).load() == configuration)
        #expect(await RecoveryStateStore(directory: root).lastRecovery(for: definition.id) == date)
    }

    @Test func recoveryStatePersistsStatusesAndEvents() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let status = MountStatus(definitionID: id, observedSource: "server:/media", observedMountPoint: "/Volumes/Media/Movies", state: .healthy, lastProbe: date, lastStateChange: date, lastHealthyTime: date, lastRecoveryTime: nil, detail: "Healthy", errorCode: .none)
        let event = LATCHEvent(date: date, mountID: id, state: .healthy, code: .none, detail: "Healthy")
        let store = RecoveryStateStore(directory: root)

        try await store.setRuntime(statuses: [id: status], events: [event])
        let reloaded = RecoveryStateStore(directory: root)

        #expect(await reloaded.statuses() == [id: status])
        #expect(await reloaded.events() == [event])
    }

    @Test func recoveryStateWriteFailurePreservesRuntimeSnapshots() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let status = MountStatus(definitionID: id, observedSource: "server:/media", observedMountPoint: "/Volumes/Media/Movies", state: .healthy, lastProbe: date, lastStateChange: date, lastHealthyTime: date, lastRecoveryTime: nil, detail: "Healthy", errorCode: .none)
        let event = LATCHEvent(date: date, mountID: id, state: .healthy, code: .none, detail: "Healthy")
        let workingStore = RecoveryStateStore(directory: root)

        try await workingStore.setRuntime(statuses: [id: status], events: [event])

        let failingStore = RecoveryStateStore(directory: root, writer: FailingRecoveryStateWriter())

        await #expect(throws: POSIXError.self) {
            try await failingStore.setRuntime(statuses: [id: status], events: [event, event])
        }

        let reloaded = RecoveryStateStore(directory: root)
        #expect(await reloaded.statuses() == [id: status])
        #expect(await reloaded.events() == [event])
    }

    @Test func recoveryStateWriteFailurePreservesPauseFlag() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let workingStore = RecoveryStateStore(directory: root)
        try await workingStore.setPaused(true, for: id)

        let failingStore = RecoveryStateStore(directory: root, writer: FailingRecoveryStateWriter())
        await #expect(throws: POSIXError.self) {
            try await failingStore.setPaused(false, for: id)
        }

        #expect(await RecoveryStateStore(directory: root).isPaused(id))
    }

    @Test func recoveryStateWriteFailurePreservesAutomaticRetryState() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let original = AutomaticRetryState(
            kind: .missingMount,
            failures: 1,
            nextAttempt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let store = RecoveryStateStore(directory: root)
        try await store.setAutomaticRetryState(original, for: id)

        let replacement = AutomaticRetryState(
            kind: .missingMount,
            failures: 0,
            nextAttempt: Date(timeIntervalSince1970: 1_800_000_010)
        )
        let failingStore = RecoveryStateStore(directory: root, writer: FailingRecoveryStateWriter())
        await #expect(throws: POSIXError.self) {
            try await failingStore.setAutomaticRetryState(replacement, for: id)
        }

        #expect(await RecoveryStateStore(directory: root).automaticRetryState(for: id) == original)
    }

    @Test func recoveryStateWriteFailurePreservesNetworkVolumeVerification() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecoveryStateStore(directory: root)
        try await store.setNetworkVolumesVerification(.verified)

        let failingStore = RecoveryStateStore(directory: root, writer: FailingRecoveryStateWriter())
        await #expect(throws: POSIXError.self) {
            try await failingStore.setNetworkVolumesVerification(.failed)
        }

        #expect(await RecoveryStateStore(directory: root).networkVolumesVerification() == .verified)
    }

    @Test func recoveryStateWriteFailurePreservesWakeTimestamp() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let serverID = UUID()
        let original = Date(timeIntervalSince1970: 1_800_000_000)
        let store = RecoveryStateStore(directory: root)
        try await store.recordWake(original, for: serverID)

        let replacement = Date(timeIntervalSince1970: 1_800_000_020)
        let failingStore = RecoveryStateStore(directory: root, writer: FailingRecoveryStateWriter())
        await #expect(throws: POSIXError.self) {
            try await failingStore.recordWake(replacement, for: serverID)
        }

        #expect(await RecoveryStateStore(directory: root).lastWake(for: serverID) == original)
    }

    @Test func recoveryStateWriteFailurePreservesRecoveryTimestamp() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let mountID = UUID()
        let original = Date(timeIntervalSince1970: 1_800_000_000)
        let replacement = Date(timeIntervalSince1970: 1_800_000_020)
        let store = RecoveryStateStore(directory: root)
        try await store.recordRecovery(original, for: mountID)

        let failingStore = RecoveryStateStore(directory: root, writer: FailingRecoveryStateWriter())
        await #expect(throws: POSIXError.self) {
            try await failingStore.recordRecovery(replacement, for: mountID)
        }

        #expect(await RecoveryStateStore(directory: root).lastRecovery(for: mountID) == original)
    }

    @Test func clearingEventsPreservesPersistedMountStatuses() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let status = MountStatus(definitionID: id, observedSource: "server:/media", observedMountPoint: "/Volumes/Media/Movies", state: .healthy, lastProbe: date, lastStateChange: date, lastHealthyTime: date, lastRecoveryTime: nil, detail: "Healthy", errorCode: .none)
        let event = LATCHEvent(date: date, mountID: id, state: .healthy, code: .none, detail: "Healthy")
        let store = RecoveryStateStore(directory: root)
        try await store.setRuntime(statuses: [id: status], events: [event])

        try await store.clearEvents()

        let reloaded = RecoveryStateStore(directory: root)
        #expect(await reloaded.events().isEmpty)
        #expect(await reloaded.statuses() == [id: status])
    }

    @Test func recoveryStateWriteFailurePreservesMountRemovalRollback() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let status = MountStatus(definitionID: id, observedSource: "server:/media", observedMountPoint: "/Volumes/Media/Movies", state: .healthy, lastProbe: date, lastStateChange: date, lastHealthyTime: date, lastRecoveryTime: nil, detail: "Healthy", errorCode: .none)
        let store = RecoveryStateStore(directory: root)
        try await store.setRuntime(statuses: [id: status], events: [])
        try await store.setPaused(true, for: id)
        try await store.setAutomaticRetryState(.init(kind: .missingMount, failures: 1, nextAttempt: date), for: id)

        let failingStore = RecoveryStateStore(directory: root, writer: FailingRecoveryStateWriter())
        await #expect(throws: POSIXError.self) {
            try await failingStore.removeMountState(for: id)
        }

        let reloaded = RecoveryStateStore(directory: root)
        #expect(await reloaded.statuses()[id] != nil)
        #expect(await reloaded.isPaused(id))
    }

    @Test func recoveryStateWriteFailurePreservesPostMountPreparation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let mountID = UUID()
        let store = RecoveryStateStore(directory: root)
        _ = try await store.preparePostMountActionDelivery(
            mountID: mountID,
            source: "nas.local:/media",
            mountPoint: "/Volumes/Media/Library",
            actions: [.revealInFinder]
        )

        let failingStore = RecoveryStateStore(directory: root, writer: FailingRecoveryStateWriter())
        await #expect(throws: POSIXError.self) {
            try await failingStore.preparePostMountActionDelivery(
                mountID: mountID,
                source: "nas.local:/media/new",
                mountPoint: "/Volumes/Media/Library",
                actions: [.revealInFinder]
            )
        }

        let reloaded = RecoveryStateStore(directory: root)
        #expect(await reloaded.pendingPostMountActionDelivery(for: mountID) != nil)
        #expect(await reloaded.postMountActionSource(for: mountID) == nil)
    }

    @Test func recoveryStateWriteFailurePreservesPostMountAcknowledgement() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let mountID = UUID()
        let store = RecoveryStateStore(directory: root)
        let delivery = try await store.preparePostMountActionDelivery(
            mountID: mountID,
            source: "nas.local:/media",
            mountPoint: "/Volumes/Media/Library",
            actions: [.revealInFinder]
        )

        let failingStore = RecoveryStateStore(directory: root, writer: FailingRecoveryStateWriter())
        await #expect(throws: POSIXError.self) {
            try await failingStore.acknowledgePostMountActionDelivery(delivery.id)
        }

        let reloaded = RecoveryStateStore(directory: root)
        #expect(await reloaded.pendingPostMountActionDelivery(for: mountID) == delivery)
        #expect(await reloaded.postMountActionSource(for: mountID) == nil)
    }

    private func makeConfiguration() -> LATCHConfiguration {
        let server = NFSServerProfile(name: "Server", hostname: "server.local")
        let mount = MountDefinition(displayName: "Movies", serverID: server.id, exportPath: "/media", mountPoint: "/Volumes/Media/Movies")
        return .init(servers: [server], mounts: [mount])
    }
}

private struct FailingRecoveryStateWriter: RecoveryStateWriting {
    func write(_ data: Data, to url: URL) throws {
        throw POSIXError(.EACCES)
    }
}
