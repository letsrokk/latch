import Foundation
import ServiceManagement
import LATCHShared

@MainActor
extension AppModel {
    func installDaemon() async {
        await install(service: daemonService, name: "Privileged daemon")
    }

    func installAgent() async {
        await install(service: agentService, name: "Login agent")
    }

    func installServices() async {
        if daemonServiceState == .enabled,
           agentServiceState == .enabled,
           (!serviceStatus.daemonOnline || !serviceStatus.agentOnline) {
            serviceRepairRetryAttempted = false
            await repairServices(force: true)
            return
        }
        errorMessage = nil
        serviceApprovalPromptSuppressed = false
        serviceSetupInProgress = true
        serviceRepairAttempted = true
        serviceRepairRetryAttempted = false
        serviceStatus.daemonOnline = false
        let result = await MonitoringServicesInstaller().install(
            daemon: SMManagedServiceAdapter(daemonService),
            loginAgent: SMManagedServiceAdapter(agentService)
        )
        syncServiceStates()

        let summary = monitoringServiceInstallationSummary(for: [
            ("Privileged daemon", result.daemon),
            ("Login agent", result.loginAgent),
        ])

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

    func removeDaemon() async {
        suspendLiveUpdates()
        let outcome = await ManagedServiceController().remove(SMManagedServiceAdapter(daemonService))
        syncServiceStates()
        switch outcome {
        case .removed:
            serviceStatus.daemonOnline = false
        case .failed(let detail):
            errorMessage = detail
            start()
        case .installed, .approvalRequired:
            break
        }
    }

    func removeAgent() async {
        await remove(service: agentService)
    }

    func setStartAtLogin(_ enabled: Bool) async {
        startAtLoginEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: startAtLoginPreferenceKey)
        await reconcileStartAtLoginPreference()
    }

    func initializeStartAtLoginPreference() {
        let defaults = UserDefaults.standard
        let storedValue = defaults.object(forKey: startAtLoginPreferenceKey) as? Bool
        startAtLoginEnabled = StartAtLoginPreference.desiredValue(storedValue: storedValue)
        if storedValue == nil {
            defaults.set(startAtLoginEnabled, forKey: startAtLoginPreferenceKey)
        }
    }

    func reconcileStartAtLoginPreference() async {
        syncServiceStates()
        guard let action = StartAtLoginPreference.requiredAction(
            desired: startAtLoginEnabled,
            state: mainApplicationServiceState
        ) else {
            if hasPendingStartAtLoginApproval { startApprovalRefreshWindow() }
            return
        }

        let controller = ManagedServiceController()
        let service = SMManagedServiceAdapter(mainApplicationService)
        let outcome: ManagedServiceActionOutcome
        switch action {
        case .install:
            outcome = await controller.install(service)
        case .remove:
            outcome = await controller.remove(service)
        case .openLoginItems, .repair:
            return
        }
        syncServiceStates()

        switch outcome {
        case .installed, .removed:
            break
        case .approvalRequired:
            serviceApprovalPromptSuppressed = false
            serviceApprovalPrompt = ServiceApprovalPrompt(serviceName: "Start at login")
            startApprovalRefreshWindow()
        case .failed(let detail):
            errorMessage = "Start at login: \(detail)"
        }
    }
}
