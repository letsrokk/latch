@preconcurrency import Network
import Darwin
import CoreWLAN
import Foundation
import LATCHShared
import IOKit.pwr_mgt

final class NativeNetworkSnapshotProvider: NetworkSnapshotProviding, @unchecked Sendable {
    func snapshot(for hostname: String) async -> NetworkSnapshot {
        let interfaces = activeInterfaces()
        let wifiNames = Set([CWWiFiClient.shared().interface()?.interfaceName].compactMap { $0 })
        return .init(
            nfsServiceReachable: await NFSReachability.check(hostname),
            routes: kernelRouteCIDRs(),
            interfaces: interfaces.map { interfaceSnapshot($0, wifiNames: wifiNames) }
        )
    }

    private func activeInterfaces() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let head else { return [] }
        defer { freeifaddrs(head) }
        var result = Set<String>()
        var cursor: UnsafeMutablePointer<ifaddrs>? = head
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr,
                  [UInt8(AF_INET), UInt8(AF_INET6)].contains(address.pointee.sa_family),
                  let rawName = entry.pointee.ifa_name else { continue }
            let flags = entry.pointee.ifa_flags
            guard (flags & UInt32(IFF_UP)) != 0, (flags & UInt32(IFF_RUNNING)) != 0 else { continue }
            result.insert(String(cString: rawName))
        }
        return result.sorted()
    }

    private func interfaceSnapshot(_ name: String, wifiNames: Set<String>) -> NetworkInterfaceSnapshot {
        let tunnel = name.hasPrefix("utun") || name.hasPrefix("ppp") || name.hasPrefix("ipsec")
        let type: NetworkInterfaceType
        if tunnel { type = .other }
        else if wifiNames.contains(name) { type = .wifi }
        else if name.hasPrefix("en") { type = .ethernet }
        else { type = .other }
        return .init(name: name, type: type, isActive: true, isTunnel: tunnel)
    }

    private func kernelRouteCIDRs() -> [String] {
        var mib = [CTL_NET, PF_ROUTE, 0, AF_UNSPEC, NET_RT_DUMP2, 0]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }
        var bytes = [UInt8](repeating: 0, count: size)
        guard bytes.withUnsafeMutableBytes({ sysctl(&mib, u_int(mib.count), $0.baseAddress, &size, nil, 0) }) == 0 else { return [] }
        return bytes.withUnsafeBytes { KernelRouteTableParser.parse($0) }
    }
}

private enum KernelRouteTableParser {
    static func parse(_ bytes: UnsafeRawBufferPointer) -> [String] {
        var result = Set<String>()
        var offset = 0
        while offset + MemoryLayout<rt_msghdr2>.size <= bytes.count {
            let header = bytes.baseAddress!.advanced(by: offset).assumingMemoryBound(to: rt_msghdr2.self).pointee
            let length = Int(header.rtm_msglen)
            guard length >= MemoryLayout<rt_msghdr2>.size, offset + length <= bytes.count else { break }
            let flags = header.rtm_flags
            guard KernelRouteFixtureParser.accepts(
                isUp: (flags & Int32(RTF_UP)) != 0,
                isReject: (flags & Int32(RTF_REJECT)) != 0,
                isBlackhole: (flags & Int32(RTF_BLACKHOLE)) != 0
            ) else {
                offset += length
                continue
            }
            let addresses = decodeAddresses(bytes.baseAddress!.advanced(by: offset + MemoryLayout<rt_msghdr2>.size), length: length - MemoryLayout<rt_msghdr2>.size, mask: header.rtm_addrs)
            if let destination = addresses[Int(RTAX_DST)], let netmask = addresses[Int(RTAX_NETMASK)], let cidr = cidr(destination: destination, netmask: netmask) { result.insert(cidr) }
            offset += length
        }
        return result.sorted()
    }

    private static func decodeAddresses(_ start: UnsafeRawPointer, length: Int, mask: Int32) -> [Int: UnsafeRawPointer] {
        var values: [Int: UnsafeRawPointer] = [:]
        var pointer = start
        let end = start.advanced(by: length)
        for index in 0..<Int(RTAX_MAX) where (mask & (1 << Int32(index))) != 0 {
            guard pointer < end else { break }
            values[index] = pointer
            let sockaddr = pointer.assumingMemoryBound(to: sockaddr.self).pointee
            let stride = max(Int(sockaddr.sa_len), MemoryLayout<sockaddr>.size)
            pointer = pointer.advanced(by: (stride + 3) & ~3)
        }
        return values
    }

    private static func cidr(destination: UnsafeRawPointer, netmask: UnsafeRawPointer) -> String? {
        let family = destination.assumingMemoryBound(to: sockaddr.self).pointee.sa_family
        if family == UInt8(AF_INET) {
            let address = destination.assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr.s_addr.bigEndian
            let mask = netmask.assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr.s_addr.bigEndian
            let prefix = mask.nonzeroBitCount
            guard mask == (prefix == 0 ? 0 : UInt32.max << UInt32(32 - prefix)) else { return nil }
            let network = address & mask
            return "\((network >> 24) & 255).\((network >> 16) & 255).\((network >> 8) & 255).\(network & 255)/\(prefix)"
        }
        if family == UInt8(AF_INET6) {
            var address = destination.assumingMemoryBound(to: sockaddr_in6.self).pointee.sin6_addr
            var mask = netmask.assumingMemoryBound(to: sockaddr_in6.self).pointee.sin6_addr
            let prefix = withUnsafeBytes(of: &mask) { $0.reduce(0) { $0 + $1.nonzeroBitCount } }
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(AF_INET6, &address, &buffer, socklen_t(buffer.count)) != nil else { return nil }
            let text = String(decoding: buffer.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
            return "\(text)/\(prefix)"
        }
        return nil
    }
}

private enum NFSReachability {
    static func check(_ hostname: String) async -> Bool {
        await withCheckedContinuation { continuation in
            let connection = NWConnection(host: .init(hostname), port: 2049, using: .tcp)
            let completion = ConnectionCompletion(continuation: continuation, connection: connection)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: completion.finish(true)
                case .failed, .cancelled: completion.finish(false)
                default: break
                }
            }
            connection.start(queue: .global(qos: .utility))
            Task {
                try? await Task.sleep(for: .seconds(3))
                completion.finish(false)
            }
        }
    }
}

private final class ConnectionCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private let connection: NWConnection

    init(continuation: CheckedContinuation<Bool, Never>, connection: NWConnection) {
        self.continuation = continuation
        self.connection = connection
    }

    func finish(_ value: Bool) {
        let callback = lock.withLock { () -> CheckedContinuation<Bool, Never>? in
            defer { continuation = nil }
            return continuation
        }
        connection.cancel()
        callback?.resume(returning: value)
    }
}

final class NetworkPathObserver: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "\(LATCHIdentity.bundleIdentifier).network-path")

    init(onChange: @escaping @Sendable () -> Void) {
        monitor.pathUpdateHandler = { _ in onChange() }
        monitor.start(queue: queue)
    }

    deinit { monitor.cancel() }
}

final class SystemWakeObserver: @unchecked Sendable {
    private let callbackBox: WakeCallbackBox
    private var notificationPort: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private var rootPort: io_connect_t = 0

    init(onWake: @escaping @Sendable () -> Void) {
        callbackBox = WakeCallbackBox(onWake: onWake)
        var port: IONotificationPortRef?
        rootPort = IORegisterForSystemPower(
            Unmanaged.passUnretained(callbackBox).toOpaque(),
            &port,
            { reference, _, messageType, _ in
                // kIOMessageSystemHasPoweredOn is unavailable to Swift because it is a C macro.
                guard messageType == 0xE0000300, let reference else { return }
                Unmanaged<WakeCallbackBox>.fromOpaque(reference).takeUnretainedValue().wake()
            },
            &notifier
        )
        notificationPort = port
        if let port, let source = IONotificationPortGetRunLoopSource(port) {
            CFRunLoopAddSource(CFRunLoopGetMain(), source.takeUnretainedValue(), .defaultMode)
        }
    }

    deinit {
        if notifier != 0 { IOObjectRelease(notifier) }
        if rootPort != 0 { IOServiceClose(rootPort) }
        if let notificationPort { IONotificationPortDestroy(notificationPort) }
    }
}

private final class WakeCallbackBox: @unchecked Sendable {
    private let onWake: @Sendable () -> Void
    init(onWake: @escaping @Sendable () -> Void) { self.onWake = onWake }
    func wake() { onWake() }
}
