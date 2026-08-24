import Foundation
import LATCHShared

final class StatusSubscription: NSObject, NSXPCListenerDelegate, LATCHStatusSink, @unchecked Sendable {
    let endpoint: NSXPCListenerEndpoint
    private let listener: NSXPCListener
    private let policy: ClientSigningPolicy
    private let validator: ClientCodeSignatureValidator
    private let receive: @MainActor @Sendable (LATCHStatusSinkUpdate) -> Void

    init(policy: ClientSigningPolicy, receive: @escaping @MainActor @Sendable (LATCHStatusSinkUpdate) -> Void) {
        self.policy = policy
        validator = ClientCodeSignatureValidator(policy: policy)
        self.receive = receive
        listener = .anonymous()
        endpoint = listener.endpoint
        super.init()
        listener.delegate = self
        listener.resume()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.setCodeSigningRequirement(policy.codeSigningRequirement)
        guard validator.accepts(processIdentifier: connection.processIdentifier) else { return false }
        connection.exportedInterface = NSXPCInterface(with: LATCHStatusSink.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }

    func receiveStatus(_ statusData: Data) {
        guard let update = try? LATCHStatusSinkCodec.decode(statusData) else { return }
        Task { @MainActor [receive, update] in receive(update) }
    }

    func cancel() {
        listener.invalidate()
    }
}
