import Foundation

public struct NFSOptions: Codable, Sendable, Equatable, Hashable {
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
        ignoreDeviceFiles: Bool
    ) {
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
        return values.joined(separator: ",")
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
