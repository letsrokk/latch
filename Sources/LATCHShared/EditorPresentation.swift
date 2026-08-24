import Foundation

public enum LATCHMainDestination: String, CaseIterable, Identifiable, Hashable, Sendable {
    case overview
    case managed
    case servers
    case external
    case activity
    case settings

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .overview: "Overview"
        case .managed: "Managed Mounts"
        case .servers: "Servers"
        case .external: "External Mounts"
        case .activity: "Activity"
        case .settings: "Settings"
        }
    }

    public var symbol: String {
        switch self {
        case .overview: "house"
        case .managed: "externaldrive.connected.to.line.below"
        case .servers: "server.rack"
        case .external: "eye"
        case .activity: "clock.arrow.circlepath"
        case .settings: "gearshape"
        }
    }
}

public enum LATCHMainWindowPresentation {
    public static let title = "LATCH"
}

public enum LATCHSidebarPresentation {
    public static let destinations = LATCHMainDestination.allCases
}

public enum ServerActionsAccessibility {
    public static func label(serverName: String) -> String {
        "Actions for \(serverName)"
    }

    public static let hint = "Opens server actions"
}

public enum MainWindowDestinationRestorationPolicy {
    public static func destination(
        stored: LATCHMainDestination?,
        current: LATCHMainDestination,
        hasExplicitRequest: Bool
    ) -> LATCHMainDestination {
        hasExplicitRequest ? current : stored ?? current
    }
}

public enum LATCHMenuFooterAction: String, CaseIterable, Identifiable, Sendable {
    case overview
    case mounts
    case settings

    public var id: Self { self }

    public var title: String {
        switch self {
        case .overview: "Overview"
        case .mounts: "Mounts"
        case .settings: "Settings"
        }
    }

    public var destination: LATCHMainDestination {
        switch self {
        case .overview: .overview
        case .mounts: .managed
        case .settings: .settings
        }
    }
}

public struct LATCHMenuMountPresentation: Sendable, Equatable {
    public let name: String
    public let mountPoint: String
    public let status: String
    public let source: String

    public init(definition: MountDefinition, source: String, statusTitle: String) {
        name = definition.displayName
        mountPoint = definition.mountPoint
        status = statusTitle
        self.source = source
    }
}

public enum ManagedMountActionExecutionRoute: Sendable, Equatable {
    case daemon
    case foregroundApplication
}

public enum ManagedMountActionExecution {
    public static func route(for action: LATCHAction) -> ManagedMountActionExecutionRoute {
        action == .reveal ? .foregroundApplication : .daemon
    }
}

public enum LATCHInterfaceCopy {
    public static let setupSectionTitle = "Monitoring Setup"
    public static let setupRequiredTitle = "Monitoring needs setup"
    public static let exportDiagnosticsTitle = "Export Diagnostics"
    public static let exportConfigurationTitle = "Export Configuration"
    public static let importConfigurationTitle = "Import Configuration"
    public static let persistenceDegradedMessage = "Persistent data is degraded. LATCH is using safe fallback data until a successful write restores storage health."
}

public enum ServerAutomationIndicator: Sendable, Equatable {
    case ready
    case blocked
}

public struct ServerAutomationPresentation: Sendable, Equatable {
    public let indicator: ServerAutomationIndicator
    public let ruleStatusTitle: String
    public let ruleStatusDetails: [String]

    public init(server: NFSServerProfile, mounts: [MountDefinition], statuses: [MountStatus]) {
        let mountIDs = Set(mounts.lazy.filter { $0.serverID == server.id }.map(\.id))
        if let waiting = statuses.first(where: {
            mountIDs.contains($0.definitionID) && $0.state == .waitingForRules
        }) {
            indicator = .blocked
            ruleStatusTitle = "Waiting"
            ruleStatusDetails = waiting.unmetRuleSummaries
        } else {
            indicator = .ready
            ruleStatusTitle = server.networkMountRules.rules.isEmpty ? "No rules" : "Satisfied"
            ruleStatusDetails = []
        }
    }
}

public enum MountFolderPresentation {
    public static func displayText(mountPoint: String, homeDirectory: String, confirmed: Bool) -> String {
        guard confirmed else { return "Select folder" }
        return MountPathSuggestion.abbreviated(mountPoint, homeDirectory: homeDirectory)
    }
}

public enum MountFolderPickerPresentation {
    public static let message = "Choose an existing empty folder."

    public static func initialDirectory(
        mountPoint: String,
        homeDirectory: URL,
        confirmed: Bool
    ) -> URL {
        guard confirmed, !mountPoint.isEmpty else { return homeDirectory.standardizedFileURL }
        return URL(fileURLWithPath: mountPoint, isDirectory: true).standardizedFileURL
    }
}

public struct MountServerSelectionPresentation: Sendable, Equatable {
    public let canSelectServer: Bool
    public let guidance: String?

    public init(availableServerCount: Int) {
        canSelectServer = availableServerCount > 0
        guidance = canSelectServer ? nil : "Add a server from Servers before configuring a mount."
    }
}

public enum MountStatusIndicator: Sendable, Equatable {
    case healthy
    case progress
    case waitingForRules
    case inactive
    case issue
}

public struct MountStatusIndicatorPresentation: Sendable, Equatable {
    public let indicator: MountStatusIndicator
    public let statusTitle: String

    public init(state: MountState?, enabled: Bool) {
        guard enabled else {
            indicator = .inactive
            statusTitle = MountState.disabled.displayName
            return
        }

        statusTitle = state?.displayName ?? "Waiting for status"

        switch state {
        case .healthy:
            indicator = .healthy
        case .mounting, .recovering, .waking:
            indicator = .progress
        case .waitingForRules:
            indicator = .waitingForRules
        case .disabled, .unmounted, nil:
            indicator = .inactive
        case .networkUnavailable, .probeTimedOut, .probeError, .stale, .cooldown, .failedClosed, .retryScheduled:
            indicator = .issue
        }
    }
}

public struct NetworkRuleEditorState: Sendable, Equatable {
    public var rules: [NetworkMountRule]
    public private(set) var connectionTypeSelection: NetworkInterfaceType

    public init(rules: [NetworkMountRule]) {
        self.rules = rules
        connectionTypeSelection = rules.lazy.compactMap { rule in
            guard case .interfaceType(let type) = rule else { return nil }
            return type
        }.first ?? .wifi
    }

    public var requiresNFSService: Bool { rules.contains(.nfsServiceReachable) }
    public var requiresTunnelInterface: Bool { rules.contains(.tunnelInterfaceActive) }
    public var connectionType: NetworkInterfaceType? {
        rules.lazy.compactMap { rule in
            guard case .interfaceType(let type) = rule else { return nil }
            return type
        }.first
    }
    public var requiresConnectionType: Bool { connectionType != nil }
    public var routeRules: [NetworkMountRule] {
        rules.filter { if case .routeAvailable = $0 { true } else { false } }
    }
    public var interfaceNameRules: [NetworkMountRule] {
        rules.filter { if case .interfaceName = $0 { true } else { false } }
    }
    public var removableRules: [NetworkMountRule] {
        routeRules + interfaceNameRules
    }

    public mutating func setNFSServiceRequired(_ required: Bool) {
        set(.nfsServiceReachable, required: required)
    }

    public mutating func setTunnelInterfaceRequired(_ required: Bool) {
        set(.tunnelInterfaceActive, required: required)
    }

    public mutating func setConnectionTypeRequired(_ required: Bool) {
        if required {
            guard !requiresConnectionType else { return }
            rules.append(.interfaceType(connectionTypeSelection))
        } else {
            rules.removeAll { if case .interfaceType = $0 { true } else { false } }
        }
    }

    public mutating func setConnectionType(_ type: NetworkInterfaceType) {
        connectionTypeSelection = type
        rules.removeAll { if case .interfaceType = $0 { true } else { false } }
        rules.append(.interfaceType(type))
    }

    public mutating func remove(_ rule: NetworkMountRule) {
        rules.removeAll { $0 == rule }
    }

    private mutating func set(_ rule: NetworkMountRule, required: Bool) {
        if required {
            guard !rules.contains(rule) else { return }
            rules.append(rule)
        } else {
            rules.removeAll { $0 == rule }
        }
    }
}

public enum ManagedMountMenuAction: Sendable, Equatable {
    case reveal
    case check
    case mount
    case editConfiguration
    case unmount
    case recover
    case removeDefinition
}

public enum ManagedMountMenuPresentation {
    public static func sections(includeRemoval: Bool) -> [[ManagedMountMenuAction]] {
        var sections: [[ManagedMountMenuAction]] = [
            [.reveal, .check],
            [.mount, .unmount, .recover],
            [.editConfiguration],
        ]
        if includeRemoval { sections[2].append(.removeDefinition) }
        return sections
    }

    public static func isEnabled(
        _ action: ManagedMountMenuAction,
        monitoringEnabled: Bool,
        canReveal: Bool,
        operationActive: Bool = false
    ) -> Bool {
        guard !operationActive else { return false }
        return switch action {
        case .reveal: canReveal
        case .check: monitoringEnabled
        case .mount, .editConfiguration, .unmount, .recover, .removeDefinition: true
        }
    }

    public static func title(for action: ManagedMountMenuAction) -> String {
        switch action {
        case .reveal: "Reveal in Finder"
        case .check: "Check Now"
        case .mount: "Mount"
        case .editConfiguration: "Edit"
        case .unmount: "Unmount"
        case .recover: "Recover"
        case .removeDefinition: "Remove"
        }
    }
}

public enum EditorPrimaryActionTitle {
    public static func title(isNew: Bool) -> String { isNew ? "Add" : "Save" }
}

public enum MountTimingKind: Sendable, Equatable {
    case probeInterval
    case probeTimeout
    case recoveryCooldown
}

public struct MountTimingFieldPresentation: Sendable, Equatable {
    public let kind: MountTimingKind
    public let title: String
    public let value: Int
    public let unit: String
    public let range: ClosedRange<Int>
    public let step: Int

    public init(kind: MountTimingKind, title: String, value: Int, unit: String, range: ClosedRange<Int>, step: Int) {
        self.kind = kind
        self.title = title
        self.value = value
        self.unit = unit
        self.range = range
        self.step = step
    }
}

public enum MountTimingPresentation {
    public static func fields(
        probeIntervalSeconds: Int,
        probeTimeoutSeconds: Int,
        recoveryCooldownSeconds: Int
    ) -> [MountTimingFieldPresentation] {
        [
            .init(kind: .probeInterval, title: "Probe interval", value: probeIntervalSeconds, unit: "seconds", range: 10...3600, step: 10),
            .init(kind: .probeTimeout, title: "Probe timeout", value: probeTimeoutSeconds, unit: "seconds", range: 1...30, step: 1),
            .init(kind: .recoveryCooldown, title: "Recovery cooldown", value: recoveryCooldownSeconds / 60, unit: "minutes", range: 1...1440, step: 1),
        ]
    }

    public static func storedSeconds(for kind: MountTimingKind, displayedValue: Int) -> Int {
        kind == .recoveryCooldown ? displayedValue * 60 : displayedValue
    }
}

public struct SavedMountTransition: Sendable, Equatable {
    public let initialState: MountState?
    public let shouldScheduleAutomaticCheck: Bool
    public let lastCheck: Date?

    public init(isNew: Bool, enabled: Bool) {
        initialState = isNew ? (enabled ? .mounting : .disabled) : nil
        shouldScheduleAutomaticCheck = enabled
        lastCheck = nil
    }
}

public enum MountEditorSaveResult: Sendable, Equatable {
    case saved
    case failed(String)

    public var failureMessage: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

public enum MountRemovalDisposition: Sendable, Equatable {
    case remove
    case requiresConfirmation
    case unmountThenRemove
    case sourceConflict

    public static func resolve(currentSource: String?, expectedSource: String, confirmed: Bool) -> Self {
        guard let currentSource else { return .remove }
        guard currentSource == expectedSource else { return .sourceConflict }
        return confirmed ? .unmountThenRemove : .requiresConfirmation
    }
}

public enum ServerEditorField: Sendable, Equatable {
    case name
    case hostname
    case networkRules
    case wakeOnLAN
}

public struct ServerEditorIssue: Sendable, Equatable {
    public let field: ServerEditorField
    public let message: String

    public init(field: ServerEditorField, message: String) {
        self.field = field
        self.message = message
    }
}

public enum ServerEditorValidation {
    public static func issues(for server: NFSServerProfile) -> [ServerEditorIssue] {
        var issues: [ServerEditorIssue] = []
        if server.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.init(field: .name, message: "Enter a name that identifies this server."))
        }
        if !isValidHostname(server.hostname) {
            issues.append(.init(field: .hostname, message: "Enter a hostname or IP address without spaces, slashes, or a port."))
        }

        guard issues.isEmpty else { return issues }

        do {
            try ConfigurationValidator().validate(
                LATCHConfiguration(servers: [server], mounts: []),
                liveMounts: []
            )
        } catch ConfigurationValidationError.invalidNetworkRule {
            issues.append(.init(field: .networkRules, message: "Correct the route or interface rule before saving."))
        } catch ConfigurationValidationError.invalidWakeOnLAN {
            issues.append(.init(field: .wakeOnLAN, message: "Enter a valid MAC address and optional IPv4 broadcast address."))
        } catch {
            issues.append(.init(field: .hostname, message: "Review the server details before saving."))
        }
        return issues
    }

    private static func isValidHostname(_ value: String) -> Bool {
        !value.isEmpty
            && value.count <= 253
            && !value.contains(where: { $0.isWhitespace || $0 == ":" || $0 == "/" })
    }
}

public enum ResponseDeadlineError: Error, Sendable, Equatable, LocalizedError {
    case timedOut

    public var errorDescription: String? {
        "The privileged daemon did not respond. Open Settings, remove and reinstall the privileged daemon, then try again."
    }
}

public enum ResponseDeadline {
    public enum CancellationBehavior: Sendable {
        case cancelWait
        case awaitResponse
    }

    public static func wait<Value: Sendable>(
        for timeout: Duration,
        cancellationBehavior: CancellationBehavior = .cancelWait,
        onTimeout: @escaping @Sendable () -> Void = {},
        start: @escaping @Sendable (@escaping @Sendable (Result<Value, any Error>) -> Void) -> Void
    ) async throws -> Value {
        let gate = ResponseContinuationGate<Value>()
        if cancellationBehavior == .awaitResponse {
            return try await withCheckedThrowingContinuation { continuation in
                guard gate.install(continuation, onCancellation: {}) else { return }
                start { result in gate.resume(with: result) }
                let deadlineTask = Task.detached {
                    try? await Task.sleep(for: timeout)
                    gate.resume(with: .failure(ResponseDeadlineError.timedOut), beforeResume: onTimeout)
                }
                gate.setDeadlineTask(deadlineTask)
            }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard gate.install(continuation, onCancellation: onTimeout) else { return }
                start { result in gate.resume(with: result) }
                let deadlineTask = Task {
                    try? await Task.sleep(for: timeout)
                    gate.resume(with: .failure(ResponseDeadlineError.timedOut), beforeResume: onTimeout)
                }
                gate.setDeadlineTask(deadlineTask)
            }
        } onCancel: {
            gate.cancel(beforeResume: onTimeout)
        }
    }
}

private final class ResponseContinuationGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, any Error>?
    private var cancellationRequested = false
    private var deadlineTask: Task<Void, Never>?

    func install(
        _ continuation: CheckedContinuation<Value, any Error>,
        onCancellation: () -> Void
    ) -> Bool {
        let shouldCancel = lock.withLock { () -> Bool in
            if cancellationRequested { return true }
            self.continuation = continuation
            return false
        }
        if shouldCancel {
            onCancellation()
            continuation.resume(throwing: CancellationError())
        }
        return !shouldCancel
    }

    func setDeadlineTask(_ task: Task<Void, Never>) {
        let shouldCancel = lock.withLock { () -> Bool in
            guard continuation != nil else { return true }
            deadlineTask = task
            return false
        }
        if shouldCancel { task.cancel() }
    }

    func cancel(beforeResume: () -> Void) {
        let pending = lock.withLock { () -> (CheckedContinuation<Value, any Error>, Task<Void, Never>?)? in
            cancellationRequested = true
            guard let continuation else { return nil }
            let result = (continuation, deadlineTask)
            self.continuation = nil
            deadlineTask = nil
            return result
        }
        guard let pending else { return }
        pending.1?.cancel()
        beforeResume()
        pending.0.resume(throwing: CancellationError())
    }

    func resume(with result: Result<Value, any Error>, beforeResume: () -> Void = {}) {
        let pending = lock.withLock { () -> (CheckedContinuation<Value, any Error>, Task<Void, Never>?)? in
            guard let continuation else { return nil }
            let pending = (continuation, deadlineTask)
            self.continuation = nil
            deadlineTask = nil
            return pending
        }
        guard let pending else { return }
        pending.1?.cancel()
        beforeResume()
        pending.0.resume(with: result)
    }
}
