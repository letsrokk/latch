import Foundation
import LATCHShared
import OSLog

final class DaemonService: NSObject, NSXPCListenerDelegate {
    private let logger = Logger(subsystem: LATCHIdentity.bundleIdentifier, category: "xpc")
    private let controller: DaemonController
    private let applicationValidator: ClientCodeSignatureValidator
    private let agentValidator: ClientCodeSignatureValidator
    private let applicationPolicy: ClientSigningPolicy
    private let agentPolicy: ClientSigningPolicy
    private let broadcaster: StatusBroadcaster
    private let applicationCoordinator: AgentEndpointRegistry
    private let networkPathObserver: NetworkPathObserver
    private let systemWakeObserver: SystemWakeObserver

    init(applicationPolicy: ClientSigningPolicy, agentPolicy: ClientSigningPolicy) {
        let broadcaster = StatusBroadcaster(policy: applicationPolicy)
        self.broadcaster = broadcaster
        let applicationCoordinator = AgentEndpointRegistry(policy: agentPolicy)
        self.applicationCoordinator = applicationCoordinator
        let dependencies = TypedDependencyOperator(applicationCoordinator: applicationCoordinator)
        let controller = DaemonController(
            probeRunner: AgentProbeRunner(requester: applicationCoordinator),
            agent: applicationCoordinator,
            agentIsOnline: { applicationCoordinator.isAvailable },
            dependencies: dependencies,
            networkSnapshots: NativeNetworkSnapshotProvider(),
            onStatusesChanged: { [broadcaster] statuses in broadcaster.broadcast(statuses) },
            onEventsChanged: { [broadcaster] events in broadcaster.broadcast(events: events) }
        )
        self.controller = controller
        networkPathObserver = NetworkPathObserver { [controller] in
            Task { await controller.networkPathChanged() }
        }
        systemWakeObserver = SystemWakeObserver { [controller] in
            Task { await controller.networkPathChanged() }
        }
        applicationValidator = ClientCodeSignatureValidator(policy: applicationPolicy)
        agentValidator = ClientCodeSignatureValidator(policy: agentPolicy)
        self.applicationPolicy = applicationPolicy
        self.agentPolicy = agentPolicy
        Task { [controller] in await controller.start() }
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let roleAndPolicy: (DaemonClientRole, ClientSigningPolicy)?
        if applicationValidator.accepts(processIdentifier: connection.processIdentifier) {
            roleAndPolicy = (.application, applicationPolicy)
        } else if agentValidator.accepts(processIdentifier: connection.processIdentifier) {
            roleAndPolicy = (.agent, agentPolicy)
        } else {
            roleAndPolicy = nil
        }
        guard let (role, policy) = roleAndPolicy else {
            logger.error("Rejected unauthorized XPC client")
            return false
        }
        connection.setCodeSigningRequirement(policy.codeSigningRequirement)
        connection.exportedInterface = NSXPCInterface(with: LATCHXPCProtocol.self)
        connection.exportedObject = DaemonConnectionService(role: role, service: self)
        connection.resume()
        return true
    }

    fileprivate func handle(_ requestData: Data, reply: @escaping (Data) -> Void) {
        let replyBox = XPCReplyBox(reply)
        let controller = controller
        Task { [controller, requestData, replyBox] in
            do {
                let envelope = try XPCCodec.decodeEnvelope(requestData)
                let response = await controller.handle(envelope.request)
                replyBox.call(try XPCCodec.encodeResponse(response, requestID: envelope.requestID))
            } catch let error as XPCValidationError {
                let code: LATCHErrorCode = error == .oversized ? .oversizedRequest : (error == .unsupportedVersion ? .unsupportedVersion : .malformedRequest)
                replyBox.call((try? XPCCodec.encodeResponse(.failure(code, "Invalid XPC request."), requestID: UUID())) ?? Data())
            } catch {
                replyBox.call((try? XPCCodec.encodeResponse(.failure(.malformedRequest, error.localizedDescription), requestID: UUID())) ?? Data())
            }
        }
    }

    fileprivate func subscribe(_ endpoint: NSXPCListenerEndpoint, reply: @escaping (Bool) -> Void) {
        broadcaster.add(endpoint: endpoint)
        reply(true)
    }

    fileprivate func registerApplicationCoordinator(_ endpoint: NSXPCListenerEndpoint, reply: @escaping (Bool) -> Void) {
        let becameAvailable = applicationCoordinator.register(endpoint: endpoint)
        reply(true)
        if becameAvailable {
            Task { [controller] in await controller.applicationCoordinatorBecameAvailable() }
        }
    }
}

private final class DaemonConnectionService: NSObject, LATCHXPCProtocol {
    private let role: DaemonClientRole
    private let service: DaemonService

    init(role: DaemonClientRole, service: DaemonService) {
        self.role = role
        self.service = service
    }

    func handle(_ requestData: Data, reply: @escaping (Data) -> Void) {
        guard DaemonClientAuthorization.permits(.handleRequest, for: role) else {
            let requestID = (try? XPCCodec.decodeEnvelope(requestData).requestID) ?? UUID()
            let response = try? XPCCodec.encodeResponse(
                .failure(.unauthorized, "This client cannot issue daemon requests."),
                requestID: requestID
            )
            reply(response ?? Data())
            return
        }
        if let envelope = try? XPCCodec.decodeEnvelope(requestData),
           !DaemonClientAuthorization.permits(envelope.request, for: role) {
            let response = try? XPCCodec.encodeResponse(
                .failure(.unauthorized, "This client cannot issue that daemon request."),
                requestID: envelope.requestID
            )
            reply(response ?? Data())
            return
        }
        service.handle(requestData, reply: reply)
    }

    func subscribe(_ endpoint: NSXPCListenerEndpoint, reply: @escaping (Bool) -> Void) {
        guard DaemonClientAuthorization.permits(.subscribe, for: role) else {
            reply(false)
            return
        }
        service.subscribe(endpoint, reply: reply)
    }

    func registerApplicationCoordinator(_ endpoint: NSXPCListenerEndpoint, reply: @escaping (Bool) -> Void) {
        guard DaemonClientAuthorization.permits(.registerApplicationCoordinator, for: role) else {
            reply(false)
            return
        }
        service.registerApplicationCoordinator(endpoint, reply: reply)
    }
}

private final class XPCReplyBox: @unchecked Sendable {
    private let callback: (Data) -> Void
    init(_ callback: @escaping (Data) -> Void) { self.callback = callback }
    func call(_ data: Data) { callback(data) }
}

private final class StatusBroadcaster: @unchecked Sendable {
    private let lock = NSLock()
    private let logger = Logger(subsystem: LATCHIdentity.bundleIdentifier, category: "runtime-updates")
    private let policy: ClientSigningPolicy
    private var connections: [UUID: NSXPCConnection] = [:]
    private var revision: UInt64 = 0
    private var latestStatuses: [MountStatus] = []
    private var latestEvents: [LATCHEvent] = []
    private var hasRuntimeState = false
    private let runtimeEventLimit = 200

    init(policy: ClientSigningPolicy) { self.policy = policy }

    func add(endpoint: NSXPCListenerEndpoint) {
        let id = UUID()
        let connection = NSXPCConnection(listenerEndpoint: endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: LATCHStatusSink.self)
        connection.setCodeSigningRequirement(policy.codeSigningRequirement)
        connection.invalidationHandler = { [weak self] in self?.remove(id) }
        connection.interruptionHandler = { [weak self] in self?.remove(id) }
        let initialSnapshot = lock.withLock { () -> LATCHRuntimeSnapshot? in
            connections[id] = connection
            guard hasRuntimeState else { return nil }
            return runtimeSnapshot()
        }
        connection.resume()
        if let initialSnapshot { send(initialSnapshot, to: connection) }
    }

    func broadcast(_ statuses: [MountStatus]) {
        let update = lock.withLock { () -> (LATCHRuntimeSnapshot, [NSXPCConnection]) in
            latestStatuses = statuses
            revision &+= 1
            hasRuntimeState = true
            return (runtimeSnapshot(), Array(connections.values))
        }
        send(update.0, to: update.1)
    }

    func broadcast(events: [LATCHEvent]) {
        let update = lock.withLock { () -> (LATCHRuntimeSnapshot, [NSXPCConnection]) in
            latestEvents = events
            revision &+= 1
            hasRuntimeState = true
            return (runtimeSnapshot(), Array(connections.values))
        }
        send(update.0, to: update.1)
    }

    private func runtimeSnapshot() -> LATCHRuntimeSnapshot {
        LATCHRuntimeSnapshot(revision: revision, statuses: latestStatuses, events: latestEvents)
    }

    private func send(_ snapshot: LATCHRuntimeSnapshot, to connections: [NSXPCConnection]) {
        var payloads = [snapshot]
        if snapshot.events.count > runtimeEventLimit {
            payloads.append(LATCHRuntimeSnapshot(
                revision: snapshot.revision,
                statuses: snapshot.statuses,
                events: Array(snapshot.events.suffix(runtimeEventLimit))
            ))
        }
        if snapshot.events.count > 100 {
            payloads.append(LATCHRuntimeSnapshot(
                revision: snapshot.revision,
                statuses: snapshot.statuses,
                events: Array(snapshot.events.suffix(100))
            ))
        }
        if snapshot.events.count > 0 {
            payloads.append(LATCHRuntimeSnapshot(
                revision: snapshot.revision,
                statuses: snapshot.statuses,
                events: []
            ))
        }
        for candidate in payloads {
            if send(snapshot: candidate, to: connections) { return }
        }
        logger.notice("Unable to encode runtime revision \(snapshot.revision, privacy: .public) for \(connections.count, privacy: .public) subscribers; dropped snapshot")
    }

    @discardableResult
    private func send(snapshot: LATCHRuntimeSnapshot, to connections: [NSXPCConnection]) -> Bool {
        guard let data = try? LATCHStatusSinkCodec.encodeRuntime(snapshot) else {
            logger.notice("Skipping runtime revision \(snapshot.revision, privacy: .public); snapshot too large with \(snapshot.events.count, privacy: .public) events")
            return false
        }
        logger.debug("Publishing runtime revision \(snapshot.revision, privacy: .public) to \(connections.count, privacy: .public) subscribers")
        if connections.isEmpty { return true }
        var validConnectionCount = 0
        for connection in connections {
            guard let sink = connection.remoteObjectProxy as? LATCHStatusSink else { continue }
            sink.receiveStatus(data)
            validConnectionCount += 1
        }
        if validConnectionCount < connections.count {
            logger.error("Dropped runtime publish to one or more stale subscribers.")
        }
        return true
    }

    private func send(_ snapshot: LATCHRuntimeSnapshot, to connection: NSXPCConnection) {
        send(snapshot, to: [connection])
    }

    private func remove(_ id: UUID) {
        let connection = lock.withLock { connections.removeValue(forKey: id) }
        connection?.invalidate()
    }
}

private final class AgentEndpointRegistry: ApplicationCoordinatorRequesting, @unchecked Sendable {
    private let lock = NSLock()
    private let logger = Logger(subsystem: LATCHIdentity.bundleIdentifier, category: "agent-requests")
    private let policy: ClientSigningPolicy
    private var connection: NSXPCConnection?
    private var availability = AgentConnectionAvailability()

    init(policy: ClientSigningPolicy) { self.policy = policy }

    var isAvailable: Bool { lock.withLock { availability.isAvailable } }

    @discardableResult
    func register(endpoint: NSXPCListenerEndpoint) -> Bool {
        let replacement = NSXPCConnection(listenerEndpoint: endpoint)
        replacement.remoteObjectInterface = NSXPCInterface(with: LATCHAgentXPCProtocol.self)
        replacement.setCodeSigningRequirement(policy.codeSigningRequirement)
        replacement.invalidationHandler = { [weak self, weak replacement] in
            self?.clear(ifMatching: replacement)
        }
        replacement.interruptionHandler = { [weak self, weak replacement] in
            self?.clear(ifMatching: replacement)
        }
        let (previous, becameAvailable) = lock.withLock { () -> (NSXPCConnection?, Bool) in
            let old = connection
            connection = replacement
            return (old, availability.register())
        }
        previous?.invalidate()
        replacement.resume()
        return becameAvailable
    }

    func request(_ request: AgentRequest) async throws -> AgentResponse {
        guard let connection = lock.withLock({ connection }) else { throw SystemOperationError.unavailable }
        let handle = AgentConnectionHandle(connection)
        let category = AgentRequestDeadline.category(for: request)
        let started = DispatchTime.now().uptimeNanoseconds
        do {
            let response = try await AgentRequestDeadline.wait(
                for: request,
                onTimeout: { [weak self] in
                    handle.connection.invalidate()
                    self?.clear(ifMatching: handle.connection)
                }
            ) { completion in
                guard let proxy = handle.connection.remoteObjectProxyWithErrorHandler({ error in completion(.failure(error)) }) as? LATCHAgentXPCProtocol else {
                    completion(.failure(SystemOperationError.unavailable))
                    return
                }
                do {
                    proxy.handle(try AgentCodec.encode(request)) { data in
                        completion(Result { try JSONDecoder().decode(AgentResponse.self, from: data) })
                    }
                } catch { completion(.failure(error)) }
            }
            let milliseconds = (DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            logger.debug("Agent request \(category.rawValue, privacy: .public) completed in \(milliseconds, privacy: .public) ms")
            return response
        } catch {
            let milliseconds = (DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            logger.notice("Agent request \(category.rawValue, privacy: .public) failed after \(milliseconds, privacy: .public) ms")
            throw error
        }
    }

    private func clear(ifMatching candidate: NSXPCConnection?) {
        lock.withLock {
            if connection === candidate {
                connection = nil
                availability.disconnect()
            }
        }
    }
}

private final class AgentConnectionHandle: @unchecked Sendable {
    let connection: NSXPCConnection

    init(_ connection: NSXPCConnection) {
        self.connection = connection
    }
}

let teamID = CurrentCodeIdentity.teamID ?? "ADHOC"
let applicationPolicy = ClientSigningPolicy(teamID: teamID, bundleIdentifiers: [LATCHIdentity.bundleIdentifier])
let agentPolicy = ClientSigningPolicy(teamID: teamID, bundleIdentifiers: [LATCHIdentity.agentIdentifier])
let service = DaemonService(applicationPolicy: applicationPolicy, agentPolicy: agentPolicy)
let listener = NSXPCListener(machServiceName: LATCHIdentity.daemonIdentifier)
listener.delegate = service
listener.resume()
RunLoop.main.run()
