import Darwin
import Foundation

public enum ConfigurationValidationError: String, Error, Sendable, Equatable {
    case unsupportedSchemaVersion
    case duplicateID
    case duplicateSource
    case duplicateMountPoint
    case invalidDisplayName
    case invalidHost
    case invalidExportPath
    case invalidMountPoint
    case mountPointOutsideApprovedRoot
    case symlinkMountPoint
    case invalidTiming
    case duplicateDependencyID
    case invalidDependency
    case externalSourceConflict
    case externalMountPointConflict
    case missingServerReference
    case duplicateServerID
    case duplicateServerHostname
    case invalidNetworkRule
    case invalidWakeOnLAN
    case invalidPostMountAction
}

public struct ConfigurationValidator: Sendable {
    public let approvedRoots: [String]

    public init(approvedRoots: [String] = ["/Volumes/Media", "/Users"]) {
        self.approvedRoots = approvedRoots.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
    }

    public func validate(_ configuration: LATCHConfiguration, liveMounts: [ExternalMountSnapshot]) throws {
        guard configuration.schemaVersion == 2 else { throw ConfigurationValidationError.unsupportedSchemaVersion }
        var serverIDs = Set<UUID>()
        var serverHostnames = Set<String>()
        for server in configuration.servers {
            guard serverIDs.insert(server.id).inserted else { throw ConfigurationValidationError.duplicateServerID }
            guard serverHostnames.insert(server.hostname.lowercased()).inserted else { throw ConfigurationValidationError.duplicateServerHostname }
            guard !server.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  isValidHost(server.hostname) else { throw ConfigurationValidationError.invalidHost }
            try validateNetworkRules(server.networkMountRules)
            try validateWakeOnLAN(server.wakeOnLAN)
        }
        let resolved = try configuration.mounts.map { definition -> MountDefinition in
            guard let server = configuration.servers.first(where: { $0.id == definition.serverID }) else {
                throw ConfigurationValidationError.missingServerReference
            }
            return definition.resolved(using: server)
        }
        try validate(resolved, liveMounts: liveMounts)
    }

    public func validate(_ definitions: [MountDefinition], liveMounts: [ExternalMountSnapshot]) throws {
        var ids = Set<UUID>()
        var sources = Set<String>()
        var mountPoints = Set<String>()
        let externalSources = Set(liveMounts.map { normalizeSource($0.source) })
        let externalMountPoints = Set(liveMounts.map { normalizePath($0.mountPoint) })

        for definition in definitions {
            guard ids.insert(definition.id).inserted else { throw ConfigurationValidationError.duplicateID }
            guard !definition.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ConfigurationValidationError.invalidDisplayName
            }
            guard isValidHost(definition.host) else { throw ConfigurationValidationError.invalidHost }
            guard isAbsoluteNormalized(definition.exportPath) else { throw ConfigurationValidationError.invalidExportPath }
            guard isAbsoluteNormalized(definition.mountPoint) else { throw ConfigurationValidationError.invalidMountPoint }

            let normalizedMountPoint = normalizePath(definition.mountPoint)
            guard approvedRoots.contains(where: { normalizedMountPoint.hasPrefix($0 + "/") }) else {
                throw ConfigurationValidationError.mountPointOutsideApprovedRoot
            }
            if isSymlink(at: normalizedMountPoint) { throw ConfigurationValidationError.symlinkMountPoint }
            guard definition.probeIntervalSeconds >= 10,
                  definition.probeTimeoutSeconds >= 1,
                  definition.probeTimeoutSeconds < definition.probeIntervalSeconds,
                  definition.recoveryCooldownSeconds >= 60 else {
                throw ConfigurationValidationError.invalidTiming
            }

            let source = normalizeSource(definition.source)
            guard sources.insert(source).inserted else { throw ConfigurationValidationError.duplicateSource }
            guard mountPoints.insert(normalizedMountPoint).inserted else { throw ConfigurationValidationError.duplicateMountPoint }
            guard !externalSources.contains(source) else { throw ConfigurationValidationError.externalSourceConflict }
            guard !externalMountPoints.contains(normalizedMountPoint) else { throw ConfigurationValidationError.externalMountPointConflict }

            try validateDependencies(definition.recoveryDependencies)
            do {
                try PostMountActionValidator.validate(definition.postMountActions)
            } catch {
                throw ConfigurationValidationError.invalidPostMountAction
            }
        }
    }

    private func validateDependencies(_ dependencies: [RecoveryDependency]) throws {
        var ids = Set<UUID>()
        for dependency in dependencies {
            guard ids.insert(dependency.id).inserted else { throw ConfigurationValidationError.duplicateDependencyID }
            guard (1...300).contains(dependency.stopTimeoutSeconds) else {
                throw ConfigurationValidationError.invalidDependency
            }
            switch dependency.kind {
            case .dockerContainer(let docker):
                guard isSimpleName(docker.containerName), isAbsoluteNormalized(docker.dockerSocketPath) else {
                    throw ConfigurationValidationError.invalidDependency
                }
                if let compose = docker.composeFilePath, !isAbsoluteNormalized(compose) {
                    throw ConfigurationValidationError.invalidDependency
                }
            case .macApplication(let app):
                guard isBundleIdentifier(app.bundleIdentifier) else {
                    throw ConfigurationValidationError.invalidDependency
                }
                if let path = app.applicationURL, !isAbsoluteNormalized(path) {
                    throw ConfigurationValidationError.invalidDependency
                }
            }
        }
    }

    private func validateNetworkRules(_ ruleSet: NetworkMountRuleSet) throws {
        for rule in ruleSet.rules {
            switch rule {
            case .nfsServiceReachable, .tunnelInterfaceActive:
                break
            case .routeAvailable(let cidr):
                guard isCanonicalCIDR(cidr) else { throw ConfigurationValidationError.invalidNetworkRule }
            case .interfaceType:
                break
            case .interfaceName(let name):
                guard isSimpleName(name) else { throw ConfigurationValidationError.invalidNetworkRule }
            }
        }
    }

    private func validateWakeOnLAN(_ settings: WakeOnLANSettings?) throws {
        guard let settings else { return }
        guard settings.port == WakeOnLAN.defaultPort, (try? WakeOnLAN.macBytes(settings.macAddress)) != nil else { throw ConfigurationValidationError.invalidWakeOnLAN }
        if let broadcastAddress = settings.broadcastAddress, !WakeOnLAN.isIPv4Address(broadcastAddress) {
            throw ConfigurationValidationError.invalidWakeOnLAN
        }
    }

    private func normalizeSource(_ source: String) -> String { source.precomposedStringWithCanonicalMapping.lowercased() }
    private func normalizePath(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.path }
    private func isAbsoluteNormalized(_ path: String) -> Bool {
        path.hasPrefix("/") && path == normalizePath(path) && !path.contains("\0")
    }
    private func isValidHost(_ host: String) -> Bool {
        !host.isEmpty && host.count <= 253 && !host.contains(where: { $0.isWhitespace || $0 == ":" || $0 == "/" })
    }
    private func isSimpleName(_ value: String) -> Bool {
        !value.isEmpty && value.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$"#, options: .regularExpression) != nil
    }
    private func isCanonicalCIDR(_ value: String) -> Bool {
        if isCanonicalIPv4CIDR(value) { return true }
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let prefix = Int(parts[1]), (0...128).contains(prefix) else { return false }
        var address = in6_addr()
        guard inet_pton(AF_INET6, String(parts[0]), &address) == 1 else { return false }
        let bytes = withUnsafeBytes(of: &address) { Array($0) }
        let wholeBytes = prefix / 8
        let remainder = prefix % 8
        guard bytes.dropFirst(wholeBytes + (remainder == 0 ? 0 : 1)).allSatisfy({ $0 == 0 }) else { return false }
        if remainder > 0 {
            let hostMask = UInt8((1 << (8 - remainder)) - 1)
            guard bytes[wholeBytes] & hostMask == 0 else { return false }
        }
        return true
    }

    private func isCanonicalIPv4CIDR(_ value: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let prefix = Int(parts[1]), (0...32).contains(prefix) else { return false }
        let octets = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return false }
        let values = octets.compactMap { Int($0) }
        guard values.count == 4, values.allSatisfy({ (0...255).contains($0) }), values.map(String.init).joined(separator: ".") == parts[0] else { return false }
        let address = values.reduce(0) { ($0 << 8) | $1 }
        let mask = prefix == 0 ? 0 : Int(UInt32.max << UInt32(32 - prefix))
        return address == address & mask
    }
    private func isBundleIdentifier(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$"#, options: .regularExpression) != nil
    }
    private func isSymlink(at path: String) -> Bool {
        guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isSymbolicLinkKey]) else { return false }
        return values.isSymbolicLink == true
    }
}
