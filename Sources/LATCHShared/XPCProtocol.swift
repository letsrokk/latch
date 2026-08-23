import Foundation

public enum LATCHAction: String, Codable, Sendable, Equatable {
    case mount, unmount, check, recover, reveal
}

public enum LATCHRequest: Codable, Sendable, Equatable {
    case getServiceStatus
    case getStatus
    case getConfiguration
    case exportPortableConfiguration
    case previewPortableConfiguration(Data)
    case applyPortableConfiguration(Data, approvedServerIDs: [UUID], approvedMountIDs: [UUID])
    case saveServer(NFSServerProfile)
    case saveServerAndDefinition(NFSServerProfile, MountDefinition)
    case removeServer(UUID)
    case saveDefinition(MountDefinition)
    case removeDefinition(UUID, confirmMounted: Bool)
    case setEnabled(UUID, Bool)
    case perform(UUID, LATCHAction, confirmed: Bool)
    case getRecentEvents(limit: Int)
    case clearEvents
    case getExternalMounts
    case getDiscoveredServers
    case wakeServer(UUID)
    case verifyNetworkVolumesPermission
    case uninstall(unmountOwned: Bool, removeState: Bool, confirmed: Bool)
}

public enum LATCHResponse: Codable, Sendable, Equatable {
    case serviceStatus(ServiceStatusSnapshot)
    case statuses([MountStatus])
    case configuration(LATCHConfiguration)
    case portableConfiguration(Data)
    case portableConfigurationPreview(PortableImportPreview)
    case events([LATCHEvent])
    case externalMounts([ExternalMountSnapshot])
    case discoveredServers([DiscoveredNFSServer])
    case accepted
    case failure(LATCHErrorCode, String)
}

public enum NetworkVolumesVerificationState: String, Codable, Sendable, Equatable {
    case notChecked
    case checking
    case verified
    case failed

    public var statusText: String {
        switch self {
        case .notChecked: "Not yet checked"
        case .checking: "Checking"
        case .verified: "Ready"
        case .failed: "Error"
        }
    }

    public var isError: Bool { self == .failed }
    public var isVerified: Bool { self == .verified }
}

public struct PersistenceHealthSnapshot: Codable, Sendable, Equatable {
    public var isDegraded: Bool
    public var lastFailureAt: Date?
    public var lastErrorDomain: String?
    public var lastErrorCode: Int?
    public var lastSuccessfulWriteAt: Date?

    public init(
        isDegraded: Bool = false,
        lastFailureAt: Date? = nil,
        lastErrorDomain: String? = nil,
        lastErrorCode: Int? = nil,
        lastSuccessfulWriteAt: Date? = nil
    ) {
        self.isDegraded = isDegraded
        self.lastFailureAt = lastFailureAt
        self.lastErrorDomain = lastErrorDomain
        self.lastErrorCode = lastErrorCode
        self.lastSuccessfulWriteAt = lastSuccessfulWriteAt
    }

    public static let healthy = Self()
}

public struct ServiceStatusSnapshot: Codable, Sendable, Equatable {

    public var daemonOnline: Bool
    public var daemonAuthorized: Bool
    public var agentAuthorized: Bool
    public var agentOnline: Bool
    public var networkVolumesVerification: NetworkVolumesVerificationState
    public var persistenceHealth: PersistenceHealthSnapshot

    public init(daemonOnline: Bool, daemonAuthorized: Bool, agentAuthorized: Bool, agentOnline: Bool = false, networkVolumesVerification: NetworkVolumesVerificationState) {
        self.daemonOnline = daemonOnline
        self.daemonAuthorized = daemonAuthorized
        self.agentAuthorized = agentAuthorized
        self.agentOnline = agentOnline
        self.networkVolumesVerification = networkVolumesVerification
        self.persistenceHealth = .healthy
    }

    public init(
        daemonOnline: Bool,
        daemonAuthorized: Bool,
        agentAuthorized: Bool,
        agentOnline: Bool,
        networkVolumesVerification: NetworkVolumesVerificationState,
        persistenceHealth: PersistenceHealthSnapshot
    ) {
        self.daemonOnline = daemonOnline
        self.daemonAuthorized = daemonAuthorized
        self.agentAuthorized = agentAuthorized
        self.agentOnline = agentOnline
        self.networkVolumesVerification = networkVolumesVerification
        self.persistenceHealth = persistenceHealth
    }

    public init(daemonOnline: Bool, daemonAuthorized: Bool, agentAuthorized: Bool, agentOnline: Bool = false, networkVolumesPermissionVerified: Bool) {
        self.init(
            daemonOnline: daemonOnline,
            daemonAuthorized: daemonAuthorized,
            agentAuthorized: agentAuthorized,
            agentOnline: agentOnline,
            networkVolumesVerification: networkVolumesPermissionVerified ? .verified : .notChecked
        )
    }

    public var networkVolumesPermissionVerified: Bool { networkVolumesVerification.isVerified }

    private enum CodingKeys: String, CodingKey {
        case daemonOnline
        case daemonAuthorized
        case agentAuthorized
        case agentOnline
        case networkVolumesVerification
        case networkVolumesPermissionVerified
        case persistenceHealth
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        daemonOnline = try values.decode(Bool.self, forKey: .daemonOnline)
        daemonAuthorized = try values.decode(Bool.self, forKey: .daemonAuthorized)
        agentAuthorized = try values.decode(Bool.self, forKey: .agentAuthorized)
        agentOnline = try values.decodeIfPresent(Bool.self, forKey: .agentOnline) ?? false
        if let state = try values.decodeIfPresent(NetworkVolumesVerificationState.self, forKey: .networkVolumesVerification) {
            networkVolumesVerification = state
        } else {
            let verified = try values.decodeIfPresent(Bool.self, forKey: .networkVolumesPermissionVerified) ?? false
            networkVolumesVerification = verified ? .verified : .notChecked
        }
        persistenceHealth = try values.decodeIfPresent(PersistenceHealthSnapshot.self, forKey: .persistenceHealth) ?? .healthy
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(daemonOnline, forKey: .daemonOnline)
        try values.encode(daemonAuthorized, forKey: .daemonAuthorized)
        try values.encode(agentAuthorized, forKey: .agentAuthorized)
        try values.encode(agentOnline, forKey: .agentOnline)
        try values.encode(networkVolumesVerification, forKey: .networkVolumesVerification)
        try values.encode(networkVolumesPermissionVerified, forKey: .networkVolumesPermissionVerified)
        try values.encode(persistenceHealth, forKey: .persistenceHealth)
    }
}

public struct XPCRequestEnvelope: Codable, Sendable, Equatable {
    public var version: Int
    public var requestID: UUID
    public var request: LATCHRequest

    public init(version: Int = XPCCodec.currentVersion, requestID: UUID = UUID(), request: LATCHRequest) {
        self.version = version
        self.requestID = requestID
        self.request = request
    }
}

public struct XPCResponseEnvelope: Codable, Sendable, Equatable {
    public var version: Int
    public var requestID: UUID
    public var response: LATCHResponse
}

public enum XPCValidationError: Error, Sendable, Equatable {
    case oversized
    case unsupportedVersion
    case malformed
    case mismatchedRequestID
}

public enum XPCCodec {
    public static let currentVersion = 2
    public static let maximumMessageBytes = 1_048_576

    public static func encodeRequest(_ request: LATCHRequest, requestID: UUID = UUID()) throws -> Data {
        let data = try JSONEncoder().encode(XPCRequestEnvelope(version: XPCCodec.currentVersion, requestID: requestID, request: request))
        guard data.count <= maximumMessageBytes else { throw XPCValidationError.oversized }
        return data
    }

    public static func decodeEnvelope(_ data: Data) throws -> XPCRequestEnvelope {
        guard data.count <= maximumMessageBytes else { throw XPCValidationError.oversized }
        let envelope: XPCRequestEnvelope
        do { envelope = try JSONDecoder().decode(XPCRequestEnvelope.self, from: data) }
        catch { throw XPCValidationError.malformed }
        guard envelope.version == currentVersion else { throw XPCValidationError.unsupportedVersion }
        return envelope
    }

    public static func decodeRequest(_ data: Data) throws -> LATCHRequest {
        try decodeEnvelope(data).request
    }

    public static func decodeResponse(_ data: Data, expectedRequestID: UUID) throws -> LATCHResponse {
        guard data.count <= maximumMessageBytes else { throw XPCValidationError.oversized }
        let envelope: XPCResponseEnvelope
        do {
            envelope = try JSONDecoder().decode(XPCResponseEnvelope.self, from: data)
        } catch {
            throw XPCValidationError.malformed
        }
        guard envelope.version == currentVersion else { throw XPCValidationError.unsupportedVersion }
        guard envelope.requestID == expectedRequestID else { throw XPCValidationError.mismatchedRequestID }
        return envelope.response
    }

    public static func encodeResponse(_ response: LATCHResponse, requestID: UUID) throws -> Data {
        let data = try JSONEncoder().encode(XPCResponseEnvelope(version: currentVersion, requestID: requestID, response: response))
        guard data.count <= maximumMessageBytes else { throw XPCValidationError.oversized }
        return data
    }
}

@objc public protocol LATCHXPCProtocol {
    func handle(_ requestData: Data, reply: @escaping (Data) -> Void)
    func subscribe(_ endpoint: NSXPCListenerEndpoint, reply: @escaping (Bool) -> Void)
    func registerApplicationCoordinator(_ endpoint: NSXPCListenerEndpoint, reply: @escaping (Bool) -> Void)
}

@objc public protocol LATCHStatusSink {
    func receiveStatus(_ statusData: Data)
}
