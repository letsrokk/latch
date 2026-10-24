import Darwin
import Foundation

public protocol MountTableProviding: Sendable {
    func snapshots() throws -> [ExternalMountSnapshot]
}

public struct DarwinMountTable: MountTableProviding, Sendable {
    public init() {}

    public func snapshots() throws -> [ExternalMountSnapshot] {
        let effectiveOptions = mountCommandOptions()
        let observedOptions = nfsstatOptions()
        var mounts: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&mounts, MNT_NOWAIT)
        guard count >= 0, let mounts else { throw POSIXError(.EIO) }

        return (0..<Int(count)).compactMap { index in
            let entry = mounts[index]
            let type = tupleString(entry.f_fstypename)
            guard type == "nfs" else { return nil }
            return ExternalMountSnapshot(
                source: tupleString(entry.f_mntfromname),
                mountPoint: tupleString(entry.f_mntonname),
                fileSystemType: type,
                options: (effectiveOptions[MountOutputParser.key(source: tupleString(entry.f_mntfromname), mountPoint: tupleString(entry.f_mntonname))]
                    ?? optionNames(flags: UInt64(entry.f_flags))).filter { !NFSObservedOptions.isRuntimeParameter($0) }
                    + (observedOptions[MountOutputParser.key(source: tupleString(entry.f_mntfromname), mountPoint: tupleString(entry.f_mntonname))] ?? [])
            )
        }
    }

    private func nfsstatOptions() -> [String: [String]] {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nfsstat")
        process.arguments = ["-m"]
        process.environment = ["LC_ALL": "C", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: deadline)
            defer { deadline.cancel() }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return [:] }
            return NFSStatMountParser.optionsByMount(from: String(decoding: data, as: UTF8.self))
        } catch {
            return [:]
        }
    }

    private func mountCommandOptions() -> [String: [String]] {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/sbin/mount")
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return [:] }
            return MountOutputParser.optionsByMount(from: String(decoding: data, as: UTF8.self))
        } catch {
            return [:]
        }
    }

    private func tupleString<T>(_ tuple: T) -> String {
        withUnsafePointer(to: tuple) {
            $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) {
                String(cString: $0)
            }
        }
    }

    private func optionNames(flags: UInt64) -> [String] {
        var values: [String] = []
        values.append((flags & UInt64(MNT_RDONLY)) != 0 ? "ro" : "rw")
        if (flags & UInt64(MNT_NOEXEC)) != 0 { values.append("noexec") }
        if (flags & UInt64(MNT_NOSUID)) != 0 { values.append("nosuid") }
        if (flags & UInt64(MNT_NODEV)) != 0 { values.append("nodev") }
        if (flags & UInt64(MNT_DONTBROWSE)) != 0 { values.append("nobrowse") }
        return values
    }
}

public struct NFSObservedOptions: Sendable, Equatable {
    public let version: String?
    public let transport: String?
    public let readSizeBytes: Int?
    public let writeSizeBytes: Int?

    public init(options: [String]) {
        func value(_ key: String) -> String? {
            options.first(where: { $0.hasPrefix(key + "=") }).map { String($0.dropFirst(key.count + 1)) }
        }
        let rawVersion = value("vers")
        version = rawVersion == "4" ? "4.0" : rawVersion
        let rawTransport = value("proto") ?? options.first(where: { ["tcp", "udp", "tcp6", "udp6"].contains($0) })
        transport = rawTransport.map { $0.hasPrefix("tcp") ? "tcp" : $0.hasPrefix("udp") ? "udp" : $0 }
        readSizeBytes = value("rsize").flatMap(Int.init)
        writeSizeBytes = value("wsize").flatMap(Int.init)
    }

    public static func isRuntimeParameter(_ option: String) -> Bool {
        ["vers=", "nfsvers=", "proto=", "rsize=", "wsize="].contains(where: option.hasPrefix)
            || ["tcp", "udp", "tcp6", "udp6"].contains(option)
    }

    public func verifyRequestedVersion(_ requested: String?) throws {
        guard let requested else { return }
        guard version == requested else {
            throw NFSVersionVerificationError(requested: requested, observed: version)
        }
    }
}

public struct NFSVersionVerificationError: Error, Sendable, Equatable, LocalizedError {
    public let requested: String
    public let observed: String?

    public var errorDescription: String? {
        "NFS protocol verification failed: requested \(requested), observed \(observed ?? "Unknown"). LATCH will not accept a different protocol version."
    }
}

public enum NFSStatMountParser {
    public static func optionsByMount(from output: String) -> [String: [String]] {
        var result: [String: [String]] = [:]
        var mountKey: String?
        var currentParameters = false
        var nfsParameters = false
        for line in output.split(whereSeparator: \.isNewline) {
            let text = String(line)
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("/"), let separator = text.range(of: " from ", options: .backwards) {
                mountKey = MountOutputParser.key(source: String(text[separator.upperBound...]), mountPoint: String(text[..<separator.lowerBound]))
                currentParameters = false
                nfsParameters = false
            } else if trimmed.hasPrefix("-- ") {
                currentParameters = trimmed == "-- Current mount parameters:"
                    || trimmed == "-- Current mount parameters"
                nfsParameters = false
            } else if currentParameters, let mountKey {
                if trimmed.hasPrefix("NFS parameters:") {
                    nfsParameters = true
                } else if trimmed.contains(":") {
                    nfsParameters = false
                }
                guard nfsParameters else { continue }
                let parameters = trimmed.replacingOccurrences(of: "NFS parameters:", with: "")
                let tokens = parameters.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
                result[mountKey, default: []].append(contentsOf: tokens.filter(NFSObservedOptions.isRuntimeParameter))
            }
        }
        return result
    }
}

public enum MountOutputParser {
    public static func key(source: String, mountPoint: String) -> String { "\(source)\u{0}\(mountPoint)" }

    public static func optionsByMount(from output: String) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let value = String(line)
            guard value.hasSuffix(")"),
                  let optionStart = value.range(of: " (", options: .backwards),
                  let separator = value[..<optionStart.lowerBound].range(of: " on ", options: .backwards) else { continue }
            let source = String(value[..<separator.lowerBound])
            let mountPoint = String(value[separator.upperBound..<optionStart.lowerBound])
            let rawOptions = value[optionStart.upperBound..<value.index(before: value.endIndex)]
            let values = rawOptions.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard values.first == "nfs" else { continue }
            result[key(source: source, mountPoint: mountPoint)] = Array(values.dropFirst())
        }
        return result
    }
}
