import Darwin
import Foundation

public protocol MountTableProviding: Sendable {
    func snapshots() throws -> [ExternalMountSnapshot]
}

public struct DarwinMountTable: MountTableProviding, Sendable {
    public init() {}

    public func snapshots() throws -> [ExternalMountSnapshot] {
        let effectiveOptions = mountCommandOptions()
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
                options: effectiveOptions[MountOutputParser.key(source: tupleString(entry.f_mntfromname), mountPoint: tupleString(entry.f_mntonname))]
                    ?? optionNames(flags: UInt64(entry.f_flags))
            )
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
