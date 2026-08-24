import AppKit
import LATCHShared
import SwiftUI

struct LATCHMenu: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    private var overview: LATCHOverview {
        LATCHOverview(definitions: model.configuration.mounts, statuses: model.statuses, services: model.serviceStatus)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: model.aggregateSymbol)
                    .font(.title2)
                    .foregroundStyle(headerColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("LATCH").font(.headline)
                    Text(headerStatus).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Refresh status")
                    .accessibilityLabel("Refresh status")
            }

            Divider()

            if !overview.setupRequirements.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(LATCHInterfaceCopy.setupRequiredTitle).fontWeight(.semibold)
                        Text("Complete \(overview.setupRequirements.count) remaining step\(overview.setupRequirements.count == 1 ? "" : "s") before recovery is enabled.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Finish Setup") { openMainWindow(destination: .settings) }
                }
                .padding(10)
                .background(.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
            }

            if model.configuration.mounts.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "externaldrive.badge.plus").font(.title).foregroundStyle(.secondary)
                    Text("No managed mounts").fontWeight(.semibold)
                    Text("Add a volume to start monitoring its health.").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 108)
            } else {
                let displayed = Array(model.configuration.mounts.prefix(4))
                VStack(spacing: 0) {
                    ForEach(displayed) { definition in
                        MountMenuRow(
                            definition: definition,
                            status: model.statuses.first { $0.definitionID == definition.id },
                            expectedSource: model.configuration.resolve(definition)?.source,
                            operation: model.operationSnapshots.values.first { $0.mountID == definition.id },
                            request: request,
                            cancel: { operationID in Task { await model.cancelOperation(operationID) } }
                        )
                        if definition.id != displayed.last?.id { Divider() }
                    }
                }
            }

            Divider()

            HStack {
                Button("Overview") { openMainWindow(destination: .overview) }
                Button("Settings") { openMainWindow(destination: .settings) }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 380)
    }

    private var headerStatus: String {
        LATCHMenuHeaderPresentation(overview: overview).text
    }

    private var headerColor: Color {
        if !model.serviceStatus.daemonOnline || overview.needsAttention > 0 { return .orange }
        return overview.activeManaged > 0 && overview.healthy == overview.activeManaged ? .green : .secondary
    }

    private func openMainWindow(destination: LATCHMainDestination) {
        model.mainDestination = destination
        dismiss()
        openWindow(id: "latch-main")
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func request(_ action: LATCHAction, definition: MountDefinition) {
        switch action {
        case .unmount:
            confirm(
                action,
                definition: definition,
                title: "Unmount \(definition.displayName)?",
                detail: "Unmounting can interrupt applications that are using this volume."
            )
        case .recover:
            confirm(
                action,
                definition: definition,
                title: "Recover \(definition.displayName)?",
                detail: "LATCH will stop configured dependencies, unmount only this source, remount it, and verify the result."
            )
        case .check, .mount, .reveal:
            Task { await model.action(action, definition: definition) }
        }
    }

    private func confirm(_ action: LATCHAction, definition: MountDefinition, title: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.alertStyle = .warning
        let confirmButton = alert.addButton(withTitle: action == .recover ? "Recover" : "Unmount")
        confirmButton.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await model.action(action, definition: definition, confirmed: true) }
    }
}

private struct MountMenuRow: View {
    let definition: MountDefinition
    let status: MountStatus?
    let expectedSource: String?
    let operation: OperationSnapshot?
    let request: (LATCHAction, MountDefinition) -> Void
    let cancel: (UUID) -> Void

    var body: some View {
        let statusTitle = operation?.detail ?? MountStatusIndicatorPresentation(state: status?.state, enabled: definition.enabled).statusTitle
        let presentation = LATCHMenuMountPresentation(
            definition: definition,
            source: expectedSource ?? "Unknown server",
            statusTitle: statusTitle
        )
        HStack(spacing: 10) {
            let visual = MountStateVisual(status: status, enabled: definition.enabled)
            Image(systemName: visual.symbol)
                .foregroundStyle(visual.color)
                .font(.title3)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 12) {
                    Text(presentation.name).fontWeight(.medium).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(presentation.mountPoint).fontWeight(.medium).lineLimit(1)
                        .help(presentation.mountPoint)
                }
                HStack(spacing: 12) {
                    Text(presentation.status).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(presentation.source).lineLimit(1).help(presentation.source)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Menu {
                if let operation {
                    Button("Cancel Operation") { cancel(operation.id) }
                        .disabled(!operation.canCancel)
                    Divider()
                }
                Button("Reveal in Finder") { request(.reveal, definition) }
                    .disabled(!MountRevealPolicy.isAvailable(
                        observedSource: status?.observedSource,
                        expectedSource: expectedSource
                    ) || operation != nil)
                Button("Check Now") { request(.check, definition) }
                    .disabled(!definition.enabled || operation != nil)
                Divider()
                Button("Mount") { request(.mount, definition) }.disabled(operation != nil)
                Button("Unmount", role: .destructive) { request(.unmount, definition) }.disabled(operation != nil)
                Button("Recover", role: .destructive) { request(.recover, definition) }.disabled(operation != nil)
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("Actions for \(definition.displayName)")
        }
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
    }
}

struct MountStateVisual {
    let symbol: String
    let color: Color

    init(status: MountStatus?, enabled: Bool) {
        guard enabled else { symbol = "pause.circle.fill"; color = .gray; return }
        switch status?.state {
        case .healthy: symbol = "checkmark.circle.fill"; color = .green
        case .mounting, .recovering: symbol = "arrow.triangle.2.circlepath.circle.fill"; color = .blue
        case .stale, .failedClosed: symbol = "xmark.octagon.fill"; color = .red
        case .networkUnavailable, .probeTimedOut, .probeError: symbol = "exclamationmark.circle.fill"; color = .red
        case .cooldown: symbol = "clock.fill"; color = .orange
        case .waitingForRules: symbol = "network.slash"; color = .orange
        case .waking: symbol = "power.circle.fill"; color = .blue
        case .retryScheduled: symbol = "clock.arrow.circlepath"; color = .orange
        case .disabled: symbol = "pause.circle.fill"; color = .orange
        case .unmounted: symbol = "externaldrive.badge.xmark"; color = .secondary
        case nil: symbol = "externaldrive"; color = .secondary
        }
    }
}

struct PendingMountAction: Identifiable {
    let id = UUID()
    let definition: MountDefinition
    let action: LATCHAction
    let title: String
    let detail: String
}
