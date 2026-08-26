import Foundation
import Testing
@testable import LATCHShared

@Suite("LATCH branding contracts")
struct BrandingContractTests {
    @Test func applicationSupportPathRemainsCompatible() {
        #expect(LATCHIdentity.applicationSupportDirectory.path == "/Library/Application Support/LATCH")
    }

    @Test func identifiersRemainCompatible() {
        #expect(LATCHIdentity.bundleIdentifier == "com.github.letsrokk.latch")
        #expect(LATCHIdentity.daemonIdentifier == "com.github.letsrokk.latch.daemon")
        #expect(LATCHIdentity.agentIdentifier == "com.github.letsrokk.latch.agent")
        #expect(LATCHIdentity.probeIdentifier == "com.github.letsrokk.latch.probe")
        #expect(LATCHIdentity.preferenceSuite == "com.github.letsrokk.latch.shared")
        #expect(LATCHIdentity.configurationTypeIdentifier == "com.github.letsrokk.latch.configuration")
    }
}
