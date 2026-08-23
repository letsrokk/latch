import Foundation
import Testing
@testable import LATCHShared

@Suite("Network mount rules")
struct NetworkMountRulesTests {
    @Test func emptyRuleSetPasses() {
        let result = NetworkMountRuleEvaluator.evaluate(.init(), snapshot: .init())

        #expect(result.isSatisfied)
        #expect(result.unmetRuleSummaries == [])
    }

    @Test func allRequiresEveryRuleAndReportsHumanSummaries() {
        let rules = NetworkMountRuleSet(combinator: .all, rules: [.nfsServiceReachable, .routeAvailable("10.0.0.0/24"), .interfaceType(.wifi)])
        let snapshot = NetworkSnapshot(nfsServiceReachable: false, routes: ["10.0.0.0/24"], interfaces: [.init(name: "en0", type: .ethernet, isActive: true)])

        let result = NetworkMountRuleEvaluator.evaluate(rules, snapshot: snapshot)

        #expect(!result.isSatisfied)
        #expect(result.unmetRuleSummaries == ["NFS service reachable on TCP port 2049", "Active Wi-Fi interface"])
    }

    @Test func anyPassesWhenOneRuleMatches() {
        let rules = NetworkMountRuleSet(combinator: .any, rules: [.interfaceName("utun4"), .tunnelInterfaceActive])
        let snapshot = NetworkSnapshot(interfaces: [.init(name: "utun4", type: .other, isActive: true, isTunnel: true)])

        let result = NetworkMountRuleEvaluator.evaluate(rules, snapshot: snapshot)

        #expect(result.isSatisfied)
        #expect(result.unmetRuleSummaries == [])
    }

    @Test func unmetRulesTakePrecedenceOverADeferredRetry() {
        let retry = AutomaticRetryState(kind: .missingMount, failures: 1, nextAttempt: Date(timeIntervalSince1970: 200))
        let evaluation = NetworkRuleEvaluation(isSatisfied: false, unmetRuleSummaries: ["Active tunnel interface"])

        #expect(NetworkAutomaticWorkDisposition.resolve(ruleEvaluation: evaluation, retry: retry, now: Date(timeIntervalSince1970: 100)) == .waitingForRules(["Active tunnel interface"]))
    }

    @Test func ruleTransitionCanBypassAnOldRetryButSteadyStateCannot() {
        let retry = AutomaticRetryState(kind: .missingMount, failures: 1, nextAttempt: Date(timeIntervalSince1970: 200))
        let satisfied = NetworkRuleEvaluation(isSatisfied: true, unmetRuleSummaries: [])
        let now = Date(timeIntervalSince1970: 100)

        #expect(NetworkAutomaticWorkDisposition.resolve(ruleEvaluation: satisfied, retry: retry, now: now, rulesJustSatisfied: true) == .proceed)
        #expect(NetworkAutomaticWorkDisposition.resolve(ruleEvaluation: satisfied, retry: retry, now: now, rulesJustSatisfied: false) == .retryScheduled)
    }

    @Test func restoredWaitingStatusBecomesAnImmediateStartupTransition() {
        let evaluation = NetworkRuleEvaluation(isSatisfied: true, unmetRuleSummaries: [])

        #expect(NetworkRuleTransition.isJustSatisfied(previousSatisfaction: nil, persistedState: .waitingForRules, evaluation: evaluation, isForcedReevaluation: true))
    }

    @Test func routedAndIPv6CIDRFixturesRemainAvailableToRules() {
        let routes = KernelRouteFixtureParser.parse([
            .init(destination: "0.0.0.0", prefixLength: 0),
            .init(destination: "2001:db8::", prefixLength: 64),
            .init(destination: "10.20.0.0", prefixLength: 16, isUp: false),
            .init(destination: "10.30.0.0", prefixLength: 16, isReject: true),
            .init(destination: "10.40.0.0", prefixLength: 16, isBlackhole: true),
        ])
        let ipv6 = NetworkMountRuleEvaluator.evaluate(.init(rules: [.routeAvailable("2001:db8::/64")]), snapshot: .init(routes: routes))
        let defaultRoute = NetworkMountRuleEvaluator.evaluate(.init(rules: [.routeAvailable("10.10.0.0/16")]), snapshot: .init(routes: routes))

        #expect(routes == ["0.0.0.0/0", "2001:db8::/64"])
        #expect(ipv6.isSatisfied)
        #expect(defaultRoute.isSatisfied)
    }

    @Test func cidrRuleRequiresCanonicalCIDR() {
        let configuration = LATCHConfiguration(servers: [.init(name: "NAS", hostname: "nas.local", networkMountRules: .init(rules: [.routeAvailable("10.0.0.1/24")]))])

        #expect(throws: ConfigurationValidationError.invalidNetworkRule) {
            try ConfigurationValidator().validate(configuration, liveMounts: [])
        }
    }

    @Test func canonicalIPv6RouteRuleIsValid() throws {
        let configuration = LATCHConfiguration(servers: [.init(name: "NAS", hostname: "nas.local", networkMountRules: .init(rules: [.routeAvailable("2001:db8::/64")]))])

        try ConfigurationValidator().validate(configuration, liveMounts: [])
    }

    @Test func serverIdentifiersAndHostnamesMustBeUnique() {
        let id = UUID()
        let configuration = LATCHConfiguration(servers: [.init(id: id, name: "One", hostname: "nas.local"), .init(id: id, name: "Two", hostname: "NAS.local")])

        #expect(throws: ConfigurationValidationError.duplicateServerID) {
            try ConfigurationValidator().validate(configuration, liveMounts: [])
        }
    }
}
