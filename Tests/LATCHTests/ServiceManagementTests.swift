import Foundation
import Testing
@testable import LATCHShared

@Suite("Managed service setup")
@MainActor
struct ServiceManagementTests {
    @Test func serviceFingerprintChangesWhenTheContainingAppChanges() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let relativePaths = [
            "Contents/MacOS/LATCH",
            "Contents/Info.plist",
            "Contents/Library/Helpers/LATCHDaemon",
            "Contents/Library/Helpers/LATCHAgent",
            "Contents/Library/LaunchDaemons/com.github.letsrokk.latch.daemon.plist",
            "Contents/Library/LaunchAgents/com.github.letsrokk.latch.agent.plist",
        ]
        for relativePath in relativePaths {
            let url = root.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("initial".utf8).write(to: url)
        }
        let original = ServiceBundleFingerprint.current(bundleURL: root)

        try Data("rebuilt app".utf8).write(to: root.appendingPathComponent("Contents/MacOS/LATCH"))

        #expect(ServiceBundleFingerprint.current(bundleURL: root) != original)
    }

    @Test func pendingApprovalPollsEveryFiveSecondsUntilTheWindowExpires() {
        #expect(ManagedServiceApprovalPollSchedule.delay(afterAttempt: 0) == 5)
        #expect(ManagedServiceApprovalPollSchedule.delay(afterAttempt: 1) == 5)
        #expect(ManagedServiceApprovalPollSchedule.delay(afterAttempt: 2) == 5)
        #expect(ManagedServiceApprovalPollSchedule.delay(afterAttempt: 24) == 5)
        #expect(ManagedServiceApprovalPollSchedule.delay(afterAttempt: 25) == nil)
    }

    @Test func startAtLoginDefaultsOnButPreservesAnExplicitPreference() {
        #expect(StartAtLoginPreference.desiredValue(storedValue: nil))
        #expect(StartAtLoginPreference.desiredValue(storedValue: true))
        #expect(!StartAtLoginPreference.desiredValue(storedValue: false))
    }

    @Test func startAtLoginReconcilesItsServiceWithoutChangingMonitoringServices() {
        #expect(StartAtLoginPreference.requiredAction(desired: true, state: .notRegistered) == .install)
        #expect(StartAtLoginPreference.requiredAction(desired: false, state: .enabled) == .remove)
        #expect(StartAtLoginPreference.requiredAction(desired: true, state: .enabled) == nil)
        #expect(StartAtLoginPreference.requiredAction(desired: false, state: .notRegistered) == nil)
    }

    @Test func daemonApprovalTriggersDataRefreshAndClearsApprovalGuidance() {
        let decision = ManagedServiceRefreshDecision(
            previousDaemon: .requiresApproval,
            previousLoginAgent: .requiresApproval,
            previousMainApplication: .requiresApproval,
            daemon: .enabled,
            loginAgent: .enabled,
            mainApplication: .enabled
        )

        #expect(decision.shouldRefreshDaemonData)
        #expect(decision.shouldClearApprovalGuidance)
    }

    @Test func enabledDaemonContinuesToBeProbedDuringTheSetupWindow() {
        let decision = ManagedServiceRefreshDecision(
            previousDaemon: .enabled,
            previousLoginAgent: .enabled,
            previousMainApplication: .enabled,
            daemon: .enabled,
            loginAgent: .enabled,
            mainApplication: .enabled
        )

        #expect(decision.shouldRefreshDaemonData)
    }

    @Test func partialApprovalKeepsGuidanceForTheRemainingService() {
        let decision = ManagedServiceRefreshDecision(
            previousDaemon: .requiresApproval,
            previousLoginAgent: .requiresApproval,
            previousMainApplication: .requiresApproval,
            daemon: .enabled,
            loginAgent: .enabled,
            mainApplication: .requiresApproval
        )

        #expect(!decision.shouldClearApprovalGuidance)
        #expect(decision.shouldRefreshDaemonData)
    }

    @Test func approvalRequiredAfterRegistrationIsGuidanceNotFailure() async {
        let service = FakeManagedService(state: .notRegistered, registerResult: .requiresApproval)

        let outcome = await ManagedServiceController().install(service)

        #expect(outcome == .approvalRequired)
        #expect(service.registerCount == 1)
    }

    @Test func operationNotPermittedDuringRegistrationStartsApprovalPolling() async {
        let service = FakeManagedService(
            state: .notRegistered,
            registerResult: .notRegistered,
            registerError: NSError(domain: NSPOSIXErrorDomain, code: 1)
        )

        let outcome = await ManagedServiceController().install(service)

        #expect(outcome == .approvalRequired)
    }

    @Test func launchDeniedDuringRegistrationStartsApprovalPolling() async {
        let service = FakeManagedService(
            state: .notRegistered,
            registerResult: .notRegistered,
            registerError: NSError(domain: "SMAppServiceErrorDomain", code: 10)
        )

        let outcome = await ManagedServiceController().install(service)

        #expect(outcome == .approvalRequired)
    }

    @Test func transientSMAppServiceDenialRetriesRegistrationOnce() async {
        let service = SequencedManagedService(registrationResults: [
            .failure(NSError(domain: "SMAppServiceErrorDomain", code: 1)),
            .success(.enabled),
        ])
        let controller = ManagedServiceController(waitBeforeTransientRetry: {})

        let outcome = await controller.install(service)

        #expect(outcome == .installed)
        #expect(service.registerCount == 2)
    }

    @Test func repeatedSMAppServiceDenialStopsAfterOneRetryAndRequestsApproval() async {
        let service = SequencedManagedService(registrationResults: [
            .failure(NSError(domain: "SMAppServiceErrorDomain", code: 1)),
            .failure(NSError(domain: "SMAppServiceErrorDomain", code: 1)),
        ])
        let controller = ManagedServiceController(waitBeforeTransientRetry: {})

        let outcome = await controller.install(service)

        #expect(outcome == .approvalRequired)
        #expect(service.registerCount == 2)
    }

    @Test func daemonApprovalDoesNotPreventInstallingTheLoginAgent() async {
        let daemon = FakeManagedService(state: .notRegistered, registerResult: .requiresApproval)
        let agent = FakeManagedService(state: .notRegistered, registerResult: .enabled)

        let result = await MonitoringServicesInstaller().install(
            daemon: daemon,
            loginAgent: agent
        )

        #expect(result.daemon == .approvalRequired)
        #expect(result.loginAgent == .installed)
        #expect(daemon.registerCount == 1)
        #expect(agent.registerCount == 1)
    }

    @Test func monitoringSetupDoesNotReregisterAnEnabledService() async {
        let daemon = FakeManagedService(state: .enabled, registerResult: .enabled)
        let agent = FakeManagedService(state: .notRegistered, registerResult: .enabled)

        let result = await MonitoringServicesInstaller().install(
            daemon: daemon,
            loginAgent: agent
        )

        #expect(result.daemon == .installed)
        #expect(result.loginAgent == .installed)
        #expect(daemon.registerCount == 0)
        #expect(agent.registerCount == 1)
    }

    @Test func removingMonitoringServicesDoesNotRemoveTheMainApplicationLoginItem() async {
        let agent = FakeManagedService(state: .enabled, registerResult: .enabled)
        let daemon = FakeManagedService(state: .enabled, registerResult: .enabled)

        let failures = await MonitoringServicesUninstaller().uninstall(
            loginAgent: agent,
            daemon: daemon
        )

        #expect(agent.unregisterCount == 1)
        #expect(daemon.unregisterCount == 1)
        #expect(failures.isEmpty)
    }

    @Test func monitoringRemovalAvailabilityIgnoresTheMainApplicationLoginItem() {
        let absent = MonitoringServicesUninstallPlan(
            daemon: .notRegistered,
            loginAgent: .notFound
        )
        let agentOnly = MonitoringServicesUninstallPlan(
            daemon: .notRegistered,
            loginAgent: .enabled
        )

        #expect(!absent.isAvailable)
        #expect(agentOnly.isAvailable)
        #expect(!agentOnly.shouldContactDaemon)
    }

    @Test func repairReregistersBothMonitoringServices() async {
        let daemon = FakeManagedService(state: .enabled, registerResult: .enabled)
        let agent = FakeManagedService(state: .enabled, registerResult: .enabled)

        let result = await MonitoringServicesInstaller().repair(
            daemon: daemon,
            loginAgent: agent
        )

        #expect(result.daemon == .installed)
        #expect(result.loginAgent == .installed)
        #expect(result.removalFailures.isEmpty)
        #expect(agent.unregisterCount == 1)
        #expect(daemon.unregisterCount == 1)
        #expect(agent.registerCount == 1)
        #expect(daemon.registerCount == 1)
    }

    @Test func repairWaitsForServiceManagementToFinishUnregistering() async {
        let daemon = DelayedUnregisterManagedService(readsBeforeUnregistered: 2)
        let agent = DelayedUnregisterManagedService(readsBeforeUnregistered: 2)
        let installer = MonitoringServicesInstaller(
            unregistrationPollSchedule: .init(maximumAttempts: 3, delay: 0)
        )

        let result = await installer.repair(
            daemon: daemon,
            loginAgent: agent
        )

        #expect(result.daemon == .installed)
        #expect(result.loginAgent == .installed)
        #expect(result.removalFailures.isEmpty)
        #expect(daemon.registerCount == 1)
        #expect(agent.registerCount == 1)
    }

    @Test func repairDoesNotRegisterWhileServiceManagementStillReportsEnabled() async {
        let daemon = DelayedUnregisterManagedService(readsBeforeUnregistered: 10)
        let agent = DelayedUnregisterManagedService(readsBeforeUnregistered: 10)
        let installer = MonitoringServicesInstaller(
            unregistrationPollSchedule: .init(maximumAttempts: 2, delay: 0)
        )

        let result = await installer.repair(
            daemon: daemon,
            loginAgent: agent
        )

        #expect(!result.removalFailures.isEmpty)
        #expect(daemon.registerCount == 0)
        #expect(agent.registerCount == 0)
    }

    @Test func updatedServiceBundleKeepsRequestingRepairUntilRegistrationSucceeds() {
        #expect(ManagedServiceRegistrationRepairPolicy.shouldRepairUpdatedRegistration(
            daemon: .enabled,
            loginAgent: .enabled,
            currentFingerprint: "new",
            registeredFingerprint: "old"
        ))
        #expect(!ManagedServiceRegistrationRepairPolicy.shouldRepairUpdatedRegistration(
            daemon: .enabled,
            loginAgent: .enabled,
            currentFingerprint: "same",
            registeredFingerprint: "same"
        ))
        #expect(ManagedServiceRegistrationRepairPolicy.shouldRepairUpdatedRegistration(
            daemon: .notRegistered,
            loginAgent: .notRegistered,
            currentFingerprint: "new",
            registeredFingerprint: "old"
        ))
        #expect(!ManagedServiceRegistrationRepairPolicy.shouldRepairUpdatedRegistration(
            daemon: .notRegistered,
            loginAgent: .notRegistered,
            currentFingerprint: "new",
            registeredFingerprint: nil
        ))
    }

    @Test func offlineAgentRequestsOnlyOneRepairPerApplicationRun() {
        #expect(ManagedServiceRegistrationRepairPolicy.shouldRepairUnavailableAgent(
            daemonOnline: true,
            agentOnline: false,
            repairAttempted: false
        ))
        #expect(!ManagedServiceRegistrationRepairPolicy.shouldRepairUnavailableAgent(
            daemonOnline: true,
            agentOnline: false,
            repairAttempted: true
        ))
        #expect(!ManagedServiceRegistrationRepairPolicy.shouldRepairUnavailableAgent(
            daemonOnline: true,
            agentOnline: true,
            repairAttempted: false
        ))
    }

    @Test func failedStartupGetsOneAutomaticSecondRegistrationCycle() {
        #expect(ManagedServiceRegistrationRepairPolicy.shouldRetryUnavailableServices(
            daemonOnline: false,
            agentOnline: false,
            initialRepairAttempted: true,
            retryAttempted: false
        ))
        #expect(ManagedServiceRegistrationRepairPolicy.shouldRetryUnavailableServices(
            daemonOnline: true,
            agentOnline: false,
            initialRepairAttempted: true,
            retryAttempted: false
        ))
        #expect(!ManagedServiceRegistrationRepairPolicy.shouldRetryUnavailableServices(
            daemonOnline: false,
            agentOnline: false,
            initialRepairAttempted: true,
            retryAttempted: true
        ))
        #expect(!ManagedServiceRegistrationRepairPolicy.shouldRetryUnavailableServices(
            daemonOnline: false,
            agentOnline: false,
            initialRepairAttempted: false,
            retryAttempted: false
        ))
        #expect(!ManagedServiceRegistrationRepairPolicy.shouldRetryUnavailableServices(
            daemonOnline: true,
            agentOnline: true,
            initialRepairAttempted: true,
            retryAttempted: false
        ))
    }

    @Test func removingAnEnabledServiceReportsRemoval() async {
        let service = FakeManagedService(state: .enabled, registerResult: .enabled)

        let outcome = await ManagedServiceController().remove(service)

        #expect(outcome == .removed)
        #expect(service.unregisterCount == 1)
    }

    @Test func removingANotFoundServiceReportsRemovalWithoutUnregistering() async {
        let service = FakeManagedService(state: .notFound, registerResult: .notFound)

        let outcome = await ManagedServiceController().remove(service)

        #expect(outcome == .removed)
        #expect(service.unregisterCount == 0)
    }

    @Test func uninstallAttemptsLoginAgentAndDaemonWhenOneRemovalFails() async {
        let agent = FakeManagedService(state: .enabled, registerResult: .enabled, unregisterError: .removalFailed)
        let daemon = FakeManagedService(state: .enabled, registerResult: .enabled)
        let mainApplication = FakeManagedService(state: .enabled, registerResult: .enabled)

        let failures = await ManagedServicesUninstaller().uninstall(
            mainApplication: mainApplication,
            loginAgent: agent,
            daemon: daemon
        )

        #expect(mainApplication.unregisterCount == 1)
        #expect(agent.unregisterCount == 1)
        #expect(daemon.unregisterCount == 1)
        #expect(failures.count == 1)
    }

    @Test func uninstallPlanIsUnavailableWhenBothServicesAreAbsent() {
        let plan = ManagedServicesUninstallPlan(
            daemon: .notRegistered,
            loginAgent: .notFound,
            mainApplication: .notRegistered
        )

        #expect(!plan.isAvailable)
        #expect(!plan.shouldContactDaemon)
        #expect(!plan.shouldUnregisterDaemon)
        #expect(!plan.shouldUnregisterLoginAgent)
        #expect(!plan.shouldUnregisterMainApplication)
    }

    @Test func uninstallPlanSkipsDaemonCleanupWhenOnlyLoginAgentIsRegistered() {
        let plan = ManagedServicesUninstallPlan(
            daemon: .notRegistered,
            loginAgent: .enabled,
            mainApplication: .enabled
        )

        #expect(plan.isAvailable)
        #expect(!plan.shouldContactDaemon)
        #expect(!plan.shouldUnregisterDaemon)
        #expect(plan.shouldUnregisterLoginAgent)
        #expect(plan.shouldUnregisterMainApplication)
    }

    @Test func uninstallPlanContactsAnEnabledDaemon() {
        let plan = ManagedServicesUninstallPlan(
            daemon: .enabled,
            loginAgent: .notRegistered,
            mainApplication: .notRegistered
        )

        #expect(plan.isAvailable)
        #expect(plan.shouldContactDaemon)
        #expect(plan.shouldUnregisterDaemon)
        #expect(!plan.shouldUnregisterLoginAgent)
        #expect(!plan.shouldUnregisterMainApplication)
    }
}

@MainActor
private final class FakeManagedService: ManagedServiceControlling {
    private(set) var managedState: ManagedServiceState
    private let registerResult: ManagedServiceState
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0
    private let unregisterError: FakeServiceError?
    private let registerError: (any Error)?

    init(
        state: ManagedServiceState,
        registerResult: ManagedServiceState,
        unregisterError: FakeServiceError? = nil,
        registerError: (any Error)? = nil
    ) {
        managedState = state
        self.registerResult = registerResult
        self.unregisterError = unregisterError
        self.registerError = registerError
    }

    func register() throws {
        registerCount += 1
        managedState = registerResult
        if let registerError { throw registerError }
        if registerResult == .requiresApproval { throw FakeServiceError.approvalRequired }
    }

    func unregister() async throws {
        unregisterCount += 1
        if let unregisterError { throw unregisterError }
        managedState = .notRegistered
    }
}

private enum FakeServiceError: Error { case approvalRequired, removalFailed }

@MainActor
private final class DelayedUnregisterManagedService: ManagedServiceControlling {
    private var state: ManagedServiceState = .enabled
    private var remainingEnabledReads: Int
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0

    init(readsBeforeUnregistered: Int) {
        remainingEnabledReads = readsBeforeUnregistered
    }

    var managedState: ManagedServiceState {
        if unregisterCount > 0, remainingEnabledReads > 0 {
            remainingEnabledReads -= 1
            return .enabled
        }
        if unregisterCount > 0 { state = .notRegistered }
        return state
    }

    func register() throws {
        registerCount += 1
        state = .enabled
        unregisterCount = 0
    }

    func unregister() async throws {
        unregisterCount += 1
    }
}

@MainActor
private final class SequencedManagedService: ManagedServiceControlling {
    private(set) var managedState: ManagedServiceState = .notRegistered
    private var registrationResults: [Result<ManagedServiceState, NSError>]
    private(set) var registerCount = 0

    init(registrationResults: [Result<ManagedServiceState, NSError>]) {
        self.registrationResults = registrationResults
    }

    func register() throws {
        registerCount += 1
        let result = registrationResults.removeFirst()
        switch result {
        case .success(let state): managedState = state
        case .failure(let error): throw error
        }
    }

    func unregister() async throws {
        managedState = .notRegistered
    }
}
