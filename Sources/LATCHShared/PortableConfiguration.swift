import Foundation

/// A deliberately narrow, user-portable representation of saved configuration.
/// Runtime state, service authorization, diagnostics, and credentials are not part
/// of this format.
public struct PortableConfigurationDocument: Codable, Sendable, Equatable {
    public var formatVersion: Int
    public var configurationSchemaVersion: Int
    public var servers: [NFSServerProfile]
    public var mounts: [MountDefinition]

    public init(formatVersion: Int = PortableConfigurationCodec.currentFormatVersion, configurationSchemaVersion: Int = 2, servers: [NFSServerProfile], mounts: [MountDefinition]) {
        self.formatVersion = formatVersion
        self.configurationSchemaVersion = configurationSchemaVersion
        self.servers = servers
        self.mounts = mounts
    }

    public var configuration: LATCHConfiguration {
        .init(schemaVersion: configurationSchemaVersion, servers: servers, mounts: mounts)
    }
}

public enum PortableConfigurationError: Error, Sendable, Equatable, LocalizedError {
    case oversized
    case malformed
    case unsupportedFormatVersion
    case unsupportedConfigurationSchema
    case missingApprovedServerReference
    case itemIsConflicted
    case unknownApprovedItem

    public var errorDescription: String? {
        switch self {
        case .oversized: "The configuration file is too large to fit safely inside LATCH’s 1 MiB import transport limit."
        case .malformed: "The configuration file is malformed or contains unsupported data."
        case .unsupportedFormatVersion: "This configuration file uses an unsupported portable format version."
        case .unsupportedConfigurationSchema: "This configuration file uses an unsupported configuration schema."
        case .missingApprovedServerReference: "Each imported mount needs its referenced server to be selected or already configured."
        case .itemIsConflicted: "Conflicting imported items cannot be applied."
        case .unknownApprovedItem: "The approved import selection does not match the configuration file."
        }
    }
}

public enum PortableConfigurationCodec {
    public static let currentFormatVersion = 1
    /// Leaves room for JSON's Base64 representation and up to 1,000 selected IDs
    /// inside the 1 MiB XPC envelope used by preview and apply.
    public static let maximumBytes = 740_000
    public static let maximumItems = 1_000

    public static func export(_ configuration: LATCHConfiguration) throws -> Data {
        guard configuration.schemaVersion == 2 else { throw PortableConfigurationError.unsupportedConfigurationSchema }
        let document = PortableConfigurationDocument(
            servers: configuration.servers.sorted { $0.id.uuidString < $1.id.uuidString },
            mounts: configuration.mounts.sorted { $0.id.uuidString < $1.id.uuidString }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        try validateTransport(data, document: document)
        return data
    }

    public static func decode(_ data: Data) throws -> PortableConfigurationDocument {
        guard data.count <= maximumBytes else { throw PortableConfigurationError.oversized }
        try StrictPortableConfigurationJSON.validate(data)
        let document: PortableConfigurationDocument
        do { document = try JSONDecoder().decode(PortableConfigurationDocument.self, from: data) }
        catch { throw PortableConfigurationError.malformed }
        guard document.formatVersion == currentFormatVersion else { throw PortableConfigurationError.unsupportedFormatVersion }
        guard document.configurationSchemaVersion == 2 else { throw PortableConfigurationError.unsupportedConfigurationSchema }
        try validateTransport(data, document: document)
        return document
    }

    private static func validateTransport(_ data: Data, document: PortableConfigurationDocument) throws {
        guard document.servers.count + document.mounts.count <= maximumItems,
              (try? XPCCodec.encodeRequest(.previewPortableConfiguration(data))) != nil,
              (try? XPCCodec.encodeRequest(.applyPortableConfiguration(data, approvedServerIDs: document.servers.map(\.id), approvedMountIDs: document.mounts.map(\.id)))) != nil,
              (try? XPCCodec.encodeResponse(.portableConfiguration(data), requestID: UUID())) != nil else {
            throw PortableConfigurationError.oversized
        }
    }
}

public enum PortableImportItemKind: String, Codable, Sendable, Equatable {
    case server
    case mount
}

public enum PortableImportDisposition: String, Codable, Sendable, Equatable {
    case addition
    case update
    case conflict
}

public enum PortableImportConflict: String, Codable, Sendable, Equatable {
    case hostname
    case source
    case mountPoint
    case liveSource
    case liveMountPoint
    case serverDependency
}

public struct PortableImportItem: Codable, Sendable, Equatable, Identifiable {
    public var kind: PortableImportItemKind
    public var id: UUID
    public var title: String
    public var serverID: UUID?
    public var disposition: PortableImportDisposition
    public var conflict: PortableImportConflict?

    public init(kind: PortableImportItemKind, id: UUID, title: String, serverID: UUID? = nil, disposition: PortableImportDisposition, conflict: PortableImportConflict? = nil) {
        self.kind = kind
        self.id = id
        self.title = title
        self.serverID = serverID
        self.disposition = disposition
        self.conflict = conflict
    }

    public var isApprovable: Bool { disposition != .conflict }

    public var conflictExplanation: String? {
        switch conflict {
        case .hostname: "Another configured server already uses this hostname."
        case .source: "Another configured mount already uses this NFS source."
        case .mountPoint: "Another configured mount already uses this mount point."
        case .liveSource: "A live external mount already uses this NFS source."
        case .liveMountPoint: "A live external mount already uses this mount point."
        case .serverDependency: "The imported server for this mount conflicts with local configuration."
        case nil: nil
        }
    }
}

public struct PortableImportPreview: Codable, Sendable, Equatable {
    public var items: [PortableImportItem]

    public init(items: [PortableImportItem]) { self.items = items }

    public func item(kind: PortableImportItemKind, id: UUID) -> PortableImportItem? {
        items.first { $0.kind == kind && $0.id == id }
    }
}

public enum PortableConfigurationImporter {
    public static func preview(_ data: Data, current: LATCHConfiguration, liveMounts: [ExternalMountSnapshot]) throws -> PortableImportPreview {
        let incoming = try validatedDocument(data).configuration
        let currentServersByID = Dictionary(uniqueKeysWithValues: current.servers.map { ($0.id, $0) })
        let currentMountsByID = Dictionary(uniqueKeysWithValues: current.mounts.map { ($0.id, $0) })
        let localServerIDsByHostname = Dictionary(grouping: current.servers, by: { normalizedHostname($0.hostname) })
        let localMountsBySource = Dictionary(grouping: resolvedMounts(current), by: { normalizedSource($0.source) })
        let localMountsByPoint = Dictionary(grouping: resolvedMounts(current), by: { normalizedPath($0.mountPoint) })
        let liveSources = Set(liveMounts.map { normalizedSource($0.source) })
        let liveMountPoints = Set(liveMounts.map { normalizedPath($0.mountPoint) })

        var items = incoming.servers.map { server -> PortableImportItem in
            if currentServersByID[server.id] != nil {
                return .init(kind: .server, id: server.id, title: server.name, disposition: .update)
            }
            if localServerIDsByHostname[normalizedHostname(server.hostname)]?.isEmpty == false {
                return .init(kind: .server, id: server.id, title: server.name, disposition: .conflict, conflict: .hostname)
            }
            return .init(kind: .server, id: server.id, title: server.name, disposition: .addition)
        }

        let serverItemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        for mount in incoming.mounts {
            guard let server = incoming.servers.first(where: { $0.id == mount.serverID }) else { continue }
            let source = normalizedSource(mount.resolved(using: server).source)
            let mountPoint = normalizedPath(mount.mountPoint)
            let sourceConflict = localMountsBySource[source]?.contains { $0.id != mount.id } == true
            let mountPointConflict = localMountsByPoint[mountPoint]?.contains { $0.id != mount.id } == true
            let item: PortableImportItem
            if sourceConflict {
                item = .init(kind: .mount, id: mount.id, title: mount.displayName, serverID: mount.serverID, disposition: .conflict, conflict: .source)
            } else if mountPointConflict {
                item = .init(kind: .mount, id: mount.id, title: mount.displayName, serverID: mount.serverID, disposition: .conflict, conflict: .mountPoint)
            } else if liveSources.contains(source) {
                item = .init(kind: .mount, id: mount.id, title: mount.displayName, serverID: mount.serverID, disposition: .conflict, conflict: .liveSource)
            } else if liveMountPoints.contains(mountPoint) {
                item = .init(kind: .mount, id: mount.id, title: mount.displayName, serverID: mount.serverID, disposition: .conflict, conflict: .liveMountPoint)
            } else if serverItemsByID[mount.serverID]?.isApprovable == false {
                item = .init(kind: .mount, id: mount.id, title: mount.displayName, serverID: mount.serverID, disposition: .conflict, conflict: .serverDependency)
            } else if currentMountsByID[mount.id] != nil {
                item = .init(kind: .mount, id: mount.id, title: mount.displayName, serverID: mount.serverID, disposition: .update)
            } else {
                item = .init(kind: .mount, id: mount.id, title: mount.displayName, serverID: mount.serverID, disposition: .addition)
            }
            items.append(item)
        }
        return .init(items: items.sorted { lhs, rhs in
            if lhs.kind == rhs.kind { return lhs.id.uuidString < rhs.id.uuidString }
            return lhs.kind.rawValue < rhs.kind.rawValue
        })
    }

    public static func apply(
        _ data: Data,
        approvedServerIDs: Set<UUID>,
        approvedMountIDs: Set<UUID>,
        current: LATCHConfiguration,
        liveMounts: [ExternalMountSnapshot]
    ) throws -> LATCHConfiguration {
        let document = try validatedDocument(data)
        let incoming = document.configuration
        let preview = try preview(data, current: current, liveMounts: liveMounts)
        try validateSelection(approvedServerIDs, kind: .server, preview: preview)
        try validateSelection(approvedMountIDs, kind: .mount, preview: preview)

        var candidate = current
        for server in incoming.servers where approvedServerIDs.contains(server.id) {
            replace(server, in: &candidate.servers, id: \ .id)
        }
        for mount in incoming.mounts where approvedMountIDs.contains(mount.id) {
            guard candidate.servers.contains(where: { $0.id == mount.serverID }) else {
                throw PortableConfigurationError.missingApprovedServerReference
            }
            replace(mount, in: &candidate.mounts, id: \ .id)
        }
        try ConfigurationValidator().validate(candidate, liveMounts: liveMounts)
        return candidate
    }

    private static func validatedDocument(_ data: Data) throws -> PortableConfigurationDocument {
        let document = try PortableConfigurationCodec.decode(data)
        try ConfigurationValidator().validate(document.configuration, liveMounts: [])
        return document
    }

    private static func validateSelection(_ ids: Set<UUID>, kind: PortableImportItemKind, preview: PortableImportPreview) throws {
        for id in ids {
            guard let item = preview.item(kind: kind, id: id) else { throw PortableConfigurationError.unknownApprovedItem }
            guard item.isApprovable else { throw PortableConfigurationError.itemIsConflicted }
        }
    }

    private static func replace<T>(_ value: T, in values: inout [T], id: KeyPath<T, UUID>) {
        if let index = values.firstIndex(where: { $0[keyPath: id] == value[keyPath: id] }) {
            values[index] = value
        } else {
            values.append(value)
        }
    }

    private static func resolvedMounts(_ configuration: LATCHConfiguration) -> [MountDefinition] {
        configuration.mounts.compactMap { mount in
            configuration.servers.first(where: { $0.id == mount.serverID }).map(mount.resolved(using:))
        }
    }

    private static func normalizedHostname(_ value: String) -> String { value.precomposedStringWithCanonicalMapping.lowercased() }
    private static func normalizedSource(_ value: String) -> String { value.precomposedStringWithCanonicalMapping.lowercased() }
    private static func normalizedPath(_ value: String) -> String { URL(fileURLWithPath: value).standardizedFileURL.path }
}

/// Makes persistence ordering explicit: live configuration changes only after a
/// durable save succeeds.
public enum ConfigurationPersistenceTransaction {
    public static func commit(
        _ candidate: LATCHConfiguration,
        current: inout LATCHConfiguration,
        persist: (LATCHConfiguration) throws -> Void
    ) throws {
        try persist(candidate)
        current = candidate
    }
}

private enum StrictPortableConfigurationJSON {
    static func validate(_ data: Data) throws {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { throw PortableConfigurationError.malformed }
        let document = try object(root, allowed: ["formatVersion", "configurationSchemaVersion", "servers", "mounts"])
        for server in try array(document["servers"]) { try validateServer(server) }
        for mount in try array(document["mounts"]) { try validateMount(mount) }
    }

    private static func validateServer(_ value: Any) throws {
        let server = try object(value, allowed: ["id", "name", "hostname", "networkMountRules", "wakeOnLAN"])
        if let rules = server["networkMountRules"] { try validateRules(rules) }
        if let wakeOnLAN = server["wakeOnLAN"], !(wakeOnLAN is NSNull) {
            _ = try object(wakeOnLAN, allowed: ["macAddress", "broadcastAddress", "port"])
        }
    }

    private static func validateRules(_ value: Any) throws {
        let rules = try object(value, allowed: ["combinator", "rules"])
        for rule in try array(rules["rules"]) {
            _ = try object(rule, allowed: ["kind", "value"])
        }
    }

    private static func validateMount(_ value: Any) throws {
        let mount = try object(value, allowed: [
            "id", "displayName", "serverID", "exportPath", "mountPoint", "mountOptions", "enabled",
            "probeIntervalSeconds", "probeTimeoutSeconds", "recoveryCooldownSeconds", "recoveryDependencies", "postMountActions",
        ])
        if let options = mount["mountOptions"] {
            _ = try object(options, allowed: [
                "readOnly", "reservedPort", "requireTCP", "interruptible", "disableLocking", "hideFromFinder",
                "noExecutableFiles", "ignoreSetuid", "ignoreDeviceFiles",
            ])
        }
        for dependency in try array(mount["recoveryDependencies"]) { try validateDependency(dependency) }
        for action in try array(mount["postMountActions"]) { try validateAction(action) }
    }

    private static func validateDependency(_ value: Any) throws {
        let dependency = try object(value, allowed: ["id", "enabled", "stopTimeoutSeconds", "kind"])
        let kind = try object(dependency["kind"], allowed: ["dockerContainer", "macApplication"])
        guard kind.count == 1 else { throw PortableConfigurationError.malformed }
        if let docker = kind["dockerContainer"] {
            _ = try associatedObject(docker, allowed: ["containerName", "dockerSocketPath", "composeFilePath"])
        }
        if let application = kind["macApplication"] {
            _ = try associatedObject(application, allowed: ["bundleIdentifier", "applicationURL", "forceQuitAfterTimeout"])
        }
    }

    private static func validateAction(_ value: Any) throws {
        let action = try object(value, allowed: ["revealInFinder", "openApplication", "openRelativePath"])
        guard action.count == 1 else { throw PortableConfigurationError.malformed }
        if let reveal = action["revealInFinder"] {
            _ = try object(reveal, allowed: [])
        }
        if let application = action["openApplication"] {
            _ = try object(application, allowed: ["bundleIdentifier", "applicationURL"])
        }
        if let path = action["openRelativePath"] {
            let payload = try object(path, allowed: ["_0"])
            guard payload.count == 1, payload["_0"] != nil else { throw PortableConfigurationError.malformed }
        }
    }

    private static func associatedObject(_ value: Any, allowed: Set<String>) throws -> [String: Any] {
        let outer = try object(value, allowed: ["_0"])
        guard let payload = outer["_0"] else { throw PortableConfigurationError.malformed }
        return try object(payload, allowed: allowed)
    }

    private static func object(_ value: Any?, allowed: Set<String>) throws -> [String: Any] {
        guard let dictionary = value as? [String: Any], Set(dictionary.keys).isSubset(of: allowed) else {
            throw PortableConfigurationError.malformed
        }
        return dictionary
    }

    private static func array(_ value: Any?) throws -> [Any] {
        guard let values = value as? [Any] else { throw PortableConfigurationError.malformed }
        return values
    }
}
