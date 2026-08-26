import Foundation
import Testing
@testable import LATCHShared

@Suite("Mount workflow policies")
struct MountWorkflowPolicyTests {
    @Test func newlyAddedEnabledMountStartsAutomaticWorkImmediately() {
        let transition = SavedMountTransition(isNew: true, enabled: true)

        #expect(transition.initialState == .mounting)
        #expect(transition.shouldScheduleAutomaticCheck)
        #expect(transition.lastCheck == nil)
    }

    @Test func editedMountIsRecheckedWithoutPublishingANewMountState() {
        let transition = SavedMountTransition(isNew: false, enabled: true)

        #expect(transition.initialState == nil)
        #expect(transition.shouldScheduleAutomaticCheck)
        #expect(transition.lastCheck == nil)
    }

    @Test(arguments: [false, true])
    func removingAnOwnedMountUnmountsBeforeDeleting(_ confirmed: Bool) {
        let disposition = MountRemovalDisposition.resolve(
            currentSource: "nas.local:/music",
            expectedSource: "nas.local:/music",
            confirmed: confirmed
        )

        #expect(disposition == (confirmed ? .unmountThenRemove : .requiresConfirmation))
    }

    @Test func removingAnAbsentMountDeletesTheDefinitionWithoutUnmounting() {
        #expect(MountRemovalDisposition.resolve(
            currentSource: nil,
            expectedSource: "nas.local:/music",
            confirmed: true
        ) == .remove)
    }

    @Test func removingAConflictingMountNeverTouchesOrDeletesIt() {
        #expect(MountRemovalDisposition.resolve(
            currentSource: "other.local:/data",
            expectedSource: "nas.local:/music",
            confirmed: true
        ) == .sourceConflict)
    }

    @Test func pausedMonitoringDisablesOnlyTheHealthCheckAction() {
        #expect(!ManagedMountMenuPresentation.isEnabled(.check, monitoringEnabled: false, canReveal: true))
        #expect(ManagedMountMenuPresentation.isEnabled(.mount, monitoringEnabled: false, canReveal: true))
        #expect(!ManagedMountMenuPresentation.isEnabled(.reveal, monitoringEnabled: true, canReveal: false))
    }

    @Test func activeOperationDisablesEveryConflictingManagedMountAction() {
        let actions: [ManagedMountMenuAction] = [
            .reveal,
            .check,
            .mount,
            .unmount,
            .recover,
            .editConfiguration,
            .removeDefinition,
        ]

        for action in actions {
            #expect(!ManagedMountMenuPresentation.isEnabled(
                action,
                monitoringEnabled: true,
                canReveal: true,
                operationActive: true
            ))
        }
    }

    @Test func revealRunsInTheForegroundApplication() {
        #expect(ManagedMountActionExecution.route(for: .reveal) == .foregroundApplication)
        #expect(ManagedMountActionExecution.route(for: .check) == .daemon)
    }

    @Test func revealAvailabilityRequiresTheResolvedServerSource() throws {
        let server = NFSServerProfile(name: "NAS", hostname: "nas.local")
        let definition = MountDefinition(
            displayName: "Archive",
            serverID: server.id,
            exportPath: "/archive",
            mountPoint: "/Volumes/Media/Archive"
        )
        let configuration = LATCHConfiguration(servers: [server], mounts: [definition])
        let expectedSource = try #require(configuration.resolve(definition)?.source)

        #expect(definition.source.isEmpty)
        #expect(MountRevealPolicy.isAvailable(observedSource: "nas.local:/archive", expectedSource: expectedSource))
        #expect(!MountRevealPolicy.isAvailable(observedSource: "other.local:/archive", expectedSource: expectedSource))
        #expect(!MountRevealPolicy.isAvailable(observedSource: "nas.local:/archive", expectedSource: nil))
    }
}
