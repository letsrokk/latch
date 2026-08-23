import Foundation
import Testing
@testable import LATCHShared

@Suite("Portable configuration")
struct PortableConfigurationTests {
    @Test func exportIsVersionedDeterministicAndContainsOnlyPortableConfiguration() throws {
        let server = NFSServerProfile(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, name: "NAS", hostname: "nas.local")
        let mount = MountDefinition(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, displayName: "Music", serverID: server.id, exportPath: "/music", mountPoint: "/Volumes/Media/Music")
        let configuration = LATCHConfiguration(servers: [server], mounts: [mount])

        let first = try PortableConfigurationCodec.export(configuration)
        let second = try PortableConfigurationCodec.export(configuration)
        let document = try JSONSerialization.jsonObject(with: first) as! [String: Any]

        #expect(first == second)
        #expect(document["formatVersion"] as? Int == 1)
        #expect(document["configurationSchemaVersion"] as? Int == 2)
        #expect(document["servers"] != nil)
        #expect(document["mounts"] != nil)
        #expect(document["statuses"] == nil)
        #expect(document["events"] == nil)
        #expect(document["credentials"] == nil)
        #expect(try PortableConfigurationCodec.decode(first).configuration == configuration)
    }

    @Test func previewClassifiesAdditionsSameIDUpdatesAndConflictsWithoutMutatingLocalConfiguration() throws {
        let localServer = server(id: "00000000-0000-0000-0000-000000000001", hostname: "local.example")
        let localMount = mount(id: "00000000-0000-0000-0000-000000000011", serverID: localServer.id, exportPath: "/local", mountPoint: "/Volumes/Media/Local")
        let updateServer = NFSServerProfile(id: localServer.id, name: "Renamed", hostname: "updated.example")
        let conflictServer = server(id: "00000000-0000-0000-0000-000000000002", hostname: "local.example")
        let updateMount = MountDefinition(id: localMount.id, displayName: "Renamed local", serverID: updateServer.id, exportPath: "/updated", mountPoint: "/Volumes/Media/Updated")
        let sourceConflict = mount(id: "00000000-0000-0000-0000-000000000012", serverID: conflictServer.id, exportPath: "/local", mountPoint: "/Volumes/Media/Remote")
        let mountPointConflict = mount(id: "00000000-0000-0000-0000-000000000013", serverID: conflictServer.id, exportPath: "/other", mountPoint: "/Volumes/Media/Local")
        let local = LATCHConfiguration(servers: [localServer], mounts: [localMount])
        let incoming = LATCHConfiguration(servers: [updateServer, conflictServer], mounts: [updateMount, sourceConflict, mountPointConflict])

        let preview = try PortableConfigurationImporter.preview(try PortableConfigurationCodec.export(incoming), current: local, liveMounts: [])

        #expect(preview.item(kind: .server, id: localServer.id)?.disposition == .update)
        #expect(preview.item(kind: .server, id: conflictServer.id)?.conflict == .hostname)
        #expect(preview.item(kind: .mount, id: localMount.id)?.disposition == .update)
        #expect(preview.item(kind: .mount, id: sourceConflict.id)?.conflict == .source)
        #expect(preview.item(kind: .mount, id: mountPointConflict.id)?.conflict == .mountPoint)
        #expect(local == LATCHConfiguration(servers: [localServer], mounts: [localMount]))
    }

    @Test func applyMergesApprovedEntriesWithoutDeletingUnmentionedLocals() throws {
        let localServer = server(id: "00000000-0000-0000-0000-000000000001", hostname: "local.example")
        let localMount = mount(id: "00000000-0000-0000-0000-000000000011", serverID: localServer.id, exportPath: "/local", mountPoint: "/Volumes/Media/Local")
        let importedServer = server(id: "00000000-0000-0000-0000-000000000002", hostname: "remote.example")
        let importedMount = mount(id: "00000000-0000-0000-0000-000000000012", serverID: importedServer.id, exportPath: "/remote", mountPoint: "/Volumes/Media/Remote")
        let local = LATCHConfiguration(servers: [localServer], mounts: [localMount])
        let data = try PortableConfigurationCodec.export(.init(servers: [importedServer], mounts: [importedMount]))

        let merged = try PortableConfigurationImporter.apply(data, approvedServerIDs: [importedServer.id], approvedMountIDs: [importedMount.id], current: local, liveMounts: [])

        #expect(merged.servers.contains(localServer))
        #expect(merged.mounts.contains(localMount))
        #expect(merged.servers.contains(importedServer))
        #expect(merged.mounts.contains(importedMount))
    }

    @Test func applyRequiresSelectedMountDependenciesAndRevalidatesLiveMounts() throws {
        let importedServer = server(id: "00000000-0000-0000-0000-000000000002", hostname: "remote.example")
        let importedMount = mount(id: "00000000-0000-0000-0000-000000000012", serverID: importedServer.id, exportPath: "/remote", mountPoint: "/Volumes/Media/Remote")
        let data = try PortableConfigurationCodec.export(.init(servers: [importedServer], mounts: [importedMount]))

        #expect(throws: PortableConfigurationError.missingApprovedServerReference) {
            try PortableConfigurationImporter.apply(data, approvedServerIDs: [], approvedMountIDs: [importedMount.id], current: .init(), liveMounts: [])
        }
        #expect(throws: PortableConfigurationError.itemIsConflicted) {
            try PortableConfigurationImporter.apply(data, approvedServerIDs: [importedServer.id], approvedMountIDs: [importedMount.id], current: .init(), liveMounts: [.init(source: "other:/x", mountPoint: "/Volumes/Media/Remote", fileSystemType: "nfs", options: [])])
        }
    }

    @Test func importRejectsUnsupportedVersionInvalidFieldsAndOversizedPayload() throws {
        let server = NFSServerProfile(name: "NAS", hostname: "nas.local", networkMountRules: .init(rules: [.routeAvailable("10.1.2.3/8")]))
        var mount = MountDefinition(displayName: "Music", serverID: server.id, exportPath: "/music", mountPoint: "/Volumes/Media/Music")
        mount.postMountActions = [.openRelativePath("../../outside")]
        let unsafe = PortableConfigurationDocument(formatVersion: 1, configurationSchemaVersion: 2, servers: [server], mounts: [mount])

        #expect(throws: ConfigurationValidationError.invalidNetworkRule) {
            try PortableConfigurationImporter.preview(try JSONEncoder().encode(unsafe), current: .init(), liveMounts: [])
        }
        let unsupported = PortableConfigurationDocument(formatVersion: 99, configurationSchemaVersion: 2, servers: [], mounts: [])
        #expect(throws: PortableConfigurationError.unsupportedFormatVersion) {
            try PortableConfigurationCodec.decode(try JSONEncoder().encode(unsupported))
        }
        #expect(throws: PortableConfigurationError.oversized) {
            try PortableConfigurationCodec.decode(Data(repeating: 0, count: PortableConfigurationCodec.maximumBytes + 1))
        }
    }

    @Test func importRejectsDuplicateIdentifiersInvalidWakeOnLANAndUnsafeActions() throws {
        let serverID = UUID()
        let first = NFSServerProfile(id: serverID, name: "NAS", hostname: "nas.local")
        let duplicate = NFSServerProfile(id: serverID, name: "Duplicate", hostname: "other.local")
        let duplicateServers = PortableConfigurationDocument(servers: [first, duplicate], mounts: [])
        #expect(throws: ConfigurationValidationError.duplicateServerID) {
            try PortableConfigurationImporter.preview(try JSONEncoder().encode(duplicateServers), current: .init(), liveMounts: [])
        }

        let wakeServer = NFSServerProfile(name: "NAS", hostname: "nas.local", wakeOnLAN: .init(macAddress: "not-a-mac"))
        #expect(throws: ConfigurationValidationError.invalidWakeOnLAN) {
            try PortableConfigurationImporter.preview(try PortableConfigurationCodec.export(.init(servers: [wakeServer])), current: .init(), liveMounts: [])
        }

        var unsafeMount = MountDefinition(displayName: "Music", serverID: first.id, exportPath: "/music", mountPoint: "/Volumes/Media/Music")
        unsafeMount.postMountActions = [.openRelativePath("../../outside")]
        #expect(throws: ConfigurationValidationError.invalidPostMountAction) {
            try PortableConfigurationImporter.preview(try PortableConfigurationCodec.export(.init(servers: [first], mounts: [unsafeMount])), current: .init(), liveMounts: [])
        }
    }

    @Test func importRejectsRuntimeFieldsAndAppliesSameIDUpdates() throws {
        let server = server(id: "00000000-0000-0000-0000-000000000001", hostname: "nas.local")
        let oldMount = mount(id: "00000000-0000-0000-0000-000000000011", serverID: server.id, exportPath: "/old", mountPoint: "/Volumes/Media/Old")
        let newMount = mount(id: "00000000-0000-0000-0000-000000000011", serverID: server.id, exportPath: "/new", mountPoint: "/Volumes/Media/New")
        let data = try PortableConfigurationCodec.export(.init(servers: [server], mounts: [newMount]))
        let updated = try PortableConfigurationImporter.apply(data, approvedServerIDs: [], approvedMountIDs: [newMount.id], current: .init(servers: [server], mounts: [oldMount]), liveMounts: [])

        #expect(updated.mounts == [newMount])
        #expect(throws: PortableConfigurationError.malformed) {
            try PortableConfigurationCodec.decode(Data("{\"formatVersion\":1,\"configurationSchemaVersion\":2,\"servers\":[],\"mounts\":[],\"statuses\":[]}".utf8))
        }
    }

    @Test func portablePayloadAtTheSafeBoundaryFitsThePreviewXPCRequest() throws {
        let prefix = "{\"formatVersion\":1,\"configurationSchemaVersion\":2,\"servers\":[],\"mounts\":[]}"
        let padded = prefix + String(repeating: " ", count: PortableConfigurationCodec.maximumBytes - prefix.utf8.count)
        let payload = Data(padded.utf8)

        #expect(try PortableConfigurationCodec.decode(payload).servers.isEmpty)
        #expect(try XPCCodec.encodeRequest(.previewPortableConfiguration(payload)).count <= XPCCodec.maximumMessageBytes)
    }

    @Test func importRejectsUnknownNestedFields() throws {
        let server = NFSServerProfile(name: "NAS", hostname: "nas.local", networkMountRules: .init(rules: [.nfsServiceReachable]), wakeOnLAN: .init(macAddress: "00:11:22:33:44:55"))
        let mount = MountDefinition(displayName: "Music", serverID: server.id, exportPath: "/music", mountPoint: "/Volumes/Media/Music")
        let data = try PortableConfigurationCodec.export(.init(servers: [server], mounts: [mount]))
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var servers = try #require(object["servers"] as? [[String: Any]])
        servers[0]["credential"] = "do not import"
        object["servers"] = servers

        #expect(throws: PortableConfigurationError.malformed) {
            try PortableConfigurationCodec.decode(try JSONSerialization.data(withJSONObject: object))
        }
    }

    @Test func strictDecoderRejectsUnknownKeysAtEveryNestedPortableBoundary() throws {
        let server = NFSServerProfile(name: "NAS", hostname: "nas.local", networkMountRules: .init(rules: [.nfsServiceReachable]), wakeOnLAN: .init(macAddress: "00:11:22:33:44:55"))
        let dependencies: [RecoveryDependency] = [
            .init(kind: .dockerContainer(.init(containerName: "media", dockerSocketPath: "/Users/test/.docker.sock", composeFilePath: nil))),
        ]
        let mount = MountDefinition(
            displayName: "Music", serverID: server.id, exportPath: "/music", mountPoint: "/Volumes/Media/Music",
            recoveryDependencies: dependencies,
            postMountActions: [.revealInFinder, .openApplication(bundleIdentifier: "com.apple.finder", applicationURL: nil), .openRelativePath("Music")]
        )
        let data = try PortableConfigurationCodec.export(.init(servers: [server], mounts: [mount]))
        #expect(try PortableConfigurationCodec.decode(data).mounts == [mount])

        for location in NestedUnknownFieldLocation.allCases {
            var document = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            location.insertUnknownField(into: &document)
            #expect(throws: PortableConfigurationError.malformed) {
                try PortableConfigurationCodec.decode(try JSONSerialization.data(withJSONObject: document))
            }
        }
    }

    @Test func previewDisablesMountWhoseImportedServerIsConflicted() throws {
        let localServer = server(id: "00000000-0000-0000-0000-000000000001", hostname: "nas.local")
        let importedServer = server(id: "00000000-0000-0000-0000-000000000002", hostname: "nas.local")
        let importedMount = mount(id: "00000000-0000-0000-0000-000000000011", serverID: importedServer.id, exportPath: "/music", mountPoint: "/Volumes/Media/Music")

        let preview = try PortableConfigurationImporter.preview(try PortableConfigurationCodec.export(.init(servers: [importedServer], mounts: [importedMount])), current: .init(servers: [localServer]), liveMounts: [])

        #expect(preview.item(kind: .server, id: importedServer.id)?.conflict == .hostname)
        #expect(preview.item(kind: .mount, id: importedMount.id)?.conflict == .serverDependency)
    }

    @Test func persistenceTransactionLeavesLiveConfigurationUnchangedWhenSavingFails() {
        let original = LATCHConfiguration()
        let candidate = LATCHConfiguration(servers: [.init(name: "NAS", hostname: "nas.local")])
        var current = original

        #expect(throws: TestPersistenceError.failed) {
            try ConfigurationPersistenceTransaction.commit(candidate, current: &current) { _ in throw TestPersistenceError.failed }
        }
        #expect(current == original)
    }

    private func server(id: String, hostname: String) -> NFSServerProfile {
        .init(id: UUID(uuidString: id)!, name: hostname, hostname: hostname)
    }

    private func mount(id: String, serverID: UUID, exportPath: String, mountPoint: String) -> MountDefinition {
        .init(id: UUID(uuidString: id)!, displayName: id, serverID: serverID, exportPath: exportPath, mountPoint: mountPoint)
    }
}

private enum TestPersistenceError: Error { case failed }

private enum NestedUnknownFieldLocation: CaseIterable {
    case server, rules, rule, wakeOnLAN, mount, options, dependency, dependencyKind, action, actionPayload

    func insertUnknownField(into document: inout [String: Any]) {
        var servers = document["servers"] as! [[String: Any]]
        var mounts = document["mounts"] as! [[String: Any]]
        switch self {
        case .server:
            servers[0]["credential"] = true
        case .rules:
            var rules = servers[0]["networkMountRules"] as! [String: Any]
            rules["runtime"] = true
            servers[0]["networkMountRules"] = rules
        case .rule:
            var rules = servers[0]["networkMountRules"] as! [String: Any]
            var entries = rules["rules"] as! [[String: Any]]
            entries[0]["credential"] = true
            rules["rules"] = entries
            servers[0]["networkMountRules"] = rules
        case .wakeOnLAN:
            var wake = servers[0]["wakeOnLAN"] as! [String: Any]
            wake["authToken"] = true
            servers[0]["wakeOnLAN"] = wake
        case .mount:
            mounts[0]["status"] = true
        case .options:
            var options = mounts[0]["mountOptions"] as! [String: Any]
            options["logs"] = true
            mounts[0]["mountOptions"] = options
        case .dependency:
            var dependencies = mounts[0]["recoveryDependencies"] as! [[String: Any]]
            dependencies[0]["credential"] = true
            mounts[0]["recoveryDependencies"] = dependencies
        case .dependencyKind:
            var dependencies = mounts[0]["recoveryDependencies"] as! [[String: Any]]
            var kind = dependencies[0]["kind"] as! [String: Any]
            var docker = kind["dockerContainer"] as! [String: Any]
            var details = docker["_0"] as! [String: Any]
            details["runtime"] = true
            docker["_0"] = details
            kind["dockerContainer"] = docker
            dependencies[0]["kind"] = kind
            mounts[0]["recoveryDependencies"] = dependencies
        case .action:
            var actions = mounts[0]["postMountActions"] as! [[String: Any]]
            actions[0]["runtime"] = true
            mounts[0]["postMountActions"] = actions
        case .actionPayload:
            var actions = mounts[0]["postMountActions"] as! [[String: Any]]
            var path = actions[2]["openRelativePath"] as! [String: Any]
            path["credential"] = true
            actions[2]["openRelativePath"] = path
            mounts[0]["postMountActions"] = actions
        }
        document["servers"] = servers
        document["mounts"] = mounts
    }
}
