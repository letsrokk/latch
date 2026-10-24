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

    @Test func newNFSOptionsEncodeWithoutChangingLegacyDefaults() throws {
        var options = NFSOptions.recommended
        let legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(options)) as! [String: Any]
        let oldKeys = legacy.filter { !["nfsVersion", "readSizeBytes", "writeSizeBytes", "additionalMountOptions"].contains($0.key) }
        let decoded = try JSONDecoder().decode(NFSOptions.self, from: JSONSerialization.data(withJSONObject: oldKeys))
        #expect(decoded == options)
        options.nfsVersion = "4.1"
        options.readSizeBytes = 131072
        options.writeSizeBytes = 131072
        options.additionalMountOptions = " readahead=32, ,acregmax=30 "
        #expect(options.encoded == "rw,resvport,tcp,intr,nobrowse,nosuid,nodev,vers=4.1,rsize=131072,wsize=131072,readahead=32,acregmax=30")
        let roundTrip = try JSONDecoder().decode(NFSOptions.self, from: JSONEncoder().encode(options))
        #expect(roundTrip == options)
    }

    @Test(arguments: ["=32", "readahead=", "a=b=c", "foo bar", "foo=bar\nbaz", "foo=bar\u{0}", "-o", "server:/share", "/mnt/share", "readahead=2,readahead=3", "soft,hard", "ac,noac", "sync,async", "hard,nosoft", "sync,noasync", "vers=4.1", "nfsvers=3", "nfsv4", "rsize=4096", "rwsize=8192", "tcp,udp", "ro,rw", "nointr", "locks", "nolockd", "nolocallocks", "browse", "exec", "suid", "dev", "proto=udp", "update", "bg"])
    func invalidAdditionalOptionsAreRejected(_ value: String) {
        #expect(throws: NFSOptionsValidationError.self) { try NFSOptions.parseAdditional(value) }
    }

    @Test func additionalOptionsHaveBoundsAndDoNotEvaluateValues() throws {
        #expect(try NFSOptions.parseAdditional(" readahead=32, ,acregmax=30,custom_flag ") == ["readahead=32", "acregmax=30", "custom_flag"])
        #expect(try NFSOptions.parseAdditional("custom=$(id);touch/tmp/never") == ["custom=$(id);touch/tmp/never"])
        #expect(throws: NFSOptionsValidationError.self) { try NFSOptions.parseAdditional(String(repeating: "x", count: 4097)) }
        #expect(throws: NFSOptionsValidationError.self) { try NFSOptions.parseAdditional((0..<65).map { "custom\($0)" }.joined(separator: ",")) }
        #expect(throws: NFSOptionsValidationError.self) { try NFSOptions.parseAdditional("mntvers=3,mountvers=2") }
        var invalid = NFSOptions.recommended
        invalid.readSizeBytes = 12345
        #expect(throws: NFSOptionsValidationError.self) { try invalid.validate() }
        invalid = .recommended
        invalid.nfsVersion = "4.9"
        #expect(throws: NFSOptionsValidationError.self) { try invalid.validate() }
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
            try ConfigurationValidator().validate(LATCHConfiguration(schemaVersion: 99, mounts: []), liveMounts: [])
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
