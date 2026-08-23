import Darwin
import Foundation
import Testing
@testable import LATCHShared

@Suite("Existing mount target validation")
struct MountTargetTests {
    @Test func commandFailureExplainsTheExecutableStatusAndSystemDetail() {
        let error = SystemCommandError(executable: "/sbin/mount", status: 2, detail: "permission denied")

        #expect(error.localizedDescription == "mount failed with exit status 2: permission denied")
    }

    @Test func acceptsAnExistingEmptyOwnedDirectoryInsideAnAllowedRoot() throws {
        try withTemporaryRoot { root in
            let target = root.appendingPathComponent("MyMusic", isDirectory: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)

            let result = try ExistingMountTargetValidator().validate(
                target.path,
                allowedRoots: [root.path],
                requiredOwnerID: getuid(),
                requireEmpty: true
            )

            #expect(result == target.standardizedFileURL.path)
        }
    }

    @Test func rejectsAMissingDirectoryWithoutCreatingIt() throws {
        try withTemporaryRoot { root in
            let target = root.appendingPathComponent("Missing", isDirectory: true)

            #expect(throws: MountTargetValidationError.notFound) {
                try ExistingMountTargetValidator().validate(
                    target.path,
                    allowedRoots: [root.path],
                    requiredOwnerID: getuid(),
                    requireEmpty: true
                )
            }
            #expect(!FileManager.default.fileExists(atPath: target.path))
        }
    }

    @Test func rejectsANonEmptyDirectory() throws {
        try withTemporaryRoot { root in
            let target = root.appendingPathComponent("MyMusic", isDirectory: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            try Data("keep".utf8).write(to: target.appendingPathComponent("existing.txt"))

            #expect(throws: MountTargetValidationError.notEmpty) {
                try ExistingMountTargetValidator().validate(
                    target.path,
                    allowedRoots: [root.path],
                    requiredOwnerID: getuid(),
                    requireEmpty: true
                )
            }
        }
    }

    @Test func rejectsASymlinkTarget() throws {
        try withTemporaryRoot { root in
            let real = root.appendingPathComponent("Real", isDirectory: true)
            let link = root.appendingPathComponent("Link", isDirectory: true)
            try FileManager.default.createDirectory(at: real, withIntermediateDirectories: false)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

            #expect(throws: MountTargetValidationError.symbolicLink) {
                try ExistingMountTargetValidator().validate(
                    link.path,
                    allowedRoots: [root.path],
                    requiredOwnerID: getuid(),
                    requireEmpty: true
                )
            }
        }
    }

    @Test func rejectsASymlinkedAncestorWithoutFollowingIt() throws {
        try withTemporaryRoot { root in
            let realParent = root.appendingPathComponent("Real", isDirectory: true)
            let target = realParent.appendingPathComponent("Target", isDirectory: true)
            let linkedParent = root.appendingPathComponent("Linked", isDirectory: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: linkedParent, withDestinationURL: realParent)

            #expect(throws: MountTargetValidationError.symbolicLink) {
                try ExistingMountTargetValidator().validate(
                    linkedParent.appendingPathComponent("Target").path,
                    allowedRoots: [root.path],
                    requiredOwnerID: getuid(),
                    requireEmpty: true
                )
            }
        }
    }

    @Test func rejectsOwnerMismatch() throws {
        try withTemporaryRoot { root in
            let target = root.appendingPathComponent("Target", isDirectory: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)

            #expect(throws: MountTargetValidationError.wrongOwner) {
                try ExistingMountTargetValidator().validate(
                    target.path,
                    allowedRoots: [root.path],
                    requiredOwnerID: getuid() &+ 1,
                    requireEmpty: true
                )
            }
        }
    }

    @Test func capturedIdentityRejectsAReplacedTarget() throws {
        try withTemporaryRoot { root in
            let target = root.appendingPathComponent("Target", isDirectory: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            let validator = ExistingMountTargetValidator()
            let identity = try validator.inspect(
                target.path,
                allowedRoots: [root.path],
                requiredOwnerID: getuid(),
                requireEmpty: true
            )

            try FileManager.default.removeItem(at: target)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)

            #expect(throws: MountTargetValidationError.identityChanged) {
                try validator.revalidate(
                    identity,
                    allowedRoots: [root.path],
                    requiredOwnerID: getuid(),
                    requireEmpty: true
                )
            }
        }
    }

    @Test func rejectsAPathOutsideTheAllowedRoots() throws {
        try withTemporaryRoot { root in
            let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: outside) }

            #expect(throws: MountTargetValidationError.outsideAllowedRoots) {
                try ExistingMountTargetValidator().validate(
                    outside.path,
                    allowedRoots: [root.path],
                    requiredOwnerID: getuid(),
                    requireEmpty: true
                )
            }
        }
    }

    private func withTemporaryRoot(_ body: (URL) throws -> Void) throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let root = repositoryRoot.appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }
}
