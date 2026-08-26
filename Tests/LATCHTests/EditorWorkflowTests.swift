import Foundation
import Testing
@testable import LATCHShared

@Suite("Configuration editor workflows")
struct EditorWorkflowTests {
    @Test func serverRuleEditorGroupsSavedRulesWithTheirMatchingEditors() {
        let editor = NetworkRuleEditorState(rules: [
            .nfsServiceReachable,
            .routeAvailable("192.168.1.0/24"),
            .routeAvailable("10.0.0.0/8"),
            .interfaceType(.ethernet),
            .interfaceName("en0"),
            .interfaceName("utun3"),
            .tunnelInterfaceActive,
        ])

        #expect(editor.requiresNFSService)
        #expect(editor.requiresTunnelInterface)
        #expect(editor.requiresConnectionType)
        #expect(editor.connectionType == .ethernet)
        #expect(editor.routeRules == [
            .routeAvailable("192.168.1.0/24"),
            .routeAvailable("10.0.0.0/8"),
        ])
        #expect(editor.interfaceNameRules == [
            .interfaceName("en0"),
            .interfaceName("utun3"),
        ])
    }

    @Test func connectionTypeControlKeepsItsSelectionWhileTheRequirementIsDisabled() {
        var editor = NetworkRuleEditorState(rules: [
            .interfaceType(.wifi),
            .interfaceType(.ethernet),
            .nfsServiceReachable,
        ])

        editor.setConnectionType(.other)
        #expect(editor.rules == [.nfsServiceReachable, .interfaceType(.other)])

        editor.setConnectionTypeRequired(false)
        #expect(editor.rules == [.nfsServiceReachable])
        #expect(!editor.requiresConnectionType)
        #expect(editor.connectionTypeSelection == .other)

        editor.setConnectionTypeRequired(true)
        #expect(editor.rules == [.nfsServiceReachable, .interfaceType(.other)])
        #expect(editor.connectionType == .other)
    }

    @Test func serverEditorRequiresANameAndValidHostBeforeSaving() {
        #expect(ServerEditorValidation.issues(for: .init(name: "", hostname: "")).map(\.field) == [.name, .hostname])
        #expect(ServerEditorValidation.issues(for: .init(name: "Media NAS", hostname: "nas local")).map(\.field) == [.hostname])
        #expect(ServerEditorValidation.issues(for: .init(name: "Media NAS", hostname: "nas.local")).isEmpty)
    }

    @Test func serverEditorRejectsInvalidWakeOnLANSettings() {
        let server = NFSServerProfile(
            name: "Media NAS",
            hostname: "nas.local",
            wakeOnLAN: .init(macAddress: "not-a-mac", broadcastAddress: "999.1.1.1")
        )

        #expect(ServerEditorValidation.issues(for: server).map(\.field) == [.wakeOnLAN])
    }

    @Test func editingPreservesPersistedMountOptions() {
        let saved = NFSOptions(readOnly: true, reservedPort: false, requireTCP: false, interruptible: false, disableLocking: true, hideFromFinder: false, noExecutableFiles: true, ignoreSetuid: false, ignoreDeviceFiles: false)
        let definition = MountDefinition(displayName: "Archive", host: "server.local", exportPath: "/archive", mountPoint: "/Volumes/Media/Archive", mountOptions: saved)

        #expect(MountDraft(editing: definition).mountOptions == saved)
    }

    @Test func editingPreservesPersistedMonitoringIntervals() {
        let definition = MountDefinition(displayName: "Archive", host: "server.local", exportPath: "/archive", mountPoint: "/Volumes/Media/Archive", probeIntervalSeconds: 120, probeTimeoutSeconds: 7, recoveryCooldownSeconds: 900)
        let draft = MountDraft(editing: definition)

        #expect(draft.probeIntervalSeconds == 120)
        #expect(draft.probeTimeoutSeconds == 7)
        #expect(draft.recoveryCooldownSeconds == 900)
        #expect(draft.definition().probeIntervalSeconds == 120)
        #expect(draft.definition().probeTimeoutSeconds == 7)
        #expect(draft.definition().recoveryCooldownSeconds == 900)
    }

    @Test func recoveryCooldownEditorConvertsMinutesToStoredSeconds() {
        #expect(MountTimingPresentation.storedSeconds(for: .recoveryCooldown, displayedValue: 10) == 600)
    }

    @Test func draftPersistsTheSelectedServerIdentifier() {
        let serverID = UUID()
        let definition = MountDefinition(displayName: "Archive", serverID: serverID, exportPath: "/archive", mountPoint: "/Volumes/Media/Archive")
        let draft = MountDraft(editing: definition)

        #expect(draft.serverID == serverID)
        #expect(draft.definition().serverID == serverID)
    }
}
