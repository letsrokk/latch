import Foundation
import Testing
@testable import LATCHShared

@Suite("Application termination policy")
struct ApplicationTerminationPolicyTests {
    @Test func gracefulExitAlwaysCompletesTheStop() {
        #expect(ApplicationTerminationPolicy.disposition(
            exitedGracefully: true,
            allowForceQuit: false,
            configuredURL: URL(fileURLWithPath: "/Applications/A.app"),
            runningURL: nil
        ) == .succeeded)
    }

    @Test func forceQuitRequiresEquivalentResolvedBundleURLs() {
        let configured = URL(fileURLWithPath: "/Applications/A.app")
        let equivalent = URL(fileURLWithPath: "/Applications/../Applications/A.app")

        #expect(ApplicationTerminationPolicy.disposition(
            exitedGracefully: false,
            allowForceQuit: true,
            configuredURL: configured,
            runningURL: equivalent
        ) == .forceQuit)
        #expect(ApplicationTerminationPolicy.disposition(
            exitedGracefully: false,
            allowForceQuit: true,
            configuredURL: configured,
            runningURL: URL(fileURLWithPath: "/Applications/B.app")
        ) == .failed)
    }

    @Test func runningApplicationIdentityRequiresTheConfiguredBundleURL() {
        let configured = URL(fileURLWithPath: "/Applications/A.app")
        #expect(ApplicationTerminationPolicy.matches(
            configuredURL: configured,
            runningURL: URL(fileURLWithPath: "/Applications/../Applications/A.app")
        ))
        #expect(!ApplicationTerminationPolicy.matches(
            configuredURL: configured,
            runningURL: URL(fileURLWithPath: "/Users/test/Applications/A.app")
        ))
        #expect(!ApplicationTerminationPolicy.matches(configuredURL: configured, runningURL: nil))
    }

    @Test func forceQuitMustBeExplicitlyEnabledAndRestartMustBeObserved() {
        let url = URL(fileURLWithPath: "/Applications/A.app")
        #expect(ApplicationTerminationPolicy.disposition(
            exitedGracefully: false,
            allowForceQuit: false,
            configuredURL: url,
            runningURL: url
        ) == .failed)
        #expect(ApplicationTerminationPolicy.restartVerified(isRunning: true))
        #expect(!ApplicationTerminationPolicy.restartVerified(isRunning: false))
    }

    @Test func forceQuitAcceptsASymlinkToTheConfiguredApplication() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let configured = root.appendingPathComponent("Applications/A.app")
        let linked = root.appendingPathComponent("Links/A.app")
        try FileManager.default.createDirectory(
            at: configured,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: linked.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: configured)

        #expect(ApplicationTerminationPolicy.matches(configuredURL: configured, runningURL: linked))
        #expect(ApplicationTerminationPolicy.disposition(
            exitedGracefully: false,
            allowForceQuit: true,
            configuredURL: configured,
            runningURL: linked
        ) == .forceQuit)
    }
}
