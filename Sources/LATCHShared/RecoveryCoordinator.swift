import Darwin
import Foundation

public enum RecoveryTrigger: Sendable, Equatable {
    case automatic(ProbeResult)
    case manual
}

public struct RecoveryResult: Sendable, Equatable {
    public let state: MountState
    public let code: LATCHErrorCode
    public let detail: String
    public let didAttemptRecovery: Bool
}

public protocol MountOperating: Sendable {
    func networkAvailable(for host: String) async -> Bool
    func currentSource(at mountPoint: String) async throws -> String?
    func forceUnmount(_ mountPoint: String, expectedSource: String, cancellation: MountOperationCancellation) async throws
    func validateEmptyMountPoint(_ mountPoint: String, cancellation: MountOperationCancellation) async throws
    func mount(_ definition: MountDefinition, cancellation: MountOperationCancellation) async throws
    func verifySource(_ source: String, at mountPoint: String, cancellation: MountOperationCancellation) async throws
    func probe(_ definition: MountDefinition, cancellation: MountOperationCancellation) async throws -> ProbeResult
}

public extension MountOperating {
    func forceUnmount(_ mountPoint: String, expectedSource: String) async throws {
        try await forceUnmount(mountPoint, expectedSource: expectedSource, cancellation: .never)
    }

    func validateEmptyMountPoint(_ mountPoint: String) async throws {
        try await validateEmptyMountPoint(mountPoint, cancellation: .never)
    }

    func mount(_ definition: MountDefinition) async throws {
        try await mount(definition, cancellation: .never)
    }

    func verifySource(_ source: String, at mountPoint: String) async throws {
        try await verifySource(source, at: mountPoint, cancellation: .never)
    }

    func probe(_ definition: MountDefinition) async -> ProbeResult {
        (try? await probe(definition, cancellation: .never))
            ?? ProbeResult(metadataErrno: EIO, failedOperation: .metadata)
    }
}

public protocol DependencyOperating: Sendable {
    func prepare(_ dependency: RecoveryDependency) async throws
    func isRunning(_ dependency: RecoveryDependency) async throws -> Bool
    func stop(_ dependency: RecoveryDependency, cancellation: MountOperationCancellation) async throws
    func start(_ dependency: RecoveryDependency, cancellation: MountOperationCancellation) async throws
    func verifyRunning(_ dependency: RecoveryDependency, cancellation: MountOperationCancellation) async throws
}

public extension DependencyOperating {
    func stop(_ dependency: RecoveryDependency) async throws {
        try await stop(dependency, cancellation: .never)
    }

    func start(_ dependency: RecoveryDependency) async throws {
        try await start(dependency, cancellation: .never)
    }

    func verifyRunning(_ dependency: RecoveryDependency) async throws {
        try await verifyRunning(dependency, cancellation: .never)
    }
}

public actor RecoveryCoordinator {
    private let mounts: any MountOperating
    private let dependencies: any DependencyOperating
    private let permissionGate: @Sendable () async -> Bool
    private let now: @Sendable () -> Date
    private let cooldownStore: any RecoveryCooldownStoring
    private var recoveryInProgress = false
    private var recoveryDisabled = false

    public init(
        mounts: any MountOperating,
        dependencies: any DependencyOperating,
        permissionGate: @escaping @Sendable () async -> Bool,
        cooldownStore: any RecoveryCooldownStoring = InMemoryRecoveryCooldownStore(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.mounts = mounts
        self.dependencies = dependencies
        self.permissionGate = permissionGate
        self.cooldownStore = cooldownStore
        self.now = now
    }

    public func recover(
        _ definition: MountDefinition,
        trigger: RecoveryTrigger,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) async -> RecoveryResult {
        if case .automatic(let probe) = trigger, !ProbeClassifier.classify(probe).shouldAutomaticallyRecover {
            let classification = ProbeClassifier.classify(probe)
            return .init(state: classification.state, code: classification.code, detail: classification.detail, didAttemptRecovery: false)
        }
        let cancellation = MountOperationCancellation(isCancelled: isCancelled)
        if isCancelled() { return await cancellationResult(stopped: [], mountState: .untouched) }
        guard !recoveryDisabled, !recoveryInProgress else {
            return .init(state: .cooldown, code: .none, detail: "Another recovery is active or recovery is being disabled.", didAttemptRecovery: false)
        }
        recoveryInProgress = true
        defer { recoveryInProgress = false }
        if isCancelled() { return await cancellationResult(stopped: [], mountState: .untouched) }
        let permissionGranted = await permissionGate()
        if isCancelled() { return await cancellationResult(stopped: [], mountState: .untouched) }
        guard permissionGranted else {
            return .init(state: .probeError, code: .tccDenied, detail: "Recovery is disabled until the registered daemon passes the Network Volumes probe.", didAttemptRecovery: false)
        }
        if isCancelled() { return await cancellationResult(stopped: [], mountState: .untouched) }
        let previousRecovery = await cooldownStore.lastRecovery(for: definition.id)
        if isCancelled() { return await cancellationResult(stopped: [], mountState: .untouched) }
        if let previousRecovery, now().timeIntervalSince(previousRecovery) < Double(definition.recoveryCooldownSeconds) {
            return .init(state: .cooldown, code: .none, detail: "Recovery is in its per-volume cooldown.", didAttemptRecovery: false)
        }
        if isCancelled() { return await cancellationResult(stopped: [], mountState: .untouched) }
        let networkAvailable = await mounts.networkAvailable(for: definition.host)
        if isCancelled() { return await cancellationResult(stopped: [], mountState: .untouched) }
        guard networkAvailable else {
            return .init(state: .networkUnavailable, code: .networkUnavailable, detail: "The server is unavailable; no unmount was attempted.", didAttemptRecovery: false)
        }

        do {
            if isCancelled() { return await cancellationResult(stopped: [], mountState: .untouched) }
            let currentSource = try await mounts.currentSource(at: definition.mountPoint)
            if isCancelled() { return await cancellationResult(stopped: [], mountState: .untouched) }
            guard currentSource == definition.source else {
                return .init(state: .probeError, code: .sourceMismatch, detail: "The exact configured source does not own the mountpoint.", didAttemptRecovery: false)
            }
        } catch {
            if isCancelled() { return await cancellationResult(stopped: [], mountState: .untouched) }
            return .init(state: .probeError, code: .sourceMismatch, detail: "The mount source could not be verified.", didAttemptRecovery: false)
        }

        let enabled = definition.recoveryDependencies.filter(\.enabled)
        var running: [RecoveryDependency] = []
        do {
            for dependency in enabled {
                if isCancelled() { return await cancellationResult(stopped: [], mountState: .untouched) }
                try await dependencies.prepare(dependency)
                if isCancelled() { return await cancellationResult(stopped: [], mountState: .untouched) }
                let dependencyIsRunning = try await dependencies.isRunning(dependency)
                if isCancelled() { return await cancellationResult(stopped: [], mountState: .untouched) }
                if dependencyIsRunning { running.append(dependency) }
            }
        } catch {
            if isCancelled() { return await cancellationResult(stopped: [], mountState: .untouched) }
            return .init(state: .stale, code: .dependencyUnavailable, detail: "Dependency state or restart capability is unavailable; recovery was aborted.", didAttemptRecovery: false)
        }

        var stopped: [RecoveryDependency] = []
        do {
            for dependency in running {
                if isCancelled() { return await cancellationResult(stopped: stopped, mountState: .untouched) }
                try await dependencies.stop(dependency, cancellation: cancellation)
                stopped.append(dependency)
                if isCancelled() { return await cancellationResult(stopped: stopped, mountState: .untouched) }
            }
        } catch {
            if isCancelled() { return await cancellationResult(stopped: stopped, mountState: .untouched) }
            switch await restartAndVerify(stopped, cancellation: cancellation) {
            case .success:
                break
            case .failed:
                return .init(state: .failedClosed, code: .dependencyStopFailed, detail: "Dependency stop failed and an earlier dependency could not be restored.", didAttemptRecovery: false)
            case .cancelled:
                return await cancellationResult(stopped: stopped, mountState: .untouched)
            }
            return .init(state: .stale, code: .dependencyStopFailed, detail: "A dependency could not be stopped; the mount was not changed.", didAttemptRecovery: false)
        }

        if isCancelled() { return await cancellationResult(stopped: stopped, mountState: .untouched) }
        do {
            try await cooldownStore.recordRecovery(now(), for: definition.id, cancellation: cancellation)
            if isCancelled() { return await cancellationResult(stopped: stopped, mountState: .untouched) }
        }
        catch {
            if isCancelled() { return await cancellationResult(stopped: stopped, mountState: .untouched) }
            switch await restartAndVerify(stopped, cancellation: cancellation) {
            case .success:
                return .init(state: .stale, code: .verificationFailed, detail: "The persisted recovery cooldown could not be recorded; recovery was aborted.", didAttemptRecovery: false)
            case .failed:
                return .init(state: .failedClosed, code: .verificationFailed, detail: "The recovery cooldown could not be persisted and at least one stopped dependency could not be restored.", didAttemptRecovery: false)
            case .cancelled:
                return await cancellationResult(stopped: stopped, mountState: .untouched)
            }
        }

        var mountState = RecoveryMountState.untouched
        do {
            try cancellation.throwIfCancelled()
            try await mounts.forceUnmount(
                definition.mountPoint,
                expectedSource: definition.source,
                cancellation: cancellation
            )
            mountState = .unavailable
            if isCancelled() { return await cancellationResult(stopped: stopped, mountState: mountState) }

            try cancellation.throwIfCancelled()
            try await mounts.validateEmptyMountPoint(definition.mountPoint, cancellation: cancellation)
            if isCancelled() { return await cancellationResult(stopped: stopped, mountState: mountState) }

            try cancellation.throwIfCancelled()
            try await mounts.mount(definition, cancellation: cancellation)
            if isCancelled() { return await cancellationResult(stopped: stopped, mountState: mountState) }

            try cancellation.throwIfCancelled()
            try await mounts.verifySource(definition.source, at: definition.mountPoint, cancellation: cancellation)
            if isCancelled() { return await cancellationResult(stopped: stopped, mountState: mountState) }

            try cancellation.throwIfCancelled()
            let freshProbe = try await mounts.probe(definition, cancellation: cancellation)
            if isCancelled() { return await cancellationResult(stopped: stopped, mountState: mountState) }
            guard ProbeClassifier.classify(freshProbe).state == .healthy else { throw RecoveryFailure.probeFailed }
            mountState = .verified
            if isCancelled() { return await cancellationResult(stopped: stopped, mountState: mountState) }
            switch await restartAndVerify(stopped, cancellation: cancellation) {
            case .success:
                if isCancelled() {
                    _ = await stopAndVerify(stopped)
                    return await cancellationResult(stopped: stopped, mountState: .verified)
                }
            case .failed:
                throw RecoveryFailure.dependencyRestartFailed
            case .cancelled:
                return await cancellationResult(stopped: stopped, mountState: .verified)
            }
            return .init(state: .healthy, code: .none, detail: "The exact NFS source was remounted and verified.", didAttemptRecovery: true)
        } catch MountOperationCancellationError.cancelled {
            return await cancellationResult(stopped: stopped, mountState: mountState)
        } catch {
            return .init(state: .failedClosed, code: .remountFailed, detail: "Recovery failed after dependencies stopped; they remain stopped to prevent local writes.", didAttemptRecovery: true)
        }
    }

    public func disableAndWaitUntilIdle() async {
        recoveryDisabled = true
        await waitUntilIdle()
    }

    public func waitUntilIdle() async {
        while recoveryInProgress { try? await Task.sleep(for: .milliseconds(50)) }
    }

    private func restartAndVerify(
        _ stopped: [RecoveryDependency],
        cancellation: MountOperationCancellation
    ) async -> DependencyRestartResult {
        var attempted: [RecoveryDependency] = []
        for dependency in stopped.reversed() {
            guard !cancellation.isCancelled else {
                _ = await stopAndVerify(attempted)
                return .cancelled
            }
            attempted.append(dependency)
            do {
                try cancellation.throwIfCancelled()
                try await dependencies.start(dependency, cancellation: cancellation)
                try cancellation.throwIfCancelled()
                try await dependencies.verifyRunning(dependency, cancellation: cancellation)
                try cancellation.throwIfCancelled()
            } catch MountOperationCancellationError.cancelled {
                _ = await stopAndVerify(attempted)
                return .cancelled
            } catch {
                _ = await stopAndVerify(attempted)
                return .failed
            }
        }
        guard !cancellation.isCancelled else {
            _ = await stopAndVerify(attempted)
            return .cancelled
        }
        return .success
    }

    private func stopAndVerify(_ dependenciesToStop: [RecoveryDependency]) async -> Bool {
        var allStopped = true
        for dependency in dependenciesToStop.reversed() {
            do {
                try await dependencies.stop(dependency)
            } catch {
                allStopped = false
            }
            do {
                if try await dependencies.isRunning(dependency) { allStopped = false }
            } catch {
                allStopped = false
            }
        }
        return allStopped
    }

    private func cancellationResult(
        stopped: [RecoveryDependency],
        mountState: RecoveryMountState
    ) async -> RecoveryResult {
        switch mountState {
        case .unavailable, .verified:
            return .init(
                state: .failedClosed,
                code: .verificationFailed,
                detail: "Recovery was canceled after the mount changed; dependencies remain stopped to prevent local writes.",
                didAttemptRecovery: true
            )
        case .untouched:
            if !stopped.isEmpty {
                guard await restoreStoppedDependenciesAfterCancellation(stopped) else {
                    return .init(
                        state: .failedClosed,
                        code: .verificationFailed,
                        detail: "Recovery was canceled before the mount changed, but a stopped dependency could not be safely restored.",
                        didAttemptRecovery: false
                    )
                }
                return .init(
                    state: .stale,
                    code: .verificationFailed,
                    detail: "Recovery was canceled before the mount changed; stopped dependencies were restored and verified.",
                    didAttemptRecovery: false
                )
            }
            return .init(
                state: .stale,
                code: .verificationFailed,
                detail: "Recovery was canceled because this mount's generation changed.",
                didAttemptRecovery: false
            )
        }
    }

    private func restoreStoppedDependenciesAfterCancellation(_ stopped: [RecoveryDependency]) async -> Bool {
        switch await restartAndVerify(stopped, cancellation: .never) {
        case .success:
            return true
        case .failed, .cancelled:
            return false
        }
    }
}

private enum RecoveryMountState { case untouched, unavailable, verified }
private enum RecoveryFailure: Error { case probeFailed, dependencyRestartFailed }
private enum DependencyRestartResult { case success, failed, cancelled }
