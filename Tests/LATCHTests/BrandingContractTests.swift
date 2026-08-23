import Foundation
import Testing
@testable import LATCHShared

@Suite("LATCH branding contracts")
struct BrandingContractTests {
    @Test func activeIdentityUsesOnlyLatchPathsAndIdentifiers() {
        #expect(LATCHIdentity.preferenceSuite == "com.github.letsrokk.latch.shared")
        #expect(LATCHIdentity.applicationSupportDirectory.path == "/Library/Application Support/LATCH")
    }

    @Test func reverseDNSIdentifiersUseGitHubNamespace() {
        #expect(LATCHIdentity.bundleIdentifier == "com.github.letsrokk.latch")
        #expect(LATCHIdentity.daemonIdentifier == "com.github.letsrokk.latch.daemon")
        #expect(LATCHIdentity.agentIdentifier == "com.github.letsrokk.latch.agent")
        #expect(LATCHIdentity.probeIdentifier == "com.github.letsrokk.latch.probe")
        #expect(LATCHIdentity.preferenceSuite == "com.github.letsrokk.latch.shared")
        #expect(LATCHIdentity.configurationTypeIdentifier == "com.github.letsrokk.latch.configuration")
    }

    @Test func finalDomainAndXPCNamesAreAvailable() {
        let configuration = LATCHConfiguration()
        let request = LATCHRequest.getConfiguration
        let event = LATCHEvent(
            date: Date(timeIntervalSince1970: 0),
            mountID: nil,
            state: nil,
            code: LATCHErrorCode.none,
            detail: "Ready"
        )

        #expect(configuration.schemaVersion == 2)
        #expect(request == .getConfiguration)
        #expect(event.code == .none)
    }
}
