import Foundation

public enum DaemonClientRole: Sendable, Equatable {
    case application
    case agent
}

public enum DaemonXPCOperation: Sendable, Equatable {
    case handleRequest
    case subscribe
    case registerApplicationCoordinator
}

public enum DaemonClientAuthorization {
    public static func permits(_ operation: DaemonXPCOperation, for role: DaemonClientRole) -> Bool {
        return switch (role, operation) {
        case (.application, .handleRequest), (.application, .subscribe), (.agent, .handleRequest), (.agent, .registerApplicationCoordinator):
            true
        case (.application, .registerApplicationCoordinator), (.agent, .subscribe):
            false
        }
    }

    public static func permits(_ request: LATCHRequest, for role: DaemonClientRole) -> Bool {
        guard role == .agent else { return true }
        return switch request {
        case .getStatus, .getRecentEvents:
            true
        default:
            false
        }
    }
}

public struct ClientSigningPolicy: Sendable, Equatable {
    public let teamID: String
    public let bundleIdentifiers: Set<String>

    public init(teamID: String, bundleIdentifiers: Set<String>) {
        self.teamID = teamID
        self.bundleIdentifiers = bundleIdentifiers
    }

    public func accepts(teamID candidateTeamID: String?, bundleIdentifier: String?) -> Bool {
        let teamMatches = teamID == "ADHOC" ? candidateTeamID == nil : candidateTeamID == teamID
        return teamMatches && bundleIdentifier.map(bundleIdentifiers.contains) == true
    }

    public var codeSigningRequirement: String {
        let identifiers = bundleIdentifiers.sorted().map { "identifier \"\($0)\"" }.joined(separator: " or ")
        if teamID == "ADHOC" { return "(\(identifiers))" }
        return "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\" and (\(identifiers))"
    }
}

#if canImport(Security)
import Security
import Darwin

public struct ClientCodeSignatureValidator: Sendable {
    public let policy: ClientSigningPolicy

    public init(policy: ClientSigningPolicy) { self.policy = policy }

    public func accepts(processIdentifier: pid_t) -> Bool {
        let attributes = [kSecGuestAttributePid: processIdentifier] as CFDictionary
        return accepts(attributes: attributes)
    }

    public func accepts(auditToken: audit_token_t) -> Bool {
        var token = auditToken
        let tokenData = withUnsafeBytes(of: &token) { Data($0) }
        return accepts(attributes: [kSecGuestAttributeAudit: tokenData] as CFDictionary)
    }

    private func accepts(attributes: CFDictionary) -> Bool {
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else { return false }
        guard SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [CFString: Any] else { return false }
        return policy.accepts(
            teamID: values[kSecCodeInfoTeamIdentifier] as? String,
            bundleIdentifier: values[kSecCodeInfoIdentifier] as? String
        )
    }
}

public enum CurrentCodeIdentity {
    public static var teamID: String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [CFString: Any] else { return nil }
        return values[kSecCodeInfoTeamIdentifier] as? String
    }
}
#endif
