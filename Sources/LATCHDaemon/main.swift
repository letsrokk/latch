import Foundation
import LATCHShared
import OSLog

final class DaemonService: NSObject, LATCHXPCProtocol, NSXPCListenerDelegate {
    private let logger = Logger(subsystem: LATCHIdentity.bundleIdentifier, category: "xpc")
    private let controller: DaemonController
    private let validator: ClientCodeSignatureValidator
    private let policy: ClientSigningPolicy
    private let broadcaster: StatusBroadcaster
    private let applicationCoordinator: AgentEndpointRegistry
    private let networkPathObserver: NetworkPathObserver
    private let systemWakeObserver: SystemWakeObserver

    init(policy: ClientSigningPolicy) {
        let broadcaster = StatusBroadcaster(policy: policy)
        self.broadcaster = broadcaster
        let agentPolicy = ClientSigningPolicy(teamID: policy.teamID, bundleIdentifiers: [LATCHIdentity.agentIdentifier])
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
        validator = ClientCodeSignatureValidator(policy: policy)
        self.policy = policy
        Task { [controller] in await controller.start() }
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.setCodeSigningRequirement(policy.codeSigningRequirement)
        guard validator.accepts(processIdentifier: connection.processIdentifier) else {
            logger.error("Rejected unauthorized XPC client")
            return false
        }
        connection.exportedInterface = NSXPCInterface(with: LATCHXPCProtocol.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }

    func handle(_ requestData: Data, reply: @escaping (Data) -> Void) {
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

    func subscribe(_ endpoint: NSXPCListenerEndpoint, reply: @escaping (Bool) -> Void) {
        broadcaster.add(endpoint: endpoint)
        reply(true)
    }

    func registerApplicationCoordinator(_ endpoint: NSXPCListenerEndpoint, reply: @escaping (Bool) -> Void) {
        let becameAvailable = applicationCoordinator.register(endpoint: endpoint)
        reply(true)
        if becameAvailable {
            Task { [controller] in await controller.applicationCoordinatorBecameAvailable() }
        }
    }
}

private final class XPCReplyBox: @unchecked Sendable {
    private let callback: (Data) -> Void
    init(_ callback: @escaping (Data) -> Void) { self.callback = callback }
    func call(_ data: Data) { callback(data) }
}

private final class StatusBroadcaster: @unchecked Sendable {
    private let lock = NSLock()
    private let policy: ClientSigningPolicy
    private var connections: [UUID: NSXPCConnection] = [:]

    init(policy: ClientSigningPolicy) { self.policy = policy }

    func add(endpoint: NSXPCListenerEndpoint) {
        let id = UUID()
        let connection = NSXPCConnection(listenerEndpoint: endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: LATCHStatusSink.self)
        connection.setCodeSigningRequirement(policy.codeSigningRequirement)
        connection.invalidationHandler = { [weak self] in self?.remove(id) }
        connection.interruptionHandler = { [weak self] in self?.remove(id) }
        lock.withLock { connections[id] = connection }
        connection.resume()
    }

    func broadcast(_ statuses: [MountStatus]) {
        guard let data = try? JSONEncoder().encode(statuses) else { return }
        send(data)
    }

    func broadcast(events: [LATCHEvent]) {
        guard let data = try? LATCHStatusSinkCodec.encodeEvents(events) else { return }
        send(data)
    }

    private func send(_ data: Data) {
        let snapshot = lock.withLock { Array(connections.values) }
        for connection in snapshot {
            (connection.remoteObjectProxy as? LATCHStatusSink)?.receiveStatus(data)
        }
    }

    private func remove(_ id: UUID) {
        let connection = lock.withLock { connections.removeValue(forKey: id) }
        connection?.invalidate()
    }
}

private final class AgentEndpointRegistry: ApplicationCoordinatorRequesting, @unchecked Sendable {
    private let lock = NSLock()
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
        return try await withCheckedThrowingContinuation { continuation in
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in continuation.resume(throwing: error) }) as? LATCHAgentXPCProtocol else {
                continuation.resume(throwing: SystemOperationError.unavailable)
                return
            }
            do {
                proxy.handle(try AgentCodec.encode(request)) { data in
                    do { continuation.resume(returning: try JSONDecoder().decode(AgentResponse.self, from: data)) }
                    catch { continuation.resume(throwing: error) }
                }
            } catch { continuation.resume(throwing: error) }
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

let teamID = CurrentCodeIdentity.teamID ?? "ADHOC"
let identifiers: Set<String> = [LATCHIdentity.bundleIdentifier, LATCHIdentity.agentIdentifier]
let service = DaemonService(policy: .init(teamID: teamID, bundleIdentifiers: identifiers))
let listener = NSXPCListener(machServiceName: LATCHIdentity.daemonIdentifier)
listener.delegate = service
listener.resume()
RunLoop.main.run()
