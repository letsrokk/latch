import Foundation

public struct AgentConnectionAvailability: Sendable, Equatable {
    public private(set) var isAvailable = false

    public init() {}

    /// Returns true only when this registration restores agent availability.
    public mutating func register() -> Bool {
        let becameAvailable = !isAvailable
        isAvailable = true
        return becameAvailable
    }

    public mutating func disconnect() {
        isAvailable = false
    }
}

public enum AgentRequest: Codable, Sendable, Equatable {
    case probe(mountPoint: String, timeoutSeconds: Int)
    case prepare(MacApplicationDependency)
    case isRunning(String)
    case stop(MacApplicationDependency, timeoutSeconds: Int)
    case start(MacApplicationDependency)
    case verifyRunning(String, timeoutSeconds: Int)
    case executePostMountActions(PostMountActionDelivery)
    case revealManagedMount(mountPoint: String)
}

public enum AgentResponse: Codable, Sendable, Equatable {
    case probe(ProbeResult)
    case ready
    case running(Bool)
    case succeeded
    case postMountActionsAcknowledged(PostMountActionAcknowledgement)
    case postMountActionFailures([String])
    case failed(String)
}

public protocol AgentRequesting: Sendable {
    func request(_ request: AgentRequest) async throws -> AgentResponse
}

public struct AgentProbeRunner: ProbeRunning, Sendable {
    private let requester: any AgentRequesting

    public init(requester: any AgentRequesting) {
        self.requester = requester
    }

    public func run(mountPoint: String, timeoutSeconds: Int) async -> ProbeResult {
        do {
            guard case .probe(let result) = try await requester.request(
                .probe(mountPoint: mountPoint, timeoutSeconds: timeoutSeconds)
            ) else {
                return unavailableResult
            }
            return result
        } catch {
            return unavailableResult
        }
    }

    private var unavailableResult: ProbeResult {
        ProbeResult(executionUnavailable: true)
    }
}

@objc public protocol LATCHAgentXPCProtocol {
    func handle(_ requestData: Data, reply: @escaping (Data) -> Void)
}

public enum AgentCodec {
    public static func encode(_ request: AgentRequest) throws -> Data {
        let data = try JSONEncoder().encode(request)
        guard data.count <= XPCCodec.maximumMessageBytes else { throw XPCValidationError.oversized }
        return data
    }

    public static func decode(_ data: Data) throws -> AgentRequest {
        guard data.count <= XPCCodec.maximumMessageBytes else { throw XPCValidationError.oversized }
        do { return try JSONDecoder().decode(AgentRequest.self, from: data) }
        catch { throw XPCValidationError.malformed }
    }
}
