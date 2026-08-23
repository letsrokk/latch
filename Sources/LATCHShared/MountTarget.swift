import Darwin
import Foundation

public enum MountTargetValidationError: Error, Sendable, Equatable, LocalizedError {
    case invalidPath
    case notFound
    case notDirectory
    case symbolicLink
    case outsideAllowedRoots
    case wrongOwner
    case identityChanged
    case notEmpty
    case unreadable

    public var errorDescription: String? {
        switch self {
        case .invalidPath: "Choose a valid absolute folder path."
        case .notFound: "The selected mount folder no longer exists. Choose or create it in Finder."
        case .notDirectory: "The selected mount target is not a folder."
        case .symbolicLink: "Symbolic links cannot be used as mount folders."
        case .outsideAllowedRoots: "Choose a folder inside your home directory or /Volumes/Media."
        case .wrongOwner: "The selected mount folder must belong to the current user."
        case .identityChanged: "The selected mount folder changed while it was being prepared."
        case .notEmpty: "The selected mount folder must be empty before it can be mounted."
        case .unreadable: "The selected mount folder could not be inspected."
        }
    }
}

public struct MountTargetIdentity: Sendable, Equatable {
    public let path: String
    public let device: UInt64
    public let inode: UInt64
    public let ownerID: uid_t

    public init(path: String, device: UInt64, inode: UInt64, ownerID: uid_t) {
        self.path = path
        self.device = device
        self.inode = inode
        self.ownerID = ownerID
    }
}

public struct MountPathSuggestion: Sendable {
    public static func path(displayName: String, homeDirectory: String) -> String {
        let name = displayName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        guard !name.isEmpty else { return URL(fileURLWithPath: homeDirectory).standardizedFileURL.path }
        return URL(fileURLWithPath: homeDirectory, isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
            .standardizedFileURL.path
    }

    public static func abbreviated(_ path: String, homeDirectory: String) -> String {
        let home = URL(fileURLWithPath: homeDirectory).standardizedFileURL.path
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard standardized.hasPrefix(home + "/") else { return standardized }
        return "~" + standardized.dropFirst(home.count)
    }
}

public struct ExistingMountTargetValidator: Sendable {
    public init() {}

    @discardableResult
    public func validate(
        _ path: String,
        allowedRoots: [String],
        requiredOwnerID: uid_t? = nil,
        requireEmpty: Bool
    ) throws -> String {
        try inspect(
            path,
            allowedRoots: allowedRoots,
            requiredOwnerID: requiredOwnerID,
            requireEmpty: requireEmpty
        ).path
    }

    public func inspect(
        _ path: String,
        allowedRoots: [String],
        requiredOwnerID: uid_t? = nil,
        requireEmpty: Bool
    ) throws -> MountTargetIdentity {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard path.hasPrefix("/"), path == standardized, !path.contains("\0") else {
            throw MountTargetValidationError.invalidPath
        }

        let roots = allowedRoots.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        guard roots.contains(where: { standardized.hasPrefix($0 + "/") }) else {
            throw MountTargetValidationError.outsideAllowedRoots
        }

        let descriptor = try openDirectoryWithoutFollowingLinks(standardized)
        defer { close(descriptor) }
        var information = stat()
        guard fstat(descriptor, &information) == 0 else { throw MountTargetValidationError.unreadable }
        guard (information.st_mode & S_IFMT) == S_IFDIR else { throw MountTargetValidationError.notDirectory }
        if let requiredOwnerID, information.st_uid != requiredOwnerID { throw MountTargetValidationError.wrongOwner }
        if requireEmpty, try !isEmpty(descriptor) { throw MountTargetValidationError.notEmpty }
        return MountTargetIdentity(
            path: standardized,
            device: UInt64(information.st_dev),
            inode: UInt64(information.st_ino),
            ownerID: information.st_uid
        )
    }

    @discardableResult
    public func revalidate(
        _ identity: MountTargetIdentity,
        allowedRoots: [String],
        requiredOwnerID: uid_t? = nil,
        requireEmpty: Bool
    ) throws -> MountTargetIdentity {
        let current = try inspect(
            identity.path,
            allowedRoots: allowedRoots,
            requiredOwnerID: requiredOwnerID,
            requireEmpty: requireEmpty
        )
        guard current == identity else { throw MountTargetValidationError.identityChanged }
        return current
    }

    private func openDirectoryWithoutFollowingLinks(_ path: String) throws -> Int32 {
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw MountTargetValidationError.unreadable }
        for component in path.split(separator: "/") {
            let next = openat(descriptor, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0 {
                let failure = errno
                var componentInformation = stat()
                let isSymbolicLink = fstatat(descriptor, String(component), &componentInformation, AT_SYMLINK_NOFOLLOW) == 0
                    && (componentInformation.st_mode & S_IFMT) == S_IFLNK
                close(descriptor)
                if isSymbolicLink { throw MountTargetValidationError.symbolicLink }
                switch failure {
                case ELOOP: throw MountTargetValidationError.symbolicLink
                case ENOENT: throw MountTargetValidationError.notFound
                case ENOTDIR: throw MountTargetValidationError.notDirectory
                default: throw MountTargetValidationError.unreadable
                }
            }
            close(descriptor)
            descriptor = next
        }
        return descriptor
    }

    private func isEmpty(_ descriptor: Int32) throws -> Bool {
        let duplicate = dup(descriptor)
        guard duplicate >= 0, let directory = fdopendir(duplicate) else {
            if duplicate >= 0 { close(duplicate) }
            throw MountTargetValidationError.unreadable
        }
        defer { closedir(directory) }
        errno = 0
        while let entry = readdir(directory) {
            var nameStorage = entry.pointee.d_name
            let nameCapacity = MemoryLayout.size(ofValue: nameStorage)
            let name = withUnsafePointer(to: &nameStorage) {
                $0.withMemoryRebound(to: CChar.self, capacity: nameCapacity) {
                    String(cString: $0)
                }
            }
            if name != "." && name != ".." { return false }
        }
        guard errno == 0 else { throw MountTargetValidationError.unreadable }
        return true
    }
}
