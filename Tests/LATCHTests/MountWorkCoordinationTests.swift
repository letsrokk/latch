import Foundation
import Testing
@testable import LATCHShared

@Suite("Per-mount work coordination")
struct MountWorkCoordinationTests {
    @Test func invalidationSupersedesAwaitingAutomaticWorkWithoutAllowingOverlap() async throws {
        let mountID = UUID()
        let coordinator = MountWorkCoordinator()
        let automatic = try #require(coordinator.beginAutomatic(for: mountID))

        #expect(coordinator.beginAutomatic(for: mountID) == nil)

        let replacement = coordinator.beginManual(for: mountID)
        #expect(!coordinator.isCurrent(automatic))
        #expect(coordinator.isCurrent(replacement))
        #expect(coordinator.beginAutomatic(for: mountID) == nil)

        coordinator.finishAutomatic(automatic)
        #expect(coordinator.beginAutomatic(for: mountID) == nil)
        coordinator.finishManual(replacement)
        #expect(coordinator.beginAutomatic(for: mountID) != nil)
    }

    @Test func manualWorkOwnsTheGenerationUntilItsMatchingTokenFinishes() async throws {
        let mountID = UUID()
        let coordinator = MountWorkCoordinator()
        let first = coordinator.beginManual(for: mountID)

        #expect(coordinator.beginAutomatic(for: mountID) == nil)

        let replacement = coordinator.beginManual(for: mountID)
        coordinator.finishManual(first)
        #expect(!coordinator.isCurrent(first))
        #expect(coordinator.isCurrent(replacement))
        #expect(coordinator.beginAutomatic(for: mountID) == nil)

        coordinator.finishManual(replacement)
        #expect(coordinator.beginAutomatic(for: mountID) != nil)
    }

    @Test func laterConfigurationMutationInvalidatesManualMountGeneration() async {
        let mountID = UUID()
        let coordinator = MountWorkCoordinator()
        let manual = coordinator.beginManual(for: mountID)

        coordinator.invalidate(mountID)

        #expect(!coordinator.isCurrent(manual))
    }

    @Test func mountsHaveIndependentGenerationsAndInflightChecks() async throws {
        let firstID = UUID()
        let secondID = UUID()
        let coordinator = MountWorkCoordinator()

        let first = try #require(coordinator.beginAutomatic(for: firstID))
        let second = try #require(coordinator.beginAutomatic(for: secondID))
        coordinator.invalidate(firstID)

        #expect(!coordinator.isCurrent(first))
        #expect(coordinator.isCurrent(second))
    }
}
