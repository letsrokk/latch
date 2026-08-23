import Darwin
import Foundation

public struct NetworkInterfaceSnapshot: Sendable, Equatable {
    public var name: String
    public var type: NetworkInterfaceType
    public var isActive: Bool
    public var isTunnel: Bool

    public init(name: String, type: NetworkInterfaceType, isActive: Bool, isTunnel: Bool = false) {
        self.name = name
        self.type = type
        self.isActive = isActive
        self.isTunnel = isTunnel
    }
}

public struct NetworkSnapshot: Sendable, Equatable {
    public var nfsServiceReachable: Bool
    public var routes: [String]
    public var interfaces: [NetworkInterfaceSnapshot]

    public init(nfsServiceReachable: Bool = false, routes: [String] = [], interfaces: [NetworkInterfaceSnapshot] = []) {
        self.nfsServiceReachable = nfsServiceReachable
        self.routes = routes
        self.interfaces = interfaces
    }
}

public protocol NetworkSnapshotProviding: Sendable {
    func snapshot(for hostname: String) async -> NetworkSnapshot
}

public struct StaticNetworkSnapshotProvider: NetworkSnapshotProviding {
    public var value: NetworkSnapshot
    public init(_ value: NetworkSnapshot) { self.value = value }
    public func snapshot(for hostname: String) async -> NetworkSnapshot { value }
}

public struct NetworkRuleEvaluation: Sendable, Equatable {
    public var isSatisfied: Bool
    public var unmetRuleSummaries: [String]

    public init(isSatisfied: Bool, unmetRuleSummaries: [String]) {
        self.isSatisfied = isSatisfied
        self.unmetRuleSummaries = unmetRuleSummaries
    }
}

public enum NetworkAutomaticWorkDisposition: Sendable, Equatable {
    case proceed
    case retryScheduled
    case waitingForRules([String])

    public static func resolve(ruleEvaluation: NetworkRuleEvaluation?, retry: AutomaticRetryState?, now: Date, rulesJustSatisfied: Bool = false) -> Self {
        if let ruleEvaluation, !ruleEvaluation.isSatisfied { return .waitingForRules(ruleEvaluation.unmetRuleSummaries) }
        if rulesJustSatisfied { return .proceed }
        if let retry, retry.nextAttempt > now { return .retryScheduled }
        return .proceed
    }
}

public enum NetworkRuleTransition {
    public static func isJustSatisfied(
        previousSatisfaction: Bool?,
        persistedState: MountState?,
        evaluation: NetworkRuleEvaluation?,
        isForcedReevaluation: Bool
    ) -> Bool {
        isForcedReevaluation && evaluation?.isSatisfied == true && (previousSatisfaction == false || persistedState == .waitingForRules)
    }
}

public struct KernelRouteFixture: Sendable, Equatable {
    public var destination: String
    public var prefixLength: Int
    public var isUp: Bool
    public var isReject: Bool
    public var isBlackhole: Bool
    public init(destination: String, prefixLength: Int, isUp: Bool = true, isReject: Bool = false, isBlackhole: Bool = false) {
        self.destination = destination
        self.prefixLength = prefixLength
        self.isUp = isUp
        self.isReject = isReject
        self.isBlackhole = isBlackhole
    }
}

/// A pure boundary between native route-table collection and rule evaluation.
public enum KernelRouteFixtureParser {
    public static func parse(_ routes: [KernelRouteFixture]) -> [String] {
        routes.filter { accepts(isUp: $0.isUp, isReject: $0.isReject, isBlackhole: $0.isBlackhole) }
            .map { "\($0.destination)/\($0.prefixLength)" }
    }

    public static func accepts(isUp: Bool, isReject: Bool, isBlackhole: Bool) -> Bool {
        isUp && !isReject && !isBlackhole
    }
}

public enum NetworkMountRuleEvaluator {
    public static func evaluate(_ ruleSet: NetworkMountRuleSet, snapshot: NetworkSnapshot) -> NetworkRuleEvaluation {
        let unmet = ruleSet.rules.filter { !matches($0, snapshot: snapshot) }.map(\.summary)
        let isSatisfied: Bool
        if ruleSet.rules.isEmpty { isSatisfied = true }
        else if ruleSet.combinator == .all { isSatisfied = unmet.isEmpty }
        else { isSatisfied = unmet.count < ruleSet.rules.count }
        return .init(isSatisfied: isSatisfied, unmetRuleSummaries: isSatisfied ? [] : unmet)
    }

    private static func matches(_ rule: NetworkMountRule, snapshot: NetworkSnapshot) -> Bool {
        switch rule {
        case .nfsServiceReachable: snapshot.nfsServiceReachable
        case .routeAvailable(let cidr): snapshot.routes.contains { routeContains($0, requested: cidr) }
        case .interfaceType(let type): snapshot.interfaces.contains { $0.isActive && $0.type == type }
        case .interfaceName(let name): snapshot.interfaces.contains { $0.isActive && $0.name == name }
        case .tunnelInterfaceActive: snapshot.interfaces.contains { $0.isActive && $0.isTunnel }
        }
    }

    private static func routeContains(_ route: String, requested: String) -> Bool {
        let routeParts = route.split(separator: "/", omittingEmptySubsequences: false)
        let requestedParts = requested.split(separator: "/", omittingEmptySubsequences: false)
        guard routeParts.count == 2, requestedParts.count == 2,
              let routePrefix = Int(routeParts[1]), let requestedPrefix = Int(requestedParts[1]),
              routePrefix <= requestedPrefix else { return false }
        let routeText = String(routeParts[0])
        let requestedText = String(requestedParts[0])
        var routeV4 = in_addr()
        var requestedV4 = in_addr()
        if inet_pton(AF_INET, routeText, &routeV4) == 1, inet_pton(AF_INET, requestedText, &requestedV4) == 1 {
            let mask = routePrefix == 0 ? 0 : UInt32.max << UInt32(32 - routePrefix)
            return UInt32(bigEndian: routeV4.s_addr) & mask == UInt32(bigEndian: requestedV4.s_addr) & mask
        }
        var routeV6 = in6_addr()
        var requestedV6 = in6_addr()
        guard routePrefix <= 128, requestedPrefix <= 128,
              inet_pton(AF_INET6, routeText, &routeV6) == 1, inet_pton(AF_INET6, requestedText, &requestedV6) == 1 else { return false }
        let routeBytes = withUnsafeBytes(of: &routeV6) { Array($0) }
        let requestedBytes = withUnsafeBytes(of: &requestedV6) { Array($0) }
        let fullBytes = routePrefix / 8
        guard routeBytes.prefix(fullBytes) == requestedBytes.prefix(fullBytes) else { return false }
        guard routePrefix % 8 != 0 else { return true }
        let mask = UInt8.max << UInt8(8 - routePrefix % 8)
        return routeBytes[fullBytes] & mask == requestedBytes[fullBytes] & mask
    }
}
