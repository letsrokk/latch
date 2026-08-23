import Foundation
import Testing
@testable import LATCHShared

@Suite("Wake-on-LAN")
struct WakeOnLANTests {
    @Test func magicPacketUsesHeaderFollowedBySixteenMACCopies() throws {
        let packet = try WakeOnLAN.magicPacket(macAddress: "aA:bB:cC:dD:eE:fF")

        #expect(packet.count == 102)
        #expect(Array(packet.prefix(6)) == [255, 255, 255, 255, 255, 255])
        #expect(Array(packet.dropFirst(6).prefix(6)) == [170, 187, 204, 221, 238, 255])
        #expect(Array(packet.suffix(6)) == [170, 187, 204, 221, 238, 255])
    }

    @Test func malformedMACIsRejectedWhenSavingAServer() {
        let configuration = LATCHConfiguration(servers: [.init(name: "NAS", hostname: "nas.local", wakeOnLAN: .init(macAddress: "not-a-mac"))])

        #expect(throws: ConfigurationValidationError.invalidWakeOnLAN) {
            try ConfigurationValidator().validate(configuration, liveMounts: [])
        }
    }

    @Test func invalidBroadcastAddressIsRejectedWhenSavingAServer() {
        let configuration = LATCHConfiguration(servers: [.init(name: "NAS", hostname: "nas.local", wakeOnLAN: .init(macAddress: "aa:bb:cc:dd:ee:ff", broadcastAddress: "not-an-ip"))])

        #expect(throws: ConfigurationValidationError.invalidWakeOnLAN) {
            try ConfigurationValidator().validate(configuration, liveMounts: [])
        }
    }

    @Test func portOtherThanNineIsRejectedWhenSavingAServer() {
        let configuration = LATCHConfiguration(servers: [.init(name: "NAS", hostname: "nas.local", wakeOnLAN: .init(macAddress: "aa:bb:cc:dd:ee:ff", port: 7))])

        #expect(throws: ConfigurationValidationError.invalidWakeOnLAN) {
            try ConfigurationValidator().validate(configuration, liveMounts: [])
        }
    }

    @Test func controllerRejectsNonStandardPortEvenIfUnvalidatedConfigurationReachedIt() async {
        let controller = WakeOnLANController(sender: RecordingPacketSender(), broadcasts: StaticBroadcastProvider(["192.168.1.255"]), clock: FixedWakeClock(.now), sleeper: RecordingSleeper(), state: RecordingWakeState())

        await #expect(throws: WakeOnLANError.invalidPort) {
            try await controller.wake(serverID: UUID(), settings: .init(macAddress: "aa:bb:cc:dd:ee:ff", port: 7), trigger: .manual)
        }
    }

    @Test func automaticWakeIsLimitedPerServerButManualWakeBypassesCooldown() {
        let now = Date(timeIntervalSince1970: 10_000)
        let recent = now.addingTimeInterval(-299)

        #expect(WakeOnLANCooldown.allows(.automatic, lastWake: recent, now: now) == false)
        #expect(WakeOnLANCooldown.allows(.manual, lastWake: recent, now: now))
        #expect(WakeOnLANCooldown.allows(.automatic, lastWake: now.addingTimeInterval(-300), now: now))
    }

    @Test func controllerSendsThreePacketsToEveryActiveBroadcastWithQuarterSecondDelays() async throws {
        let sender = RecordingPacketSender()
        let sleeper = RecordingSleeper()
        let state = RecordingWakeState()
        let now = Date(timeIntervalSince1970: 10_000)
        let controller = WakeOnLANController(sender: sender, broadcasts: StaticBroadcastProvider(["192.168.1.255", "10.0.0.255"]), clock: FixedWakeClock(now), sleeper: sleeper, state: state)

        #expect(try await controller.wake(serverID: UUID(), settings: .init(macAddress: "aa:bb:cc:dd:ee:ff"), trigger: .automatic))
        #expect(await sender.calls.count == 6)
        #expect(await sender.calls.allSatisfy { $0.packet.count == 102 && $0.port == 9 })
        #expect(await sleeper.intervals == [0.25, 0.25])
    }

    @Test func controllerRejectsOverrideThatIsNotAnActiveBroadcast() async {
        let sender = RecordingPacketSender()
        let controller = WakeOnLANController(sender: sender, broadcasts: StaticBroadcastProvider(["192.168.1.255"]), clock: FixedWakeClock(.now), sleeper: RecordingSleeper(), state: RecordingWakeState())

        await #expect(throws: WakeOnLANError.invalidBroadcastAddress) {
            try await controller.wake(serverID: UUID(), settings: .init(macAddress: "aa:bb:cc:dd:ee:ff", broadcastAddress: "10.0.0.255"), trigger: .manual)
        }
        #expect(await sender.calls.isEmpty)
    }

    @Test func controllerUsesOnlyTheValidatedActiveOverride() async throws {
        let sender = RecordingPacketSender()
        let controller = WakeOnLANController(sender: sender, broadcasts: StaticBroadcastProvider(["192.168.1.255", "10.0.0.255"]), clock: FixedWakeClock(.now), sleeper: RecordingSleeper(), state: RecordingWakeState())

        #expect(try await controller.wake(serverID: UUID(), settings: .init(macAddress: "aa:bb:cc:dd:ee:ff", broadcastAddress: "10.0.0.255"), trigger: .manual))
        #expect(await sender.calls.map(\.address) == ["10.0.0.255", "10.0.0.255", "10.0.0.255"])
    }

    @Test func automaticWakeReservesPersistedServerCooldownBeforeSending() async throws {
        let sender = RecordingPacketSender()
        let state = GatedLastWakeState()
        let now = Date(timeIntervalSince1970: 10_000)
        let controller = WakeOnLANController(sender: sender, broadcasts: StaticBroadcastProvider(["192.168.1.255"]), clock: FixedWakeClock(now), sleeper: RecordingSleeper(), state: state)
        let serverID = UUID()

        async let first: Bool = controller.wake(serverID: serverID, settings: .init(macAddress: "aa:bb:cc:dd:ee:ff"), trigger: .automatic)
        await state.waitUntilFirstRead()
        async let second: Bool = controller.wake(serverID: serverID, settings: .init(macAddress: "aa:bb:cc:dd:ee:ff"), trigger: .automatic)
        await Task.yield()
        #expect(await state.readCount == 1)
        await state.releaseFirstRead()
        #expect(try await [first, second].filter { $0 }.count == 1)
        #expect(await state.lastWake(for: serverID) == now)
        #expect(await sender.calls.count == 3)
    }

    @Test func manualWakeWaitsForAnInFlightAutomaticWakeThenSends() async throws {
        let sender = RecordingPacketSender()
        let clock = GatedWakeClock(Date(timeIntervalSince1970: 10_000))
        let controller = WakeOnLANController(sender: sender, broadcasts: StaticBroadcastProvider(["192.168.1.255"]), clock: clock, sleeper: RecordingSleeper(), state: RecordingWakeState())
        let serverID = UUID()

        async let automatic: Bool = controller.wake(serverID: serverID, settings: .init(macAddress: "aa:bb:cc:dd:ee:ff"), trigger: .automatic)
        await clock.waitUntilFirstRead()
        async let manual: Bool = controller.wake(serverID: serverID, settings: .init(macAddress: "aa:bb:cc:dd:ee:ff"), trigger: .manual)
        await Task.yield()
        await clock.releaseFirstRead()

        #expect(try await automatic)
        #expect(try await manual)
        #expect(await sender.calls.count == 6)
    }

    @Test func gatedClockRetainsItsFirstReadSignalUntilTheWaiterRegisters() async {
        let clock = GatedWakeClock(.now)
        let read = Task { await clock.now() }
        await Task.yield()

        await clock.waitUntilFirstRead()
        await clock.releaseFirstRead()
        _ = await read.value
    }

    @Test func gatedLastWakeStateRetainsItsFirstReadSignalUntilTheWaiterRegisters() async {
        let state = GatedLastWakeState()
        let serverID = UUID()
        let read = Task { await state.lastWake(for: serverID) }
        await Task.yield()

        await state.waitUntilFirstRead()
        await state.releaseFirstRead()
        _ = await read.value
    }

    @Test func senderFailureRetainsThePersistedAutomaticReservation() async {
        let now = Date(timeIntervalSince1970: 10_000)
        let serverID = UUID()
        let state = RecordingWakeState()
        let controller = WakeOnLANController(sender: FailingPacketSender(), broadcasts: StaticBroadcastProvider(["192.168.1.255"]), clock: FixedWakeClock(now), sleeper: RecordingSleeper(), state: state)

        await #expect(throws: TestWakeError.sendFailed) {
            try await controller.wake(serverID: serverID, settings: .init(macAddress: "aa:bb:cc:dd:ee:ff"), trigger: .automatic)
        }
        #expect(await state.lastWake(for: serverID) == now)
    }

    @Test func manualWakeBypassesPersistedAutomaticCooldown() async throws {
        let sender = RecordingPacketSender()
        let now = Date(timeIntervalSince1970: 10_000)
        let serverID = UUID()
        let state = RecordingWakeState(values: [serverID: now.addingTimeInterval(-1)])
        let controller = WakeOnLANController(sender: sender, broadcasts: StaticBroadcastProvider(["192.168.1.255"]), clock: FixedWakeClock(now), sleeper: RecordingSleeper(), state: state)

        #expect(try await controller.wake(serverID: serverID, settings: .init(macAddress: "aa:bb:cc:dd:ee:ff"), trigger: .manual))
        #expect(await sender.calls.count == 3)
    }

    @Test func postWakePollingChecksTCPEveryFiveSecondsForSixtySecondsAndSchedulesBackoffWhenUnavailable() async {
        let sleeper = RecordingSleeper()
        let controller = WakeOnLANController(sender: RecordingPacketSender(), broadcasts: StaticBroadcastProvider([]), sleeper: sleeper, state: RecordingWakeState())
        let reachability = AlwaysUnreachable()

        #expect(await controller.waitUntilReachable(hostname: "nas.local", reachability: reachability) == false)
        #expect(await reachability.calls == 13)
        #expect(await sleeper.intervals == Array(repeating: 5, count: 12))
        #expect(WakeOnLANOrchestration.postWakeDisposition(reachable: false) == .scheduleMissingMountRetry)
    }

    @Test func automaticWakeTransitionSchedulesMissingMountRetryAfterWakePollTimeout() async throws {
        let performer = RecordingAutomaticWakePerformer(wakeResult: true, reachableResult: false)
        let orchestrator = AutomaticWakeOrchestrator(performer: performer)
        let woke = WakeSignal()

        let transition = try await orchestrator.transition(
            rulesSatisfied: true,
            nfsReachable: false,
            serverID: UUID(),
            settings: .init(macAddress: "aa:bb:cc:dd:ee:ff"),
            hostname: "nas.local",
            onWakeSent: { await woke.mark() }
        )

        #expect(await woke.value)
        #expect(transition == .scheduleMissingMountRetry)
        #expect(await performer.wakeCalls == 1)
        #expect(await performer.pollCalls == 1)
    }
}

private actor RecordingPacketSender: WakeOnLANPacketSending {
    struct Call: Sendable { let packet: Data; let address: String; let port: UInt16 }
    var calls: [Call] = []
    func send(_ packet: Data, to broadcastAddress: String, port: UInt16) { calls.append(.init(packet: packet, address: broadcastAddress, port: port)) }
}

private struct StaticBroadcastProvider: WakeOnLANBroadcastProviding {
    let addresses: [String]
    init(_ addresses: [String]) { self.addresses = addresses }
    func activeIPv4BroadcastAddresses() async -> [String] { addresses }
}

private struct FixedWakeClock: WakeOnLANClock {
    let value: Date
    init(_ value: Date) { self.value = value }
    func now() async -> Date { value }
}

private actor RecordingSleeper: WakeOnLANSleeping {
    var intervals: [TimeInterval] = []
    func sleep(for interval: TimeInterval) { intervals.append(interval) }
}

private actor RecordingWakeState: WakeOnLANStateStoring {
    var values: [UUID: Date]
    init(values: [UUID: Date] = [:]) { self.values = values }
    func lastWake(for serverID: UUID) -> Date? { values[serverID] }
    func recordWake(_ date: Date, for serverID: UUID) { values[serverID] = date }
}

private actor GatedLastWakeState: WakeOnLANStateStoring {
    var values: [UUID: Date] = [:]
    var readCount = 0
    private var didReachFirstRead = false
    private var firstReadWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func lastWake(for serverID: UUID) async -> Date? {
        readCount += 1
        if readCount == 1 {
            didReachFirstRead = true
            firstReadWaiter?.resume()
            firstReadWaiter = nil
            await withCheckedContinuation { releaseWaiter = $0 }
        }
        return values[serverID]
    }

    func recordWake(_ date: Date, for serverID: UUID) { values[serverID] = date }
    func waitUntilFirstRead() async {
        guard !didReachFirstRead else { return }
        await withCheckedContinuation { firstReadWaiter = $0 }
    }
    func releaseFirstRead() { releaseWaiter?.resume(); releaseWaiter = nil }
}

private actor GatedWakeClock: WakeOnLANClock {
    let value: Date
    private var reads = 0
    private var didReachFirstRead = false
    private var firstReadWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    init(_ value: Date) { self.value = value }
    func now() async -> Date {
        reads += 1
        if reads == 1 {
            didReachFirstRead = true
            firstReadWaiter?.resume()
            firstReadWaiter = nil
            await withCheckedContinuation { releaseWaiter = $0 }
        }
        return value
    }
    func waitUntilFirstRead() async {
        guard !didReachFirstRead else { return }
        await withCheckedContinuation { firstReadWaiter = $0 }
    }
    func releaseFirstRead() { releaseWaiter?.resume(); releaseWaiter = nil }
}

private actor AlwaysUnreachable: WakeOnLANReachabilityChecking {
    var calls = 0
    func isReachable(hostname: String, port: UInt16) -> Bool { calls += 1; return false }
}

private struct FailingPacketSender: WakeOnLANPacketSending {
    func send(_ packet: Data, to broadcastAddress: String, port: UInt16) async throws { throw TestWakeError.sendFailed }
}

private enum TestWakeError: Error, Equatable { case sendFailed }

private actor WakeSignal {
    var value = false
    func mark() { value = true }
}

private actor RecordingAutomaticWakePerformer: AutomaticWakePerforming {
    let wakeResult: Bool
    let reachableResult: Bool
    var wakeCalls = 0
    var pollCalls = 0
    init(wakeResult: Bool, reachableResult: Bool) { self.wakeResult = wakeResult; self.reachableResult = reachableResult }
    func wake(serverID: UUID, settings: WakeOnLANSettings) -> Bool { wakeCalls += 1; return wakeResult }
    func waitUntilReachable(hostname: String) -> Bool { pollCalls += 1; return reachableResult }
}
