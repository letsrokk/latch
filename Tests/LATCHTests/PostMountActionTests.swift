import Foundation
import Testing
@testable import LATCHShared

@Suite("Post-mount actions")
struct PostMountActionTests {
    @Test func actionConfigurationAcceptsTypedSafeActions() throws {
        let actions: [PostMountAction] = [
            .revealInFinder,
            .openApplication(bundleIdentifier: "org.videolan.vlc", applicationURL: "/Applications/VLC.app"),
            .openRelativePath("Media/Albums"),
            .openRelativePath("."),
        ]

        try PostMountActionValidator.validate(actions)
    }

    @Test(arguments: ["", "/etc", "../outside", "Media/../outside"])
    func actionConfigurationRejectsUnsafeRelativePaths(_ path: String) {
        #expect(throws: PostMountActionValidationError.invalidRelativePath) {
            try PostMountActionValidator.validate([.openRelativePath(path)])
        }
    }

    @Test func actionConfigurationRejectsInvalidApplicationHint() {
        #expect(throws: PostMountActionValidationError.invalidApplicationHint) {
            try PostMountActionValidator.validate([.openApplication(bundleIdentifier: "org.videolan.vlc", applicationURL: "VLC")])
        }
    }

    @Test func resolvedPathRejectsASymlinkThatEscapesMountedVolume() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: outside)

        #expect(throws: PostMountActionValidationError.relativePathEscapesMount) {
            try PostMountPathResolver.resolve(relativePath: "escape", beneath: root)
        }
    }

    @Test func resolvedPathAllowsTheMountedVolumeRoot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        #expect(try PostMountPathResolver.resolve(relativePath: ".", beneath: root) == root.standardizedFileURL)
    }

    @Test func applicationTargetRequiresTheResolvedBundleIdentifierToMatch() {
        #expect(throws: PostMountActionValidationError.applicationBundleMismatch) {
            try PostMountApplicationTarget.validate(
                resolvedURL: URL(fileURLWithPath: "/Applications/VLC.app"),
                expectedBundleIdentifier: "org.videolan.vlc",
                actualBundleIdentifier: "com.example.other"
            )
        }
    }

    @Test func dispatchPolicyOnlyRunsForAbsentToSuccessfulMount() {
        #expect(PostMountDispatchPolicy.shouldDispatch(previousSource: nil, verifiedSource: "nas.local:/media"))
        #expect(!PostMountDispatchPolicy.shouldDispatch(previousSource: "nas.local:/media", verifiedSource: "nas.local:/media"))
        #expect(!PostMountDispatchPolicy.shouldDispatch(previousSource: "other:/media", verifiedSource: "nas.local:/media"))
        #expect(!PostMountDispatchPolicy.shouldDispatch(previousSource: nil, verifiedSource: nil))
    }

    @Test func agentPostMountAndManualRevealRequestsRoundTrip() throws {
        let actions: [PostMountAction] = [.revealInFinder, .openRelativePath("Media")]
        let delivery = PostMountActionDelivery(
            mountID: UUID(),
            source: "nas.local:/media",
            mountPoint: "/Volumes/Media/Library",
            actions: actions
        )
        let postMount = AgentRequest.executePostMountActions(delivery)
        let acknowledgement = AgentResponse.postMountActionsAcknowledged(.init(deliveryID: delivery.id, failures: []))
        let reveal = AgentRequest.revealManagedMount(mountPoint: "/Volumes/Media/Library")

        #expect(try AgentCodec.decode(AgentCodec.encode(postMount)) == postMount)
        #expect(try JSONDecoder().decode(AgentResponse.self, from: JSONEncoder().encode(acknowledgement)) == acknowledgement)
        #expect(try AgentCodec.decode(AgentCodec.encode(reveal)) == reveal)
    }

    @Test func dispatchedTransitionMarkerSurvivesStatusRefreshAndRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let mountID = UUID()
        let store = RecoveryStateStore(directory: root)

        try await store.recordPostMountActions(for: mountID, source: "nas.local:/media")
        let reloaded = RecoveryStateStore(directory: root)

        #expect(await reloaded.postMountActionSource(for: mountID) == "nas.local:/media")
        try await reloaded.clearPostMountActions(for: mountID)
        #expect(await reloaded.postMountActionSource(for: mountID) == nil)
    }

    @Test func daemonPersistsPendingDeliveryBeforeAcknowledgementAndCompletesOnlyAfterAck() async throws {
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
        let reloaded = RecoveryStateStore(directory: root)

        #expect(await reloaded.pendingPostMountActionDelivery(for: mountID) == delivery)
        #expect(await reloaded.postMountActionSource(for: mountID) == nil)

        try await reloaded.acknowledgePostMountActionDelivery(delivery.id)
        let completed = RecoveryStateStore(directory: root)
        #expect(await completed.pendingPostMountActionDelivery(for: mountID) == nil)
        #expect(await completed.postMountActionSource(for: mountID) == "nas.local:/media")
    }

    @Test func agentLedgerDeduplicatesACompletedDeliveryAfterAcknowledgementLoss() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let delivery = PostMountActionDelivery(
            mountID: UUID(),
            source: "nas.local:/media",
            mountPoint: "/Volumes/Media/Library",
            actions: [.revealInFinder]
        )
        let effects = ActionEffectRecorder()
        let first = DurablePostMountActionExecutor(ledger: PostMountActionLedger(directory: root))
        let firstAck = try await first.execute(delivery) { item in
            await effects.record(item.id)
            return nil
        }

        let restarted = DurablePostMountActionExecutor(ledger: PostMountActionLedger(directory: root))
        let repeatedAck = try await restarted.execute(delivery) { item in
            await effects.record(item.id)
            return nil
        }

        #expect(firstAck == repeatedAck)
        #expect(await effects.identifiers == delivery.items.map(\.id))
    }

    @Test func agentDoesNotRepeatAnActionWhoseCrashWindowIsDurablyStarted() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let delivery = PostMountActionDelivery(
            mountID: UUID(),
            source: "nas.local:/media",
            mountPoint: "/Volumes/Media/Library",
            actions: [.revealInFinder]
        )
        let ledger = PostMountActionLedger(directory: root)
        try ledger.register(delivery)
        #expect(try ledger.beginAction(delivery.items[0], deliveryID: delivery.id) == .perform)
        let effects = ActionEffectRecorder()

        let acknowledgement = try await DurablePostMountActionExecutor(ledger: ledger).execute(delivery) { item in
            await effects.record(item.id)
            return nil
        }

        #expect(await effects.identifiers.isEmpty)
        #expect(acknowledgement.failures.count == 1)
    }

    @Test func actionFailureProducesActivityDetailWithoutChangingMountState() {
        #expect(PostMountActionDispatchOutcome.activityFailures(for: .succeeded).isEmpty)
        #expect(PostMountActionDispatchOutcome.activityFailures(for: .postMountActionsAcknowledged(.init(deliveryID: UUID(), failures: ["Finder could not open the path."]))) == ["Finder could not open the path."])
        #expect(PostMountActionDispatchOutcome.activityFailures(for: .postMountActionFailures(["Finder could not open the path."])) == ["Finder could not open the path."])
        #expect(PostMountActionDispatchOutcome.activityFailures(for: .failed("The signed agent is unavailable.")) == ["The signed agent is unavailable."])
        #expect(PostMountActionDispatchOutcome.preservesMountState)
    }
}

private actor ActionEffectRecorder {
    var identifiers: [UUID] = []
    func record(_ identifier: UUID) { identifiers.append(identifier) }
}
