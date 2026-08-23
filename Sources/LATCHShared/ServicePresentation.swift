import Foundation

public enum ManagedServiceState: String, Sendable, Equatable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
}

public enum ManagedServiceApprovalPollSchedule {
    public static let maximumAttempts = 25

    public static func delay(afterAttempt attempt: Int) -> TimeInterval? {
        guard (0..<maximumAttempts).contains(attempt) else { return nil }
        return 5
    }
}

public enum StartAtLoginPreference {
    public static func desiredValue(storedValue: Bool?) -> Bool {
        storedValue ?? true
    }

    public static func requiredAction(
        desired: Bool,
        state: ManagedServiceState
    ) -> ManagedServicesAction? {
        if desired, state == .notRegistered || state == .notFound { return .install }
        if !desired, state == .enabled || state == .requiresApproval { return .remove }
        return nil
    }
}

public enum ManagedServiceRegistrationRepairPolicy {
    public static func shouldRepairUpdatedRegistration(
        daemon: ManagedServiceState,
        loginAgent: ManagedServiceState,
        currentFingerprint: String?,
        registeredFingerprint: String?
    ) -> Bool {
        guard daemon != .notFound,
              loginAgent != .notFound,
              let currentFingerprint,
              let registeredFingerprint else { return false }
        return registeredFingerprint != currentFingerprint
    }

    public static func shouldRepairUnavailableAgent(
        daemonOnline: Bool,
        agentOnline: Bool,
        repairAttempted: Bool
    ) -> Bool {
        daemonOnline && !agentOnline && !repairAttempted
    }

    public static func shouldRetryUnavailableServices(
        daemonOnline: Bool,
        agentOnline: Bool,
        initialRepairAttempted: Bool,
        retryAttempted: Bool
    ) -> Bool {
        initialRepairAttempted && !retryAttempted && (!daemonOnline || !agentOnline)
    }
}

public struct ManagedServiceRefreshDecision: Sendable, Equatable {
    public let shouldRefreshDaemonData: Bool
    public let shouldClearApprovalGuidance: Bool

    public init(
        previousDaemon: ManagedServiceState,
        previousLoginAgent: ManagedServiceState,
        previousMainApplication: ManagedServiceState,
        daemon: ManagedServiceState,
        loginAgent: ManagedServiceState,
        mainApplication: ManagedServiceState
    ) {
        shouldRefreshDaemonData = daemon == .enabled
        let approvalWasPending = previousDaemon == .requiresApproval
            || previousLoginAgent == .requiresApproval
            || previousMainApplication == .requiresApproval
        let approvalIsPending = daemon == .requiresApproval
            || loginAgent == .requiresApproval
            || mainApplication == .requiresApproval
        shouldClearApprovalGuidance = approvalWasPending && !approvalIsPending
    }
}

public struct ManagedServicePresentation: Sendable, Equatable {
    public let name: String
    public let state: ManagedServiceState

    public init(name: String, state: ManagedServiceState) {
        self.name = name
        self.state = state
    }

    public var statusText: String {
        switch state {
        case .notRegistered: "Not Installed"
        case .enabled: "Ready"
        case .requiresApproval: "Needs Approval"
        case .notFound: "Unavailable"
        }
    }

    public var actionTitle: String {
        switch state {
        case .notRegistered, .notFound: "Install"
        case .enabled: "Remove"
        case .requiresApproval: "Open Login Items"
        }
    }

    public var shouldOfferSystemSettings: Bool { state == .requiresApproval }
}

public enum ManagedServicesAction: Sendable, Equatable {
    case install
    case openLoginItems
    case repair
    case remove
}

public struct ManagedServicesPresentation: Sendable, Equatable {
    public let statusText: String
    public let action: ManagedServicesAction

    public init(
        daemon: ManagedServiceState,
        loginAgent: ManagedServiceState,
        daemonOnline: Bool = false,
        agentOnline: Bool = false,
        setupInProgress: Bool = false
    ) {
        if daemon == .requiresApproval || loginAgent == .requiresApproval {
            statusText = "Needs Approval"
            action = .openLoginItems
        } else if daemon == .enabled && loginAgent == .enabled {
            if daemonOnline && agentOnline {
                statusText = "Ready"
                action = .remove
            } else if setupInProgress {
                statusText = "Starting Services"
                action = .remove
            } else if daemonOnline {
                statusText = "Login Agent Offline"
                action = .repair
            } else {
                statusText = "Daemon Offline"
                action = .repair
            }
        } else if setupInProgress {
            statusText = "Installing"
            action = .install
        } else {
            statusText = "Setup Required"
            action = .install
        }
    }
}

public enum ManagedServiceActionOutcome: Sendable, Equatable {
    case installed
    case approvalRequired
    case removed
    case failed(String)
}

public enum ManagedServiceRegistrationFailure {
    public static func isTransientFirstRegistrationDenial(_ error: any Error) -> Bool {
        matches(error) { error in
            error.domain == "SMAppServiceErrorDomain" && error.code == 1
        }
    }

    public static func requiresApproval(_ error: any Error) -> Bool {
        matches(error) { error in
            (error.domain == NSPOSIXErrorDomain && error.code == 1)
                || (error.domain == "SMAppServiceErrorDomain" && (error.code == 1 || error.code == 10))
        }
    }

    private static func matches(
        _ source: any Error,
        predicate: (NSError) -> Bool
    ) -> Bool {
        let error = source as NSError
        if predicate(error) { return true }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? any Error {
            return matches(underlying, predicate: predicate)
        }
        return false
    }
}

@MainActor
public protocol ManagedServiceControlling: AnyObject {
    var managedState: ManagedServiceState { get }
    func register() throws
    func unregister() async throws
}

@MainActor
public struct ManagedServiceController {
    private let waitBeforeTransientRetry: @MainActor () async -> Void

    public init(
        waitBeforeTransientRetry: @escaping @MainActor () async -> Void = {
            try? await Task.sleep(for: .seconds(1))
        }
    ) {
        self.waitBeforeTransientRetry = waitBeforeTransientRetry
    }

    public func install(_ service: any ManagedServiceControlling) async -> ManagedServiceActionOutcome {
        do {
            try service.register()
        } catch {
            if ManagedServiceRegistrationFailure.isTransientFirstRegistrationDenial(error) {
                await waitBeforeTransientRetry()
                do {
                    try service.register()
                } catch {
                    return registrationFailureOutcome(error, service: service)
                }
                return registrationStateOutcome(service.managedState)
            }
            return registrationFailureOutcome(error, service: service)
        }

        return registrationStateOutcome(service.managedState)
    }

    private func registrationFailureOutcome(
        _ error: any Error,
        service: any ManagedServiceControlling
    ) -> ManagedServiceActionOutcome {
        if ManagedServiceRegistrationFailure.requiresApproval(error) {
            return .approvalRequired
        }
        switch service.managedState {
        case .requiresApproval: return .approvalRequired
        case .enabled: return .installed
        case .notRegistered, .notFound: return .failed(error.localizedDescription)
        }
    }

    private func registrationStateOutcome(_ state: ManagedServiceState) -> ManagedServiceActionOutcome {
        switch state {
        case .enabled: return .installed
        case .requiresApproval: return .approvalRequired
        case .notRegistered: return .failed("The service was not registered.")
        case .notFound: return .failed("The service could not be found in the app bundle.")
        }
    }

    public func remove(_ service: any ManagedServiceControlling) async -> ManagedServiceActionOutcome {
        if service.managedState == .notRegistered { return .removed }
        do {
            try await service.unregister()
            return .removed
        } catch {
            if service.managedState == .notRegistered { return .removed }
            return .failed(error.localizedDescription)
        }
    }
}

public struct ManagedServicesInstallResult: Sendable, Equatable {
    public let daemon: ManagedServiceActionOutcome
    public let loginAgent: ManagedServiceActionOutcome
    public let mainApplication: ManagedServiceActionOutcome
}

public struct MonitoringServicesInstallResult: Sendable, Equatable {
    public let daemon: ManagedServiceActionOutcome
    public let loginAgent: ManagedServiceActionOutcome
}

public struct MonitoringServicesRepairResult: Sendable, Equatable {
    public let daemon: ManagedServiceActionOutcome
    public let loginAgent: ManagedServiceActionOutcome
    public let removalFailures: [String]
}

@MainActor
private enum ManagedServiceOperations {
    static func install(
        _ service: any ManagedServiceControlling
    ) async -> ManagedServiceActionOutcome {
        service.managedState == .enabled
            ? .installed
            : await ManagedServiceController().install(service)
    }

    static func uninstall(
        _ services: [(name: String, service: any ManagedServiceControlling)]
    ) async -> [String] {
        var failures: [String] = []
        let controller = ManagedServiceController()
        for (name, service) in services {
            if case .failed(let detail) = await controller.remove(service) {
                failures.append("\(name): \(detail)")
            }
        }
        return failures
    }

    static func waitForUnregistration(
        of services: [any ManagedServiceControlling],
        maximumAttempts: Int,
        delay: TimeInterval
    ) async -> Bool {
        guard maximumAttempts > 0 else { return false }
        for attempt in 0..<maximumAttempts {
            let states = services.map(\.managedState)
            if states.allSatisfy({ $0 == .notRegistered }) { return true }
            guard attempt + 1 < maximumAttempts else { break }
            try? await Task.sleep(for: .seconds(delay))
        }
        return false
    }
}

@MainActor
public struct MonitoringServicesInstaller {
    public struct UnregistrationPollSchedule: Sendable, Equatable {
        public let maximumAttempts: Int
        public let delay: TimeInterval

        public init(maximumAttempts: Int = 40, delay: TimeInterval = 0.25) {
            self.maximumAttempts = maximumAttempts
            self.delay = delay
        }
    }

    private let unregistrationPollSchedule: UnregistrationPollSchedule

    public init(unregistrationPollSchedule: UnregistrationPollSchedule = .init()) {
        self.unregistrationPollSchedule = unregistrationPollSchedule
    }

    public func install(
        daemon: any ManagedServiceControlling,
        loginAgent: any ManagedServiceControlling
    ) async -> MonitoringServicesInstallResult {
        let daemonOutcome = await ManagedServiceOperations.install(daemon)
        let loginAgentOutcome = await ManagedServiceOperations.install(loginAgent)
        return .init(daemon: daemonOutcome, loginAgent: loginAgentOutcome)
    }

    public func repair(
        daemon: any ManagedServiceControlling,
        loginAgent: any ManagedServiceControlling
    ) async -> MonitoringServicesRepairResult {
        var removalFailures = await MonitoringServicesUninstaller().uninstall(
            loginAgent: loginAgent,
            daemon: daemon
        )
        guard await waitForUnregistration(daemon: daemon, loginAgent: loginAgent) else {
            let detail = "ServiceManagement did not finish unregistering the previous services."
            removalFailures.append(detail)
            return .init(
                daemon: .failed(detail),
                loginAgent: .failed(detail),
                removalFailures: removalFailures
            )
        }
        let installation = await install(daemon: daemon, loginAgent: loginAgent)
        return .init(
            daemon: installation.daemon,
            loginAgent: installation.loginAgent,
            removalFailures: removalFailures
        )
    }

    private func waitForUnregistration(
        daemon: any ManagedServiceControlling,
        loginAgent: any ManagedServiceControlling
    ) async -> Bool {
        await ManagedServiceOperations.waitForUnregistration(
            of: [daemon, loginAgent],
            maximumAttempts: unregistrationPollSchedule.maximumAttempts,
            delay: unregistrationPollSchedule.delay
        )
    }
}

public struct ManagedServicesRepairResult: Sendable, Equatable {
    public let daemon: ManagedServiceActionOutcome
    public let loginAgent: ManagedServiceActionOutcome
    public let mainApplication: ManagedServiceActionOutcome
    public let removalFailures: [String]
}

@MainActor
public struct ManagedServicesInstaller {
    public struct UnregistrationPollSchedule: Sendable, Equatable {
        public let maximumAttempts: Int
        public let delay: TimeInterval

        public init(maximumAttempts: Int = 40, delay: TimeInterval = 0.25) {
            self.maximumAttempts = maximumAttempts
            self.delay = delay
        }
    }

    private let unregistrationPollSchedule: UnregistrationPollSchedule

    public init(unregistrationPollSchedule: UnregistrationPollSchedule = .init()) {
        self.unregistrationPollSchedule = unregistrationPollSchedule
    }

    public func install(
        daemon: any ManagedServiceControlling,
        loginAgent: any ManagedServiceControlling,
        mainApplication: any ManagedServiceControlling
    ) async -> ManagedServicesInstallResult {
        let daemonOutcome = await ManagedServiceOperations.install(daemon)
        let loginAgentOutcome = await ManagedServiceOperations.install(loginAgent)
        let mainApplicationOutcome = await ManagedServiceOperations.install(mainApplication)
        return .init(
            daemon: daemonOutcome,
            loginAgent: loginAgentOutcome,
            mainApplication: mainApplicationOutcome
        )
    }

    public func repair(
        daemon: any ManagedServiceControlling,
        loginAgent: any ManagedServiceControlling,
        mainApplication: any ManagedServiceControlling
    ) async -> ManagedServicesRepairResult {
        var removalFailures = await ManagedServicesUninstaller().uninstall(
            mainApplication: mainApplication,
            loginAgent: loginAgent,
            daemon: daemon
        )
        guard await waitForUnregistration(
            daemon: daemon,
            loginAgent: loginAgent,
            mainApplication: mainApplication
        ) else {
            let detail = "ServiceManagement did not finish unregistering the previous services."
            removalFailures.append(detail)
            return .init(
                daemon: .failed(detail),
                loginAgent: .failed(detail),
                mainApplication: .failed(detail),
                removalFailures: removalFailures
            )
        }
        let installation = await install(
            daemon: daemon,
            loginAgent: loginAgent,
            mainApplication: mainApplication
        )
        return .init(
            daemon: installation.daemon,
            loginAgent: installation.loginAgent,
            mainApplication: installation.mainApplication,
            removalFailures: removalFailures
        )
    }

    private func waitForUnregistration(
        daemon: any ManagedServiceControlling,
        loginAgent: any ManagedServiceControlling,
        mainApplication: any ManagedServiceControlling
    ) async -> Bool {
        await ManagedServiceOperations.waitForUnregistration(
            of: [daemon, loginAgent, mainApplication],
            maximumAttempts: unregistrationPollSchedule.maximumAttempts,
            delay: unregistrationPollSchedule.delay
        )
    }
}

@MainActor
public struct ManagedServicesUninstaller {
    public init() {}

    public func uninstall(
        mainApplication: any ManagedServiceControlling,
        loginAgent: any ManagedServiceControlling,
        daemon: any ManagedServiceControlling
    ) async -> [String] {
        await ManagedServiceOperations.uninstall([
            ("LATCH login item", mainApplication),
            ("Login agent", loginAgent),
            ("Privileged daemon", daemon),
        ])
    }
}

@MainActor
public struct MonitoringServicesUninstaller {
    public init() {}

    public func uninstall(
        loginAgent: any ManagedServiceControlling,
        daemon: any ManagedServiceControlling
    ) async -> [String] {
        await ManagedServiceOperations.uninstall([
            ("Login agent", loginAgent),
            ("Privileged daemon", daemon),
        ])
    }
}

public struct MonitoringServicesUninstallPlan: Sendable, Equatable {
    public let shouldContactDaemon: Bool
    public let shouldUnregisterDaemon: Bool
    public let shouldUnregisterLoginAgent: Bool

    public init(daemon: ManagedServiceState, loginAgent: ManagedServiceState) {
        shouldContactDaemon = daemon == .enabled
        shouldUnregisterDaemon = daemon == .enabled || daemon == .requiresApproval
        shouldUnregisterLoginAgent = loginAgent == .enabled || loginAgent == .requiresApproval
    }

    public var isAvailable: Bool {
        shouldUnregisterDaemon || shouldUnregisterLoginAgent
    }
}

public struct ManagedServicesUninstallPlan: Sendable, Equatable {
    public let shouldContactDaemon: Bool
    public let shouldUnregisterDaemon: Bool
    public let shouldUnregisterLoginAgent: Bool
    public let shouldUnregisterMainApplication: Bool

    public init(
        daemon: ManagedServiceState,
        loginAgent: ManagedServiceState,
        mainApplication: ManagedServiceState
    ) {
        shouldContactDaemon = daemon == .enabled
        shouldUnregisterDaemon = daemon == .enabled || daemon == .requiresApproval
        shouldUnregisterLoginAgent = loginAgent == .enabled || loginAgent == .requiresApproval
        shouldUnregisterMainApplication = mainApplication == .enabled || mainApplication == .requiresApproval
    }

    public var isAvailable: Bool {
        shouldUnregisterDaemon || shouldUnregisterLoginAgent || shouldUnregisterMainApplication
    }
}
