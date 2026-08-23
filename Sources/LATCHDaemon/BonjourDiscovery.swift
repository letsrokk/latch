@preconcurrency import Network
import Foundation
import LATCHShared

/// Browses only the advertised NFS Bonjour service. It never scans subnets or enumerates exports.
final class BonjourNFSServerDiscovery: @unchecked Sendable {
    private let lock = NSLock()
    private let browser: NWBrowser
    private let resolver: any BonjourServiceResolving
    private let queue = DispatchQueue(label: "\(LATCHIdentity.bundleIdentifier).nfs-bonjour", qos: .utility)
    private var servers: [DiscoveredNFSServer] = []
    private var revision: UInt64 = 0
    private var resolutionTask: Task<Void, Never>?

    init(resolver: any BonjourServiceResolving = NativeBonjourServiceResolver()) {
        self.resolver = resolver
        browser = NWBrowser(for: .bonjour(type: "_nfs._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.replace(results.compactMap(Self.descriptor))
        }
        browser.start(queue: queue)
    }

    deinit {
        browser.cancel()
        resolutionTask?.cancel()
    }

    func snapshots() -> [DiscoveredNFSServer] { lock.withLock { servers } }

    private func replace(_ services: [BonjourServiceDescriptor]) {
        let update = lock.withLock { () -> (UInt64, Task<Void, Never>?) in
            revision &+= 1
            let currentRevision = revision
            let previous = resolutionTask
            resolutionTask = nil
            return (currentRevision, previous)
        }
        update.1?.cancel()

        let resolver = resolver
        let task = Task { [weak self] in
            let snapshots = await BonjourResolutionBatch.resolve(services, resolver: resolver, timeout: 3)
            guard !Task.isCancelled else { return }
            self?.publish(snapshots, revision: update.0)
        }
        lock.withLock {
            guard revision == update.0 else {
                task.cancel()
                return
            }
            resolutionTask = task
        }
    }

    private func publish(_ snapshots: [DiscoveredNFSServer], revision candidate: UInt64) {
        lock.withLock {
            guard revision == candidate else { return }
            servers = snapshots
            resolutionTask = nil
        }
    }

    private static func descriptor(_ result: NWBrowser.Result) -> BonjourServiceDescriptor? {
        guard case let .service(name, type, domain, interface) = result.endpoint else { return nil }
        return .init(name: name, type: type, domain: domain, interfaceIndex: interface?.index)
    }
}

private final class NativeBonjourServiceResolver: BonjourServiceResolving, @unchecked Sendable {
    private let lock = NSLock()
    private var resolutions: [UUID: NetServiceResolution] = [:]

    func resolve(_ descriptor: BonjourServiceDescriptor, timeout: TimeInterval) async -> DiscoveredNFSServer? {
        let identifier = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let resolution = NetServiceResolution(descriptor: descriptor, timeout: timeout) { [weak self] result in
                    self?.lock.withLock { self?.resolutions[identifier] = nil }
                    continuation.resume(returning: result)
                }
                lock.withLock { resolutions[identifier] = resolution }
                DispatchQueue.main.async { resolution.start() }
            }
        } onCancel: { [weak self] in
            let resolution = self?.lock.withLock { self?.resolutions[identifier] }
            resolution?.cancel()
        }
    }
}

private final class NetServiceResolution: NSObject, NetServiceDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let service: NetService
    private let name: String
    private let timeout: TimeInterval
    private let completion: @Sendable (DiscoveredNFSServer?) -> Void
    private var completed = false

    init(
        descriptor: BonjourServiceDescriptor,
        timeout: TimeInterval,
        completion: @escaping @Sendable (DiscoveredNFSServer?) -> Void
    ) {
        name = descriptor.name
        self.timeout = timeout
        self.completion = completion
        let type = descriptor.type.hasSuffix(".") ? descriptor.type : descriptor.type + "."
        service = NetService(domain: descriptor.domain, type: type, name: descriptor.name)
    }

    func start() {
        guard !lock.withLock({ completed }) else { return }
        service.delegate = self
        service.schedule(in: .main, forMode: .default)
        service.resolve(withTimeout: timeout)
    }

    func cancel() {
        DispatchQueue.main.async { [self] in
            service.stop()
            finish(nil)
        }
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let hostname = sender.hostName, (1...Int(UInt16.max)).contains(sender.port) else {
            finish(nil)
            return
        }
        finish(.init(name: name, hostname: hostname, port: UInt16(sender.port)))
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        _ = errorDict
        finish(nil)
    }

    private func finish(_ result: DiscoveredNFSServer?) {
        let shouldComplete = lock.withLock { () -> Bool in
            guard !completed else { return false }
            completed = true
            return true
        }
        guard shouldComplete else { return }
        service.stop()
        service.remove(from: .main, forMode: .default)
        completion(result)
    }
}
