import Foundation

public struct NFSOptions: Codable, Sendable, Equatable, Hashable {
    public var nfsVersion: String?
    public var readSizeBytes: Int?
    public var writeSizeBytes: Int?
    public var additionalMountOptions: String
    public var readOnly: Bool
    public var reservedPort: Bool
    public var requireTCP: Bool
    public var interruptible: Bool
    public var disableLocking: Bool
    public var hideFromFinder: Bool
    public var noExecutableFiles: Bool
    public var ignoreSetuid: Bool
    public var ignoreDeviceFiles: Bool

    public init(
        readOnly: Bool,
        reservedPort: Bool,
        requireTCP: Bool,
        interruptible: Bool,
        disableLocking: Bool,
        hideFromFinder: Bool,
        noExecutableFiles: Bool,
        ignoreSetuid: Bool,
        ignoreDeviceFiles: Bool,
        nfsVersion: String? = nil,
        readSizeBytes: Int? = nil,
        writeSizeBytes: Int? = nil,
        additionalMountOptions: String = ""
    ) {
        self.nfsVersion = nfsVersion
        self.readSizeBytes = readSizeBytes
        self.writeSizeBytes = writeSizeBytes
        self.additionalMountOptions = additionalMountOptions
        self.readOnly = readOnly
        self.reservedPort = reservedPort
        self.requireTCP = requireTCP
        self.interruptible = interruptible
        self.disableLocking = disableLocking
        self.hideFromFinder = hideFromFinder
        self.noExecutableFiles = noExecutableFiles
        self.ignoreSetuid = ignoreSetuid
        self.ignoreDeviceFiles = ignoreDeviceFiles
    }

    public static let recommended = NFSOptions(
        readOnly: false,
        reservedPort: true,
        requireTCP: true,
        interruptible: true,
        disableLocking: false,
        hideFromFinder: true,
        noExecutableFiles: false,
        ignoreSetuid: true,
        ignoreDeviceFiles: true
    )

    public var encoded: String {
        var values = [readOnly ? "ro" : "rw"]
        if reservedPort { values.append("resvport") }
        if requireTCP { values.append("tcp") }
        if interruptible { values.append("intr") }
        if disableLocking { values.append("nolocks") }
        if hideFromFinder { values.append("nobrowse") }
        if noExecutableFiles { values.append("noexec") }
        if ignoreSetuid { values.append("nosuid") }
        if ignoreDeviceFiles { values.append("nodev") }
        if let nfsVersion { values.append("vers=\(nfsVersion)") }
        if let readSizeBytes { values.append("rsize=\(readSizeBytes)") }
        if let writeSizeBytes { values.append("wsize=\(writeSizeBytes)") }
        values.append(contentsOf: additionalMountOptions.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        return values.joined(separator: ",")
    }

    private enum CodingKeys: String, CodingKey {
        case readOnly, reservedPort, requireTCP, interruptible, disableLocking, hideFromFinder
        case noExecutableFiles, ignoreSetuid, ignoreDeviceFiles
        case nfsVersion, readSizeBytes, writeSizeBytes, additionalMountOptions
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        readOnly = try values.decode(Bool.self, forKey: .readOnly)
        reservedPort = try values.decode(Bool.self, forKey: .reservedPort)
        requireTCP = try values.decode(Bool.self, forKey: .requireTCP)
        interruptible = try values.decode(Bool.self, forKey: .interruptible)
        disableLocking = try values.decode(Bool.self, forKey: .disableLocking)
        hideFromFinder = try values.decode(Bool.self, forKey: .hideFromFinder)
        noExecutableFiles = try values.decode(Bool.self, forKey: .noExecutableFiles)
        ignoreSetuid = try values.decode(Bool.self, forKey: .ignoreSetuid)
        ignoreDeviceFiles = try values.decode(Bool.self, forKey: .ignoreDeviceFiles)
        nfsVersion = try values.decodeIfPresent(String.self, forKey: .nfsVersion)
        readSizeBytes = try values.decodeIfPresent(Int.self, forKey: .readSizeBytes)
        writeSizeBytes = try values.decodeIfPresent(Int.self, forKey: .writeSizeBytes)
        additionalMountOptions = try values.decodeIfPresent(String.self, forKey: .additionalMountOptions) ?? ""
    }

    public static let transferSizes = (12...21).map { 1 << $0 }
    public static let maximumTransferSize = transferSizes.last(where: { clientAccepts("rsize=\($0)") }) ?? 4096
    private static let supports41 = clientAccepts("vers=4.1")

    public static func supportsVersion(_ version: String) -> Bool {
        switch version {
        case "3", "4.0": true
        case "4.1": supports41
        default: false
        }
    }

    private static func clientAccepts(_ option: String) -> Bool {
        // -h exits during option parsing, before any source lookup or mount syscall.
        // Probe the installed parser because SDK limits can differ from the running client.
        let process = Process()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/sbin/mount_nfs")
        process.arguments = ["-o", option, "-h"]
        process.environment = ["LC_ALL": "C", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        do {
            try process.run()
            let data = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = String(decoding: data, as: UTF8.self)
            return output.contains("usage: mount_nfs") && !output.contains("illegal NFS version")
                && !output.contains("illegal rsize") && !output.contains("illegal wsize")
        } catch { return false }
    }

    public func validate() throws {
        if let nfsVersion, !Self.supportsVersion(nfsVersion) {
            throw NFSOptionsValidationError.invalid("This macOS NFS client does not support the requested NFS version. Choose a supported version or Automatic.")
        }
        for (name, size) in [("Read", readSizeBytes), ("Write", writeSizeBytes)] {
            if let size, !Self.transferSizes.contains(size) || size > Self.maximumTransferSize {
                throw NFSOptionsValidationError.invalid("\(name) request size must be a supported power of two from 4 KiB through \(Self.maximumTransferSize / 1024) KiB. Choose Default or a supported size.")
            }
        }
        _ = try Self.parseAdditional(additionalMountOptions)
    }

    public static func parseAdditional(_ input: String) throws -> [String] {
        guard input.utf8.count <= 4096 else {
            throw NFSOptionsValidationError.invalid("Additional mount options must fit within 4,096 bytes.")
        }
        let entries = input.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard entries.count <= 64 else {
            throw NFSOptionsValidationError.invalid("Enter at most 64 additional mount options.")
        }
        var seen = Set<String>()
        for entry in entries {
            let parts = entry.split(separator: "=", omittingEmptySubsequences: false)
            let name = String(parts[0]).lowercased()
            guard parts.count <= 2,
                  name.range(of: #"^[a-z][a-z0-9_.-]*$"#, options: .regularExpression) != nil,
                  !entry.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0) }),
                  parts.count == 1 || !parts[1].isEmpty else {
                throw NFSOptionsValidationError.invalid("Enter comma-separated option names or key=value entries. Enter options only, without -o, commands, addresses, or mount paths.")
            }
            if let control = structuredControl(for: name) {
                throw NFSOptionsValidationError.invalid("Set \(control) using \(control == "the NFS version" ? "the NFS version picker" : "its control") instead of Additional mount options.")
            }
            guard !["force", "update", "remount", "bg", "background"].contains(name) else {
                throw NFSOptionsValidationError.invalid("LATCH manages mount execution. Remove the \(name) option.")
            }
            let aliases = ["nfsport": "port", "mountvers": "mountversion", "mntvers": "mountversion", "mountproto": "mntproto", "nosoft": "hard", "nohard": "soft", "noasync": "sync", "nosync": "async"]
            let canonical = aliases[name] ?? name
            guard seen.insert(canonical).inserted else {
                throw NFSOptionsValidationError.invalid("Remove the duplicate \(name) option from Additional mount options.")
            }
            let opposite = canonical.hasPrefix("no") ? String(canonical.dropFirst(2)) : "no" + canonical
            let pairs = ["soft": "hard", "hard": "soft", "sync": "async", "async": "sync", "fg": "bg", "inet": "inet6", "inet6": "inet"]
            if seen.contains(opposite) || pairs[canonical].map({ seen.contains($0) }) == true {
                throw NFSOptionsValidationError.invalid("Remove contradictory options from Additional mount options (\(name)).")
            }
        }
        return entries
    }

    private static func structuredControl(for name: String) -> String? {
        let base = name.hasPrefix("no") ? String(name.dropFirst(2)) : name
        if ["vers", "nfsvers", "nfsv2", "nfsv3", "nfsv4", "nfsv4.0", "nfsv4.1", "v2", "v3", "v4", "minorversion"].contains(base) { return "the NFS version" }
        if ["rsize", "wsize", "rwsize"].contains(base) { return "read and write request sizes" }
        if ["ro", "rw", "rdonly", "read-only", "readwrite"].contains(base) { return "read-only access" }
        if ["tcp", "udp", "proto", "netid"].contains(base) { return "the transport" }
        if ["resvport", "reservedport"].contains(base) { return "the reserved port" }
        if base == "intr" { return "interruptible operations" }
        if ["lock", "locks", "lockd", "nlm", "locallocks"].contains(base) { return "NFS locking" }
        if base == "browse" { return "Finder visibility" }
        if base == "exec" { return "executable files" }
        if base == "suid" { return "setuid and setgid behavior" }
        if base == "dev" { return "device files" }
        return nil
    }

    public static let controls: [NFSOptionControl] = [
        .init(key: .readOnly, title: "Read-only", hint: "Prevents every application from changing files on this volume."),
        .init(key: .reservedPort, title: "Reserved port", hint: "Uses a privileged client port, which some NFS servers such as Synology require."),
        .init(key: .requireTCP, title: "Require TCP", hint: "Prevents fallback to UDP and uses TCP for more reliable media transfers."),
        .init(key: .interruptible, title: "Interrupt blocked operations", hint: "Allows a terminated process to escape some NFS operations blocked by an unavailable server."),
        .init(key: .disableLocking, title: "Disable NFS locking", hint: "Disables remote file locking and should be enabled only when the server or workload does not use locks."),
        .init(key: .hideFromFinder, title: "Hide from Finder", hint: "Keeps the mounted volume out of Finder’s normal volume and desktop listings."),
        .init(key: .noExecutableFiles, title: "Block executable files", hint: "Prevents programs and scripts stored on this media volume from being executed directly."),
        .init(key: .ignoreSetuid, title: "Ignore setuid and setgid", hint: "Prevents privilege-changing file bits on the NFS volume from taking effect."),
        .init(key: .ignoreDeviceFiles, title: "Ignore device files", hint: "Prevents device files stored on the NFS volume from being treated as real devices."),
    ]
}

public struct NFSOptionControl: Sendable, Equatable, Identifiable {
    public enum Key: String, Codable, Sendable, CaseIterable {
        case readOnly, reservedPort, requireTCP, interruptible, disableLocking
        case hideFromFinder, noExecutableFiles, ignoreSetuid, ignoreDeviceFiles
    }

    public let key: Key
    public let title: String
    public let hint: String
    public var id: Key { key }

    public init(key: Key, title: String, hint: String) {
        self.key = key
        self.title = title
        self.hint = hint
    }
}

public extension NFSOptions {
    subscript(key: NFSOptionControl.Key) -> Bool {
        get {
            switch key {
            case .readOnly: readOnly
            case .reservedPort: reservedPort
            case .requireTCP: requireTCP
            case .interruptible: interruptible
            case .disableLocking: disableLocking
            case .hideFromFinder: hideFromFinder
            case .noExecutableFiles: noExecutableFiles
            case .ignoreSetuid: ignoreSetuid
            case .ignoreDeviceFiles: ignoreDeviceFiles
            }
        }
        set {
            switch key {
            case .readOnly: readOnly = newValue
            case .reservedPort: reservedPort = newValue
            case .requireTCP: requireTCP = newValue
            case .interruptible: interruptible = newValue
            case .disableLocking: disableLocking = newValue
            case .hideFromFinder: hideFromFinder = newValue
            case .noExecutableFiles: noExecutableFiles = newValue
            case .ignoreSetuid: ignoreSetuid = newValue
            case .ignoreDeviceFiles: ignoreDeviceFiles = newValue
            }
        }
    }

    func changesToRecommended() -> [NFSOptionChange] {
        NFSOptionControl.Key.allCases.compactMap { key in
            let recommended = Self.recommended[key]
            guard self[key] != recommended else { return nil }
            return NFSOptionChange(key: key, from: self[key], to: recommended)
        }
    }
}

public struct NFSOptionChange: Sendable, Equatable, Identifiable {
    public let key: NFSOptionControl.Key
    public let from: Bool
    public let to: Bool
    public var id: NFSOptionControl.Key { key }

    public init(key: NFSOptionControl.Key, from: Bool, to: Bool) {
        self.key = key
        self.from = from
        self.to = to
    }
}

public enum NFSOptionsValidationError: Error, Sendable, Equatable, LocalizedError {
    case invalid(String)
    public var errorDescription: String? {
        switch self { case .invalid(let message): message }
    }
}
