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
    case isRunning(MacApplicationDependency)
    case stop(MacApplicationDependency, timeoutSeconds: Int)
    case start(MacApplicationDependency)
    case verifyRunning(MacApplicationDependency, timeoutSeconds: Int)
    case dependencyPrepare(RecoveryDependency)
    case dependencyIsRunning(RecoveryDependency)
    case dependencyStop(RecoveryDependency, timeoutSeconds: Int)
    case dependencyStart(RecoveryDependency)
    case dependencyVerifyRunning(RecoveryDependency, timeoutSeconds: Int)
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

public enum AgentRequestDeadline {
    public enum Category: String, Sendable, Equatable {
        case probe
        case dependency
        case postMount
        case reveal
    }

    public static func category(for request: AgentRequest) -> Category {
        switch request {
        case .probe:
            .probe
        case .executePostMountActions:
            .postMount
        case .revealManagedMount:
            .reveal
        case .prepare, .isRunning, .stop, .start, .verifyRunning,
             .dependencyPrepare, .dependencyIsRunning, .dependencyStop,
             .dependencyStart, .dependencyVerifyRunning:
            .dependency
        }
    }

    public static func timeout(for request: AgentRequest) -> Duration {
        switch request {
        case .probe(_, let timeoutSeconds):
            .seconds(max(3, timeoutSeconds + 2))
        case .stop(_, let timeoutSeconds),
             .verifyRunning(_, let timeoutSeconds),
             .dependencyStop(_, let timeoutSeconds),
             .dependencyVerifyRunning(_, let timeoutSeconds):
            .seconds(max(15, timeoutSeconds + 10))
        case .prepare, .isRunning, .start,
             .dependencyPrepare, .dependencyIsRunning, .dependencyStart:
            .seconds(30)
        case .executePostMountActions:
            .seconds(30)
        case .revealManagedMount:
            .seconds(8)
        }
    }

    public static func wait(
        for request: AgentRequest,
        timeoutOverride: Duration? = nil,
        onTimeout: @escaping @Sendable () -> Void,
        start: @escaping @Sendable (@escaping @Sendable (Result<AgentResponse, any Error>) -> Void) -> Void
    ) async throws -> AgentResponse {
        try await ResponseDeadline.wait(
            for: timeoutOverride ?? timeout(for: request),
            cancellationBehavior: category(for: request) == .dependency ? .awaitResponse : .cancelWait,
            onTimeout: onTimeout,
            start: start
        )
    }
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
