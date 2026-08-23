import AppKit
import Combine
import Foundation
import LATCHShared
import ServiceManagement
import UserNotifications
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    @Published var serviceStatus = ServiceStatusSnapshot(daemonOnline: false, daemonAuthorized: false, agentAuthorized: false, networkVolumesPermissionVerified: false)
    @Published var configuration = LATCHConfiguration()
    @Published var statuses: [MountStatus] = []
    @Published var externalMounts: [ExternalMountSnapshot] = []
    @Published var discoveredServers: [DiscoveredNFSServer] = []
    @Published var events: [LATCHEvent] = []
    @Published var errorMessage: String?
    @Published var daemonServiceState: ManagedServiceState = .notRegistered
    @Published var agentServiceState: ManagedServiceState = .notRegistered
    @Published var mainApplicationServiceState: ManagedServiceState = .notRegistered
    @Published var startAtLoginEnabled = true
    @Published var serviceSetupInProgress = false
    @Published var serviceApprovalPrompt: ServiceApprovalPrompt?
    @Published var configurationImportPreview: PortableImportPreview?
    @Published var mainDestination: LATCHMainDestination = .overview
    @Published private(set) var hasLoadedServiceStatus = false

    let daemonService = SMAppService.daemon(plistName: "\(LATCHIdentity.daemonIdentifier).plist")
    let agentService = SMAppService.agent(plistName: "\(LATCHIdentity.agentIdentifier).plist")
    let mainApplicationService = SMAppService.mainApp
    private var statusSubscription: StatusSubscription?
    private var refreshTask: Task<Void, Never>?
    private var approvalRefreshTask: Task<Void, Never>?
    var serviceApprovalPromptSuppressed = false
    var serviceRepairAttempted = false
    var serviceRepairRetryAttempted = false
    private var isTearingDownServices = false
    private var debugActionRan = false
    var importedConfigurationData: Data?
    private lazy var daemonClient = LATCHDaemonRequestClient(signingRequirement: daemonSigningRequirement)
    private let visualPreviewMode: Bool
    private let serviceRegistrationFingerprint = ServiceBundleFingerprint.current()
    private let serviceRegistrationFingerprintKey = "serviceRegistrationFingerprint"
    let startAtLoginPreferenceKey = "startAtLoginEnabled"
    private let daemonSigningRequirement = ClientSigningPolicy(
        teamID: CurrentCodeIdentity.teamID ?? "ADHOC",
        bundleIdentifiers: [LATCHIdentity.daemonIdentifier]
    ).codeSigningRequirement

    init() {
#if DEBUG
        visualPreviewMode = ProcessInfo.processInfo.arguments.contains("--visual-preview")
        if visualPreviewMode {
            let fixture = LATCHPreviewFixture.operationalOverview()
            serviceStatus = fixture.serviceStatus
            configuration = fixture.configuration
            statuses = fixture.statuses
            externalMounts = fixture.externalMounts
            events = fixture.events
            daemonServiceState = .enabled
            agentServiceState = .enabled
            mainApplicationServiceState = .enabled
            startAtLoginEnabled = true
            hasLoadedServiceStatus = true
        } else {
            initializeStartAtLoginPreference()
            syncServiceStates()
        }
#else
        visualPreviewMode = false
        initializeStartAtLoginPreference()
        syncServiceStates()
#endif
    }

    var aggregateSymbol: String {
        LATCHMenuBarPresentation(
            services: serviceStatus,
            statuses: statuses,
            hasLoadedServiceStatus: hasLoadedServiceStatus
        ).symbol
    }

    var canUninstallServices: Bool {
        MonitoringServicesUninstallPlan(
            daemon: daemonServiceState,
            loginAgent: agentServiceState
        ).isAvailable
    }

    func start() {
        guard !visualPreviewMode else { return }
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await self.reconcileStartAtLoginPreference()
            guard !Task.isCancelled else { return }
            await self.repairUpdatedServicesIfNeeded()
            guard !Task.isCancelled else { return }
            await self.refresh()
            guard !Task.isCancelled else { return }
            await self.requestNotificationAuthorization()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled else { return }
                await self.refresh()
            }
        }
    }

    func refresh() async {
        guard !visualPreviewMode, !isTearingDownServices else { return }
        syncServiceStates()
        guard !serviceSetupInProgress else { return }
        guard daemonServiceState == .enabled else {
            serviceStatus.daemonOnline = false
            hasLoadedServiceStatus = true
            return
        }
        establishStatusSubscription()
        do {
            try await loadDaemonData()
            if daemonServiceState == .enabled,
               agentServiceState == .enabled,
               serviceStatus.daemonOnline,
               !serviceStatus.agentOnline,
               !serviceSetupInProgress {
                serviceSetupInProgress = true
                startApprovalRefreshWindow()
            }
        } catch {
            serviceStatus.daemonOnline = false
            hasLoadedServiceStatus = true
            if !serviceSetupInProgress { errorMessage = error.localizedDescription }
        }
    }

    private func loadDaemonData() async throws {
        if case .serviceStatus(var value) = try await send(.getServiceStatus) {
            value.daemonAuthorized = daemonService.status == .enabled
            value.agentAuthorized = agentService.status == .enabled
            serviceStatus = value
            hasLoadedServiceStatus = true
        }
        if case .configuration(let value) = try await send(.getConfiguration) { configuration = value }
        if case .statuses(let value) = try await send(.getStatus) { statuses = value }
        if case .externalMounts(let value) = try await send(.getExternalMounts) { externalMounts = value }
        if case .discoveredServers(let value) = try await send(.getDiscoveredServers) { discoveredServers = value }
        if case .events(let value) = try await send(.getRecentEvents(limit: 100)) { events = LATCHEvent.newestFirst(value) }
    }

    func uninstall(unmountOwned: Bool, removeState: Bool) async {
        guard !isTearingDownServices else { return }
        let plan = MonitoringServicesUninstallPlan(
            daemon: daemonServiceState,
            loginAgent: agentServiceState
        )
        guard plan.isAvailable else { return }
        isTearingDownServices = true
        var failures: [String] = []
        if plan.shouldContactDaemon {
            do {
                let response = try await send(.uninstall(unmountOwned: unmountOwned, removeState: removeState, confirmed: true))
                if case .failure(_, let detail) = response { failures.append("Daemon cleanup: \(detail)") }
            } catch {
                failures.append("Daemon cleanup: \(error.localizedDescription)")
            }
        }

        suspendLiveUpdates()
        failures += await MonitoringServicesUninstaller().uninstall(
            loginAgent: SMManagedServiceAdapter(agentService),
            daemon: SMManagedServiceAdapter(daemonService)
        )
        syncServiceStates()
        serviceStatus.daemonOnline = daemonServiceState == .enabled
        isTearingDownServices = false
        if !failures.isEmpty { errorMessage = failures.joined(separator: "\n") }
        if daemonServiceState == .enabled { start() }
    }

    func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
        startApprovalRefreshWindow()
    }

    func mainWindowDidAppear() {
        guard serviceSetupInProgress || hasPendingServiceApproval else { return }
        startApprovalRefreshWindow()
    }

    func mainWindowDidClose() {
        serviceSetupInProgress = false
        stopApprovalRefreshWindow()
    }

    func applicationDidBecomeActive() async {
        guard !visualPreviewMode else { return }
        await refreshServiceAuthorization(forceDaemonRefresh: true)
        if serviceSetupInProgress || hasPendingServiceApproval { startApprovalRefreshWindow() }
    }

    func clearServiceApprovalPrompt() {
        serviceApprovalPrompt = nil
        serviceApprovalPromptSuppressed = true
    }

    func prepareForAppReplacement(markerPath: String) async {
        suspendLiveUpdates()
        let failures = await ManagedServicesUninstaller().uninstall(
            mainApplication: SMManagedServiceAdapter(mainApplicationService),
            loginAgent: SMManagedServiceAdapter(agentService),
            daemon: SMManagedServiceAdapter(daemonService)
        )
        guard failures.isEmpty else { return }

        for _ in 0..<40 {
            syncServiceStates()
            let remainingServices = ManagedServicesUninstallPlan(
                daemon: daemonServiceState,
                loginAgent: agentServiceState,
                mainApplication: mainApplicationServiceState
            )
            if !remainingServices.isAvailable {
                try? Data("ready\n".utf8).write(to: URL(fileURLWithPath: markerPath), options: .atomic)
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

#if DEBUG
    func runDebugActionIfRequested() async {
        guard !debugActionRan else { return }
        debugActionRan = true
        let arguments = ProcessInfo.processInfo.arguments

        if let value = arguments.first(where: { $0.hasPrefix("--debug-service-action=") })?.split(separator: "=", maxSplits: 1).last {
            switch value {
            case "install-daemon": await installDaemon()
            case "install-agent": await installAgent()
            case "remove-daemon": await removeDaemon()
            case "remove-agent": await removeAgent()
            default: break
            }
        }

        if let path = arguments.first(where: { $0.hasPrefix("--debug-mount-point=") })?.split(separator: "=", maxSplits: 1).last {
            await refresh()
            guard let definition = configuration.mounts.first else { return }
            var draft = MountDraft(editing: definition)
            draft.mountPoint = String(path)
            if let exportPath = arguments.first(where: { $0.hasPrefix("--debug-export-path=") })?.split(separator: "=", maxSplits: 1).last {
                draft.exportPath = String(exportPath)
            }
            await save(draft)
            guard errorMessage == nil else { return }
            await action(.mount, definition: draft.definition())
        }

        if let rawID = arguments.first(where: { $0.hasPrefix("--debug-mount-id=") })?.split(separator: "=", maxSplits: 1).last,
           let id = UUID(uuidString: String(rawID)) {
            await refresh()
            guard let definition = configuration.mounts.first(where: { $0.id == id }) else { return }
            await action(.mount, definition: definition)
        }
    }
#endif

    func performRequest(_ request: LATCHRequest) async {
        do {
            if case .failure(_, let detail) = try await send(request) { errorMessage = detail }
            await refresh()
        } catch { errorMessage = error.localizedDescription }
    }

    func install(service: SMAppService, name: String) async {
        errorMessage = nil
        serviceApprovalPromptSuppressed = false
        serviceSetupInProgress = true
        serviceStatus.daemonOnline = false
        let outcome = await ManagedServiceController().install(SMManagedServiceAdapter(service))
        syncServiceStates()
        switch outcome {
        case .installed:
            startApprovalRefreshWindow()
        case .approvalRequired:
            serviceApprovalPrompt = ServiceApprovalPrompt(serviceName: name)
            startApprovalRefreshWindow()
        case .failed(let detail):
            serviceSetupInProgress = false
            errorMessage = detail
        case .removed:
            break
        }
    }

    func remove(service: SMAppService) async {
        let outcome = await ManagedServiceController().remove(SMManagedServiceAdapter(service))
        syncServiceStates()
        switch outcome {
        case .removed:
            await refresh()
        case .failed(let detail):
            errorMessage = detail
        case .installed, .approvalRequired:
            break
        }
    }

    func syncServiceStates() {
        daemonServiceState = ManagedServiceState(daemonService.status)
        agentServiceState = ManagedServiceState(agentService.status)
        mainApplicationServiceState = ManagedServiceState(mainApplicationService.status)
        serviceStatus.daemonAuthorized = daemonServiceState == .enabled
        serviceStatus.agentAuthorized = agentServiceState == .enabled
        if daemonServiceState != .enabled {
            serviceStatus.daemonOnline = false
            statusSubscription?.cancel()
            statusSubscription = nil
        }
    }

    func suspendLiveUpdates() {
        refreshTask?.cancel()
        refreshTask = nil
        stopApprovalRefreshWindow()
        statusSubscription?.cancel()
        statusSubscription = nil
    }

    func send(_ request: LATCHRequest) async throws -> LATCHResponse {
        try await daemonClient.request(request)
    }

    private func requestNotificationAuthorization() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    private func establishStatusSubscription() {
        guard statusSubscription == nil, daemonService.status == .enabled else { return }
        let teamID = Bundle.main.object(forInfoDictionaryKey: "LATCHTeamIdentifier") as? String ?? "ADHOC"
        let subscription = StatusSubscription(policy: .init(teamID: teamID, bundleIdentifiers: [LATCHIdentity.daemonIdentifier])) { [weak self] statuses in
            self?.statuses = statuses
        }
        statusSubscription = subscription
        let connection = NSXPCConnection(machServiceName: LATCHIdentity.daemonIdentifier, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: LATCHXPCProtocol.self)
        connection.setCodeSigningRequirement(daemonSigningRequirement)
        connection.resume()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ [weak self] error in
            Task { @MainActor in
                self?.statusSubscription?.cancel()
                self?.statusSubscription = nil
                if self?.serviceSetupInProgress == false {
                    self?.errorMessage = error.localizedDescription
                }
                connection.invalidate()
            }
        }) as? LATCHXPCProtocol else { connection.invalidate(); return }
        proxy.subscribe(subscription.endpoint) { _ in
            Task { @MainActor in connection.invalidate() }
        }
    }

    var hasPendingMonitoringServiceApproval: Bool {
        daemonServiceState == .requiresApproval || agentServiceState == .requiresApproval
    }

    var hasPendingStartAtLoginApproval: Bool {
        startAtLoginEnabled && mainApplicationServiceState == .requiresApproval
    }

    private var hasPendingServiceApproval: Bool {
        hasPendingMonitoringServiceApproval || hasPendingStartAtLoginApproval
    }

    func startApprovalRefreshWindow() {
        guard !visualPreviewMode, serviceSetupInProgress || hasPendingServiceApproval else { return }
        approvalRefreshTask?.cancel()
        approvalRefreshTask = Task { [weak self] in
            var attempt = 0
            while let delay = ManagedServiceApprovalPollSchedule.delay(afterAttempt: attempt), !Task.isCancelled {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let self else { return }
                await self.refreshServiceAuthorization()
                guard self.serviceSetupInProgress || self.hasPendingServiceApproval else {
                    self.approvalRefreshTask = nil
                    return
                }
                attempt += 1
            }
            guard !Task.isCancelled, let self else { return }
            self.approvalRefreshTask = nil
            self.serviceSetupInProgress = false
            if self.daemonServiceState == .enabled,
               self.agentServiceState == .enabled {
                if !self.serviceStatus.daemonOnline {
                    self.errorMessage = "LATCH services are enabled, but the privileged daemon did not start. Use Repair in Monitoring Setup."
                } else if !self.serviceStatus.agentOnline {
                    self.errorMessage = "The LATCH login agent did not start. Use Repair in Monitoring Setup."
                }
            }
        }
    }

    private func stopApprovalRefreshWindow() {
        approvalRefreshTask?.cancel()
        approvalRefreshTask = nil
    }

    private func refreshServiceAuthorization(forceDaemonRefresh: Bool = false) async {
        let previousDaemon = daemonServiceState
        let previousAgent = agentServiceState
        let previousMainApplication = mainApplicationServiceState
        syncServiceStates()
        let decision = ManagedServiceRefreshDecision(
            previousDaemon: previousDaemon,
            previousLoginAgent: previousAgent,
            previousMainApplication: previousMainApplication,
            daemon: daemonServiceState,
            loginAgent: agentServiceState,
            mainApplication: mainApplicationServiceState
        )
        if hasPendingServiceApproval {
            if serviceApprovalPrompt == nil, !serviceApprovalPromptSuppressed {
                let name = hasPendingMonitoringServiceApproval ? "Monitoring services" : "Start at login"
                serviceApprovalPrompt = ServiceApprovalPrompt(serviceName: name)
            }
            if hasPendingMonitoringServiceApproval { return }
        }
        if decision.shouldClearApprovalGuidance {
            serviceApprovalPrompt = nil
            serviceApprovalPromptSuppressed = false
        }
        guard daemonServiceState == .enabled,
              agentServiceState == .enabled else { return }

        if serviceSetupInProgress {
            guard await probeDaemonDuringSetup() else {
                await repairUnavailableServicesIfNeeded()
                return
            }
            serviceSetupInProgress = false
            if !hasPendingServiceApproval {
                approvalRefreshTask = nil
                serviceApprovalPrompt = nil
                serviceApprovalPromptSuppressed = false
            }
            recordCurrentServiceRegistration()
            establishStatusSubscription()
            await refresh()
        } else if forceDaemonRefresh || decision.shouldRefreshDaemonData {
            await refresh()
        }
    }

    private func probeDaemonDuringSetup() async -> Bool {
        do {
            guard case .serviceStatus(var value) = try await send(.getServiceStatus) else { return false }
            value.daemonAuthorized = daemonService.status == .enabled
            value.agentAuthorized = agentService.status == .enabled
            serviceStatus = value
            errorMessage = nil
            return value.daemonOnline && value.agentOnline
        } catch {
            serviceStatus.daemonOnline = false
            statusSubscription?.cancel()
            statusSubscription = nil
            return false
        }
    }

    private func repairUpdatedServicesIfNeeded() async {
        let defaults = UserDefaults.standard
        guard ManagedServiceRegistrationRepairPolicy.shouldRepairUpdatedRegistration(
            daemon: daemonServiceState,
            loginAgent: agentServiceState,
            currentFingerprint: serviceRegistrationFingerprint,
            registeredFingerprint: defaults.string(forKey: serviceRegistrationFingerprintKey)
        ) else { return }
        await repairServices()
    }

    private func repairUnavailableServicesIfNeeded() async {
        if ManagedServiceRegistrationRepairPolicy.shouldRetryUnavailableServices(
            daemonOnline: serviceStatus.daemonOnline,
            agentOnline: serviceStatus.agentOnline,
            initialRepairAttempted: serviceRepairAttempted,
            retryAttempted: serviceRepairRetryAttempted
        ) {
            serviceRepairRetryAttempted = true
            await repairServices(force: true)
            return
        }
        guard ManagedServiceRegistrationRepairPolicy.shouldRepairUnavailableAgent(
            daemonOnline: serviceStatus.daemonOnline,
            agentOnline: serviceStatus.agentOnline,
            repairAttempted: serviceRepairAttempted
        ) else { return }
        await repairServices()
    }

    func repairServices(force: Bool = false) async {
        guard force || !serviceRepairAttempted else { return }
        serviceRepairAttempted = true
        errorMessage = nil
        serviceApprovalPromptSuppressed = false
        serviceSetupInProgress = true
        serviceStatus.daemonOnline = false
        serviceStatus.agentOnline = false
        statusSubscription?.cancel()
        statusSubscription = nil
        let result = await MonitoringServicesInstaller().repair(
            daemon: SMManagedServiceAdapter(daemonService),
            loginAgent: SMManagedServiceAdapter(agentService)
        )
        syncServiceStates()
        let summary = monitoringServiceInstallationSummary(
            for: [
                ("Privileged daemon", result.daemon),
                ("Login agent", result.loginAgent),
            ],
            initialFailures: result.removalFailures
        )
        if summary.requiresApproval || hasPendingMonitoringServiceApproval {
            serviceApprovalPrompt = ServiceApprovalPrompt(serviceName: "Monitoring services")
        }
        if summary.failures.isEmpty {
            startApprovalRefreshWindow()
        } else {
            serviceSetupInProgress = false
            errorMessage = summary.failures.joined(separator: "\n")
        }
    }

    func monitoringServiceInstallationSummary(
        for services: [(name: String, outcome: ManagedServiceActionOutcome)],
        initialFailures: [String] = []
    ) -> (failures: [String], requiresApproval: Bool) {
        var failures = initialFailures
        var requiresApproval = false
        for (name, outcome) in services {
            switch outcome {
            case .installed, .removed:
                break
            case .approvalRequired:
                requiresApproval = true
            case .failed(let detail):
                failures.append("\(name): \(detail)")
            }
        }
        return (failures, requiresApproval)
    }

    private func recordCurrentServiceRegistration() {
        guard let fingerprint = serviceRegistrationFingerprint else { return }
        let defaults = UserDefaults.standard
        defaults.set(fingerprint, forKey: serviceRegistrationFingerprintKey)
        serviceRepairAttempted = false
        serviceRepairRetryAttempted = false
    }

    func revealInFinder(_ definition: MountDefinition) {
        let expectedSource = configuration.resolve(definition)?.source
        let observedSource = statuses.first(where: { $0.id == definition.id })?.observedSource
        guard MountRevealPolicy.isAvailable(observedSource: observedSource, expectedSource: expectedSource) else {
            errorMessage = "This volume is not currently mounted at its configured folder."
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([
            URL(fileURLWithPath: definition.mountPoint).standardizedFileURL
        ])
    }
}

private extension UTType {
    static let latchConfiguration = UTType(exportedAs: LATCHIdentity.configurationTypeIdentifier)
}

struct ServiceApprovalPrompt: Identifiable, Equatable {
    let id = UUID()
    let serviceName: String
}

@MainActor
final class SMManagedServiceAdapter: ManagedServiceControlling {
    private let service: SMAppService

    init(_ service: SMAppService) {
        self.service = service
    }

    var managedState: ManagedServiceState { ManagedServiceState(service.status) }

    func register() throws {
        try service.register()
    }

    func unregister() async throws {
        try await service.unregister()
    }
}

private extension ManagedServiceState {
    init(_ status: SMAppService.Status) {
        switch status {
        case .notRegistered: self = .notRegistered
        case .enabled: self = .enabled
        case .requiresApproval: self = .requiresApproval
        case .notFound: self = .notFound
        @unknown default: self = .notFound
        }
    }
}

enum AppModelError: LocalizedError {
    case daemonUnavailable
    var errorDescription: String? { "The privileged daemon is unavailable." }
}
