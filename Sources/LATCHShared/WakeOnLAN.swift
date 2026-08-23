import Darwin
import Foundation

public enum WakeOnLANError: Error, Sendable, Equatable {
    case invalidMACAddress
    case invalidBroadcastAddress
    case invalidPort
}

public enum WakeOnLAN {
    public static let magicPacketLength = 102
    public static let packetCount = 3
    public static let packetInterval: TimeInterval = 0.25
    public static let defaultPort: UInt16 = 9

    public static func macBytes(_ macAddress: String) throws -> [UInt8] {
        let compact = macAddress.filter { $0.isHexDigit }
        guard compact.count == 12,
              macAddress.range(of: #"^(?:[0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}$"#, options: .regularExpression) != nil else {
            throw WakeOnLANError.invalidMACAddress
        }
        var bytes: [UInt8] = []
        var index = compact.startIndex
        for _ in 0..<6 {
            let end = compact.index(index, offsetBy: 2)
            guard let value = UInt8(compact[index..<end], radix: 16) else { throw WakeOnLANError.invalidMACAddress }
            bytes.append(value)
            index = end
        }
        return bytes
    }

    public static func magicPacket(macAddress: String) throws -> Data {
        let mac = try macBytes(macAddress)
        return Data(repeating: 0xff, count: 6) + Data((0..<16).flatMap { _ in mac })
    }

    public static func isIPv4Address(_ address: String) -> Bool {
        var parsed = in_addr()
        return inet_pton(AF_INET, address, &parsed) == 1
    }
}

public enum WakeTrigger: Sendable, Equatable {
    case automatic
    case manual
}

public enum WakeOnLANCooldown {
    public static let interval: TimeInterval = 300

    public static func allows(_ trigger: WakeTrigger, lastWake: Date?, now: Date) -> Bool {
        trigger == .manual || lastWake.map { now.timeIntervalSince($0) >= interval } ?? true
    }
}

public enum WakeOnLANPostWakeDisposition: Sendable, Equatable {
    case continueMonitoring
    case scheduleMissingMountRetry
}

/// Pure orchestration policy used by the daemon after its bounded NFS polling window.
public enum WakeOnLANOrchestration {
    public static func postWakeDisposition(reachable: Bool) -> WakeOnLANPostWakeDisposition {
        reachable ? .continueMonitoring : .scheduleMissingMountRetry
    }
}

public protocol WakeOnLANPacketSending: Sendable {
    func send(_ packet: Data, to broadcastAddress: String, port: UInt16) async throws
}

public protocol WakeOnLANBroadcastProviding: Sendable {
    func activeIPv4BroadcastAddresses() async -> [String]
}

public protocol WakeOnLANClock: Sendable {
    func now() async -> Date
}

public struct SystemWakeOnLANClock: WakeOnLANClock {
    public init() {}
    public func now() async -> Date { Date() }
}

public protocol WakeOnLANSleeping: Sendable {
    func sleep(for interval: TimeInterval) async
}

public struct TaskWakeOnLANSleeper: WakeOnLANSleeping {
    public init() {}
    public func sleep(for interval: TimeInterval) async { try? await Task.sleep(for: .seconds(interval)) }
}

public protocol WakeOnLANReachabilityChecking: Sendable {
    func isReachable(hostname: String, port: UInt16) async -> Bool
}

public protocol WakeOnLANStateStoring: Sendable {
    func lastWake(for serverID: UUID) async -> Date?
    func recordWake(_ date: Date, for serverID: UUID) async throws
}

public protocol AutomaticWakePerforming: Sendable {
    func wake(serverID: UUID, settings: WakeOnLANSettings) async throws -> Bool
    func waitUntilReachable(hostname: String) async -> Bool
}

public enum AutomaticWakeTransition: Sendable, Equatable {
    case noAction
    case continueMonitoring
    case scheduleMissingMountRetry
}

/// Coordinates the automatic wake path without depending on daemon-only mount operations.
public struct AutomaticWakeOrchestrator: Sendable {
    private let performer: any AutomaticWakePerforming

    public init(performer: any AutomaticWakePerforming) { self.performer = performer }

    public func transition(
        rulesSatisfied: Bool,
        nfsReachable: Bool,
        serverID: UUID,
        settings: WakeOnLANSettings?,
        hostname: String,
        onWakeSent: @escaping @Sendable () async -> Void = {}
    ) async throws -> AutomaticWakeTransition {
        guard rulesSatisfied, !nfsReachable, let settings else { return .noAction }
        guard try await performer.wake(serverID: serverID, settings: settings) else { return .noAction }
        await onWakeSent()
        return await performer.waitUntilReachable(hostname: hostname) ? .continueMonitoring : .scheduleMissingMountRetry
    }
}

/// Sends a standards-compliant magic packet while keeping the automatic wake rate limited per server.
public actor WakeOnLANController {
    private let sender: any WakeOnLANPacketSending
    private let broadcasts: any WakeOnLANBroadcastProviding
    private let clock: any WakeOnLANClock
    private let sleeper: any WakeOnLANSleeping
    private let state: any WakeOnLANStateStoring
    private var reservedServers = Set<UUID>()
    private var reservationWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]

    public init(sender: any WakeOnLANPacketSending, broadcasts: any WakeOnLANBroadcastProviding, clock: any WakeOnLANClock = SystemWakeOnLANClock(), sleeper: any WakeOnLANSleeping = TaskWakeOnLANSleeper(), state: any WakeOnLANStateStoring) {
        self.sender = sender
        self.broadcasts = broadcasts
        self.clock = clock
        self.sleeper = sleeper
        self.state = state
    }

    @discardableResult
    public func wake(serverID: UUID, settings: WakeOnLANSettings, trigger: WakeTrigger) async throws -> Bool {
        guard settings.port == WakeOnLAN.defaultPort else { throw WakeOnLANError.invalidPort }
        if reservedServers.contains(serverID) {
            guard trigger == .manual else { return false }
            await waitForReservationRelease(of: serverID)
            return try await wake(serverID: serverID, settings: settings, trigger: trigger)
        }
        // Reserve before the first suspension. This actor can otherwise re-enter while the persistent
        // state is read and allow several mounts sharing one server to send simultaneously.
        reservedServers.insert(serverID)
        defer { releaseReservation(of: serverID) }
        let now = await clock.now()
        guard WakeOnLANCooldown.allows(trigger, lastWake: await state.lastWake(for: serverID), now: now) else { return false }
        let packet = try WakeOnLAN.magicPacket(macAddress: settings.macAddress)
        let activeBroadcasts = Set(await broadcasts.activeIPv4BroadcastAddresses().filter(WakeOnLAN.isIPv4Address))
        let targets: [String]
        if let override = settings.broadcastAddress {
            guard activeBroadcasts.contains(override) else { throw WakeOnLANError.invalidBroadcastAddress }
            targets = [override]
        } else {
            targets = activeBroadcasts.sorted()
        }
        guard !targets.isEmpty else { return false }
        // Keep the reservation on sender failure. Retrying a partially sent packet can wake a server
        // repeatedly, so conservative rate limiting is safer than rollback.
        try await state.recordWake(now, for: serverID)
        for attempt in 0..<WakeOnLAN.packetCount {
            for target in targets { try await sender.send(packet, to: target, port: settings.port) }
            if attempt + 1 < WakeOnLAN.packetCount { await sleeper.sleep(for: WakeOnLAN.packetInterval) }
        }
        return true
    }

    public func waitUntilReachable(hostname: String, reachability: any WakeOnLANReachabilityChecking) async -> Bool {
        for attempt in 0...12 {
            if await reachability.isReachable(hostname: hostname, port: 2049) { return true }
            if attempt < 12 { await sleeper.sleep(for: 5) }
        }
        return false
    }

    private func waitForReservationRelease(of serverID: UUID) async {
        await withCheckedContinuation { continuation in
            // This recheck and waiter registration run under the actor's isolation. A reservation
            // released between the caller's observation and this point therefore cannot lose wakeup.
            guard reservedServers.contains(serverID) else {
                continuation.resume()
                return
            }
            reservationWaiters[serverID, default: []].append(continuation)
        }
    }

    private func releaseReservation(of serverID: UUID) {
        reservedServers.remove(serverID)
        let waiters = reservationWaiters.removeValue(forKey: serverID) ?? []
        for waiter in waiters { waiter.resume() }
    }
}
