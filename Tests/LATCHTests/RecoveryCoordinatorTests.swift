import Foundation
import Darwin
import Testing
@testable import LATCHShared

@Suite("Guarded recovery")
struct RecoveryCoordinatorTests {
    @Test func automaticWorkRunsWithBoundedConcurrency() async {
        let tracker = ConcurrentWorkTracker()

        await BoundedAsyncWork.run(Array(0..<6), limit: 2) { _ in
            await tracker.begin()
            try? await Task.sleep(for: .milliseconds(20))
            await tracker.end()
        }

        #expect(await tracker.completed == 6)
        #expect(await tracker.peak == 2)
    }

    @Test func sweepCacheSharesOneInFlightReachabilityCheckPerHost() async {
        let cache = SweepValueCache<Bool>()
        let loads = AsyncCounter()
        let loadGate = TestOperationGate()

        async let first = cache.value(for: "nas.local") {
            await loads.increment()
            await loadGate.enterAndWait()
            return true
        }
        await loadGate.waitUntilEntered()
        async let second = cache.value(for: "nas.local") {
            await loads.increment()
            return false
        }
        await loadGate.release()

        #expect(await first)
        #expect(await second)
        #expect(await loads.value == 1)
    }

    @Test func sweepCacheCanRefreshAHostAfterWakeOnLANChangesReachability() async {
        let cache = SweepValueCache<Bool>()
        let loads = AsyncCounter()

        let beforeWake = await cache.value(for: "nas.local") {
            await loads.increment()
            return false
        }
        await cache.invalidate("nas.local")
        let afterWake = await cache.value(for: "nas.local") {
            await loads.increment()
            return true
        }

        #expect(beforeWake == false)
        #expect(afterWake)
        #expect(await loads.value == 2)
    }

    @Test(arguments: [
        ProbeResult(),
        ProbeResult(networkUnavailable: true),
        ProbeResult(timedOut: true),
        ProbeResult(metadataErrno: EACCES),
        ProbeResult(metadataErrno: EIO),
    ])
    func automaticRecoveryIgnoresEveryResultExceptESTALE(_ probe: ProbeResult) async {
        let mounts = FakeMountOperator()
        let dependencies = FakeDependencyOperator()
        let coordinator = RecoveryCoordinator(mounts: mounts, dependencies: dependencies, permissionGate: { true })

        let result = await coordinator.recover(makeDefinition(), trigger: .automatic(probe))

        #expect(result.didAttemptRecovery == false)
        #expect(await mounts.operations.isEmpty)
    }

    @Test func configuredDependenciesStopInOrderAndRestartInReverse() async {
        let first = dependency(name: "radarr")
        let second = dependency(name: "indexer")
        let mounts = FakeMountOperator()
        let dependencies = FakeDependencyOperator(running: [first.id, second.id])
        let coordinator = RecoveryCoordinator(mounts: mounts, dependencies: dependencies, permissionGate: { true })

        let result = await coordinator.recover(
            makeDefinition(dependencies: [first, second]),
            trigger: .automatic(ProbeResult(metadataErrno: ESTALE))
        )

        #expect(result.state == .healthy)
        #expect(await mounts.lastUnmountRequest == .init(
            mountPoint: "/Volumes/Media/Movies",
            expectedSource: "server.local:/media"
        ))
        #expect(await dependencies.operations == [
            "prepare:radarr", "inspect:radarr", "prepare:indexer", "inspect:indexer",
            "stop:radarr", "stop:indexer", "start:indexer", "verify:indexer", "start:radarr", "verify:radarr",
        ])
    }

    @Test func noDependenciesPerformNoDependencyOperations() async {
        let mounts = FakeMountOperator()
        let dependencies = FakeDependencyOperator()
        let coordinator = RecoveryCoordinator(mounts: mounts, dependencies: dependencies, permissionGate: { true })

        let result = await coordinator.recover(makeDefinition(), trigger: .automatic(ProbeResult(metadataErrno: ESTALE)))

        #expect(result.state == .healthy)
        #expect(await dependencies.operations.isEmpty)
    }

    @Test func configuredButStoppedDependencyIsNotStartedAfterRecovery() async {
        let dependency = dependency(name: "radarr")
        let dependencies = FakeDependencyOperator()
        let coordinator = RecoveryCoordinator(mounts: FakeMountOperator(), dependencies: dependencies, permissionGate: { true })

        let result = await coordinator.recover(makeDefinition(dependencies: [dependency]), trigger: .manual)

        #expect(result.state == .healthy)
        #expect(await dependencies.operations == ["prepare:radarr", "inspect:radarr"])
    }

    @Test func unresolvedDependencyAbortsBeforeUnmount() async {
        let dependency = dependency(name: "radarr")
        let mounts = FakeMountOperator()
        let dependencies = FakeDependencyOperator(failPrepare: dependency.id)
        let coordinator = RecoveryCoordinator(mounts: mounts, dependencies: dependencies, permissionGate: { true })

        let result = await coordinator.recover(makeDefinition(dependencies: [dependency]), trigger: .manual)

        #expect(result.code == .dependencyUnavailable)
        #expect(await mounts.operations.contains("unmount") == false)
    }

    @Test func dependencyInspectionFailureAbortsBeforeUnmount() async {
        let dependency = dependency(name: "radarr")
        let mounts = FakeMountOperator()
        let dependencies = FakeDependencyOperator(failInspect: dependency.id)
        let coordinator = RecoveryCoordinator(mounts: mounts, dependencies: dependencies, permissionGate: { true })

        let result = await coordinator.recover(makeDefinition(dependencies: [dependency]), trigger: .manual)

        #expect(result.code == .dependencyUnavailable)
        #expect(await dependencies.operations == ["prepare:radarr", "inspect:radarr"])
        #expect(await mounts.operations.contains("unmount") == false)
    }

    @Test func sourceMismatchRefusesUnmount() async {
        let mounts = FakeMountOperator(source: "other:/wrong")
        let coordinator = RecoveryCoordinator(mounts: mounts, dependencies: FakeDependencyOperator(), permissionGate: { true })

        let result = await coordinator.recover(makeDefinition(), trigger: .manual)

        #expect(result.code == .sourceMismatch)
        #expect(await mounts.operations == ["network", "source"])
    }

    @Test func failureAfterDependencyStopLeavesItStopped() async {
        let dep = dependency(name: "radarr")
        let mounts = FakeMountOperator(failMount: true)
        let dependencies = FakeDependencyOperator(running: [dep.id])
        let coordinator = RecoveryCoordinator(mounts: mounts, dependencies: dependencies, permissionGate: { true })

        let result = await coordinator.recover(makeDefinition(dependencies: [dep]), trigger: .manual)

        #expect(result.state == .failedClosed)
        #expect(await dependencies.operations.contains("stop:radarr"))
        #expect(await dependencies.operations.contains("start:radarr") == false)
    }

    @Test func persistedCooldownSurvivesCoordinatorRecreation() async {
        let definition = makeDefinition()
        let cooldowns = FakeCooldownStore()
        let first = RecoveryCoordinator(mounts: FakeMountOperator(), dependencies: FakeDependencyOperator(), permissionGate: { true }, cooldownStore: cooldowns)
        _ = await first.recover(definition, trigger: .manual)
        let secondMounts = FakeMountOperator()
        let second = RecoveryCoordinator(mounts: secondMounts, dependencies: FakeDependencyOperator(), permissionGate: { true }, cooldownStore: cooldowns)

        let result = await second.recover(definition, trigger: .manual)

        #expect(result.state == .cooldown)
        #expect(await secondMounts.operations.isEmpty)
    }

    @Test func globalLockRejectsConcurrentRecovery() async {
        let mounts = FakeMountOperator()
        let coordinator = RecoveryCoordinator(
            mounts: mounts,
            dependencies: FakeDependencyOperator(),
            permissionGate: {
                try? await Task.sleep(for: .milliseconds(100))
                return true
            }
        )
        let definition = makeDefinition()
        let first = Task { await coordinator.recover(definition, trigger: .manual) }
        try? await Task.sleep(for: .milliseconds(10))

        let second = await coordinator.recover(definition, trigger: .manual)
        _ = await first.value

        #expect(second.state == .cooldown)
        #expect(await mounts.operations.filter { $0 == "unmount" }.count == 1)
    }

    @Test func stopFailureRestartsAndVerifiesEarlierDependenciesBeforeAborting() async {
        let first = dependency(name: "radarr")
        let second = dependency(name: "indexer")
        let dependencies = FakeDependencyOperator(running: [first.id, second.id], failStop: second.id)
        let mounts = FakeMountOperator()
        let coordinator = RecoveryCoordinator(mounts: mounts, dependencies: dependencies, permissionGate: { true })

        let result = await coordinator.recover(makeDefinition(dependencies: [first, second]), trigger: .manual)

        #expect(result.state == .stale)
        #expect(await dependencies.operations.suffix(2) == ["start:radarr", "verify:radarr"])
        #expect(await mounts.operations.contains("unmount") == false)
    }

    @Test func stopFailureAfterRemoteSideEffectRestoresAndVerifiesTheUncertainDependency() async {
        let dependency = dependency(name: "radarr")
        let dependencies = FakeDependencyOperator(
            running: [dependency.id],
            failStopAfterSideEffect: dependency.id
        )
        let mounts = FakeMountOperator()
        let coordinator = RecoveryCoordinator(mounts: mounts, dependencies: dependencies, permissionGate: { true })

        let result = await coordinator.recover(makeDefinition(dependencies: [dependency]), trigger: .manual)

        #expect(result.state == .stale)
        #expect(result.code == .dependencyStopFailed)
        #expect(await dependencies.operations == [
            "prepare:radarr", "inspect:radarr", "stop:radarr", "inspect:radarr", "start:radarr", "verify:radarr",
        ])
        #expect(await dependencies.running == Set([dependency.id]))
        #expect(await mounts.operations.contains("unmount") == false)
    }

    @Test func cancellationDuringUncertainStopRestorationPublishesCancelledAfterSafeCleanup() async {
        let dependency = dependency(name: "radarr")
        let cancellation = TestCancellation()
        let restoreGate = TestOperationGate()
        let dependencies = FakeDependencyOperator(
            running: [dependency.id],
            failStopAfterSideEffect: dependency.id,
            startGate: restoreGate
        )
        let mounts = FakeMountOperator()
        let coordinator = RecoveryCoordinator(mounts: mounts, dependencies: dependencies, permissionGate: { true })
        let recovery = Task {
            await coordinator.recover(
                makeDefinition(dependencies: [dependency]),
                trigger: .manual,
                isCancelled: { cancellation.isCancelled }
            )
        }
        await restoreGate.waitUntilEntered()

        cancellation.cancel()
        await restoreGate.release()
        let result = await recovery.value

        #expect(result.state == .stale)
        #expect(result.code == .verificationFailed)
        #expect(result.detail.contains("canceled"))
        #expect(await dependencies.running == Set([dependency.id]))
        #expect(await mounts.operations.contains("unmount") == false)
    }

    @Test func cooldownPersistenceFailureRestartsAndVerifiesStoppedDependencies() async {
        let dependency = dependency(name: "radarr")
        let mounts = FakeMountOperator()
        let dependencies = FakeDependencyOperator(running: [dependency.id])
        let coordinator = RecoveryCoordinator(
            mounts: mounts,
            dependencies: dependencies,
            permissionGate: { true },
            cooldownStore: FakeCooldownStore(failRecord: true)
        )

        let result = await coordinator.recover(makeDefinition(dependencies: [dependency]), trigger: .manual)

        #expect(result.state == .stale)
        #expect(result.code == .verificationFailed)
        #expect(await dependencies.operations.suffix(2) == ["start:radarr", "verify:radarr"])
        #expect(await mounts.operations.contains("unmount") == false)
    }

    @Test func cooldownPersistenceRollbackFailureFailsClosed() async {
        let dependency = dependency(name: "radarr")
        let dependencies = FakeDependencyOperator(running: [dependency.id], failVerify: dependency.id)
        let coordinator = RecoveryCoordinator(
            mounts: FakeMountOperator(),
            dependencies: dependencies,
            permissionGate: { true },
            cooldownStore: FakeCooldownStore(failRecord: true)
        )

        let result = await coordinator.recover(makeDefinition(dependencies: [dependency]), trigger: .manual)

        #expect(result.state == .failedClosed)
        #expect(result.code == .verificationFailed)
        #expect(await dependencies.operations.suffix(2) == ["stop:radarr", "inspect:radarr"])
        #expect(await dependencies.running.isEmpty)
    }

    @Test func cancellationAfterDependencyInspectionPreventsTheFirstStop() async {
        let dependency = dependency(name: "radarr")
        let cancellation = TestCancellation()
        let dependencies = FakeDependencyOperator(
            running: [dependency.id],
            cancelAfterOperation: "inspect:radarr",
            cancellation: cancellation
        )
        let mounts = FakeMountOperator()
        let coordinator = RecoveryCoordinator(mounts: mounts, dependencies: dependencies, permissionGate: { true })

        let result = await coordinator.recover(
            makeDefinition(dependencies: [dependency]),
            trigger: .manual,
            isCancelled: { cancellation.isCancelled }
        )

        #expect(result.state == .stale)
        #expect(result.code == .verificationFailed)
        #expect(await dependencies.operations == ["prepare:radarr", "inspect:radarr"])
        #expect(await mounts.operations == ["network", "source"])
    }

    @Test func cancellationAfterAStopRestoresAndVerifiesBeforeReturningRolledBack() async {
        let dependency = dependency(name: "radarr")
        let cancellation = TestCancellation()
        let dependencies = FakeDependencyOperator(
            running: [dependency.id],
            cancelAfterOperation: "stop:radarr",
            cancellation: cancellation
        )
        let mounts = FakeMountOperator()
        let coordinator = RecoveryCoordinator(mounts: mounts, dependencies: dependencies, permissionGate: { true })

        let result = await coordinator.recover(
            makeDefinition(dependencies: [dependency]),
            trigger: .manual,
            isCancelled: { cancellation.isCancelled }
        )

        #expect(result.state == .stale)
        #expect(result.code == .verificationFailed)
        #expect(await dependencies.operations == [
            "prepare:radarr", "inspect:radarr", "stop:radarr", "start:radarr", "verify:radarr",
        ])
        #expect(await dependencies.running == Set([dependency.id]))
        #expect(await mounts.operations.contains("unmount") == false)
    }

    @Test func preChangeCancellationCleanupFailureRestopsAndInspectsBeforeFailingClosed() async {
        let dependency = dependency(name: "radarr")
        let cancellation = TestCancellation()
        let dependencies = FakeDependencyOperator(
            running: [dependency.id],
            failVerify: dependency.id,
            cancelAfterOperation: "stop:radarr",
            cancellation: cancellation
        )
        let mounts = FakeMountOperator()
        let coordinator = RecoveryCoordinator(mounts: mounts, dependencies: dependencies, permissionGate: { true })

        let result = await coordinator.recover(
            makeDefinition(dependencies: [dependency]),
            trigger: .manual,
            isCancelled: { cancellation.isCancelled }
        )

        #expect(result.state == .failedClosed)
        #expect(result.code == .verificationFailed)
        #expect(await dependencies.operations.suffix(4) == [
            "start:radarr", "verify:radarr", "stop:radarr", "inspect:radarr",
        ])
        #expect(await dependencies.running.isEmpty)
        #expect(await mounts.operations.contains("unmount") == false)
    }

    @Test func manualIdleWaitDoesNotFinishUntilPreChangeCancellationCleanupFinishes() async throws {
        let dependency = dependency(name: "radarr")
        let stopGate = TestOperationGate()
        let cleanupStartGate = TestOperationGate()
        let dependencies = FakeDependencyOperator(
            running: [dependency.id],
            stopGate: stopGate,
            startGate: cleanupStartGate
        )
        let definition = makeDefinition(dependencies: [dependency])
        let work = MountWorkCoordinator()
        let automaticToken = try #require(work.beginAutomatic(for: definition.id))
        let coordinator = RecoveryCoordinator(mounts: FakeMountOperator(), dependencies: dependencies, permissionGate: { true })
        let recovery = Task {
            await coordinator.recover(
                definition,
                trigger: .manual,
                isCancelled: { !work.isCurrent(automaticToken) }
            )
        }
        await stopGate.waitUntilEntered()

        let manualToken = work.beginManual(for: automaticToken.mountID)
        await stopGate.release()
        await cleanupStartGate.waitUntilEntered()
        let waiterStarted = TestCancellation()
        let idleCompleted = TestCancellation()
        let idleWait = Task {
            waiterStarted.cancel()
            await coordinator.waitUntilIdle()
            idleCompleted.cancel()
        }
        while !waiterStarted.isCancelled { await Task.yield() }
        try await Task.sleep(for: .milliseconds(20))
        #expect(!idleCompleted.isCancelled)

        await cleanupStartGate.release()
        let result = await recovery.value
        await idleWait.value
        work.finishManual(manualToken)
        work.finishAutomatic(automaticToken)

        #expect(result.state == .stale)
        #expect(idleCompleted.isCancelled)
        #expect(await dependencies.running == Set([dependency.id]))
        #expect(await dependencies.operations.suffix(2) == ["start:radarr", "verify:radarr"])
    }

    @Test func cancellationDuringRestartVerificationRestopsAndInspectsTheAttemptedDependency() async {
        let dependency = dependency(name: "radarr")
        let cancellation = TestCancellation()
        let dependencies = FakeDependencyOperator(
            running: [dependency.id],
            cancelAfterOperation: "verify:radarr",
            cancellation: cancellation
        )
        let mounts = FakeMountOperator()
        let coordinator = RecoveryCoordinator(mounts: mounts, dependencies: dependencies, permissionGate: { true })

        let result = await coordinator.recover(
            makeDefinition(dependencies: [dependency]),
            trigger: .manual,
            isCancelled: { cancellation.isCancelled }
        )

        #expect(result.state == .failedClosed)
        #expect(result.code == .verificationFailed)
        #expect(await dependencies.operations.suffix(4) == [
            "start:radarr", "verify:radarr", "stop:radarr", "inspect:radarr",
        ])
        #expect(await dependencies.running.isEmpty)
        #expect(await mounts.operations.suffix(5) == ["unmount", "empty", "mount", "verifySource", "probe"])
    }

    @Test func restartStartBoundaryRechecksCancellationBeforeStartingTheDependency() async {
        let dependency = dependency(name: "radarr")
        let cancellation = TestCancellation()
        let dependencies = FakeDependencyOperator(
            running: [dependency.id],
            cancelBeforeOperation: "start:radarr",
            cancellation: cancellation
        )
        let mounts = FakeMountOperator()
        let coordinator = RecoveryCoordinator(mounts: mounts, dependencies: dependencies, permissionGate: { true })

        let result = await coordinator.recover(
            makeDefinition(dependencies: [dependency]),
            trigger: .manual,
            isCancelled: { cancellation.isCancelled }
        )

        #expect(result.state == .failedClosed)
        #expect(result.code == .verificationFailed)
        #expect(await dependencies.operations.suffix(2) == ["stop:radarr", "inspect:radarr"])
        #expect(await dependencies.operations.contains("start:radarr") == false)
        #expect(await dependencies.running.isEmpty)
        #expect(await mounts.operations.suffix(5) == ["unmount", "empty", "mount", "verifySource", "probe"])
    }

    @Test func dependencyStopBoundaryRechecksCancellationBeforeTheSideEffect() async {
        let dependency = dependency(name: "radarr")
        let cancellation = TestCancellation()
        let dependencies = FakeDependencyOperator(
            running: [dependency.id],
            cancelBeforeOperation: "stop:radarr",
            cancellation: cancellation
        )
        let mounts = FakeMountOperator()
        let coordinator = RecoveryCoordinator(mounts: mounts, dependencies: dependencies, permissionGate: { true })

        let result = await coordinator.recover(
            makeDefinition(dependencies: [dependency]),
            trigger: .manual,
            isCancelled: { cancellation.isCancelled }
        )

        #expect(result.state == .stale)
        #expect(await dependencies.operations == ["prepare:radarr", "inspect:radarr", "inspect:radarr"])
        #expect(await dependencies.running == Set([dependency.id]))
        #expect(await mounts.operations.contains("unmount") == false)
    }

    @Test func cancellationDuringUnmountFailsClosedWithoutMountOrProbe() async {
        let dependency = dependency(name: "radarr")
        let cancellation = TestCancellation()
        let dependencies = FakeDependencyOperator(running: [dependency.id])
        let mounts = FakeMountOperator(
            cancelAfterOperation: "unmount",
            cancellation: cancellation
        )
        let coordinator = RecoveryCoordinator(mounts: mounts, dependencies: dependencies, permissionGate: { true })

        let result = await coordinator.recover(
            makeDefinition(dependencies: [dependency]),
            trigger: .manual,
            isCancelled: { cancellation.isCancelled }
        )

        #expect(result.state == .failedClosed)
        #expect(result.code == .verificationFailed)
        #expect(result.didAttemptRecovery)
        #expect(await mounts.operations == ["network", "source", "unmount"])
        #expect(await dependencies.operations.contains("start:radarr") == false)
    }

    @Test func guardedMountExecutionDoesNotMountAfterCancellationDuringValidation() async {
        let cancellation = TestCancellation()
        let mounts = FakeMountOperator(
            cancelAfterOperation: "empty",
            cancellation: cancellation
        )
        let executor = GuardedMountExecutor(mounts: mounts)

        await #expect(throws: MountOperationCancellationError.cancelled) {
            try await executor.mount(
                makeDefinition(),
                cancellation: .init(isCancelled: { cancellation.isCancelled })
            )
        }

        #expect(await mounts.operations == ["empty"])
    }

    @Test func mountBoundaryRechecksCancellationImmediatelyBeforeTheSideEffect() async {
        let cancellation = TestCancellation()
        let mounts = FakeMountOperator(
            cancelBeforeOperation: "mount",
            cancellation: cancellation
        )
        let executor = GuardedMountExecutor(mounts: mounts)

        await #expect(throws: MountOperationCancellationError.cancelled) {
            try await executor.mount(
                makeDefinition(),
                cancellation: .init(isCancelled: { cancellation.isCancelled })
            )
        }

        #expect(await mounts.operations == ["empty"])
    }

    @Test func cooldownRollbackFailureStopsAndInspectsEveryRestartedDependency() async {
        let first = dependency(name: "radarr")
        let second = dependency(name: "indexer")
        let dependencies = FakeDependencyOperator(running: [first.id, second.id], failVerify: first.id)
        let coordinator = RecoveryCoordinator(
            mounts: FakeMountOperator(),
            dependencies: dependencies,
            permissionGate: { true },
            cooldownStore: FakeCooldownStore(failRecord: true)
        )

        let result = await coordinator.recover(makeDefinition(dependencies: [first, second]), trigger: .manual)

        #expect(result.state == .failedClosed)
        #expect(result.code == .verificationFailed)
        #expect(await dependencies.operations.suffix(4) == [
            "stop:radarr", "inspect:radarr", "stop:indexer", "inspect:indexer",
        ])
        #expect(await dependencies.running.isEmpty)
    }

    @Test func restartFailureStopsEveryDependencyRestartedDuringTheAttempt() async {
        let first = dependency(name: "radarr")
        let second = dependency(name: "indexer")
        let dependencies = FakeDependencyOperator(running: [first.id, second.id], failVerify: first.id)
        let coordinator = RecoveryCoordinator(mounts: FakeMountOperator(), dependencies: dependencies, permissionGate: { true })

        let result = await coordinator.recover(makeDefinition(dependencies: [first, second]), trigger: .manual)

        #expect(result.state == .failedClosed)
        #expect(await dependencies.operations.suffix(4) == [
            "stop:radarr", "inspect:radarr", "stop:indexer", "inspect:indexer",
        ])
        #expect(await dependencies.running.isEmpty)
    }

    private func makeDefinition(dependencies: [RecoveryDependency] = []) -> MountDefinition {
        MountDefinition(displayName: "Movies", host: "server.local", exportPath: "/media", mountPoint: "/Volumes/Media/Movies", recoveryDependencies: dependencies)
    }

    private func dependency(name: String) -> RecoveryDependency {
        RecoveryDependency(kind: .dockerContainer(.init(containerName: name, dockerSocketPath: "/tmp/docker.sock", composeFilePath: nil)))
    }
}

private actor FakeMountOperator: MountOperating {
    struct UnmountRequest: Sendable, Equatable {
        let mountPoint: String
        let expectedSource: String
    }

    var operations: [String] = []
    var lastUnmountRequest: UnmountRequest?
    let source: String?
    let failMount: Bool
    let cancelAfterOperation: String?
    let cancelBeforeOperation: String?
    let cancellation: TestCancellation?

    init(
        source: String? = "server.local:/media",
        failMount: Bool = false,
        cancelAfterOperation: String? = nil,
        cancelBeforeOperation: String? = nil,
        cancellation: TestCancellation? = nil
    ) {
        self.source = source
        self.failMount = failMount
        self.cancelAfterOperation = cancelAfterOperation
        self.cancelBeforeOperation = cancelBeforeOperation
        self.cancellation = cancellation
    }

    func networkAvailable(for host: String) async -> Bool { record("network"); return true }
    func currentSource(at mountPoint: String) async throws -> String? { record("source"); return source }
    func forceUnmount(_ mountPoint: String, expectedSource: String, cancellation token: MountOperationCancellation) async throws {
        lastUnmountRequest = .init(mountPoint: mountPoint, expectedSource: expectedSource)
        try record("unmount", cancellation: token)
    }
    func validateEmptyMountPoint(_ mountPoint: String, cancellation token: MountOperationCancellation) async throws {
        try record("empty", cancellation: token)
    }
    func mount(_ definition: MountDefinition, cancellation token: MountOperationCancellation) async throws {
        try record("mount", cancellation: token)
        if failMount { throw FakeFailure.expected }
    }
    func verifySource(_ source: String, at mountPoint: String, cancellation token: MountOperationCancellation) async throws {
        try record("verifySource", cancellation: token)
    }
    func probe(_ definition: MountDefinition, cancellation token: MountOperationCancellation) async throws -> ProbeResult {
        try record("probe", cancellation: token)
        return ProbeResult()
    }

    private func record(_ operation: String) {
        operations.append(operation)
        if cancelAfterOperation == operation { cancellation?.cancel() }
    }

    private func record(_ operation: String, cancellation token: MountOperationCancellation) throws {
        if cancelBeforeOperation == operation { cancellation?.cancel() }
        try token.throwIfCancelled()
        record(operation)
    }
}

private actor FakeDependencyOperator: DependencyOperating {
    var operations: [String] = []
    var running: Set<UUID>
    let failStop: UUID?
    let failStopAfterSideEffect: UUID?
    let failInspect: UUID?
    let failVerify: UUID?
    let failPrepare: UUID?
    let cancelAfterOperation: String?
    let cancelBeforeOperation: String?
    let cancellation: TestCancellation?
    let stopGate: TestOperationGate?
    let startGate: TestOperationGate?

    init(
        running: Set<UUID> = [],
        failStop: UUID? = nil,
        failStopAfterSideEffect: UUID? = nil,
        failInspect: UUID? = nil,
        failVerify: UUID? = nil,
        failPrepare: UUID? = nil,
        cancelAfterOperation: String? = nil,
        cancelBeforeOperation: String? = nil,
        cancellation: TestCancellation? = nil,
        stopGate: TestOperationGate? = nil,
        startGate: TestOperationGate? = nil
    ) {
        self.running = running
        self.failStop = failStop
        self.failStopAfterSideEffect = failStopAfterSideEffect
        self.failInspect = failInspect
        self.failVerify = failVerify
        self.failPrepare = failPrepare
        self.cancelAfterOperation = cancelAfterOperation
        self.cancelBeforeOperation = cancelBeforeOperation
        self.cancellation = cancellation
        self.stopGate = stopGate
        self.startGate = startGate
    }

    func prepare(_ dependency: RecoveryDependency) async throws {
        operations.append("prepare:\(dependency.nameForTesting)")
        if dependency.id == failPrepare { throw FakeFailure.expected }
        cancelIfRequested(after: "prepare:\(dependency.nameForTesting)")
    }
    func isRunning(_ dependency: RecoveryDependency) async throws -> Bool {
        let operation = "inspect:\(dependency.nameForTesting)"
        operations.append(operation)
        if dependency.id == failInspect { throw FakeFailure.expected }
        let result = running.contains(dependency.id)
        cancelIfRequested(after: operation)
        return result
    }
    func stop(_ dependency: RecoveryDependency, cancellation token: MountOperationCancellation) async throws {
        let operation = "stop:\(dependency.nameForTesting)"
        if cancelBeforeOperation == operation { cancellation?.cancel() }
        try token.throwIfCancelled()
        operations.append(operation)
        if dependency.id == failStop { throw FakeFailure.expected }
        running.remove(dependency.id)
        if dependency.id == failStopAfterSideEffect { throw FakeFailure.expected }
        cancelIfRequested(after: operation)
        if let stopGate { await stopGate.enterAndWait() }
    }
    func start(_ dependency: RecoveryDependency, cancellation token: MountOperationCancellation) async throws {
        let operation = "start:\(dependency.nameForTesting)"
        if cancelBeforeOperation == operation { cancellation?.cancel() }
        try token.throwIfCancelled()
        operations.append(operation)
        running.insert(dependency.id)
        cancelIfRequested(after: operation)
        if let startGate { await startGate.enterAndWait() }
    }
    func verifyRunning(_ dependency: RecoveryDependency, cancellation token: MountOperationCancellation) async throws {
        let operation = "verify:\(dependency.nameForTesting)"
        if cancelBeforeOperation == operation { cancellation?.cancel() }
        try token.throwIfCancelled()
        operations.append(operation)
        if dependency.id == failVerify { throw FakeFailure.expected }
        guard running.contains(dependency.id) else { throw FakeFailure.expected }
        cancelIfRequested(after: operation)
        try token.throwIfCancelled()
    }

    private func cancelIfRequested(after operation: String) {
        if cancelAfterOperation == operation { cancellation?.cancel() }
    }
}

private extension RecoveryDependency {
    var nameForTesting: String {
        switch kind {
        case .dockerContainer(let value): value.containerName
        case .macApplication(let value): value.bundleIdentifier
        }
    }
}

private enum FakeFailure: Error { case expected }

private final class TestCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isCancelled: Bool { lock.withLock { value } }
    func cancel() { lock.withLock { value = true } }
}

private actor TestOperationGate {
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func enterAndWait() async {
        entered = true
        let waitingForEntry = entryWaiters
        entryWaiters.removeAll()
        for waiter in waitingForEntry { waiter.resume() }
        guard !released else { return }
        await withCheckedContinuation { continuation in
            if released { continuation.resume() }
            else { releaseWaiters.append(continuation) }
        }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        released = true
        let waitingForRelease = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waitingForRelease { waiter.resume() }
    }
}

private actor FakeCooldownStore: RecoveryCooldownStoring {
    private var values: [UUID: Date] = [:]
    private let failRecord: Bool

    init(failRecord: Bool = false) { self.failRecord = failRecord }

    func lastRecovery(for mountID: UUID) async -> Date? { values[mountID] }
    func recordRecovery(_ date: Date, for mountID: UUID, cancellation: MountOperationCancellation) async throws {
        try cancellation.throwIfCancelled()
        if failRecord { throw FakeFailure.expected }
        values[mountID] = date
        try cancellation.throwIfCancelled()
    }
}

private actor ConcurrentWorkTracker {
    private var active = 0
    private(set) var peak = 0
    private(set) var completed = 0

    func begin() {
        active += 1
        peak = max(peak, active)
    }

    func end() {
        active -= 1
        completed += 1
    }
}

private actor AsyncCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}
