import Foundation
import Testing
@testable import LATCHShared

@Suite("Bonjour NFS discovery")
struct BonjourDiscoveryTests {
    @Test func resolutionPublishesOnlyConcreteHostsAndUsesABoundedTimeout() async {
        let resolved = BonjourServiceDescriptor(name: "Media", type: "_nfs._tcp", domain: "local.", interfaceIndex: 4)
        let unresolved = BonjourServiceDescriptor(name: "Offline", type: "_nfs._tcp", domain: "local.", interfaceIndex: 4)
        let resolver = FakeBonjourServiceResolver(values: [
            resolved: .init(name: "Media", hostname: "nas.local", port: 2049),
        ])

        let snapshots = await BonjourResolutionBatch.resolve(
            [resolved, unresolved],
            resolver: resolver,
            timeout: 0.25
        )

        #expect(snapshots == [.init(name: "Media", hostname: "nas.local", port: 2049)])
        #expect(await resolver.timeouts == [0.25, 0.25])
    }

    @Test func resolutionDeduplicatesServicesThatReachTheSameHostAndPort() async {
        let first = BonjourServiceDescriptor(name: "A Media", type: "_nfs._tcp", domain: "local.")
        let second = BonjourServiceDescriptor(name: "Z Duplicate", type: "_nfs._tcp", domain: "local.", interfaceIndex: 7)
        let resolver = FakeBonjourServiceResolver(values: [
            first: .init(name: first.name, hostname: "NAS.local.", port: 2049),
            second: .init(name: second.name, hostname: "nas.local", port: 2049),
        ])

        let snapshots = await BonjourResolutionBatch.resolve([second, first], resolver: resolver, timeout: 1)

        #expect(snapshots == [.init(name: "A Media", hostname: "NAS.local", port: 2049)])
    }

    @Test func resolutionStopsWaitingAtTheBatchTimeout() async {
        let service = BonjourServiceDescriptor(name: "Slow", type: "_nfs._tcp", domain: "local.")
        let clock = ContinuousClock()
        let started = clock.now

        let snapshots = await BonjourResolutionBatch.resolve(
            [service],
            resolver: SlowBonjourServiceResolver(),
            timeout: 0.01
        )

        #expect(snapshots.isEmpty)
        #expect(clock.now - started < .seconds(1))
    }

    @Test func configurationTemplateRequiresAResolvedHostname() {
        #expect(DiscoveredNFSServer(name: "Unresolved").configurationTemplate == nil)
        #expect(DiscoveredNFSServer(name: "Empty", hostname: "  ").configurationTemplate == nil)

        let template = DiscoveredNFSServer(name: "Media", hostname: "nas.local.").configurationTemplate
        #expect(template?.name == "Media")
        #expect(template?.hostname == "nas.local")
    }
}

private struct SlowBonjourServiceResolver: BonjourServiceResolving {
    func resolve(_ service: BonjourServiceDescriptor, timeout: TimeInterval) async -> DiscoveredNFSServer? {
        _ = service
        _ = timeout
        do { try await Task.sleep(for: .seconds(60)) }
        catch { return nil }
        return .init(name: "Slow", hostname: "too-late.local")
    }
}

private actor FakeBonjourServiceResolver: BonjourServiceResolving {
    private let values: [BonjourServiceDescriptor: DiscoveredNFSServer]
    private(set) var timeouts: [TimeInterval] = []

    init(values: [BonjourServiceDescriptor: DiscoveredNFSServer]) {
        self.values = values
    }

    func resolve(_ service: BonjourServiceDescriptor, timeout: TimeInterval) async -> DiscoveredNFSServer? {
        timeouts.append(timeout)
        return values[service]
    }
}
