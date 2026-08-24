import SwiftUI
import LATCHShared

struct ScreenHeader: View {
    let title: String
    let subtitle: String
    var actionTitle: String? = nil
    var actionDisabled = false
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.title2).fontWeight(.semibold)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(actionDisabled)
            }
        }
    }
}
struct LATCHSettingsScreen: View {
    let daemonState: ManagedServiceState
    let agentState: ManagedServiceState
    let mainApplicationState: ManagedServiceState
    let startAtLoginEnabled: Bool
    let daemonOnline: Bool
    let agentOnline: Bool
    let serviceSetupInProgress: Bool
    let persistenceDegraded: Bool
    @Binding var notificationsEnabled: Bool
    @Binding var prolongedUnavailableSeconds: Int
    let installServices: () -> Void
    let removeServices: () -> Void
    let openLoginItems: () -> Void
    let setStartAtLogin: @Sendable (Bool) -> Void
    let exportDiagnostics: () -> Void
    let exportConfiguration: () -> Void
    let importConfiguration: () -> Void
    let importPreview: PortableImportPreview?
    let applyImport: (Set<UUID>, Set<UUID>) -> Void
    let cancelImport: () -> Void
    @State private var approvedServerIDs: Set<UUID> = []
    @State private var approvedMountIDs: Set<UUID> = []

    private var prolongedUnavailableMinutes: Binding<Int> {
        Binding(
            get: { NotificationDelayPolicy.minutes(forSeconds: prolongedUnavailableSeconds) },
            set: { prolongedUnavailableSeconds = NotificationDelayPolicy.seconds(forMinutes: $0) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScreenHeader(
                title: "Settings",
                subtitle: "Service setup, notifications, configuration portability, and support."
            )
            .padding(.horizontal, 24)
            .padding(.top, 20)

            Form {
                Section(LATCHInterfaceCopy.setupSectionTitle) {
                    if persistenceDegraded {
                        HStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text(LATCHInterfaceCopy.persistenceDegradedMessage)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .padding(10)
                        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    }

                    ManagedServicesSetupRow(
                        presentation: .init(
                            daemon: daemonState,
                            loginAgent: agentState,
                            daemonOnline: daemonOnline,
                            agentOnline: agentOnline,
                            setupInProgress: serviceSetupInProgress
                        ),
                        install: installServices,
                        openLoginItems: openLoginItems,
                        remove: removeServices
                    )
                    StartAtLoginRow(
                        isEnabled: startAtLoginEnabled,
                        serviceState: mainApplicationState,
                        setEnabled: setStartAtLogin
                    )
                }

                Section("Notifications") {
                    Toggle("Recovery and availability notifications", isOn: $notificationsEnabled)
                    HStack(spacing: 8) {
                        Text("Notify after")
                        Text("\(NotificationDelayPolicy.minutes(forSeconds: prolongedUnavailableSeconds))")
                            .monospacedDigit()
                            .frame(minWidth: 28)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(.separator.opacity(0.9)))
                        Stepper("", value: prolongedUnavailableMinutes, in: NotificationDelayPolicy.minuteRange)
                            .labelsHidden()
                            .fixedSize()
                            .accessibilityLabel("Notification delay in minutes")
                            .accessibilityValue(NotificationDelayPolicy.accessibilityValue(forSeconds: prolongedUnavailableSeconds))
                        Text("minutes unavailable")
                        Spacer()
                    }
                        .disabled(!notificationsEnabled)
                }

                Section("Support") {
                    Button(LATCHInterfaceCopy.exportDiagnosticsTitle, action: exportDiagnostics)
                    Button(LATCHInterfaceCopy.exportConfigurationTitle, action: exportConfiguration)
                    Button(LATCHInterfaceCopy.importConfigurationTitle, action: importConfiguration)
                }

                Section("About") {
                    LabeledContent("LATCH", value: LATCHIdentity.expandedName)
                }
            }
            .formStyle(.grouped)
        }
        .sheet(isPresented: Binding(get: { importPreview != nil }, set: { if !$0 { cancelImport() } })) {
            if let importPreview {
                ConfigurationImportPreviewSheet(
                    preview: importPreview,
                    approvedServerIDs: $approvedServerIDs,
                    approvedMountIDs: $approvedMountIDs,
                    apply: { applyImport(approvedServerIDs, approvedMountIDs) },
                    cancel: cancelImport
                )
                .onAppear {
                    approvedServerIDs = Set(importPreview.items.filter { $0.kind == .server && $0.isApprovable }.map(\.id))
                    approvedMountIDs = Set(importPreview.items.filter { $0.kind == .mount && $0.isApprovable }.map(\.id))
                }
            }
        }
    }
}

struct ConfigurationImportPreviewSheet: View {
    let preview: PortableImportPreview
    @Binding var approvedServerIDs: Set<UUID>
    @Binding var approvedMountIDs: Set<UUID>
    let apply: () -> Void
    let cancel: () -> Void

    private var approvedItemCount: Int { approvedServerIDs.count + approvedMountIDs.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import Configuration").font(.title2).fontWeight(.semibold)
            Text("Choose the additions and same-ID updates to merge. LATCH does not delete local configuration. Conflicts stay disabled until you resolve them manually.")
                .foregroundStyle(.secondary)
            List {
                Section("Servers") {
                    ForEach(preview.items.filter { $0.kind == .server }) { item in
                        ImportPreviewRow(item: item, selected: binding(for: item))
                    }
                }
                Section("Mounts") {
                    ForEach(preview.items.filter { $0.kind == .mount }) { item in
                        ImportPreviewRow(item: item, selected: binding(for: item))
                    }
                }
            }
            HStack {
                Button("Cancel", action: cancel)
                Spacer()
                Button("Apply \(approvedItemCount) Item\(approvedItemCount == 1 ? "" : "s")", action: apply)
                    .buttonStyle(.borderedProminent)
                    .disabled(approvedItemCount == 0)
            }
        }
        .padding(24)
        .frame(minWidth: 600, minHeight: 440)
    }

    private func binding(for item: PortableImportItem) -> Binding<Bool> {
        Binding(
            get: {
                switch item.kind {
                case .server: approvedServerIDs.contains(item.id)
                case .mount: approvedMountIDs.contains(item.id)
                }
            },
            set: { selected in
                switch item.kind {
                case .server:
                    if selected {
                        approvedServerIDs.insert(item.id)
                    } else {
                        approvedServerIDs.remove(item.id)
                        for mount in preview.items where mount.kind == .mount && mount.serverID == item.id {
                            approvedMountIDs.remove(mount.id)
                        }
                    }
                case .mount:
                    if selected {
                        approvedMountIDs.insert(item.id)
                        if let serverID = item.serverID,
                           preview.item(kind: .server, id: serverID)?.isApprovable == true {
                            approvedServerIDs.insert(serverID)
                        }
                    } else {
                        approvedMountIDs.remove(item.id)
                    }
                }
            }
        )
    }
}

struct ImportPreviewRow: View {
    let item: PortableImportItem
    @Binding var selected: Bool

    var body: some View {
        Toggle(isOn: $selected) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                Text(detail).font(.caption).foregroundStyle(item.isApprovable ? Color.secondary : Color.red)
            }
        }
        .disabled(!item.isApprovable)
    }

    private var detail: String {
        if let explanation = item.conflictExplanation { return explanation }
        return item.disposition == .addition ? "Will be added" : "Will update the item with the same ID"
    }
}

struct ManagedServicesSetupRow: View {
    let presentation: ManagedServicesPresentation
    let install: () -> Void
    let openLoginItems: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .font(.title3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Monitoring services").fontWeight(.medium)
                Text("The privileged daemon manages mounts; the login agent performs work in your user session.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Monitoring services, \(presentation.statusText)")
            Spacer()
            Text(presentation.statusText)
                .font(.subheadline)
                .foregroundStyle(color)
                .accessibilityHidden(true)
            Button(actionTitle, action: action)
                .accessibilityHint("Changes monitoring service setup")
        }
        .padding(.vertical, 4)
    }

    private var action: () -> Void {
        switch presentation.action {
        case .install, .repair: install
        case .openLoginItems: openLoginItems
        case .remove: remove
        }
    }

    private var actionTitle: String {
        switch presentation.action {
        case .install: "Install"
        case .repair: "Repair"
        case .openLoginItems: "Open Login Items"
        case .remove: "Remove"
        }
    }

    private var symbol: String {
        switch presentation.statusText {
        case "Ready": "checkmark.circle.fill"
        case "Needs Approval": "exclamationmark.circle.fill"
        case "Starting Services", "Installing": "arrow.trianglehead.2.clockwise.rotate.90.circle.fill"
        case "Daemon Offline", "Login Agent Offline": "xmark.circle.fill"
        default: "circle"
        }
    }

    private var color: Color {
        switch presentation.statusText {
        case "Ready": .green
        case "Needs Approval": .orange
        case "Starting Services", "Installing": .blue
        case "Daemon Offline", "Login Agent Offline": .red
        default: .secondary
        }
    }
}

struct StartAtLoginRow: View {
    let isEnabled: Bool
    let serviceState: ManagedServiceState
    let setEnabled: @Sendable (Bool) -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Start at login").fontWeight(.medium)
                Text("Opens LATCH and its menu-bar controls when you sign in.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if serviceState == .requiresApproval {
                Text("Needs Approval")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
            }
            Toggle(
                "Start at login",
                isOn: Binding(get: { isEnabled }, set: setEnabled)
            )
            .labelsHidden()
            .disabled(serviceState == .notFound)
        }
        .padding(.vertical, 4)
    }
}
