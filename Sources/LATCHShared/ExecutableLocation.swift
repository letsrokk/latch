import Darwin
import Foundation

public enum ExecutableLocation {
    public static var current: URL {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size))
        let result = buffer.withUnsafeMutableBufferPointer {
            _NSGetExecutablePath($0.baseAddress, &size)
        }
        guard result == 0 else {
            return URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self)).standardizedFileURL
    }

    public static func sibling(named name: String) -> URL {
        current.deletingLastPathComponent().appendingPathComponent(name, isDirectory: false)
    }
}
