import SwiftUI
import LATCHShared

struct MainSidebarView: View {
    @Binding var selection: LATCHMainDestination
    let daemonOnline: Bool

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("LATCH").font(.headline)
                HStack(spacing: 6) {
                    Circle()
                        .fill(daemonOnline ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                    Text(daemonOnline ? "Daemon online" : "Daemon offline")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 15)

            List(selection: $selection) {
                ForEach(LATCHSidebarPresentation.destinations) { destination in
                    Label(destination.title, systemImage: destination.symbol).tag(destination)
                }
            }
            .listStyle(.sidebar)
        }
    }
}

struct FieldHint: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

struct SavedNetworkRuleRow: View {
    let rule: NetworkMountRule
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(rule.summary)
                .font(.callout)
                .lineLimit(1)
            Spacer()
            Button(role: .destructive, action: remove) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove \(rule.summary)")
            .help("Remove this network rule")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }
}

struct NetworkRuleControlGroup<Content: View>: View {
    @ViewBuilder let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            content
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        }
    }
}

struct FormDisclosureSection<Content: View>: View {
    let title: String
    @Binding var isExpanded: Bool
    @ViewBuilder let content: Content

    init(_ title: String, isExpanded: Binding<Bool>, @ViewBuilder content: () -> Content) {
        self.title = title
        _isExpanded = isExpanded
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Text(title)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")

            if isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    content
                }
                .padding(.top, 14)
            }
        }
    }
}

struct PronouncedPickerModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .pickerStyle(.menu)
            .padding(.horizontal, 3)
            .padding(.vertical, 2)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.primary.opacity(0.18), lineWidth: 1)
            }
    }
}

extension View {
    func pronouncedPicker() -> some View {
        modifier(PronouncedPickerModifier())
    }
}

struct ValidationMessage: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Label(text, systemImage: "exclamationmark.circle.fill")
            .font(.caption).foregroundStyle(.red)
    }
}

struct OutlinedNumericStepperRow: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int
    let unit: String

    var body: some View {
        HStack(spacing: 8) {
            Text("\(title):")
            Spacer()
            Text("\(value)")
                .monospacedDigit()
                .frame(minWidth: 42)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(.separator.opacity(0.9)))
            Stepper("", value: $value, in: range, step: step)
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("\(title) in \(unit)")
            Text(unit)
        }
    }
}

struct ListEmptyStateView: View {
    let presentation: LATCHEmptyStatePresentation

    init(_ presentation: LATCHEmptyStatePresentation) {
        self.presentation = presentation
    }

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: presentation.symbol)
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(presentation.title).font(.headline)
            Text(presentation.detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
        }
        .frame(maxWidth: .infinity, minHeight: 132)
        .accessibilityElement(children: .combine)
    }
}

struct ManagedMountActions: View {
    let definition: MountDefinition
    let canReveal: Bool
    let operation: OperationSnapshot?
    let edit: () -> Void
    let remove: (() -> Void)?
    let action: (LATCHAction) -> Void
    let cancel: (UUID) -> Void

    var body: some View {
        Menu {
            if let operation {
                Button("Cancel Operation") { cancel(operation.id) }
                    .disabled(!operation.canCancel)
                Divider()
            }
            let sections = ManagedMountMenuPresentation.sections(includeRemoval: remove != nil)
            ForEach(Array(sections.enumerated()), id: \.offset) { sectionIndex, section in
                ForEach(Array(section.enumerated()), id: \.offset) { _, item in
                    menuItem(item)
                }
                if sectionIndex < sections.count - 1 { Divider() }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Actions for \(definition.displayName)")
    }

    @ViewBuilder
    private func menuItem(_ item: ManagedMountMenuAction) -> some View {
        switch item {
        case .reveal:
            Button(ManagedMountMenuPresentation.title(for: item)) { action(.reveal) }
                .disabled(!isEnabled(item))
        case .check:
            Button(ManagedMountMenuPresentation.title(for: item)) { action(.check) }
                .disabled(!isEnabled(item))
        case .mount:
            Button(ManagedMountMenuPresentation.title(for: item)) { action(.mount) }
                .disabled(!isEnabled(item))
        case .editConfiguration:
            Button(ManagedMountMenuPresentation.title(for: item), action: edit)
                .disabled(!isEnabled(item))
        case .unmount:
            Button(ManagedMountMenuPresentation.title(for: item), role: .destructive) { action(.unmount) }
                .disabled(!isEnabled(item))
        case .recover:
            Button(ManagedMountMenuPresentation.title(for: item), role: .destructive) { action(.recover) }
                .disabled(!isEnabled(item))
        case .removeDefinition:
            Button(ManagedMountMenuPresentation.title(for: item), role: .destructive) { remove?() }
                .disabled(!isEnabled(item))
        }
    }

    private func isEnabled(_ item: ManagedMountMenuAction) -> Bool {
        ManagedMountMenuPresentation.isEnabled(
            item,
            monitoringEnabled: definition.enabled,
            canReveal: canReveal,
            operationActive: operation != nil
        )
    }
}

struct ManagedSummaryHeaderRow: View {
    var body: some View {
        HStack(spacing: 12) {
            Text("Volume").frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
            Text("Source").frame(minWidth: 155, maxWidth: .infinity, alignment: .leading)
            Text("Mountpoint").frame(minWidth: 115, maxWidth: .infinity, alignment: .leading)
            Text("Status").frame(width: 135, alignment: .leading)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }
}

struct ManagedSummaryRow: View {
    let definition: MountDefinition
    let source: String
    let status: MountStatus?

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 9) {
                Image(systemName: "folder.fill").foregroundStyle(.blue).font(.title3).accessibilityHidden(true)
                Text(definition.displayName).fontWeight(.medium).lineLimit(1)
            }
            .frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)

            Text(source).font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.85).help(source)
                .frame(minWidth: 155, maxWidth: .infinity, alignment: .leading)

            Text(definition.mountPoint).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(definition.mountPoint)
                .frame(minWidth: 115, maxWidth: .infinity, alignment: .leading)

            MountStatusLabel(status: status, enabled: definition.enabled)
                .frame(width: 135, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }
}

struct MountStatusLabel: View {
    let status: MountStatus?
    let enabled: Bool

    var body: some View {
        let visual = MountStateVisual(status: status, enabled: enabled)
        let presentation = MountStatusIndicatorPresentation(state: status?.state, enabled: enabled)
        Label(presentation.statusTitle, systemImage: visual.symbol)
            .foregroundStyle(visual.color)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .help(enabled ? (status?.detail ?? presentation.statusTitle) : presentation.statusTitle)
    }
}

struct MountStatusIndicatorDot: View {
    let status: MountStatus?
    let enabled: Bool

    private var presentation: MountStatusIndicatorPresentation {
        MountStatusIndicatorPresentation(state: status?.state, enabled: enabled)
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
            .accessibilityLabel(accessibilityLabel)
    }

    private var color: Color {
        switch presentation.indicator {
        case .healthy: .green
        case .progress: .blue
        case .waitingForRules: .yellow
        case .inactive: .gray
        case .issue: .red
        }
    }

    private var accessibilityLabel: String {
        switch presentation.indicator {
        case .healthy: "Healthy"
        case .progress: "Mount operation in progress"
        case .waitingForRules: "Network rules unsatisfied"
        case .inactive: "Unmounted"
        case .issue: "Mount has issues"
        }
    }
}
