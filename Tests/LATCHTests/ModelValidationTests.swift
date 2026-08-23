import Foundation
import Testing
@testable import LATCHShared

@Suite("Model validation")
struct ModelValidationTests {
    @Test func externalMountCreatesAnEditableConfigurationTemplateWithoutAdoptingIt() throws {
        let template = try #require(ExternalMountConfigurationTemplate(snapshot: .init(source: "nas.local:/media", mountPoint: "/Volumes/Media/Media", fileSystemType: "nfs", options: [])))

        #expect(template.server.hostname == "nas.local")
        #expect(template.draft.exportPath == "/media")
        #expect(template.draft.mountPoint == "/Volumes/Media/Media")
    }
    @Test func recommendedOptionsEncodeInStableOrder() {
        #expect(NFSOptions.recommended.encoded == "rw,resvport,tcp,intr,nobrowse,nosuid,nodev")
    }

    @Test func allOptionCombinationsUseOnlySupportedDeterministicTokens() {
        let options = NFSOptions(
            readOnly: true,
            reservedPort: true,
            requireTCP: true,
            interruptible: true,
            disableLocking: true,
            hideFromFinder: true,
            noExecutableFiles: true,
            ignoreSetuid: true,
            ignoreDeviceFiles: true
        )

        #expect(options.encoded == "ro,resvport,tcp,intr,nolocks,nobrowse,noexec,nosuid,nodev")
    }

    @Test func externalMountpointConflictIsRejected() throws {
        let definition = makeDefinition(mountPoint: "/Volumes/Media/Movies")
        let external = ExternalMountSnapshot(
            source: "other.local:/media",
            mountPoint: "/Volumes/Media/Movies",
            fileSystemType: "nfs",
            options: ["rw"]
        )

        #expect(throws: ConfigurationValidationError.externalMountPointConflict) {
            try ConfigurationValidator().validate([definition], liveMounts: [external])
        }
    }

    @Test func externalSourceConflictIsRejected() throws {
        let definition = makeDefinition(host: "server.local", exportPath: "/exports/media")
        let external = ExternalMountSnapshot(
            source: "server.local:/exports/media",
            mountPoint: "/Volumes/Elsewhere",
            fileSystemType: "nfs",
            options: ["rw"]
        )

        #expect(throws: ConfigurationValidationError.externalSourceConflict) {
            try ConfigurationValidator().validate([definition], liveMounts: [external])
        }
    }

    @Test func duplicateConfiguredMountpointIsRejected() {
        let first = makeDefinition(displayName: "Movies")
        let second = makeDefinition(displayName: "Duplicate", exportPath: "/exports/other")

        #expect(throws: ConfigurationValidationError.duplicateMountPoint) {
            try ConfigurationValidator().validate([first, second], liveMounts: [])
        }
    }

    @Test func mountpointOutsideApprovedRootIsRejected() {
        let definition = makeDefinition(mountPoint: "/tmp/media")

        #expect(throws: ConfigurationValidationError.mountPointOutsideApprovedRoot) {
            try ConfigurationValidator().validate([definition], liveMounts: [])
        }
    }

    @Test func configurationValidationErrorsExposeUserFacingMessages() {
        let cases: [(ConfigurationValidationError, String)] = [
            (.unsupportedSchemaVersion, "The configuration schema version is not supported."),
            (.duplicateID, "This mount identifier is already in use."),
            (.duplicateSource, "LATCH already manages this NFS share. Edit the existing mount instead."),
            (.duplicateMountPoint, "LATCH already uses this mount folder. Choose another empty folder."),
            (.invalidDisplayName, "Enter a display name."),
            (.invalidHost, "Enter a valid NFS server hostname without spaces, colons, or slashes."),
            (.invalidExportPath, "Enter an absolute export path that starts with '/'."),
            (.invalidMountPoint, "Enter an absolute mount folder that starts with '/'."),
            (.mountPointOutsideApprovedRoot, "Choose a mount folder under /Users or /Volumes/Media."),
            (.symlinkMountPoint, "The mount folder must not be a symbolic link."),
            (.invalidTiming, "Enter valid probe and recovery timing values."),
            (.duplicateDependencyID, "Recovery dependencies must have unique identifiers."),
            (.invalidDependency, "Review each recovery dependency and provide valid values."),
            (.externalSourceConflict, "This NFS share is already mounted outside LATCH. LATCH currently requires exclusive ownership of a share. Unmount the existing mount, then try again."),
            (.externalMountPointConflict, "This mount folder is already used by another NFS mount. Unmount it or choose another empty folder."),
            (.missingServerReference, "Choose a server before saving this mount."),
            (.duplicateServerID, "A server with this identifier already exists."),
            (.duplicateServerHostname, "A server with this hostname already exists."),
            (.invalidNetworkRule, "This network rule is invalid."),
            (.invalidWakeOnLAN, "Wake-on-LAN settings are invalid."),
            (.invalidPostMountAction, "A post-mount action is invalid."),
        ]

        for (error, message) in cases {
            #expect(error.localizedDescription == message)
        }

        #expect(cases.count == 21)

        #expect(ConfigurationValidationError.externalSourceConflict.localizedDescription == "This NFS share is already mounted outside LATCH. LATCH currently requires exclusive ownership of a share. Unmount the existing mount, then try again.")
        #expect(ConfigurationValidationError.externalMountPointConflict.localizedDescription == "This mount folder is already used by another NFS mount. Unmount it or choose another empty folder.")
        #expect(ConfigurationValidationError.duplicateSource.localizedDescription == "LATCH already manages this NFS share. Edit the existing mount instead.")
        #expect(ConfigurationValidationError.duplicateMountPoint.localizedDescription == "LATCH already uses this mount folder. Choose another empty folder.")
    }

    @Test func mountpointInsideAUserHomeIsAccepted() throws {
        let definition = makeDefinition(mountPoint: "/Users/test/MyMusic")

        try ConfigurationValidator().validate([definition], liveMounts: [])
    }

    @Test func relativeExportPathIsRejected() {
        let definition = makeDefinition(exportPath: "exports/media")

        #expect(throws: ConfigurationValidationError.invalidExportPath) {
            try ConfigurationValidator().validate([definition], liveMounts: [])
        }
    }

    @Test func unsafePostMountActionIsRejectedByConfigurationValidation() {
        var definition = makeDefinition()
        definition.postMountActions = [.openRelativePath("../../outside")]

        #expect(throws: ConfigurationValidationError.invalidPostMountAction) {
            try ConfigurationValidator().validate([definition], liveMounts: [])
        }
    }

    @Test func duplicateDependencyIdentifierIsRejected() {
        let dependencyID = UUID()
        let dependencies = [
            RecoveryDependency(
                id: dependencyID,
                enabled: true,
                stopTimeoutSeconds: 30,
                kind: .dockerContainer(
                    DockerContainerDependency(
                        containerName: "radarr",
                        dockerSocketPath: "/Users/test/.docker/run/docker.sock",
                        composeFilePath: nil
                    )
                )
            ),
            RecoveryDependency(
                id: dependencyID,
                enabled: true,
                stopTimeoutSeconds: 30,
                kind: .macApplication(
                    MacApplicationDependency(
                        bundleIdentifier: "com.example.Roon",
                        applicationURL: nil,
                        forceQuitAfterTimeout: false
                    )
                )
            ),
        ]
        let definition = makeDefinition(recoveryDependencies: dependencies)

        #expect(throws: ConfigurationValidationError.duplicateDependencyID) {
            try ConfigurationValidator().validate([definition], liveMounts: [])
        }
    }

    @Test func unsupportedConfigurationSchemaIsRejected() {
        #expect(throws: ConfigurationValidationError.unsupportedSchemaVersion) {
            try ConfigurationValidator().validate(LATCHConfiguration(schemaVersion: 3, mounts: []), liveMounts: [])
        }
    }

    private func makeDefinition(
        displayName: String = "Movies",
        host: String = "server.local",
        exportPath: String = "/exports/media",
        mountPoint: String = "/Volumes/Media/Movies",
        recoveryDependencies: [RecoveryDependency] = []
    ) -> MountDefinition {
        MountDefinition(
            id: UUID(),
            displayName: displayName,
            host: host,
            exportPath: exportPath,
            mountPoint: mountPoint,
            mountOptions: .recommended,
            enabled: true,
            probeIntervalSeconds: 60,
            probeTimeoutSeconds: 5,
            recoveryCooldownSeconds: 600,
            recoveryDependencies: recoveryDependencies
        )
    }
}
