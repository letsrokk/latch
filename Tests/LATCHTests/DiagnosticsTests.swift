import Foundation
import Testing
@testable import LATCHShared

@Suite("Redacted diagnostics")
struct DiagnosticsTests {
    @Test func exportOmitsPrivateLocalPathsAndDependencyHints() throws {
        let dependency = RecoveryDependency(kind: .dockerContainer(.init(
            containerName: "radarr",
            dockerSocketPath: "/Users/private/.docker/run/docker.sock",
            composeFilePath: "/Users/private/Docker/compose.yaml"
        )))
        let definition = MountDefinition(
            displayName: "Movies",
            host: "nas.private.local",
            exportPath: "/volume1/Movies",
            mountPoint: "/Volumes/Media/Movies",
            recoveryDependencies: [dependency]
        )
        let serviceStatus = ServiceStatusSnapshot(
            daemonOnline: true,
            daemonAuthorized: true,
            agentAuthorized: true,
            networkVolumesVerification: .verified
        )

        let data = try DiagnosticExporter.make(
            configuration: .init(mounts: [definition]),
            statuses: [],
            events: [],
            externalMounts: [
                ExternalMountSnapshot(
                    source: "other.private.local:/private/export",
                    mountPoint: "/Volumes/External/Private",
                    fileSystemType: "nfs",
                    options: ["nosuid"]
                )
            ],
            serviceStatus: serviceStatus
        )
        let text = String(decoding: data, as: UTF8.self)

        #expect(!text.contains("/Users/private"))
        #expect(!text.contains("nas.private.local"))
        #expect(!text.contains("/volume1/Movies"))
        #expect(!text.contains("/private/export"))
        #expect(!text.contains("other.private.local"))
        #expect(text.contains("<redacted-host>"))
        #expect(text.contains("<redacted-export-path>"))
        #expect(text.contains("radarr"))
    }
}
