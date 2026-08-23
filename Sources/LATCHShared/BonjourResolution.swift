import Foundation

public struct BonjourServiceDescriptor: Hashable, Sendable {
    public let name: String
    public let type: String
    public let domain: String
    public let interfaceIndex: Int?

    public init(name: String, type: String, domain: String, interfaceIndex: Int? = nil) {
        self.name = name
        self.type = type
        self.domain = domain
        self.interfaceIndex = interfaceIndex
    }
}

public protocol BonjourServiceResolving: Sendable {
    func resolve(_ service: BonjourServiceDescriptor, timeout: TimeInterval) async -> DiscoveredNFSServer?
}

public enum BonjourResolutionBatch {
    public static func resolve(
        _ services: [BonjourServiceDescriptor],
        resolver: any BonjourServiceResolving,
        timeout: TimeInterval
    ) async -> [DiscoveredNFSServer] {
        let uniqueServices = Array(Set(services))
        let resolved = await withTaskGroup(of: DiscoveredNFSServer?.self) { group in
            for service in uniqueServices {
                group.addTask {
                    await resolve(service, resolver: resolver, timeout: timeout)
                }
            }
            var values: [DiscoveredNFSServer] = []
            for await value in group {
                if let value { values.append(value) }
            }
            return values
        }

        var deduplicated: [String: DiscoveredNFSServer] = [:]
        for server in resolved.sorted(by: stableOrder) {
            guard let hostname = server.hostname else { continue }
            let key = "\(hostname.lowercased()):\(server.port)"
            if deduplicated[key] == nil { deduplicated[key] = server }
        }
        return deduplicated.values.sorted(by: stableOrder)
    }

    private static func resolve(
        _ service: BonjourServiceDescriptor,
        resolver: any BonjourServiceResolving,
        timeout: TimeInterval
    ) async -> DiscoveredNFSServer? {
        await withTaskGroup(of: DiscoveredNFSServer?.self) { group in
            group.addTask { await resolver.resolve(service, timeout: timeout) }
            group.addTask {
                let nanoseconds = UInt64(max(0, timeout) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            guard var server = first,
                  server.port != 0,
                  let hostname = normalizedHostname(server.hostname) else { return nil }
            server.hostname = hostname
            return server
        }
    }

    private static func normalizedHostname(_ value: String?) -> String? {
        guard var hostname = value?.trimmingCharacters(in: .whitespacesAndNewlines), !hostname.isEmpty else {
            return nil
        }
        while hostname.hasSuffix(".") { hostname.removeLast() }
        return hostname.isEmpty ? nil : hostname
    }

    private static func stableOrder(_ left: DiscoveredNFSServer, _ right: DiscoveredNFSServer) -> Bool {
        let nameOrder = left.name.localizedCaseInsensitiveCompare(right.name)
        if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
        let leftHost = left.hostname ?? ""
        let rightHost = right.hostname ?? ""
        if leftHost.caseInsensitiveCompare(rightHost) != .orderedSame {
            return leftHost.caseInsensitiveCompare(rightHost) == .orderedAscending
        }
        return left.port < right.port
    }
}

public extension DiscoveredNFSServer {
    var configurationTemplate: NFSServerProfile? {
        guard var hostname = hostname?.trimmingCharacters(in: .whitespacesAndNewlines), !hostname.isEmpty else {
            return nil
        }
        while hostname.hasSuffix(".") { hostname.removeLast() }
        guard !hostname.isEmpty else { return nil }
        let profile = NFSServerProfile(name: name, hostname: hostname)
        guard (try? ConfigurationValidator().validate(LATCHConfiguration(servers: [profile]), liveMounts: [])) != nil else {
            return nil
        }
        return profile
    }
}
