import SwiftUI
import LATCHShared

struct OverviewScreen: View {
    let overview: LATCHOverview
    let definitions: [MountDefinition]
    let configuration: LATCHConfiguration
    let statuses: [MountStatus]
    let events: [LATCHEvent]
    let finishSetup: () -> Void
    let viewActivity: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if !overview.setupRequirements.isEmpty {
                    HStack(spacing: 16) {
                        Image(systemName: "exclamationmark.circle")
                            .font(.system(size: 34, weight: .medium)).foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(LATCHInterfaceCopy.setupRequiredTitle).font(.title2).fontWeight(.semibold)
                            Text(setupDetail).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Finish Setup", action: finishSetup).buttonStyle(.borderedProminent).controlSize(.large)
                    }
                    .padding(18)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator.opacity(0.7)))
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Managed Mounts").font(.title2).fontWeight(.semibold)
                            Text("\(overview.totalManaged) mount\(overview.totalManaged == 1 ? "" : "s") • \(overview.healthy) healthy")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }

                    if definitions.isEmpty {
                        ListEmptyStateView(.managedMounts)
                    } else {
                        VStack(spacing: 0) {
                            ManagedSummaryHeaderRow()
                            Divider()
                            ForEach(definitions) { definition in
                                ManagedSummaryRow(
                                    definition: definition,
                                    source: configuration.resolve(definition)?.source ?? "Unknown server",
                                    status: statuses.first { $0.definitionID == definition.id }
                                )
                                if definition.id != definitions.last?.id { Divider() }
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Recent Activity").font(.title2).fontWeight(.semibold)
                        Spacer()
                    }
                    switch LATCHActivitySectionPresentation(events: events) {
                    case .empty:
                        ListEmptyStateView(.activity)
                    case .events(let displayedEvents):
                        VStack(spacing: 0) {
                            ForEach(displayedEvents) { event in
                                ActivityRow(event: event)
                                if event.id != displayedEvents.last?.id { Divider() }
                            }
                        }
                        Button("View All Activity…", action: viewActivity)
                            .buttonStyle(.link)
                    }
                }
            }
            .padding(24)
        }
    }

    private var setupDetail: String {
        if overview.setupRequirements.count == 1, let requirement = overview.setupRequirements.first {
            return "\(requirement.title) to enable guarded automatic recovery."
        }
        return "Complete the remaining service approvals before guarded recovery is enabled."
    }
}

struct ManagedMountsScreen: View {
    let definitions: [MountDefinition]
    let configuration: LATCHConfiguration
    let statuses: [MountStatus]
    let operations: [OperationSnapshot]
    let addMount: () -> Void
    let edit: (MountDefinition) -> Void
    let remove: (MountDefinition) -> Void
    let action: (LATCHAction, MountDefinition) -> Void
    let cancel: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScreenHeader(
                title: "Managed Mounts",
                subtitle: "Configured NFS mounts that LATCH monitors and recovers.",
                actionTitle: "Add Mount",
                action: addMount
            )
            Table(definitions) {
                TableColumn("Status") { definition in
                    let status = statuses.first { $0.definitionID == definition.id }
                    let operation = operations.first { $0.mountID == definition.id }
                    HStack(spacing: 8) {
                        ManagedMountActions(
                            definition: definition,
                            canReveal: status?.observedSource == configuration.resolve(definition)?.source,
                            operation: operation,
                            edit: { edit(definition) },
                            remove: { remove(definition) },
                            action: { action($0, definition) },
                            cancel: cancel
                        )
                        MountStatusIndicatorDot(status: status, enabled: definition.enabled)
                    }
                }
                .width(64)

                TableColumn("Volume") { definition in
                    HStack(spacing: 9) {
                        Image(systemName: "folder.fill")
                            .foregroundStyle(.blue)
                            .accessibilityHidden(true)
                        Text(definition.displayName)
                            .fontWeight(.medium)
                            .lineLimit(1)
                    }
                }
                .width(min: 125, ideal: 150, max: 175)

                TableColumn("Source") { definition in
                    Text(configuration.resolve(definition)?.source ?? "Unknown server")
                        .lineLimit(1)
                        .help(configuration.resolve(definition)?.source ?? "Unknown server")
                }
                .width(min: 140, ideal: 160, max: 195)

                TableColumn("Mountpoint") { definition in
                    Text(definition.mountPoint)
                        .lineLimit(1)
                        .help(definition.mountPoint)
                }
                .width(min: 125, ideal: 150, max: 185)

                TableColumn("State") { definition in
                    let status = statuses.first { $0.definitionID == definition.id }
                    let operation = operations.first { $0.mountID == definition.id }
                    VStack(alignment: .leading, spacing: 2) {
                        if let operation {
                            Text(operation.detail ?? "Operation in progress").lineLimit(2)
                        } else {
                            MountStatusLabel(status: status, enabled: definition.enabled)
                        }
                        if let summaries = status?.unmetRuleSummaries, !summaries.isEmpty {
                            Text(summaries.joined(separator: ", ")).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
                .width(min: 145, ideal: 170, max: 205)

            }
            .overlay {
                if definitions.isEmpty {
                    ListEmptyStateView(.managedMounts)
                        .padding(.horizontal, 16)
                }
            }
        }
        .padding(24)
    }
}

struct ServersScreen: View {
    let servers: [NFSServerProfile]
    let mounts: [MountDefinition]
    let statuses: [MountStatus]
    let discovered: [DiscoveredNFSServer]
    let addServer: () -> Void
    let edit: (NFSServerProfile) -> Void
    let remove: (NFSServerProfile) -> Void
    let wake: (NFSServerProfile) -> Void
    let configureDiscovery: (DiscoveredNFSServer) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScreenHeader(
                title: "Servers",
                subtitle: "NFS hosts and the network conditions required before LATCH performs automatic work.",
                actionTitle: "Add Server",
                action: addServer
            )
            if !discovered.isEmpty {
                GroupBox("Local NFS discovery") {
                    ForEach(discovered) { server in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(server.name).fontWeight(.medium)
                                Text(server.hostname ?? "Bonjour service has not resolved a host.").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Configure") { configureDiscovery(server) }.disabled(server.configurationTemplate == nil)
                        }
                    }
                }
            }
            Table(servers) {
                TableColumn("Status") { server in
                    let presentation = automationPresentation(for: server)
                    HStack(spacing: 8) {
                        Menu {
                            Button("Edit") { edit(server) }
                            if server.wakeOnLAN != nil { Button("Wake") { wake(server) } }
                            Button("Remove", role: .destructive) { remove(server) }
                        } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton)
                        Circle()
                            .fill(presentation.indicator == .ready ? Color.green : Color.red)
                            .frame(width: 9, height: 9)
                            .accessibilityLabel(presentation.indicator == .ready ? "Ready" : "Blocked")
                    }
                }
                .width(64)
                TableColumn("Name") { server in Text(server.name).fontWeight(.medium) }
                TableColumn("Host") { server in Text(server.hostname).textSelection(.enabled) }
                TableColumn("Rules") { server in
                    let presentation = automationPresentation(for: server)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(presentation.ruleStatusTitle)
                            .foregroundStyle(presentation.indicator == .blocked ? .orange : .secondary)
                        if !presentation.ruleStatusDetails.isEmpty {
                            Text(presentation.ruleStatusDetails.joined(separator: ", "))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
            }
            .overlay {
                if servers.isEmpty {
                    ListEmptyStateView(.servers)
                        .padding(.horizontal, 16)
                }
            }
        }
        .padding(24)
    }

    private func automationPresentation(for server: NFSServerProfile) -> ServerAutomationPresentation {
        ServerAutomationPresentation(server: server, mounts: mounts, statuses: statuses)
    }
}

struct ServerEditorView: View {
    @State private var server: NFSServerProfile
    @State private var ruleEditor: NetworkRuleEditorState
    let save: (NFSServerProfile) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var routeCIDR = ""
    @State private var interfaceName = ""
    @State private var networkRulesExpanded = false
    @State private var isSaving = false
    @State private var submissionError: String?
    @State private var nameWasEdited = false
    @State private var hostnameWasEdited = false
    private let isNew: Bool

    init(server: NFSServerProfile, save: @escaping (NFSServerProfile) async -> Bool) {
        _server = State(initialValue: server)
        _ruleEditor = State(initialValue: NetworkRuleEditorState(rules: server.networkMountRules.rules))
        self.save = save
        isNew = server.name.isEmpty && server.hostname.isEmpty
    }

    private var validationIssues: [ServerEditorIssue] { ServerEditorValidation.issues(for: server) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(isNew ? "Add Server" : "Edit Server").font(.title2).fontWeight(.semibold)
                    Text("Start with the server name and address. Automation options are optional.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)
            Divider()

            Form {
                Section("Server") {
                    VStack(alignment: .leading, spacing: 5) {
                        TextField("Name", text: $server.name)
                            .accessibilityHint("A familiar name used only inside LATCH.")
                            .onChange(of: server.name) { _, _ in nameWasEdited = true }
                        FieldHint("A familiar name, such as Media NAS.")
                        if nameWasEdited, let issue = validationIssues.first(where: { $0.field == .name }) { ValidationMessage(issue.message) }
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        TextField("Host", text: $server.hostname)
                            .accessibilityHint("The DNS name or IP address of the NFS server, without a port.")
                            .onChange(of: server.hostname) { _, _ in hostnameWasEdited = true }
                        FieldHint("A DNS name or IP address, such as nas.local or 192.168.1.20. Do not include a port or path.")
                        if hostnameWasEdited, let issue = validationIssues.first(where: { $0.field == .hostname }) { ValidationMessage(issue.message) }
                    }
                }

                Section {
                    FormDisclosureSection("Network Rules (\(server.networkMountRules.rules.count))", isExpanded: $networkRulesExpanded) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 12) {
                                Text("Match")
                                Spacer()
                                Picker("", selection: $server.networkMountRules.combinator) {
                                    Text("All rules").tag(NetworkRuleCombinator.all)
                                    Text("Any rule").tag(NetworkRuleCombinator.any)
                                }
                                .labelsHidden()
                                .accessibilityLabel("Match network rules")
                                .fixedSize()
                                .pronouncedPicker()
                            }
                            FieldHint("Choose whether every configured rule must pass, or whether any one rule is enough.")
                        }

                        NetworkRuleControlGroup {
                            HStack {
                                Text("Require NFS TCP service")
                                Spacer()
                                Toggle("", isOn: Binding(
                                    get: { ruleEditor.requiresNFSService },
                                    set: { enabled in updateRuleEditor { $0.setNFSServiceRequired(enabled) } }
                                ))
                                .labelsHidden()
                                .accessibilityLabel("Require NFS TCP service")
                            }
                            FieldHint("Automatic work waits until this host accepts TCP connections on the standard NFS port 2049.")
                        }

                        NetworkRuleControlGroup {
                            HStack {
                                Text("Require tunnel interface")
                                Spacer()
                                Toggle("", isOn: Binding(
                                    get: { ruleEditor.requiresTunnelInterface },
                                    set: { enabled in updateRuleEditor { $0.setTunnelInterfaceRequired(enabled) } }
                                ))
                                .labelsHidden()
                                .accessibilityLabel("Require tunnel interface")
                            }
                            FieldHint("Automatic work waits for an active VPN or tunnel interface such as utun, ipsec, ppp, tun, or tap.")
                        }

                        NetworkRuleControlGroup {
                            HStack {
                                Text("Require connection type")
                                Spacer()
                                Picker("", selection: Binding(
                                    get: { ruleEditor.connectionTypeSelection.rawValue },
                                    set: { value in
                                        guard let type = NetworkInterfaceType(rawValue: value) else { return }
                                        updateRuleEditor { $0.setConnectionType(type) }
                                    }
                                )) {
                                    Text("Wi-Fi").tag(NetworkInterfaceType.wifi.rawValue)
                                    Text("Ethernet").tag(NetworkInterfaceType.ethernet.rawValue)
                                    Text("Other").tag(NetworkInterfaceType.other.rawValue)
                                }
                                .labelsHidden()
                                .accessibilityLabel("Connection type")
                                .frame(width: 130)
                                .pronouncedPicker()
                                .disabled(!ruleEditor.requiresConnectionType)
                                Toggle("", isOn: Binding(
                                    get: { ruleEditor.requiresConnectionType },
                                    set: { enabled in updateRuleEditor { $0.setConnectionTypeRequired(enabled) } }
                                ))
                                .labelsHidden()
                                .accessibilityLabel("Require connection type")
                            }
                            FieldHint("Automatic work waits for an active interface of the selected connection type.")
                        }

                        NetworkRuleControlGroup {
                            HStack {
                                TextField("Route CIDR", text: $routeCIDR)
                                Button { add(.routeAvailable(routeCIDR)); routeCIDR = "" } label: {
                                    Text("Add Route").frame(width: 104)
                                }
                                .disabled(routeCIDR.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                            FieldHint("Require a route to a network in CIDR notation, such as 192.168.1.0/24.")
                            ForEach(Array(ruleEditor.routeRules.enumerated()), id: \.offset) { _, rule in
                                SavedNetworkRuleRow(rule: rule) { removeRule(rule) }
                            }
                        }

                        NetworkRuleControlGroup {
                            HStack {
                                TextField("Interface name", text: $interfaceName)
                                Button { add(.interfaceName(interfaceName)); interfaceName = "" } label: {
                                    Text("Add Interface").frame(width: 104)
                                }
                                .disabled(interfaceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                            FieldHint("Require a specific active macOS interface, such as en0 or utun3.")
                            ForEach(Array(ruleEditor.interfaceNameRules.enumerated()), id: \.offset) { _, rule in
                                SavedNetworkRuleRow(rule: rule) { removeRule(rule) }
                            }
                        }

                        if let issue = validationIssues.first(where: { $0.field == .networkRules }) { ValidationMessage(issue.message) }
                    }
                } header: {
                    Text("Automation Conditions")
                } footer: {
                    Text("When a rule is not satisfied, LATCH leaves existing mounts alone and pauses automatic checks and mounts.")
                }

                Section("Wake-on-LAN") {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Enable Wake-on-LAN", isOn: Binding(
                            get: { server.wakeOnLAN != nil },
                            set: { enabled in server.wakeOnLAN = enabled ? .init(macAddress: "") : nil }
                        ))
                        FieldHint("Send a wake packet when network rules pass but the NFS service is unavailable.")
                    }
                    if server.wakeOnLAN != nil {
                        TextField("MAC address", text: wakeBinding(\.macAddress))
                        FieldHint("The server network adapter address, such as AA:BB:CC:DD:EE:FF.")
                        TextField("Broadcast override (optional)", text: Binding(
                            get: { server.wakeOnLAN?.broadcastAddress ?? "" },
                            set: { value in server.wakeOnLAN?.broadcastAddress = value.isEmpty ? nil : value }
                        ))
                        FieldHint("Leave blank to use active interface broadcasts, or enter a specific IPv4 broadcast address.")
                        FieldHint("LATCH sends three UDP packets on port 9 and rate-limits automatic wake attempts.")
                    }
                    if let issue = validationIssues.first(where: { $0.field == .wakeOnLAN }) { ValidationMessage(issue.message) }
                }
            }
            .formStyle(.grouped)
            .textFieldStyle(.roundedBorder)
            Divider()
            HStack {
                if let submissionError {
                    Label(submissionError, systemImage: "exclamationmark.circle.fill")
                        .font(.caption).foregroundStyle(.red).lineLimit(2)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(isSaving)
                Button {
                    Task {
                        isSaving = true
                        submissionError = nil
                        if await save(server) {
                            dismiss()
                        } else {
                            submissionError = "The server was not saved. Check the daemon status in Settings, then try again."
                        }
                        isSaving = false
                    }
                } label: {
                    if isSaving { ProgressView().controlSize(.small) } else { Text(EditorPrimaryActionTitle.title(isNew: isNew)) }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!validationIssues.isEmpty || isSaving)
            }
            .padding(16)
        }
        .frame(width: 580, height: 620)
    }

    private func add(_ rule: NetworkMountRule) {
        guard !ruleEditor.rules.contains(rule) else { return }
        ruleEditor.rules.append(rule)
        server.networkMountRules.rules = ruleEditor.rules
    }

    private func updateRuleEditor(_ update: (inout NetworkRuleEditorState) -> Void) {
        update(&ruleEditor)
        server.networkMountRules.rules = ruleEditor.rules
    }

    private func removeRule(_ rule: NetworkMountRule) {
        updateRuleEditor { $0.remove(rule) }
    }

    private func wakeBinding(_ keyPath: WritableKeyPath<WakeOnLANSettings, String>) -> Binding<String> {
        Binding(get: { server.wakeOnLAN?[keyPath: keyPath] ?? "" }, set: { server.wakeOnLAN?[keyPath: keyPath] = $0 })
    }

}
