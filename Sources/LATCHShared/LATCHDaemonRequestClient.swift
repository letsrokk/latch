import Foundation

/// Performs daemon XPC requests without inheriting an actor from the caller.
///
/// NSXPCConnection invokes reply and error handlers on its own queues. Keeping
/// those handlers in this nonisolated client prevents Swift runtime executor
/// assertions when a main-actor UI or login-agent component makes a request.
public final class LATCHDaemonRequestClient: @unchecked Sendable {
    public typealias Transport = (Data, (@escaping () -> Void) -> Void) async throws -> Data

    private let responseTimeout: Duration
    private let transport: Transport

    public init(signingRequirement: String, responseTimeout: Duration = .seconds(8), transport: Transport? = nil) {
        self.responseTimeout = responseTimeout
        self.transport = transport ?? Self.defaultTransport(signingRequirement: signingRequirement)
    }

    public func request(_ request: LATCHRequest) async throws -> LATCHResponse {
        let requestID = UUID()
        let requestData = try XPCCodec.encodeRequest(request, requestID: requestID)
        let cancelTransport = CancellationHandle()

        let responseData = try await ResponseDeadline.wait(
            for: responseTimeout,
            onTimeout: { cancelTransport.cancel() }
        ) { completion in
            Task {
                do {
                    let data = try await transport(requestData) { cancelTransport.set($0) }
                    completion(.success(data))
                } catch {
                    completion(.failure(error))
                }
            }
        }

        return try XPCCodec.decodeResponse(responseData, expectedRequestID: requestID)
    }

    private static func defaultTransport(signingRequirement: String) -> Transport {
        return { requestData, registerCancel in
            try await withCheckedThrowingContinuation { continuation in
                let connection = NSXPCConnection(
                    machServiceName: LATCHIdentity.daemonIdentifier,
                    options: .privileged
                )
                let connectionBox = LATCHXPCConnectionBox(connection)
                registerCancel { connectionBox.connection.invalidate() }
                connection.remoteObjectInterface = NSXPCInterface(with: LATCHXPCProtocol.self)
                connection.setCodeSigningRequirement(signingRequirement)
                connection.resume()

                guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                    connectionBox.connection.invalidate()
                    continuation.resume(throwing: error)
                }) as? LATCHXPCProtocol else {
                    connectionBox.connection.invalidate()
                    continuation.resume(throwing: LATCHDaemonRequestClientError.unavailable)
                    return
                }

                proxy.handle(requestData) { data in
                    connectionBox.connection.invalidate()
                    continuation.resume(returning: data)
                }
            }
        }
    }
}

private final class LATCHXPCConnectionBox: @unchecked Sendable {
    let connection: NSXPCConnection

    init(_ connection: NSXPCConnection) {
        self.connection = connection
    }
}

private final class CancellationHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: () -> Void = {}

    func set(_ callback: @escaping () -> Void) {
        lock.lock()
        self.callback = callback
        lock.unlock()
    }

    func cancel() {
        let callback = lock.withLock { self.callback }
        callback()
    }
}

public enum LATCHDaemonRequestClientError: Error {
    case unavailable
}
