import Foundation
import Testing
@testable import LATCHShared

@Suite("Option presentation contract")
struct UIContractTests {
    @Test func menuFooterRoutesMountsAndSettingsToTheMainWindowWithoutADuplicatePreferencesScene() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appSource = try String(contentsOf: root.appending(path: "Sources/LATCHApp/LATCHApp.swift"), encoding: .utf8)
        let menuSource = try String(contentsOf: root.appending(path: "Sources/LATCHApp/MountViews.swift"), encoding: .utf8)

        #expect(appSource.contains(".commands {"))
        #expect(appSource.contains("LATCHCommands(model: model)"))
        #expect(!appSource.contains("Settings {"))
        #expect(!menuSource.contains("SettingsLink"))
        #expect(LATCHMenuFooterAction.allCases.map(\.title) == ["Overview", "Mounts", "Settings"])
        #expect(LATCHMenuFooterAction.allCases.map(\.destination) == [.overview, .managed, .settings])
        #expect(menuSource.contains("ForEach(LATCHMenuFooterAction.allCases)"))
    }

    @Test func monitoringSetupAndSupportCopyUsesFinalLabels() {
        #expect(LATCHInterfaceCopy.setupSectionTitle == "Monitoring Setup")
        #expect(LATCHInterfaceCopy.setupRequiredTitle == "Monitoring needs setup")
        #expect(LATCHInterfaceCopy.exportDiagnosticsTitle == "Export Diagnostics")
        #expect(LATCHInterfaceCopy.exportConfigurationTitle == "Export Configuration")
        #expect(LATCHInterfaceCopy.importConfigurationTitle == "Import Configuration")
    }

    @Test func addDialogsUseAddWhileEditDialogsKeepSave() {
        #expect(EditorPrimaryActionTitle.title(isNew: true) == "Add")
        #expect(EditorPrimaryActionTitle.title(isNew: false) == "Save")
    }

    @Test func menuNavigationRoutesToTheRequestedMainWindowDestination() {
        #expect(LATCHMainDestination.overview.title == "Overview")
        #expect(LATCHMainDestination.settings.title == "Settings")
        #expect(LATCHMainDestination.overview != LATCHMainDestination.settings)
    }

    @Test func menuMountPresentationShowsLocationAndSourceBesideNameAndStatus() {
        let definition = MountDefinition(
            displayName: "Movies",
            host: "nas.local",
            exportPath: "/volume1/Movies",
            mountPoint: "/Users/test/Movies"
        )
        let presentation = LATCHMenuMountPresentation(
            definition: definition,
            source: "nas.local:/volume1/Movies",
            statusTitle: "Healthy"
        )

        #expect(presentation.name == "Movies")
        #expect(presentation.mountPoint == "/Users/test/Movies")
        #expect(presentation.status == "Healthy")
        #expect(presentation.source == "nas.local:/volume1/Movies")
    }

    @Test func mountRemovalActionUsesTheShortLabel() {
        #expect(ManagedMountMenuPresentation.title(for: .removeDefinition) == "Remove")
    }

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

    @Test func serverStatusTurnsRedWhenNetworkRulesAreUnmet() {
        let server = NFSServerProfile(
            name: "Media NAS",
            hostname: "nas.local",
            networkMountRules: .init(rules: [.nfsServiceReachable])
        )
        let mount = MountDefinition(
            displayName: "Music",
            serverID: server.id,
            exportPath: "/music",
            mountPoint: "/Volumes/Music"
        )
        let waiting = MountStatus(
            definitionID: mount.id,
            observedSource: nil,
            observedMountPoint: mount.mountPoint,
            state: .waitingForRules,
            lastProbe: nil,
            lastStateChange: Date(),
            lastHealthyTime: nil,
            lastRecoveryTime: nil,
            detail: "Waiting for network rules.",
            errorCode: .networkUnavailable,
            unmetRuleSummaries: ["NFS service is unavailable"]
        )

        let presentation = ServerAutomationPresentation(
            server: server,
            mounts: [mount],
            statuses: [waiting]
        )

        #expect(presentation.indicator == .blocked)
        #expect(presentation.ruleStatusTitle == "Waiting")
        #expect(presentation.ruleStatusDetails == ["NFS service is unavailable"])
    }

    @Test func serverStatusStaysGreenWhenItsNetworkRulesAreNotBlockingWork() {
        let server = NFSServerProfile(
            name: "Media NAS",
            hostname: "nas.local",
            networkMountRules: .init(rules: [.nfsServiceReachable])
        )
        let mount = MountDefinition(
            displayName: "Music",
            serverID: server.id,
            exportPath: "/music",
            mountPoint: "/Volumes/Music"
        )

        let presentation = ServerAutomationPresentation(
            server: server,
            mounts: [mount],
            statuses: [status(for: mount, state: .healthy)]
        )

        #expect(presentation.indicator == .ready)
        #expect(presentation.ruleStatusTitle == "Satisfied")
        #expect(presentation.ruleStatusDetails.isEmpty)
    }

    @Test func unconfirmedMountFolderDoesNotExposeTheDraftPath() {
        #expect(MountFolderPresentation.displayText(
            mountPoint: "/Users/test/MyMusic",
            homeDirectory: "/Users/test",
            confirmed: false
        ) == "Select folder")
    }

    @Test func confirmedMountFolderUsesTheAbbreviatedSelectedPath() {
        #expect(MountFolderPresentation.displayText(
            mountPoint: "/Users/test/MyMusic",
            homeDirectory: "/Users/test",
            confirmed: true
        ) == "~/MyMusic")
    }

    @Test func folderPickerStartsAtHomeUntilASelectionIsConfirmed() {
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)

        #expect(MountFolderPickerPresentation.initialDirectory(
            mountPoint: "/Users/test/Music",
            homeDirectory: home,
            confirmed: false
        ) == home.standardizedFileURL)
    }

    @Test func folderPickerReopensAtTheConfirmedFolder() {
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        let selected = URL(fileURLWithPath: "/Users/test/Music", isDirectory: true).standardizedFileURL

        #expect(MountFolderPickerPresentation.initialDirectory(
            mountPoint: selected.path,
            homeDirectory: home,
            confirmed: true
        ) == selected)
        #expect(MountFolderPickerPresentation.message == "Choose an existing empty folder.")
    }

    @Test func mountEditorDirectsUsersToServersWhenNoServerCanBeSelected() {
        let presentation = MountServerSelectionPresentation(availableServerCount: 0)

        #expect(presentation.guidance == "Add a server from Servers before configuring a mount.")
        #expect(!presentation.canSelectServer)
    }

    @Test func mountEditorSaveResultCarriesFailureMessage() {
        let saved = MountEditorSaveResult.saved
        let failed = MountEditorSaveResult.failed("The mount was not saved.")

        #expect(saved.failureMessage == nil)
        #expect(failed.failureMessage == "The mount was not saved.")
    }

    @Test func mountEditorOffersItsServerPickerWhenServersAreAvailable() {
        let presentation = MountServerSelectionPresentation(availableServerCount: 2)

        #expect(presentation.guidance == nil)
        #expect(presentation.canSelectServer)
    }

    @Test func mountStatusIndicatorsCoverEveryRuntimeState() {
        let expected: [MountState: MountStatusIndicator] = [
            .disabled: .inactive,
            .unmounted: .inactive,
            .mounting: .progress,
            .healthy: .healthy,
            .networkUnavailable: .issue,
            .probeTimedOut: .issue,
            .probeError: .issue,
            .stale: .issue,
            .recovering: .progress,
            .cooldown: .issue,
            .failedClosed: .issue,
            .waitingForRules: .waitingForRules,
            .waking: .progress,
            .retryScheduled: .issue,
        ]

        #expect(Set(expected.keys) == Set(MountState.allCases))
        for (state, indicator) in expected {
            #expect(MountStatusIndicatorPresentation(state: state, enabled: true).indicator == indicator)
        }
    }

    @Test func disabledMountAlwaysUsesTheInactiveIndicator() {
        let paused = MountStatusIndicatorPresentation(state: .healthy, enabled: false)

        #expect(paused.indicator == .inactive)
        #expect(paused.statusTitle == "Monitoring paused")
        #expect(MountStatusIndicatorPresentation(state: nil, enabled: true).indicator == .inactive)
    }

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

    @Test func managedMountMenuUsesTheRequestedGroupingAndLabels() {
        #expect(ManagedMountMenuPresentation.sections(includeRemoval: true) == [
            [.reveal, .check],
            [.mount, .unmount, .recover],
            [.editConfiguration, .removeDefinition],
        ])
        #expect(ManagedMountMenuPresentation.title(for: .editConfiguration) == "Edit")
        #expect(ManagedMountMenuPresentation.title(for: .unmount) == "Unmount")
        #expect(ManagedMountMenuPresentation.title(for: .recover) == "Recover")
    }

    @Test func pausedMonitoringDisablesOnlyTheHealthCheckAction() {
        #expect(!ManagedMountMenuPresentation.isEnabled(.check, monitoringEnabled: false, canReveal: true))
        #expect(ManagedMountMenuPresentation.isEnabled(.mount, monitoringEnabled: false, canReveal: true))
        #expect(!ManagedMountMenuPresentation.isEnabled(.reveal, monitoringEnabled: true, canReveal: false))
    }

    @Test func activeOperationDisablesEveryConflictingManagedMountAction() {
        for action in ManagedMountMenuPresentation.sections(includeRemoval: true).flatMap({ $0 }) {
            #expect(!ManagedMountMenuPresentation.isEnabled(
                action,
                monitoringEnabled: true,
                canReveal: true,
                operationActive: true
            ))
        }
    }

    @Test func serverEditorRequiresANameAndValidHostBeforeSaving() {
        #expect(ServerEditorValidation.issues(for: .init(name: "", hostname: "")).map(\.field) == [.name, .hostname])
        #expect(ServerEditorValidation.issues(for: .init(name: "Media NAS", hostname: "nas local")).map(\.field) == [.hostname])
        #expect(ServerEditorValidation.issues(for: .init(name: "Media NAS", hostname: "nas.local")).isEmpty)
    }

    @Test func serverEditorExplainsInvalidWakeOnLANSettingsBeforeSaving() {
        let server = NFSServerProfile(
            name: "Media NAS",
            hostname: "nas.local",
            wakeOnLAN: .init(macAddress: "not-a-mac", broadcastAddress: "999.1.1.1")
        )

        #expect(ServerEditorValidation.issues(for: server).map(\.field) == [.wakeOnLAN])
    }

    @Test func responseDeadlineReturnsAReplyThatArrivesBeforeTimeout() async throws {
        let value: String = try await ResponseDeadline.wait(for: .seconds(1)) { reply in
            reply(.success("saved"))
        }

        #expect(value == "saved")
    }

    @Test func responseDeadlineFailsWhenAServiceNeverReplies() async {
        await #expect(throws: ResponseDeadlineError.timedOut) {
            let _: String = try await ResponseDeadline.wait(for: .milliseconds(20)) { _ in }
        }
    }

    @Test func responseDeadlineCancelsThePendingServiceRequestOnTimeout() async {
        let cancelled = LockedFlag()

        await #expect(throws: ResponseDeadlineError.timedOut) {
            let _: String = try await ResponseDeadline.wait(
                for: .milliseconds(20),
                onTimeout: { cancelled.set() }
            ) { _ in }
        }
        #expect(cancelled.value)
    }

    @Test func responseDeadlineCancelsThePendingServiceRequestWhenItsParentTaskIsCancelled() async {
        let cancelled = LockedFlag()
        let task = Task {
            let _: String = try await ResponseDeadline.wait(
                for: .seconds(10),
                onTimeout: { cancelled.set() }
            ) { _ in }
        }
        try? await Task.sleep(for: .milliseconds(20))
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(cancelled.value)
    }

    @Test func responseDeadlineCanJoinABoundedSideEffectAfterParentCancellation() async throws {
        let task = Task {
            try await ResponseDeadline.wait(
                for: .seconds(1),
                cancellationBehavior: .awaitResponse
            ) { reply in
                Task.detached {
                    try? await Task.sleep(for: .milliseconds(40))
                    reply(.success("completed"))
                }
            } as String
        }
        try? await Task.sleep(for: .milliseconds(10))
        task.cancel()

        #expect(try await task.value == "completed")
    }

    @Test func newMountSuggestionUsesTheUsersHomeAndDisplayName() {
        #expect(MountPathSuggestion.path(displayName: "MyMusic", homeDirectory: "/Users/test") == "/Users/test/MyMusic")
        #expect(MountPathSuggestion.path(displayName: "  My/Music  ", homeDirectory: "/Users/test") == "/Users/test/My-Music")
        #expect(MountPathSuggestion.abbreviated("/Users/test/MyMusic", homeDirectory: "/Users/test") == "~/MyMusic")
        #expect(MountDraft.new.mountPoint == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path)
    }

    @Test func serviceSetupPresentationDistinguishesApprovalFromFailure() {
        let approval = ManagedServicePresentation(name: "Privileged daemon", state: .requiresApproval)
        let missing = ManagedServicePresentation(name: "Login agent", state: .notRegistered)
        let ready = ManagedServicePresentation(name: "Login agent", state: .enabled)

        #expect(approval.statusText == "Needs Approval")
        #expect(approval.actionTitle == "Open Login Items")
        #expect(approval.shouldOfferSystemSettings)
        #expect(missing.statusText == "Not Installed")
        #expect(missing.actionTitle == "Install")
        #expect(!missing.shouldOfferSystemSettings)
        #expect(ready.statusText == "Ready")
        #expect(ready.actionTitle == "Remove")
    }

    @Test func monitoringServiceSetupDependsOnlyOnDaemonAndLoginAgent() {
        let partial = ManagedServicesPresentation(
            daemon: .enabled,
            loginAgent: .notRegistered
        )
        let approval = ManagedServicesPresentation(
            daemon: .enabled,
            loginAgent: .requiresApproval
        )
        let offline = ManagedServicesPresentation(
            daemon: .enabled,
            loginAgent: .enabled
        )
        let starting = ManagedServicesPresentation(
            daemon: .enabled,
            loginAgent: .enabled,
            setupInProgress: true
        )
        let agentOffline = ManagedServicesPresentation(
            daemon: .enabled,
            loginAgent: .enabled,
            daemonOnline: true,
            agentOnline: false
        )
        let ready = ManagedServicesPresentation(
            daemon: .enabled,
            loginAgent: .enabled,
            daemonOnline: true,
            agentOnline: true
        )

        #expect(partial.statusText == "Setup Required")
        #expect(partial.action == .install)
        #expect(approval.statusText == "Needs Approval")
        #expect(approval.action == .openLoginItems)
        #expect(offline.statusText == "Daemon Offline")
        #expect(offline.action == .repair)
        #expect(starting.statusText == "Starting Services")
        #expect(starting.action == .remove)
        #expect(agentOffline.statusText == "Login Agent Offline")
        #expect(agentOffline.action == .repair)
        #expect(ready.statusText == "Ready")
        #expect(ready.action == .remove)
    }

    @Test func revealRunsInTheForegroundApplication() {
        #expect(ManagedMountActionExecution.route(for: .reveal) == .foregroundApplication)
        #expect(ManagedMountActionExecution.route(for: .check) == .daemon)
    }

    @Test func overviewSummarizesReadinessAndManagedHealth() {
        let media = MountDefinition(displayName: "Media", host: "nas.local", exportPath: "/media", mountPoint: "/Volumes/Media/Media")
        let music = MountDefinition(displayName: "Music", host: "nas.local", exportPath: "/music", mountPoint: "/Volumes/Media/Music")
        let paused = MountDefinition(displayName: "Downloads", host: "nas.local", exportPath: "/downloads", mountPoint: "/Volumes/Media/Downloads", enabled: false)
        let services = ServiceStatusSnapshot(daemonOnline: true, daemonAuthorized: true, agentAuthorized: true, networkVolumesVerification: .notChecked)
        let statuses = [
            status(for: media, state: .healthy),
            status(for: music, state: .networkUnavailable),
            status(for: paused, state: .disabled),
        ]

        let overview = LATCHOverview(definitions: [media, music, paused], statuses: statuses, services: services)

        #expect(overview.setupRequirements.isEmpty)
        #expect(overview.totalManaged == 3)
        #expect(overview.healthy == 1)
        #expect(overview.needsAttention == 1)
        #expect(overview.paused == 1)
        #expect(overview.activeManaged == 2)
    }

    @Test func menuHealthSummaryDoesNotCountPausedMountsAsUnhealthy() {
        let active = MountDefinition(displayName: "Media", host: "nas.local", exportPath: "/media", mountPoint: "/Volumes/Media/Media")
        let paused = MountDefinition(displayName: "Downloads", host: "nas.local", exportPath: "/downloads", mountPoint: "/Volumes/Media/Downloads", enabled: false)
        let services = ServiceStatusSnapshot(daemonOnline: true, daemonAuthorized: true, agentAuthorized: true, networkVolumesVerification: .notChecked)
        let overview = LATCHOverview(
            definitions: [active, paused],
            statuses: [status(for: active, state: .healthy), status(for: paused, state: .disabled)],
            services: services
        )

        #expect(LATCHMenuHeaderPresentation(overview: overview).text == "1 of 1 volume is healthy. 1 volume is paused.")
    }

    @Test func offlineMenuBarUsesACrossedVolumeSymbol() {
        let services = ServiceStatusSnapshot(
            daemonOnline: false,
            daemonAuthorized: true,
            agentAuthorized: true,
            networkVolumesVerification: .notChecked
        )

        #expect(LATCHMenuBarPresentation(
            services: services,
            statuses: [],
            hasLoadedServiceStatus: true
        ).symbol == "externaldrive.badge.xmark")
    }

    @Test func authorizedMenuBarUsesANeutralVolumeUntilInitialStatusLoads() {
        let services = ServiceStatusSnapshot(
            daemonOnline: false,
            daemonAuthorized: true,
            agentAuthorized: true,
            networkVolumesVerification: .notChecked
        )

        #expect(LATCHMenuBarPresentation(
            services: services,
            statuses: [],
            hasLoadedServiceStatus: false
        ).symbol == "externaldrive")
    }

    @Test func emptyActivityUsesTheListEmptyState() {
        #expect(LATCHActivitySectionPresentation(events: []) == .empty)
    }

    @Test func emptyListPresentationsUseConsistentCopyAndSymbols() {
        #expect(LATCHEmptyStatePresentation.managedMounts == .init(
            symbol: "externaldrive.badge.plus",
            title: "No managed mounts",
            detail: "Add a managed NFS mount to begin monitoring and automatic recovery."
        ))
        #expect(LATCHEmptyStatePresentation.servers == .init(
            symbol: "server.rack",
            title: "No servers",
            detail: "Add an NFS server before configuring managed mounts."
        ))
        #expect(LATCHEmptyStatePresentation.externalMounts == .init(
            symbol: "eye.slash",
            title: "No external NFS mounts",
            detail: "External mounts appear here automatically when macOS reports them."
        ))
        #expect(LATCHEmptyStatePresentation.activity == .init(
            symbol: "clock.arrow.circlepath",
            title: "No recent activity",
            detail: "Health checks and recovery events will appear here."
        ))
    }

    @Test func activitySectionLimitsTheOverviewToTheThreeNewestEvents() {
        let events = (0..<4).map {
            LATCHEvent(
                date: Date(timeIntervalSince1970: TimeInterval($0)),
                mountID: nil,
                state: .healthy,
                code: .none,
                detail: "Event \($0)"
            )
        }

        #expect(LATCHActivitySectionPresentation(events: events) == .events(Array(events.prefix(3))))
    }

    @Test func activityEventPresentationSeparatesTableColumns() {
        let event = LATCHEvent(
            date: Date(timeIntervalSince1970: 123),
            mountID: nil,
            state: .networkUnavailable,
            code: .networkUnavailable,
            detail: "The server did not answer."
        )

        #expect(LATCHActivityEventPresentation(event: event) == .init(
            summary: "The server did not answer.",
            stateDetail: "The NFS server did not respond to the latest check.",
            indicator: .issue
        ))
    }

    @Test func setupRequirementsFollowTheUserActionOrder() {
        let services = ServiceStatusSnapshot(daemonOnline: false, daemonAuthorized: false, agentAuthorized: false, networkVolumesVerification: .notChecked)
        let overview = LATCHOverview(definitions: [], statuses: [], services: services)

        #expect(overview.setupRequirements == [.privilegedDaemon, .loginAgent])
    }

    @Test func networkVolumesPresentationDistinguishesPendingReadyAndFailure() {
        #expect(NetworkVolumesVerificationState.notChecked.statusText == "Not yet checked")
        #expect(NetworkVolumesVerificationState.notChecked.isError == false)
        #expect(NetworkVolumesVerificationState.checking.statusText == "Checking")
        #expect(NetworkVolumesVerificationState.verified.statusText == "Ready")
        #expect(NetworkVolumesVerificationState.failed.statusText == "Error")
        #expect(NetworkVolumesVerificationState.failed.isError)
    }

    @Test func activityIsNewestFirstRegardlessOfStorageOrder() {
        let mountID = UUID()
        let old = LATCHEvent(date: Date(timeIntervalSince1970: 10), mountID: mountID, state: .healthy, code: .none, detail: "Old")
        let newest = LATCHEvent(date: Date(timeIntervalSince1970: 30), mountID: mountID, state: .healthy, code: .none, detail: "Newest")
        let middle = LATCHEvent(date: Date(timeIntervalSince1970: 20), mountID: mountID, state: .healthy, code: .none, detail: "Middle")

        #expect(LATCHEvent.newestFirst([old, newest, middle]).map(\.detail) == ["Newest", "Middle", "Old"])
    }

    @Test func firstHealthCheckWaitsForMountGracePeriod() {
        let mountedAt = Date(timeIntervalSince1970: 100)

        #expect(!MountCheckSchedule.isDue(lastCheck: nil, mountedAt: mountedAt, now: mountedAt.addingTimeInterval(2), interval: 60, mountGrace: 3))
        #expect(MountCheckSchedule.isDue(lastCheck: nil, mountedAt: mountedAt, now: mountedAt.addingTimeInterval(3), interval: 60, mountGrace: 3))
        #expect(!MountCheckSchedule.isDue(lastCheck: mountedAt, mountedAt: nil, now: mountedAt.addingTimeInterval(59), interval: 60, mountGrace: 3))
        #expect(MountCheckSchedule.isDue(lastCheck: mountedAt, mountedAt: nil, now: mountedAt.addingTimeInterval(60), interval: 60, mountGrace: 3))
    }

    @Test func everyMountStateHasPlainLanguageStatusText() {
        #expect(MountState.healthy.displayName == "Healthy")
        #expect(MountState.networkUnavailable.displayName == "Server unavailable")
        #expect(MountState.disabled.displayName == "Monitoring paused")
        #expect(MountState.failedClosed.displayName == "Recovery failed closed")
        #expect(Set(MountState.allCases.map(\.displayName)).count == MountState.allCases.count)
    }

#if DEBUG
    @Test func visualQADataMatchesTheSelectedOverviewState() {
        let fixture = LATCHPreviewFixture.operationalOverview(at: Date(timeIntervalSince1970: 1_777_000_000))

        #expect(fixture.configuration.mounts.map(\.displayName) == ["Media", "Music", "Downloads"])
        #expect(fixture.statuses.map(\.state) == [.healthy, .networkUnavailable, .disabled])
        #expect(fixture.events.count == 3)
    }
#endif

    @Test func everyOptionHasTheSpecifiedAccessibleHint() {
        #expect(NFSOptions.controls.map(\.hint) == [
            "Prevents every application from changing files on this volume.",
            "Uses a privileged client port, which some NFS servers such as Synology require.",
            "Prevents fallback to UDP and uses TCP for more reliable media transfers.",
            "Allows a terminated process to escape some NFS operations blocked by an unavailable server.",
            "Disables remote file locking and should be enabled only when the server or workload does not use locks.",
            "Keeps the mounted volume out of Finder’s normal volume and desktop listings.",
            "Prevents programs and scripts stored on this media volume from being executed directly.",
            "Prevents privilege-changing file bits on the NFS volume from taking effect.",
            "Prevents device files stored on the NFS volume from being treated as real devices.",
        ])
    }

    @Test func addFormUsesRecommendedValues() {
        let draft = MountDraft.new

        #expect(draft.mountOptions == .recommended)
        #expect(draft.serverID != UUID())
        #expect(draft.probeIntervalSeconds == 30)
        #expect(draft.probeTimeoutSeconds == 3)
        #expect(draft.recoveryCooldownSeconds == 600)
    }

    @Test func newMountDefinitionsUseResponsiveTimingDefaults() {
        let definition = MountDefinition(
            displayName: "Archive",
            host: "server.local",
            exportPath: "/archive",
            mountPoint: "/Volumes/Media/Archive"
        )

        #expect(definition.probeIntervalSeconds == 30)
        #expect(definition.probeTimeoutSeconds == 3)
        #expect(definition.recoveryCooldownSeconds == 600)
    }

    @Test func editFormPreservesPersistedValues() {
        let saved = NFSOptions(readOnly: true, reservedPort: false, requireTCP: false, interruptible: false, disableLocking: true, hideFromFinder: false, noExecutableFiles: true, ignoreSetuid: false, ignoreDeviceFiles: false)
        let definition = MountDefinition(displayName: "Archive", host: "server.local", exportPath: "/archive", mountPoint: "/Volumes/Media/Archive", mountOptions: saved)
        #expect(MountDraft(editing: definition).mountOptions == saved)
    }

    @Test func editFormPreservesPersistedMonitoringIntervals() {
        let definition = MountDefinition(displayName: "Archive", host: "server.local", exportPath: "/archive", mountPoint: "/Volumes/Media/Archive", probeIntervalSeconds: 120, probeTimeoutSeconds: 7, recoveryCooldownSeconds: 900)
        let draft = MountDraft(editing: definition)

        #expect(draft.probeIntervalSeconds == 120)
        #expect(draft.probeTimeoutSeconds == 7)
        #expect(draft.recoveryCooldownSeconds == 900)
        #expect(draft.definition().probeIntervalSeconds == 120)
        #expect(draft.definition().probeTimeoutSeconds == 7)
        #expect(draft.definition().recoveryCooldownSeconds == 900)
    }

    @Test func mountTimingPresentationKeepsUnitsRangesAndCooldownConversion() {
        let fields = MountTimingPresentation.fields(
            probeIntervalSeconds: 60,
            probeTimeoutSeconds: 5,
            recoveryCooldownSeconds: 600
        )

        #expect(fields == [
            .init(kind: .probeInterval, title: "Probe interval", value: 60, unit: "seconds", range: 10...3600, step: 10),
            .init(kind: .probeTimeout, title: "Probe timeout", value: 5, unit: "seconds", range: 1...30, step: 1),
            .init(kind: .recoveryCooldown, title: "Recovery cooldown", value: 10, unit: "minutes", range: 1...1440, step: 1),
        ])
        #expect(MountTimingPresentation.storedSeconds(for: .recoveryCooldown, displayedValue: 10) == 600)
    }

    @Test func draftPersistsTheSelectedServerIdentifierRatherThanAHostname() {
        let serverID = UUID()
        let definition = MountDefinition(displayName: "Archive", serverID: serverID, exportPath: "/archive", mountPoint: "/Volumes/Media/Archive")
        let draft = MountDraft(editing: definition)

        #expect(draft.serverID == serverID)
        #expect(draft.definition().serverID == serverID)
    }

    @Test func menuRevealAvailabilityUsesTheResolvedServerSource() throws {
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

    @Test func resetPreviewContainsOnlyChangedValues() {
        var values = NFSOptions.recommended
        values.readOnly = true
        values.ignoreSetuid = false
        #expect(values.changesToRecommended().map(\.key) == [.readOnly, .ignoreSetuid])
    }

    private func status(for definition: MountDefinition, state: MountState) -> MountStatus {
        MountStatus(
            definitionID: definition.id,
            observedSource: definition.source,
            observedMountPoint: definition.mountPoint,
            state: state,
            lastProbe: Date(),
            lastStateChange: Date(),
            lastHealthyTime: state == .healthy ? Date() : nil,
            lastRecoveryTime: nil,
            detail: state.displayName,
            errorCode: .none
        )
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool { lock.withLock { storage } }
    func set() { lock.withLock { storage = true } }
}
