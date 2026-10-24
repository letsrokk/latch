import AppKit
import Darwin
import LATCHShared
import SwiftUI

struct MainWindowView: View {
    @EnvironmentObject private var model: AppModel
    @SceneStorage("mainDestination") private var storedDestination = LATCHMainDestination.overview.rawValue
    @State private var draft: MountDraft?
    @State private var serverDraft: NFSServerProfile?
    @State private var templateServer: NFSServerProfile?
    @State private var removeTarget: MountDefinition?
    @State private var pendingAction: PendingMountAction?
    @State private var showServiceRemoval = false
    @State private var showActivityClearConfirmation = false
    @AppStorage("notificationsEnabled", store: UserDefaults(suiteName: LATCHIdentity.preferenceSuite)) private var notificationsEnabled = true
    @AppStorage("prolongedUnavailableSeconds", store: UserDefaults(suiteName: LATCHIdentity.preferenceSuite)) private var prolongedUnavailableSeconds = 300

    private var overview: LATCHOverview {
        LATCHOverview(definitions: model.configuration.mounts, statuses: model.statuses, services: model.serviceStatus)
    }

    var body: some View {
        NavigationSplitView {
            MainSidebarView(
                selection: destinationSelection,
                daemonOnline: model.serviceStatus.daemonOnline
            )
                .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 200)
        } detail: {
            detail
                .navigationTitle(LATCHMainWindowPresentation.title)
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar(removing: .sidebarToggle)
        .textFieldStyle(.roundedBorder)
        .onAppear {
            model.restoreMainWindowDestination(from: storedDestination)
        }
        .onChange(of: model.mainDestination) { _, destination in
            storedDestination = destination.rawValue
        }
        .sheet(item: $draft) { value in
            MountEditorView(draft: value, servers: model.configuration.servers, initialServer: templateServer, status: model.statuses.first { $0.definitionID == value.id }, applyAndRemount: { saved in
                await model.applyAndRemount(saved)
            }) { saved, server in
                await model.save(saved, creating: server)
            }
        }
        .sheet(item: $serverDraft) { server in
            ServerEditorView(server: server) { saved in
                await model.save(saved)
            }
        }
        .alert("LATCH", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .alert("Approval Required", isPresented: Binding(get: { model.serviceApprovalPrompt != nil }, set: { if !$0 { model.clearServiceApprovalPrompt() } })) {
            Button("Open Login Items") {
                model.clearServiceApprovalPrompt()
                model.openLoginItems()
            }
            Button("Not Now", role: .cancel) { model.clearServiceApprovalPrompt() }
        } message: {
            Text("\(model.serviceApprovalPrompt?.serviceName ?? "This service") was installed, but macOS requires you to enable it in System Settings before it can run.")
        }
        .alert(pendingAction?.title ?? "Confirm action", isPresented: Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } })) {
            Button(pendingAction?.action == .recover ? "Recover" : "Unmount", role: .destructive) {
                if let pendingAction { Task { await model.action(pendingAction.action, definition: pendingAction.definition, confirmed: true) } }
                pendingAction = nil
            }
            Button("Cancel", role: .cancel) { pendingAction = nil }
        } message: { Text(pendingAction?.detail ?? "") }
        .confirmationDialog("Remove \(removeTarget?.displayName ?? "mount")?", isPresented: Binding(get: { removeTarget != nil }, set: { if !$0 { removeTarget = nil } })) {
            Button("Unmount and Remove", role: .destructive) {
                if let removeTarget { Task { await model.remove(removeTarget, confirmed: true) } }
                removeTarget = nil
            }
            Button("Cancel", role: .cancel) { removeTarget = nil }
        } message: { Text("LATCH unmounts the configured volume, then removes it from the list. If unmounting fails, the mount remains configured.") }
        .confirmationDialog("Remove monitoring services?", isPresented: $showServiceRemoval) {
            Button("Remove", role: .destructive) { Task { await model.uninstall(unmountOwned: false, removeState: false) } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This unregisters the privileged daemon and login agent. Mount definitions and saved state remain available.") }
        .confirmationDialog("Clear activity?", isPresented: $showActivityClearConfirmation) {
            Button("Clear", role: .destructive) { Task { await model.clearActivity() } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This permanently removes the saved health and recovery event history.") }
    }

    private var destinationSelection: Binding<LATCHMainDestination> {
        Binding(
            get: { model.mainDestination },
            set: { destination in
                storedDestination = destination.rawValue
                model.mainDestination = destination
            }
        )
    }

    @ViewBuilder
    private var detail: some View {
        switch model.mainDestination {
        case .overview:
            OverviewScreen(
                overview: overview,
                definitions: model.configuration.mounts,
                configuration: model.configuration,
                statuses: model.statuses,
                events: model.events,
                finishSetup: { model.mainDestination = .settings },
                viewActivity: { model.mainDestination = .activity }
            )
        case .managed:
            ManagedMountsScreen(
                definitions: model.configuration.mounts,
                configuration: model.configuration,
                statuses: model.statuses,
                operations: model.operationSnapshots.values.filter { !$0.state.isTerminal },
                addMount: { draft = .new },
                edit: { draft = MountDraft(editing: $0) },
                remove: { removeTarget = $0 },
                action: requestAction,
                cancel: { operationID in Task { await model.cancelOperation(operationID) } }
            )
        case .servers:
            ServersScreen(
                servers: model.configuration.servers,
                mounts: model.configuration.mounts,
                statuses: model.statuses,
                discovered: model.discoveredServers,
                addServer: { serverDraft = .init(name: "", hostname: "") },
                edit: { serverDraft = $0 },
                remove: { server in Task { await model.remove(server) } },
                wake: { server in Task { await model.wake(server) } },
                configureDiscovery: { discovery in
                    guard let template = discovery.configurationTemplate else { return }
                    serverDraft = template
                }
            )
        case .external:
            ExternalMountsScreen(mounts: model.externalMounts) { snapshot in
                guard let template = ExternalMountConfigurationTemplate(snapshot: snapshot) else { return }
                templateServer = template.server
                draft = template.draft
            }
        case .activity:
            ActivityScreen(
                events: model.events,
                clear: { showActivityClearConfirmation = true }
            )
        case .settings:
            LATCHSettingsScreen(
                daemonState: model.daemonServiceState,
                agentState: model.agentServiceState,
                mainApplicationState: model.mainApplicationServiceState,
                startAtLoginEnabled: model.startAtLoginEnabled,
                daemonOnline: model.serviceStatus.daemonOnline,
                agentOnline: model.serviceStatus.agentOnline,
                serviceSetupInProgress: model.serviceSetupInProgress,
                persistenceDegraded: model.serviceStatus.persistenceHealth.isDegraded,
                notificationsEnabled: $notificationsEnabled,
                prolongedUnavailableSeconds: $prolongedUnavailableSeconds,
                installServices: { Task { await model.installServices() } },
                removeServices: { showServiceRemoval = true },
                openLoginItems: model.openLoginItems,
                setStartAtLogin: { enabled in Task { await model.setStartAtLogin(enabled) } },
                exportDiagnostics: model.exportDiagnostics,
                exportConfiguration: model.exportConfiguration,
                importConfiguration: model.importConfiguration,
                importPreview: model.configurationImportPreview,
                applyImport: model.applyImportedConfiguration,
                cancelImport: model.cancelConfigurationImport
            )
        }
    }

    private func requestAction(_ action: LATCHAction, definition: MountDefinition) {
        switch action {
        case .unmount:
            pendingAction = .init(definition: definition, action: action, title: "Unmount \(definition.displayName)?", detail: "Unmounting can interrupt applications that are using this volume.")
        case .recover:
            pendingAction = .init(definition: definition, action: action, title: "Recover \(definition.displayName)?", detail: "LATCH will stop configured dependencies, unmount only this source, remount it, and verify the result.")
        case .check, .mount, .reveal:
            Task { await model.action(action, definition: definition) }
        }
    }
}

struct ExternalMountsScreen: View {
    let mounts: [ExternalMountSnapshot]
    let configure: (ExternalMountSnapshot) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScreenHeader(
                title: "External Mounts",
                subtitle: "Read-only observations. LATCH never probes, adopts, or changes these mounts."
            )
            Table(mounts) {
                TableColumn("Source", value: \.source)
                TableColumn("Mountpoint", value: \.mountPoint)
                TableColumn("Type", value: \.fileSystemType).width(70)
                TableColumn("Options") { Text($0.options.joined(separator: ", ")).lineLimit(1) }
                TableColumn("") { snapshot in Button("Configure") { configure(snapshot) } }
            }
            .tableStyle(.inset(alternatesRowBackgrounds: false))
            .overlay {
                if mounts.isEmpty {
                    ListEmptyStateView(.externalMounts)
                        .padding(.horizontal, 16)
                }
            }
        }
        .padding(24)
    }
}

struct ActivityScreen: View {
    let events: [LATCHEvent]
    let clear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScreenHeader(
                title: "Activity",
                subtitle: "Health and recovery events, with the newest event first.",
                actionTitle: "Clear",
                actionDisabled: events.isEmpty,
                action: clear
            )
            Table(events) {
                TableColumn("Status") { event in
                    ActivityStatusIcon(event: event)
                }
                .width(52)

                TableColumn("Event") { event in
                    Text(LATCHActivityEventPresentation(event: event).summary)
                        .fontWeight(.medium)
                        .lineLimit(2)
                }
                .width(min: 220, ideal: 320)

                TableColumn("State") { event in
                    Text(LATCHActivityEventPresentation(event: event).stateDetail)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .width(min: 180, ideal: 260)

                TableColumn("Date") { event in
                    Text(event.date.formatted(date: .abbreviated, time: .shortened))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .width(min: 130, ideal: 155, max: 180)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: false))
            .overlay {
                if events.isEmpty {
                    ListEmptyStateView(.activity)
                        .padding(.horizontal, 16)
                }
            }
        }
        .padding(24)
    }
}

struct ActivityRow: View {
    let event: LATCHEvent

    private var presentation: LATCHActivityEventPresentation {
        LATCHActivityEventPresentation(event: event)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ActivityStatusIcon(event: event)
            VStack(alignment: .leading, spacing: 2) {
                Text(presentation.summary).fontWeight(.medium)
                Text(presentation.stateDetail)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(event.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }

}

struct ActivityStatusIcon: View {
    let event: LATCHEvent

    private var indicator: LATCHActivityIndicator {
        LATCHActivityEventPresentation(event: event).indicator
    }

    var body: some View {
        Image(systemName: symbol)
            .foregroundStyle(color)
            .frame(width: 20)
            .accessibilityLabel(accessibilityLabel)
    }

    private var symbol: String {
        switch indicator {
        case .healthy: "checkmark.circle.fill"
        case .paused: "pause.circle.fill"
        case .progress: "arrow.triangle.2.circlepath.circle.fill"
        case .waiting: "clock.badge.exclamationmark.fill"
        case .issue: "exclamationmark.circle.fill"
        }
    }

    private var color: Color {
        switch indicator {
        case .healthy: .green
        case .paused: .gray
        case .progress: .blue
        case .waiting: .yellow
        case .issue: .red
        }
    }

    private var accessibilityLabel: String {
        switch indicator {
        case .healthy: "Healthy event"
        case .paused: "Paused event"
        case .progress: "Operation in progress"
        case .waiting: "Waiting for rules"
        case .issue: "Event requires attention"
        }
    }
}

struct MountEditorView: View {
    @State var draft: MountDraft
    let servers: [NFSServerProfile]
    let initialServer: NFSServerProfile?
    let status: MountStatus?
    let applyAndRemount: (MountDraft) async -> MountEditorSaveResult
    let save: (MountDraft, NFSServerProfile?) async -> MountEditorSaveResult
    @Environment(\.dismiss) private var dismiss
    @State private var showReset = false
    @State private var monitoringExpanded = false
    @State private var optionsExpanded = false
    @State private var dependenciesExpanded = false
    @State private var postMountActionsExpanded = false
    @State private var mountTargetConfirmed: Bool
    @State private var folderSelectionError: String?
    @State private var isSaving = false
    @State private var submissionError: String?
    @State private var connectionWasEdited = false
    private let isNew: Bool
    private let original: MountDraft

    private let homeDirectory = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path

    private var serverOptions: [NFSServerProfile] {
        guard let initialServer, !servers.contains(where: { $0.id == initialServer.id }) else { return servers }
        return servers + [initialServer]
    }

    private var serverSelectionPresentation: MountServerSelectionPresentation {
        MountServerSelectionPresentation(availableServerCount: serverOptions.count)
    }

    private var validationMessages: [String] {
        var messages: [String] = []
        if draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { messages.append("Enter a display name.") }
        let knownServer = serverOptions.contains { $0.id == draft.serverID }
        if !knownServer { messages.append("Select an NFS server.") }
        let serverPath = draft.exportPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !serverPath.hasPrefix("/") { messages.append("Enter an absolute server path beginning with /.") }
        if !mountTargetConfirmed { messages.append("Choose an existing empty mount folder.") }
        if let optionsError { messages.append(optionsError) }
        return messages
    }

    private var optionsError: String? {
        do {
            try draft.mountOptions.validate()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private var canApplyAndRemount: Bool {
        !isNew && status?.observedSource != nil
            && draft.serverID == original.serverID
            && draft.exportPath == original.exportPath
            && draft.mountPoint == original.mountPoint
    }

    private var recoveryCooldownMinutes: Binding<Int> {
        Binding(
            get: { draft.recoveryCooldownSeconds / 60 },
            set: { draft.recoveryCooldownSeconds = $0 * 60 }
        )
    }

    init(draft: MountDraft, servers: [NFSServerProfile], initialServer: NFSServerProfile? = nil, status: MountStatus? = nil, applyAndRemount: @escaping (MountDraft) async -> MountEditorSaveResult, save: @escaping (MountDraft, NFSServerProfile?) async -> MountEditorSaveResult) {
        _draft = State(initialValue: draft)
        self.servers = servers
        self.initialServer = initialServer
        self.status = status
        self.applyAndRemount = applyAndRemount
        self.save = save
        original = draft
        isNew = draft.displayName.isEmpty
        _mountTargetConfirmed = State(initialValue: !isNew)
        _folderSelectionError = State(initialValue: nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(isNew ? "Add Mount" : "Edit \(draft.displayName)").font(.title2).fontWeight(.semibold)
                    Text("Configure the connection first. Monitoring and recovery controls are optional.").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)

            Divider()

            Form {
                Section("Connection") {
                    TextField("Display name", text: $draft.displayName)
                        .onChange(of: draft.displayName) { _, _ in
                            connectionWasEdited = true
                        }
                    HStack(spacing: 12) {
                        Text("Server")
                        Spacer()
                        Picker("", selection: $draft.serverID) {
                            if !serverOptions.contains(where: { $0.id == draft.serverID }) {
                                Text("Select a server").tag(draft.serverID)
                            }
                            ForEach(serverOptions) { server in
                                Text("\(server.name) (\(server.hostname))").tag(server.id)
                            }
                        }
                        .labelsHidden()
                        .accessibilityLabel("Server")
                        .fixedSize()
                        .pronouncedPicker()
                        .disabled(!serverSelectionPresentation.canSelectServer)
                    }
                    .onChange(of: draft.serverID) { _, _ in connectionWasEdited = true }
                    if let guidance = serverSelectionPresentation.guidance {
                        FieldHint(guidance)
                    }
                    TextField("Server path", text: $draft.exportPath)
                        .accessibilityHint("The absolute NFS export path on the selected server.")
                        .onChange(of: draft.exportPath) { _, _ in connectionWasEdited = true }
                    FieldHint("The absolute NFS export path on the server, such as /volume1/Music.")
                    LabeledContent("Mount folder") {
                        HStack(spacing: 10) {
                            Text(MountFolderPresentation.displayText(
                                mountPoint: draft.mountPoint,
                                homeDirectory: homeDirectory,
                                confirmed: mountTargetConfirmed
                            ))
                                .foregroundStyle(mountTargetConfirmed ? Color.primary : Color.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button("Choose Folder…", action: chooseMountFolder)
                        }
                    }
                    Text(mountTargetConfirmed ? "LATCH will mount only into this existing empty folder." : "Select an existing empty folder in Finder before saving.")
                        .font(.caption)
                        .foregroundStyle(mountTargetConfirmed ? Color.secondary : Color.orange)
                    Toggle("Monitor this mount", isOn: $draft.enabled)
                    if connectionWasEdited, let firstMessage = validationMessages.first {
                        ValidationMessage(firstMessage)
                    }
                }

                Section {
                    FormDisclosureSection("Monitoring and Recovery Timing", isExpanded: $monitoringExpanded) {
                        OutlinedNumericStepperRow(title: "Probe interval", value: $draft.probeIntervalSeconds, range: 10...3600, step: 10, unit: "seconds")
                        OutlinedNumericStepperRow(title: "Probe timeout", value: $draft.probeTimeoutSeconds, range: 1...30, step: 1, unit: "seconds")
                        OutlinedNumericStepperRow(title: "Recovery cooldown", value: recoveryCooldownMinutes, range: 1...1440, step: 1, unit: "minutes")
                        Text("The probe timeout must remain shorter than the probe interval.").font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section {
                    FormDisclosureSection("Advanced NFS Options", isExpanded: $optionsExpanded) {
                        Picker("NFS version", selection: $draft.mountOptions.nfsVersion) {
                            Text("Automatic").tag(String?.none)
                            ForEach(["3", "4.0", "4.1"], id: \.self) { version in
                                Text(version).tag(Optional(version)).disabled(!NFSOptions.supportsVersion(version))
                            }
                        }
                        FieldHint("Automatic follows macOS’s normal protocol selection and may not choose the newest version. An explicit version must be verified and will not silently fall back. Unavailable versions are unsupported by this macOS NFS client.")
                        ForEach(NFSOptions.controls) { control in
                            VStack(alignment: .leading, spacing: 3) {
                                Toggle(control.title, isOn: Binding(get: { draft.mountOptions[control.key] }, set: { draft.mountOptions[control.key] = $0 }))
                                    .accessibilityHint(control.hint)
                                Text(control.hint).font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                        nfsConfigurationFields
                        if optionsError == nil {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Effective mount options").fontWeight(.medium)
                                Text(draft.mountOptions.encoded)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                FieldHint("Requested configuration; negotiated runtime values may differ. Validation does not prove macOS will honor additional options.")
                            }
                        }
                        if status?.observedSource != nil {
                            mountedNFSConfiguration
                        }
                        Button("Reset to Recommended Defaults…") { showReset = true }
                    }
                }

                Section {
                    FormDisclosureSection("Recovery Dependencies (\(draft.recoveryDependencies.count))", isExpanded: $dependenciesExpanded) {
                        ForEach(Array(draft.recoveryDependencies.indices), id: \.self) { index in
                            DependencyEditorRow(dependency: $draft.recoveryDependencies[index])
                            HStack {
                                Button("Move Up") { moveDependency(from: index, by: -1) }.disabled(index == 0)
                                Button("Move Down") { moveDependency(from: index, by: 1) }.disabled(index == draft.recoveryDependencies.count - 1)
                                Spacer()
                                Button("Remove", role: .destructive) { draft.recoveryDependencies.remove(at: index) }
                            }
                            if index != draft.recoveryDependencies.count - 1 { Divider() }
                        }
                        Menu("Add Dependency") {
                            Button("Docker Container") { draft.recoveryDependencies.append(.init(kind: .dockerContainer(.init(containerName: "container", dockerSocketPath: "/Users/Shared/docker.sock", composeFilePath: nil)))) }
                            Button("macOS Application") { draft.recoveryDependencies.append(.init(kind: .macApplication(.init(bundleIdentifier: "com.example.Application", applicationURL: nil, forceQuitAfterTimeout: false)))) }
                        }
                    }
                }

                Section {
                    FormDisclosureSection("Post-Mount Actions (\(draft.postMountActions.count))", isExpanded: $postMountActionsExpanded) {
                        ForEach(Array(draft.postMountActions.indices), id: \.self) { index in
                            PostMountActionEditorRow(action: $draft.postMountActions[index])
                            HStack {
                                Spacer()
                                Button("Remove", role: .destructive) { draft.postMountActions.remove(at: index) }
                            }
                            if index != draft.postMountActions.count - 1 { Divider() }
                        }
                        Menu("Add Post-Mount Action") {
                            Button("Reveal in Finder") { draft.postMountActions.append(.revealInFinder) }
                            Button("Open Application") { draft.postMountActions.append(.openApplication(bundleIdentifier: "com.example.Application", applicationURL: nil)) }
                            Button("Open Relative Path") { draft.postMountActions.append(.openRelativePath(".")) }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .textFieldStyle(.roundedBorder)

            Divider()

            if !isNew {
                Text("Save Changes stores settings for the next mount. Applying them to the current mount requires a remount. Apply and Remount pauses configured dependencies and attempts to restore the previous configuration on failure.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
            }
            HStack {
                if let submissionError {
                    Label(submissionError, systemImage: "exclamationmark.circle.fill")
                        .font(.caption).foregroundStyle(.red)
                        .lineLimit(nil)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(isSaving)
                if !isNew {
                    Button("Apply and Remount") {
                        Task { await submit(remount: true) }
                    }
                    .disabled(!validationMessages.isEmpty || isSaving || !canApplyAndRemount)
                    .help("Requires a mounted share and unchanged server, server path, and mount folder.")
                }
                Button {
                    Task { await submit(remount: false) }
                } label: {
                    if isSaving { ProgressView().controlSize(.small) } else { Text(EditorPrimaryActionTitle.title(isNew: isNew)) }
                }
                .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!validationMessages.isEmpty || isSaving)
            }
            .padding(16)
        }
        .frame(width: 660, height: 520)
        .confirmationDialog("Reset NFS options?", isPresented: $showReset) {
            Button("Reset Options", role: .destructive) { draft.mountOptions = .recommended }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Reset all option toggles, use Automatic NFS version and Default request sizes, and clear Additional mount options.")
        }
        .alert("Choose Another Folder", isPresented: Binding(get: { folderSelectionError != nil }, set: { if !$0 { folderSelectionError = nil } })) {
            Button("OK") { folderSelectionError = nil }
        } message: {
            Text(folderSelectionError ?? "")
        }
    }

    private var nfsConfigurationFields: some View {
        Group {
            transferSizePicker("Read request size", selection: $draft.mountOptions.readSizeBytes)
            transferSizePicker("Write request size", selection: $draft.mountOptions.writeSizeBytes)
            FieldHint("These are requested sizes; negotiated sizes may differ. Larger sizes do not always improve performance. This client supports sizes up to \(sizeLabel(NFSOptions.maximumTransferSize)).")
            VStack(alignment: .leading, spacing: 5) {
                Text("Additional mount options")
                TextEditor(text: $draft.mountOptions.additionalMountOptions)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 58, maxHeight: 100)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(.separator))
                    .accessibilityLabel("Additional mount options")
                if let optionsError { ValidationMessage(optionsError) }
                FieldHint("Enter comma-separated options only, such as readahead=32,acregmax=30. Do not enter -o, a command, server address, or mount path. Unsupported options can cause mounting to fail.")
            }
        }
    }

    private func transferSizePicker(_ title: String, selection: Binding<Int?>) -> some View {
        Picker(title, selection: selection) {
            Text("Default").tag(Int?.none)
            ForEach(NFSOptions.transferSizes, id: \.self) { size in
                Text(sizeLabel(size)).tag(Optional(size)).disabled(size > NFSOptions.maximumTransferSize)
            }
        }
    }

    private var mountedNFSConfiguration: some View {
        let observed = NFSObservedOptions(options: status?.observedMountOptions ?? [])
        return VStack(alignment: .leading, spacing: 8) {
            Text("Current mount").fontWeight(.medium)
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                GridRow {
                    Text("Setting")
                    Text("Requested (saved)")
                    Text("Observed")
                }.fontWeight(.medium)
                GridRow {
                    Text("NFS version")
                    Text(original.mountOptions.nfsVersion ?? "Automatic")
                    Text(observed.version ?? "Unknown")
                }
                GridRow {
                    Text("Transport")
                    Text(original.mountOptions.requireTCP ? "TCP" : "Automatic")
                    Text(observed.transport?.uppercased() ?? "Unknown")
                }
                GridRow {
                    Text("Read request size")
                    Text(original.mountOptions.readSizeBytes.map(sizeLabel) ?? "Default")
                    Text(observed.readSizeBytes.map(sizeLabel) ?? "Unknown")
                }
                GridRow {
                    Text("Write request size")
                    Text(original.mountOptions.writeSizeBytes.map(sizeLabel) ?? "Default")
                    Text(observed.writeSizeBytes.map(sizeLabel) ?? "Unknown")
                }
            }
            .font(.caption)
            if let requested = original.mountOptions.nfsVersion, let actual = observed.version, requested != actual {
                ValidationMessage("Protocol mismatch: requested NFS \(requested), observed NFS \(actual). Remount or recover this share before using it.")
            }
            FieldHint("Observed values come from macOS NFS mount information. Unknown means the value is unavailable.")
        }
    }

    private func sizeLabel(_ bytes: Int) -> String {
        bytes >= 1_048_576 ? "\(bytes / 1_048_576) MiB" : "\(bytes / 1024) KiB"
    }

    private func submit(remount: Bool) async {
        isSaving = true
        submissionError = nil
        let result = if remount { await applyAndRemount(draft) } else { await save(draft, initialServer) }
        switch result {
        case .saved: dismiss()
        case .failed(let detail): submissionError = detail
        }
        isSaving = false
    }

    private func chooseMountFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Mount Folder"
        panel.message = MountFolderPickerPresentation.message
        panel.prompt = "Choose Mount Folder"
        panel.directoryURL = MountFolderPickerPresentation.initialDirectory(
            mountPoint: draft.mountPoint,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            confirmed: mountTargetConfirmed
        )
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            draft.mountPoint = try ExistingMountTargetValidator().validate(
                url.standardizedFileURL.path,
                allowedRoots: [homeDirectory, "/Volumes/Media"],
                requiredOwnerID: getuid(),
                requireEmpty: true
            )
            mountTargetConfirmed = true
        } catch {
            folderSelectionError = error.localizedDescription
        }
    }

    private func moveDependency(from index: Int, by offset: Int) {
        let destination = index + offset
        guard draft.recoveryDependencies.indices.contains(destination) else { return }
        draft.recoveryDependencies.swapAt(index, destination)
    }
}

struct DependencyEditorRow: View {
    @Binding var dependency: RecoveryDependency
    @State private var showForceQuitConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Enabled", isOn: $dependency.enabled)
            Stepper("Stop timeout: \(dependency.stopTimeoutSeconds) seconds", value: $dependency.stopTimeoutSeconds, in: 1...300)
            switch dependency.kind {
            case .dockerContainer:
                TextField("Container name", text: dockerBinding(\.containerName))
                TextField("Docker socket path", text: dockerBinding(\.dockerSocketPath))
                TextField("Compose file path (optional)", text: Binding(
                    get: { dockerValue.composeFilePath ?? "" },
                    set: { var value = dockerValue; value.composeFilePath = $0.isEmpty ? nil : $0; dependency.kind = .dockerContainer(value) }
                ))
            case .macApplication:
                TextField("Bundle identifier", text: appBinding(\.bundleIdentifier))
                TextField("Application path hint (optional)", text: Binding(
                    get: { appValue.applicationURL ?? "" },
                    set: { var value = appValue; value.applicationURL = $0.isEmpty ? nil : $0; dependency.kind = .macApplication(value) }
                ))
                Toggle("Force quit after timeout", isOn: Binding(
                    get: { appValue.forceQuitAfterTimeout },
                    set: { enabled in
                        if enabled { showForceQuitConfirmation = true }
                        else { var value = appValue; value.forceQuitAfterTimeout = false; dependency.kind = .macApplication(value) }
                    }
                ))
            }
        }
        .padding(.vertical, 6)
        .confirmationDialog("Enable force quit?", isPresented: $showForceQuitConfirmation) {
            Button("Enable Force Quit", role: .destructive) { var value = appValue; value.forceQuitAfterTimeout = true; dependency.kind = .macApplication(value) }
            Button("Cancel", role: .cancel) {}
        } message: { Text("LATCH force-quits only after the graceful timeout and after validating a reliable relaunch target.") }
    }

    private var dockerValue: DockerContainerDependency {
        guard case .dockerContainer(let value) = dependency.kind else { return .init(containerName: "", dockerSocketPath: "", composeFilePath: nil) }
        return value
    }

    private var appValue: MacApplicationDependency {
        guard case .macApplication(let value) = dependency.kind else { return .init(bundleIdentifier: "", applicationURL: nil, forceQuitAfterTimeout: false) }
        return value
    }

    private func dockerBinding(_ keyPath: WritableKeyPath<DockerContainerDependency, String>) -> Binding<String> {
        Binding(get: { dockerValue[keyPath: keyPath] }, set: { var value = dockerValue; value[keyPath: keyPath] = $0; dependency.kind = .dockerContainer(value) })
    }

    private func appBinding(_ keyPath: WritableKeyPath<MacApplicationDependency, String>) -> Binding<String> {
        Binding(get: { appValue[keyPath: keyPath] }, set: { var value = appValue; value[keyPath: keyPath] = $0; dependency.kind = .macApplication(value) })
    }
}
