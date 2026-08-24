import Foundation

public enum DiagnosticExporter {
    public static func make(
        configuration: LATCHConfiguration,
        statuses: [MountStatus],
        events: [LATCHEvent],
        externalMounts: [ExternalMountSnapshot],
        serviceStatus: ServiceStatusSnapshot,
        generatedAt: Date = Date()
    ) throws -> Data {
        let dateFormatter = ISO8601DateFormatter()
        let persistenceHealth: [String: Any] = [
            "isDegraded": serviceStatus.persistenceHealth.isDegraded,
            "lastFailureAt": serviceStatus.persistenceHealth.lastFailureAt.flatMap { dateFormatter.string(from: $0) } ?? NSNull(),
            "lastSuccessfulWriteAt": serviceStatus.persistenceHealth.lastSuccessfulWriteAt.flatMap { dateFormatter.string(from: $0) } ?? NSNull(),
            "lastErrorDomain": serviceStatus.persistenceHealth.lastErrorDomain ?? NSNull(),
            "lastErrorCode": serviceStatus.persistenceHealth.lastErrorCode ?? NSNull()
        ]
        let sensitive = configuration.mounts.flatMap { definition in
            [definition.host, definition.exportPath, definition.mountPoint] + definition.recoveryDependencies.flatMap { dependency -> [String] in
                switch dependency.kind {
                case .dockerContainer(let value): [value.dockerSocketPath, value.composeFilePath].compactMap { $0 }
                case .macApplication(let value): [value.applicationURL].compactMap { $0 }
                }
            }
        }
        func clean(_ text: String) -> String {
            sensitive.reduce(text) { partial, value in partial.replacingOccurrences(of: value, with: value.hasPrefix("/") ? "<redacted-path>" : "<redacted-host>") }
        }
        func redactedPath(_ path: String) -> String { "<redacted-path>/\(URL(fileURLWithPath: path).lastPathComponent)" }

        let mounts: [[String: Any]] = configuration.mounts.map { definition in
            [
                "id": definition.id.uuidString,
                "displayName": definition.displayName,
                "host": "<redacted-host>",
                "exportPath": "<redacted-export-path>",
                "mountPoint": redactedPath(definition.mountPoint),
                "enabled": definition.enabled,
                "options": definition.mountOptions.encoded,
                "dependencyCount": definition.recoveryDependencies.count,
                "dependencies": definition.recoveryDependencies.map { dependencyDescription($0) },
            ]
        }
        let statusValues: [[String: Any]] = statuses.map {
            ["definitionID": $0.definitionID.uuidString, "state": $0.state.rawValue, "detail": clean($0.detail), "errorCode": $0.errorCode.rawValue]
        }
        let eventValues: [[String: Any]] = events.map {
            ["date": ISO8601DateFormatter().string(from: $0.date), "state": $0.state?.rawValue ?? "", "code": $0.code.rawValue, "detail": clean($0.detail)]
        }
        let externalValues: [[String: Any]] = externalMounts.map {
            ["source": redactSource($0.source), "mountPoint": redactedPath($0.mountPoint), "fileSystemType": $0.fileSystemType, "options": $0.options]
        }
        let document: [String: Any] = [
            "schemaVersion": 1,
            "generatedAt": dateFormatter.string(from: generatedAt),
            "persistenceHealth": persistenceHealth,
            "mounts": mounts,
            "statuses": statusValues,
            "events": eventValues,
            "externalMounts": externalValues,
        ]
        return try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
    }

    private static func dependencyDescription(_ dependency: RecoveryDependency) -> [String: Any] {
        var value: [String: Any] = ["id": dependency.id.uuidString, "enabled": dependency.enabled, "stopTimeoutSeconds": dependency.stopTimeoutSeconds]
        switch dependency.kind {
        case .dockerContainer(let docker):
            value["type"] = "dockerContainer"
            value["containerName"] = docker.containerName
            value["dockerSocketPath"] = "<redacted-path>"
            value["hasComposeFile"] = docker.composeFilePath != nil
        case .macApplication(let app):
            value["type"] = "macApplication"
            value["bundleIdentifier"] = app.bundleIdentifier
            value["applicationURL"] = app.applicationURL == nil ? NSNull() : "<redacted-path>"
            value["forceQuitAfterTimeout"] = app.forceQuitAfterTimeout
        }
        return value
    }

    private static func redactSource(_ source: String) -> String {
        source.contains(":") ? "<redacted-host>:<redacted-export-path>" : "<redacted-host>"
    }
}
