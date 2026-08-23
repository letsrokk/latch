import Foundation

public struct MountDraft: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var displayName: String
    public var serverID: UUID
    public var exportPath: String
    public var mountPoint: String
    public var mountOptions: NFSOptions
    public var enabled: Bool
    public var probeIntervalSeconds: Int
    public var probeTimeoutSeconds: Int
    public var recoveryCooldownSeconds: Int
    public var recoveryDependencies: [RecoveryDependency]
    public var postMountActions: [PostMountAction]

    public static var new: MountDraft {
        .init(
            id: UUID(),
            displayName: "",
            serverID: UUID(),
            exportPath: "/",
            mountPoint: FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path,
            mountOptions: .recommended,
            enabled: true,
            probeIntervalSeconds: 60,
            probeTimeoutSeconds: 5,
            recoveryCooldownSeconds: 600,
            recoveryDependencies: [],
            postMountActions: []
        )
    }

    public init(editing definition: MountDefinition) {
        id = definition.id
        displayName = definition.displayName
        serverID = definition.serverID
        exportPath = definition.exportPath
        mountPoint = definition.mountPoint
        mountOptions = definition.mountOptions
        enabled = definition.enabled
        probeIntervalSeconds = definition.probeIntervalSeconds
        probeTimeoutSeconds = definition.probeTimeoutSeconds
        recoveryCooldownSeconds = definition.recoveryCooldownSeconds
        recoveryDependencies = definition.recoveryDependencies
        postMountActions = definition.postMountActions
    }

    public func definition() -> MountDefinition {
        MountDefinition(
            id: id,
            displayName: displayName,
            serverID: serverID,
            exportPath: exportPath,
            mountPoint: mountPoint,
            mountOptions: mountOptions,
            enabled: enabled,
            probeIntervalSeconds: probeIntervalSeconds,
            probeTimeoutSeconds: probeTimeoutSeconds,
            recoveryCooldownSeconds: recoveryCooldownSeconds,
            recoveryDependencies: recoveryDependencies,
            postMountActions: postMountActions
        )
    }

    private init(id: UUID, displayName: String, serverID: UUID, exportPath: String, mountPoint: String, mountOptions: NFSOptions, enabled: Bool, probeIntervalSeconds: Int, probeTimeoutSeconds: Int, recoveryCooldownSeconds: Int, recoveryDependencies: [RecoveryDependency], postMountActions: [PostMountAction]) {
        self.id = id
        self.displayName = displayName
        self.serverID = serverID
        self.exportPath = exportPath
        self.mountPoint = mountPoint
        self.mountOptions = mountOptions
        self.enabled = enabled
        self.probeIntervalSeconds = probeIntervalSeconds
        self.probeTimeoutSeconds = probeTimeoutSeconds
        self.recoveryCooldownSeconds = recoveryCooldownSeconds
        self.recoveryDependencies = recoveryDependencies
        self.postMountActions = postMountActions
    }
}

/// Prefills a new configuration from an observed external mount. It does not adopt or alter that mount.
public struct ExternalMountConfigurationTemplate: Sendable, Equatable {
    public var server: NFSServerProfile
    public var draft: MountDraft

    public init?(snapshot: ExternalMountSnapshot) {
        guard let separator = snapshot.source.firstIndex(of: ":") else { return nil }
        let host = String(snapshot.source[..<separator])
        let exportPath = String(snapshot.source[snapshot.source.index(after: separator)...])
        guard !host.isEmpty, exportPath.hasPrefix("/") else { return nil }
        server = .init(name: host, hostname: host)
        var draft = MountDraft.new
        draft.displayName = URL(fileURLWithPath: snapshot.mountPoint).lastPathComponent
        draft.serverID = server.id
        draft.exportPath = exportPath
        draft.mountPoint = snapshot.mountPoint
        self.draft = draft
    }
}
