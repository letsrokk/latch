import AppKit
import Foundation
import LATCHShared
import OSLog
import UserNotifications
import Darwin

final class ApplicationCoordinatorService: NSObject, LATCHAgentXPCProtocol, NSXPCListenerDelegate, @unchecked Sendable {
    private let logger = Logger(subsystem: LATCHIdentity.bundleIdentifier, category: "application-lifecycle")
    private let validator: ClientCodeSignatureValidator
    private let policy: ClientSigningPolicy
    private let probeRunner: NativeProbeRunner
    private let postMountExecutor = DurablePostMountActionExecutor()

    init(policy: ClientSigningPolicy, probeURL: URL) {
        self.policy = policy
        probeRunner = NativeProbeRunner(executableURL: probeURL)
        validator = ClientCodeSignatureValidator(policy: policy)
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.setCodeSigningRequirement(policy.codeSigningRequirement)
        guard validator.accepts(processIdentifier: connection.processIdentifier) else {
            logger.error("Rejected unauthorized application-coordinator client")
            return false
        }
        connection.exportedInterface = NSXPCInterface(with: LATCHAgentXPCProtocol.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }

    func handle(_ requestData: Data, reply: @escaping (Data) -> Void) {
        let replyBox = AgentReplyBox(reply)
        Task { @MainActor [self, requestData, replyBox] in
            let response: AgentResponse
            do { response = try await execute(AgentCodec.decode(requestData)) }
            catch { response = .failed(error.localizedDescription) }
            replyBox.call((try? JSONEncoder().encode(response)) ?? Data())
        }
    }

    @MainActor
    private func execute(_ request: AgentRequest) async throws -> AgentResponse {
        switch request {
        case .probe(let mountPoint, let timeoutSeconds):
            let result = await probeRunner.run(mountPoint: mountPoint, timeoutSeconds: timeoutSeconds)
            logger.notice("User-context probe completed: \(String(describing: result), privacy: .public)")
            return .probe(result)
        case .dependencyPrepare(let dependency):
            try await executeDependency(dependency, operation: .prepare)
            return .ready
        case .dependencyIsRunning(let dependency):
            return .running(await isDependencyRunning(dependency))
        case .dependencyStop(let dependency, let timeout):
            try await stopDependency(dependency, timeout: timeout)
            return .succeeded
        case .dependencyStart(let dependency):
            try await startDependency(dependency)
            return .succeeded
        case .dependencyVerifyRunning(let dependency, let timeout):
            if await isDependencyRunning(dependency, timeout: timeout) {
                return .succeeded
            }
            return .failed("The dependency did not report as running.")
        case .prepare(let app):
            _ = try resolveAndValidate(app)
            return .ready
        case .isRunning(let identifier):
            return .running(runningApplication(identifier) != nil)
        case .stop(let app, let timeout):
            let relaunchURL = try resolveAndValidate(app)
            guard let running = runningApplication(app.bundleIdentifier) else { return .succeeded }
            _ = running.terminate()
            if await waitUntil(timeout: timeout, condition: { self.runningApplication(app.bundleIdentifier) == nil }) { return .succeeded }
            guard app.forceQuitAfterTimeout, try resolveAndValidate(app) == relaunchURL else {
                throw ApplicationCoordinatorError.cannotStopSafely
            }
            _ = running.forceTerminate()
            guard await waitUntil(timeout: 5, condition: { self.runningApplication(app.bundleIdentifier) == nil }) else {
                throw ApplicationCoordinatorError.cannotStopSafely
            }
            return .succeeded
        case .start(let app):
            let url = try resolveAndValidate(app)
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            return .succeeded
        case .verifyRunning(let identifier, let timeout):
            guard await waitUntil(timeout: timeout, condition: { self.runningApplication(identifier) != nil }) else {
                throw ApplicationCoordinatorError.restartFailed
            }
            return .succeeded
        case .executePostMountActions(let delivery):
            let acknowledgement = try await postMountExecutor.execute(delivery) { [self] item in
                do {
                    try await executePostMountAction(item.action, mountPoint: delivery.mountPoint)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }
            return .postMountActionsAcknowledged(acknowledgement)
        case .revealManagedMount(let mountPoint):
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: mountPoint).standardizedFileURL])
            return .succeeded
        }
    }

    @MainActor
    private func executePostMountAction(_ action: PostMountAction, mountPoint: String) async throws {
        try PostMountActionValidator.validate(action)
        switch action {
        case .revealInFinder:
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: mountPoint).standardizedFileURL])
        case .openRelativePath(let relativePath):
            let target = try PostMountPathResolver.resolve(relativePath: relativePath, beneath: URL(fileURLWithPath: mountPoint))
            guard NSWorkspace.shared.open(target) else { throw ApplicationCoordinatorError.postMountActionFailed }
        case .openApplication(let bundleIdentifier, let applicationURL):
            let target = applicationURL.map(URL.init(fileURLWithPath:))
                ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
            guard let target else { throw ApplicationCoordinatorError.invalidRelaunchTarget }
            let validated = try PostMountApplicationTarget.validate(
                resolvedURL: target,
                expectedBundleIdentifier: bundleIdentifier,
                actualBundleIdentifier: Bundle(url: target)?.bundleIdentifier
            )
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            _ = try await NSWorkspace.shared.openApplication(at: validated, configuration: configuration)
        }
    }

    @MainActor
    private func executeDependency(_ dependency: RecoveryDependency, operation: DependencyOperation) async throws {
        switch dependency.kind {
        case .macApplication(let app):
            try await executeMacApplicationDependency(app, operation: operation)
        case .dockerContainer(let docker):
            switch operation {
            case .prepare, .verify:
                _ = try await executeDockerCommand(
                    .init(docker: docker, command: ["inspect", "--format", "{{.Id}}", docker.containerName]),
                    timeout: 10
                )
            case .stop(let timeout):
                _ = try await executeDockerCommand(
                    .init(docker: docker, command: ["stop", "--time", String(timeout), docker.containerName]),
                    timeout: timeout + 5
                )
            case .start:
                _ = try await executeDockerCommand(
                    .init(docker: docker, command: ["start", docker.containerName]),
                    timeout: 30
                )
            case .isRunning:
                _ = await isDependencyRunning(.init(id: dependency.id, enabled: dependency.enabled, stopTimeoutSeconds: dependency.stopTimeoutSeconds, kind: dependency.kind), timeout: 10)
            }
        }
    }

    @MainActor
    private func isDependencyRunning(_ dependency: RecoveryDependency, timeout: Int = 10) async -> Bool {
        switch dependency.kind {
        case .macApplication(let app):
            return runningApplication(app.bundleIdentifier) != nil
        case .dockerContainer(let docker):
            return (try? await isDockerContainerRunning(docker: docker, timeout: timeout)) ?? false
        }
    }

    @MainActor
    private func stopDependency(_ dependency: RecoveryDependency, timeout: Int) async throws {
        try await executeDependency(dependency, operation: .stop(timeout: timeout))
    }

    @MainActor
    private func startDependency(_ dependency: RecoveryDependency) async throws {
        try await executeDependency(dependency, operation: .start)
    }

    @MainActor
    private func executeMacApplicationDependency(_ app: MacApplicationDependency, operation: DependencyOperation) async throws {
        switch operation {
        case .prepare:
            _ = try resolveAndValidate(app)
        case .isRunning:
            break
        case .stop(let timeout):
            guard let running = runningApplication(app.bundleIdentifier) else { return }
            let applicationURL = try resolveAndValidate(app)
            guard await stopApplication(
                running,
                applicationURL: applicationURL,
                timeout: timeout,
                allowForceQuit: app.forceQuitAfterTimeout
            ) else {
                throw ApplicationCoordinatorError.cannotStopSafely
            }
        case .start:
            let applicationURL = try resolveAndValidate(app)
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            _ = try await NSWorkspace.shared.openApplication(
                at: applicationURL,
                configuration: configuration
            )
        case .verify:
            if runningApplication(app.bundleIdentifier) == nil { throw ApplicationCoordinatorError.restartFailed }
        }
    }

    @MainActor
    private func stopApplication(
        _ application: NSRunningApplication,
        applicationURL: URL,
        timeout: Int,
        allowForceQuit: Bool
    ) async -> Bool {
        guard let bundleIdentifier = application.bundleIdentifier else { return false }
        _ = application.terminate()
        if await waitForExit(bundleIdentifier, timeout: max(1, timeout)) {
            return true
        }
        let configuredBundleURL = applicationURL.standardizedFileURL.resolvingSymlinksInPath()
        let runningBundleURL = application.bundleURL?.standardizedFileURL.resolvingSymlinksInPath()
        guard allowForceQuit, configuredBundleURL == runningBundleURL else {
            return false
        }
        guard application.forceTerminate() else { return false }
        return await waitForExit(bundleIdentifier, timeout: 5)
    }

    @MainActor
    private func waitForExit(_ bundleIdentifier: String, timeout: Int) async -> Bool {
        guard timeout > 0 else { return false }
        return await waitUntil(timeout: timeout) { [self] in runningApplication(bundleIdentifier) == nil }
    }

    @MainActor
    private func isDockerContainerRunning(docker: DockerContainerDependency, timeout: Int) async throws -> Bool {
        let output = try await executeDockerCommand(.init(docker: docker, command: ["inspect", "--format", "{{.State.Running}}", docker.containerName]), timeout: timeout)
        return output.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    @MainActor
    private func executeDockerCommand(_ request: DockerCommandRequest, timeout: Int) async throws -> String {
        let executable = try dockerExecutablePath()
        let environment = dockerEnvironment(docker: request.docker)
        return try await Task.detached(priority: .userInitiated) {
            try DockerCommandRunner.run(
                executable: executable,
                arguments: request.command,
                environment: environment,
                timeout: timeout
            )
        }.value
    }

    @MainActor
    private func dockerEnvironment(docker: DockerContainerDependency) -> [String: String] {
        var environment = [
            "DOCKER_HOST": "unix://\(docker.dockerSocketPath)",
            "PATH": "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin",
        ]
        if let compose = docker.composeFilePath { environment["COMPOSE_FILE"] = compose }
        return environment
    }

    @MainActor
    private func dockerExecutablePath() throws -> String {
        let candidates = ["/usr/local/bin/docker", "/opt/homebrew/bin/docker", "/Applications/Docker.app/Contents/Resources/bin/docker"]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) { return path }
        throw ApplicationCoordinatorError.missingDockerRuntime
    }

    private enum DependencyOperation {
        case prepare
        case isRunning
        case stop(timeout: Int)
        case start
        case verify
    }

    private struct DockerCommandRequest {
        let docker: DockerContainerDependency
        let command: [String]
    }

    private enum DockerCommandRunner {
        private final class OutputBuffer: @unchecked Sendable {
            private let lock = NSLock()
            private var data = Data()

            func append(_ value: Data) { lock.withLock { data.append(value) } }
            var snapshot: Data { lock.withLock { data } }
        }

        static func run(executable: String, arguments: [String], environment: [String: String], timeout: Int) throws -> String {
            let process = Process()
            let pipe = Pipe()
            let errorPipe = Pipe()
            let outputData = OutputBuffer()
            let errorData = OutputBuffer()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                outputData.append(data)
            }
            errorPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                errorData.append(data)
            }
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.environment = environment
            process.standardOutput = pipe
            process.standardError = errorPipe
            try process.run()
            let deadline = Date().addingTimeInterval(Double(timeout))
            while process.isRunning && Date() < deadline { usleep(25_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            pipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            outputData.append(pipe.fileHandleForReading.readDataToEndOfFile())
            errorData.append(errorPipe.fileHandleForReading.readDataToEndOfFile())
            let detail = String(decoding: errorData.snapshot, as: UTF8.self)
            guard process.terminationStatus == 0 else {
                throw ApplicationCoordinatorError.dockerUnavailable(detail.isEmpty ? "The Docker command failed." : detail)
            }
            return String(decoding: outputData.snapshot, as: UTF8.self)
        }
    }

    @MainActor
    private func resolveAndValidate(_ app: MacApplicationDependency) throws -> URL {
        let resolved = app.applicationURL.map { URL(fileURLWithPath: $0) }
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleIdentifier)
        guard let resolved,
              Bundle(url: resolved)?.bundleIdentifier == app.bundleIdentifier else {
            throw ApplicationCoordinatorError.invalidRelaunchTarget
        }
        return resolved.standardizedFileURL.resolvingSymlinksInPath()
    }

    @MainActor
    private func runningApplication(_ identifier: String) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: identifier).first
    }

    @MainActor
    private func waitUntil(timeout: Int, condition: @escaping @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(Double(timeout))
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return condition()
    }
}

private func registerCoordinator(endpoint: NSXPCListenerEndpoint, signingRequirement: String) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        let connection = NSXPCConnection(machServiceName: LATCHIdentity.daemonIdentifier, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: LATCHXPCProtocol.self)
        connection.setCodeSigningRequirement(signingRequirement)
        connection.resume()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            connection.invalidate()
            continuation.resume(throwing: error)
        }) as? LATCHXPCProtocol else {
            connection.invalidate()
            continuation.resume(throwing: ApplicationCoordinatorError.daemonUnavailable)
            return
        }
        proxy.registerApplicationCoordinator(endpoint) { accepted in
            connection.invalidate()
            if accepted { continuation.resume() }
            else { continuation.resume(throwing: ApplicationCoordinatorError.daemonUnavailable) }
        }
    }
}

private final class AgentReplyBox: @unchecked Sendable {
    private let callback: (Data) -> Void
    init(_ callback: @escaping (Data) -> Void) { self.callback = callback }
    func call(_ data: Data) { callback(data) }
}

@MainActor
private final class StatusNotifier {
    private var previousStates: [UUID: MountState] = [:]
    private var eventStates: [UUID: MountState] = [:]
    private var seenEventIDs = Set<UUID>()
    private var initializedEvents = false
    private var unavailableSince: [UUID: Date] = [:]
    private var prolongedNotifications = Set<UUID>()
    private let preferences = UserDefaults(suiteName: LATCHIdentity.preferenceSuite) ?? .standard
    private let daemonClient = LATCHDaemonRequestClient(
        signingRequirement: ClientSigningPolicy(
            teamID: CurrentCodeIdentity.teamID ?? "ADHOC",
            bundleIdentifiers: [LATCHIdentity.daemonIdentifier]
        ).codeSigningRequirement
    )

    func run() async {
        while !Task.isCancelled {
            if let statuses = try? await fetchStatuses() {
                let byID = Dictionary(uniqueKeysWithValues: statuses.map { ($0.id, $0) })
                pruneNotificationState(to: Set(byID.keys))
                if let events = try? await fetchEvents() { await process(events: events, statuses: byID) }
                for status in statuses { await process(status) }
            }
            try? await Task.sleep(for: .seconds(15))
        }
    }

    private func process(_ status: MountStatus) async {
        let previous = previousStates[status.id]
        if [.networkUnavailable, .probeTimedOut].contains(status.state) {
            unavailableSince[status.id] = unavailableSince[status.id] ?? Date()
        } else {
            unavailableSince[status.id] = nil
            prolongedNotifications.remove(status.id)
        }

        let threshold = preferences.object(forKey: "prolongedUnavailableSeconds") == nil ? 300 : preferences.double(forKey: "prolongedUnavailableSeconds")
        if NotificationPolicy.event(previous: previous, current: status.state, unavailableSince: unavailableSince[status.id], now: Date(), unavailableThreshold: threshold) == .prolongedUnavailable,
           !prolongedNotifications.contains(status.id) {
            await deliver(.prolongedUnavailable, status: status)
            prolongedNotifications.insert(status.id)
        }
        previousStates[status.id] = status.state
    }

    private func process(events: [LATCHEvent], statuses: [UUID: MountStatus]) async {
        if !initializedEvents {
            for event in events {
                if let mountID = event.mountID, let state = event.state { eventStates[mountID] = state }
            }
            seenEventIDs = EventWindowTransition.currentIDs(events)
            initializedEvents = true
            return
        }
        let newEventIDs = EventWindowTransition.newEventIDs(previous: seenEventIDs, current: events)
        for event in events where newEventIDs.contains(event.id) {
            guard let mountID = event.mountID, let current = event.state else { continue }
            let previous = eventStates[mountID]
            if let notification = NotificationPolicy.event(previous: previous, current: current, unavailableSince: nil, now: event.date),
               let status = statuses[mountID] {
                await deliver(notification, status: status)
            }
            eventStates[mountID] = current
        }
        seenEventIDs = EventWindowTransition.currentIDs(events)
    }

    private func pruneNotificationState(to mountIDs: Set<UUID>) {
        previousStates = previousStates.filter { mountIDs.contains($0.key) }
        eventStates = eventStates.filter { mountIDs.contains($0.key) }
        unavailableSince = unavailableSince.filter { mountIDs.contains($0.key) }
        prolongedNotifications = prolongedNotifications.filter { mountIDs.contains($0) }
    }

    private func deliver(_ event: LATCHNotificationEvent, status: MountStatus) async {
        if preferences.object(forKey: "notificationsEnabled") != nil, !preferences.bool(forKey: "notificationsEnabled") { return }
        let content = UNMutableNotificationContent()
        switch event {
        case .recoverySucceeded:
            content.title = "NFS recovery succeeded"
            content.body = status.detail
        case .recoveryFailed:
            content.title = "NFS recovery failed closed"
            content.body = status.detail
            content.interruptionLevel = .timeSensitive
        case .prolongedUnavailable:
            content.title = "NFS volume remains unavailable"
            content.body = status.detail
        }
        content.sound = .default
        try? await UNUserNotificationCenter.current().add(.init(identifier: "latch-\(status.id)-\(event)", content: content, trigger: nil))
    }

    private func fetchStatuses() async throws -> [MountStatus] {
        let response = try await fetch(.getStatus)
        guard case .statuses(let statuses) = response else { throw ApplicationCoordinatorError.daemonUnavailable }
        return statuses
    }

    private func fetchEvents() async throws -> [LATCHEvent] {
        let response = try await fetch(.getRecentEvents(limit: 100))
        guard case .events(let events) = response else { throw ApplicationCoordinatorError.daemonUnavailable }
        return events
    }

    private func fetch(_ request: LATCHRequest) async throws -> LATCHResponse {
        try await daemonClient.request(request)
    }
}

enum ApplicationCoordinatorError: LocalizedError {
    case invalidRelaunchTarget, cannotStopSafely, restartFailed, daemonUnavailable, postMountActionFailed, missingDockerRuntime, dockerUnavailable(String)
    var errorDescription: String? {
        switch self {
        case .invalidRelaunchTarget: "The application bundle identifier and relaunch target could not be validated."
        case .cannotStopSafely: "The application did not stop and cannot be force-quit safely."
        case .restartFailed: "The application did not restart before the deadline."
        case .daemonUnavailable: "The privileged daemon is unavailable."
        case .postMountActionFailed: "The requested post-mount action could not be completed."
        case .missingDockerRuntime: "Docker is required but no known executable was found."
        case .dockerUnavailable(let detail): detail
        }
    }
}

let teamID = CurrentCodeIdentity.teamID ?? "ADHOC"
let probeURL = ExecutableLocation.sibling(named: "LATCHProbe")
let service = ApplicationCoordinatorService(
    policy: .init(teamID: teamID, bundleIdentifiers: [LATCHIdentity.daemonIdentifier]),
    probeURL: probeURL
)
let listener = NSXPCListener.anonymous()
listener.delegate = service
listener.resume()
let daemonSigningRequirement = ClientSigningPolicy(teamID: teamID, bundleIdentifiers: [LATCHIdentity.daemonIdentifier]).codeSigningRequirement
Task {
    while !Task.isCancelled {
        do {
            try await registerCoordinator(endpoint: listener.endpoint, signingRequirement: daemonSigningRequirement)
            try await Task.sleep(for: .seconds(30))
        } catch {
            try? await Task.sleep(for: .seconds(2))
        }
    }
}
Task { @MainActor in await StatusNotifier().run() }
RunLoop.main.run()
