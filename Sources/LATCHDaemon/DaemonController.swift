import Foundation
import LATCHShared
import OSLog

final class OperationCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var interruption: OperationInterruption = .none

    var isCancelled: Bool { lock.withLock { cancelled } }
    var observedInterruption: OperationInterruption { lock.withLock { interruption } }

    func cancel() {
        lock.withLock { cancelled = true }
    }

    @discardableResult
    func observeCancellation() -> Bool {
        lock.withLock {
            guard cancelled else { return false }
            interruption = .cancellationObserved
            return true
        }
    }

    func observeSupersession() {
        lock.withLock {
            if interruption == .none { interruption = .supersessionObserved }
        }
    }
}

actor DaemonController {
    let logger = Logger(subsystem: LATCHIdentity.bundleIdentifier, category: "configuration")
    let stateLogger = Logger(subsystem: LATCHIdentity.bundleIdentifier, category: "mount")
    let recoveryLogger = Logger(subsystem: LATCHIdentity.bundleIdentifier, category: "recovery")
    let persistenceLogger = Logger(subsystem: LATCHIdentity.bundleIdentifier, category: "persistence")
    let store = ConfigurationStore()
    let stateStore: RecoveryStateStore
    let table = DarwinMountTable()
    let mounts: SystemMountOperator
    let mountExecutor: GuardedMountExecutor
    let agent: any AgentRequesting
    let agentIsOnline: @Sendable () -> Bool
    let dependencies: TypedDependencyOperator
    let permissionGate: PermissionGate
    let coordinator: RecoveryCoordinator
    let networkSnapshots: any NetworkSnapshotProviding
    let wakeOnLAN: WakeOnLANController
    let automaticWake: AutomaticWakeOrchestrator
    let discovery = BonjourNFSServerDiscovery()
    let mountWork = MountWorkCoordinator()
    var configuration: LATCHConfiguration
    var statuses: [UUID: MountStatus] = [:]
    var events: [LATCHEvent] = []
    var networkVolumesVerification: NetworkVolumesVerificationState = .notChecked
    var monitoringTask: Task<Void, Never>?
    var operationTasks: [UUID: Task<Void, Never>] = [:]
    var operationSnapshots: [UUID: OperationSnapshot] = [:]
    var operationCancellations: [UUID: OperationCancellationToken] = [:]
    var operationMountIDs: [UUID: UUID] = [:]
    var lastChecks: [UUID: Date] = [:]
    var mountedAt: [UUID: Date] = [:]
    var lastRuleSatisfaction: [UUID: Bool] = [:]
    let firstHealthCheckGrace: TimeInterval = 3
    let onStatusesChanged: @Sendable ([MountStatus]) -> Void
    let onEventsChanged: @Sendable ([LATCHEvent]) -> Void

    init(
        probeRunner: any ProbeRunning,
        agent: any AgentRequesting,
        agentIsOnline: @escaping @Sendable () -> Bool = { false },
        dependencies: TypedDependencyOperator,
        networkSnapshots: any NetworkSnapshotProviding,
        onStatusesChanged: @escaping @Sendable ([MountStatus]) -> Void = { _ in },
        onEventsChanged: @escaping @Sendable ([LATCHEvent]) -> Void = { _ in }
    ) {
        let stateStore = RecoveryStateStore()
        self.stateStore = stateStore
        let mountOperator = SystemMountOperator(probeRunner: probeRunner)
        mounts = mountOperator
        mountExecutor = GuardedMountExecutor(mounts: mountOperator)
        self.agent = agent
        self.agentIsOnline = agentIsOnline
        self.dependencies = dependencies
        let permission = PermissionGate()
        permissionGate = permission
        coordinator = RecoveryCoordinator(mounts: mounts, dependencies: dependencies, permissionGate: { await permission.value }, cooldownStore: stateStore)
        self.networkSnapshots = networkSnapshots
        let wakeOnLAN = WakeOnLANController(sender: NativeWakeOnLANPacketSender(), broadcasts: NativeIPv4BroadcastProvider(), state: stateStore)
        self.wakeOnLAN = wakeOnLAN
        automaticWake = AutomaticWakeOrchestrator(performer: NativeAutomaticWakePerformer(controller: wakeOnLAN, reachability: NativeNFSReachability()))
        configuration = (try? store.load()) ?? LATCHConfiguration()
        self.onStatusesChanged = onStatusesChanged
        self.onEventsChanged = onEventsChanged
    }

    func start() {
        guard monitoringTask == nil else { return }
        monitoringTask = Task { [weak self] in
            guard let self else { return }
            let persistedVerification = await self.stateStore.networkVolumesVerification()
            await self.restoreVerification(persistedVerification)
            let persistedStatuses = await self.stateStore.statuses()
            let persistedEvents = await self.stateStore.events()
            await self.restoreRuntime(statuses: persistedStatuses, events: persistedEvents)
            var isInitialEvaluation = true
            while !Task.isCancelled {
                await self.runDueChecks(forceRuleTransition: isInitialEvaluation)
                isInitialEvaluation = false
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func handle(_ request: LATCHRequest) async -> LATCHResponse {
        do {
            switch request {
            case .getServiceStatus:
                return .serviceStatus(.init(
                    daemonOnline: true,
                    daemonAuthorized: true,
                    agentAuthorized: true,
                    agentOnline: agentIsOnline(),
                    networkVolumesVerification: networkVolumesVerification,
                    persistenceHealth: await stateStore.persistenceHealthSnapshot()
                ))
            case .getStatus: return .statuses(Array(statuses.values))
            case .getConfiguration: return .configuration(configuration)
            case .getOperations:
                return .operationSnapshots(operationSnapshots.values.sorted { $0.updatedAt > $1.updatedAt })
            case .exportPortableConfiguration:
                return .portableConfiguration(try PortableConfigurationCodec.export(configuration))
            case .previewPortableConfiguration(let data):
                return .portableConfigurationPreview(try PortableConfigurationImporter.preview(data, current: configuration, liveMounts: try externalMounts()))
            case .applyPortableConfiguration(let data, let approvedServerIDs, let approvedMountIDs):
                let candidate = try PortableConfigurationImporter.apply(
                    data,
                    approvedServerIDs: Set(approvedServerIDs),
                    approvedMountIDs: Set(approvedMountIDs),
                    current: configuration,
                    liveMounts: try externalMounts()
                )
                invalidateMountWork(for: Set(configuration.mounts.map(\.id) + candidate.mounts.map(\.id)))
                try ConfigurationPersistenceTransaction.commit(candidate, current: &configuration) { try store.save($0) }
                return .accepted
            case .saveServer(let server):
                var candidate = configuration
                candidate.servers.removeAll { $0.id == server.id }
                candidate.servers.append(server)
                try ConfigurationValidator().validate(candidate, liveMounts: try externalMounts())
                invalidateMountWork(for: configuration.mounts.map(\.id))
                try ConfigurationPersistenceTransaction.commit(candidate, current: &configuration) { try store.save($0) }
                return .accepted
            case .saveServerAndDefinition(let server, let definition):
                let isNew = !configuration.mounts.contains { $0.id == definition.id }
                var candidate = configuration
                candidate.servers.removeAll { $0.id == server.id }
                candidate.servers.append(server)
                candidate.mounts.removeAll { $0.id == definition.id }
                candidate.mounts.append(definition)
                try ConfigurationValidator().validate(candidate, liveMounts: try externalMounts())
                invalidateMountWork(for: Set(configuration.mounts.map(\.id) + candidate.mounts.map(\.id)))
                try ConfigurationPersistenceTransaction.commit(candidate, current: &configuration) { try store.save($0) }
                await finishSaving(definition, isNew: isNew)
                return .accepted
            case .removeServer(let id):
                guard configuration.servers.contains(where: { $0.id == id }) else { return .failure(.malformedRequest, "Unknown NFS server.") }
                guard !configuration.mounts.contains(where: { $0.serverID == id }) else {
                    return .failure(.mountConflict, "Remove or reassign every mount that uses this server first.")
                }
                var candidate = configuration
                candidate.servers.removeAll { $0.id == id }
                try ConfigurationPersistenceTransaction.commit(candidate, current: &configuration) { try store.save($0) }
                return .accepted
            case .getExternalMounts: return .externalMounts(try externalMounts())
            case .getDiscoveredServers: return .discoveredServers(discovery.snapshots())
            case .wakeServer(let id):
                guard let server = configuration.servers.first(where: { $0.id == id }), let settings = server.wakeOnLAN else {
                    return .failure(.malformedRequest, "This server does not have valid Wake-on-LAN settings.")
                }
                let sent = try await wakeOnLAN.wake(serverID: id, settings: settings, trigger: .manual)
                guard sent else { return .failure(.networkUnavailable, "No active IPv4 broadcast address is available for Wake-on-LAN.") }
                await recordWakeEvent(server: server, detail: "Sent a manual Wake-on-LAN request.")
                return .accepted
            case .getRecentEvents(let limit): return .events(Array(events.suffix(max(0, min(limit, 500)))))
            case .clearEvents:
                let shouldClear = await withPersistenceIgnoreError { [weak self] in
                    try await self?.stateStore.clearEvents()
                }
                if shouldClear {
                    events.removeAll()
                    onEventsChanged([])
                }
                return .accepted
            case .saveDefinition(let definition):
                let isNew = !configuration.mounts.contains { $0.id == definition.id }
                var updated = configuration.mounts.filter { $0.id != definition.id }
                var candidate = configuration
                let saved = definition
                guard candidate.resolve(saved) != nil else { return .failure(.malformedRequest, "Select an existing NFS server.") }
                updated.append(saved)
                candidate.mounts = updated
                try ConfigurationValidator().validate(candidate, liveMounts: try externalMounts())
                mountWork.invalidate(saved.id)
                try ConfigurationPersistenceTransaction.commit(candidate, current: &configuration) { try store.save($0) }
                await finishSaving(saved, isNew: isNew)
                return .accepted
            case .removeDefinition(let id, let confirmMounted):
                guard let definition = configuration.mounts.first(where: { $0.id == id }) else { return .failure(.malformedRequest, "Unknown mount definition.") }
                guard let resolved = resolvedDefinition(definition) else { return .failure(.malformedRequest, "The mount references an unknown NFS server.") }
                mountWork.invalidate(id)
                let currentSource = try await mounts.currentSource(at: resolved.mountPoint)
                switch MountRemovalDisposition.resolve(currentSource: currentSource, expectedSource: resolved.source, confirmed: confirmMounted) {
                case .requiresConfirmation:
                    return .failure(.mountConflict, "Removing a mounted definition requires confirmation.")
                case .sourceConflict:
                    return .failure(.sourceMismatch, "A different source owns the configured mountpoint.")
                case .unmountThenRemove:
                    await coordinator.waitUntilIdle()
                    try await mounts.forceUnmount(resolved.mountPoint, expectedSource: resolved.source)
                case .remove:
                    break
                }
                var candidate = configuration
                candidate.mounts.removeAll { $0.id == id }
                try ConfigurationPersistenceTransaction.commit(candidate, current: &configuration) { try store.save($0) }
                statuses[id] = nil
                lastChecks[id] = nil
                mountedAt[id] = nil
                lastRuleSatisfaction[id] = nil
                await withPersistenceIgnoreError { [weak self] in
                    try await self?.stateStore.removeMountState(for: id)
                }
                onStatusesChanged(Array(statuses.values))
                return .accepted
            case .setEnabled(let id, let enabled):
                guard let index = configuration.mounts.firstIndex(where: { $0.id == id }) else { return .failure(.malformedRequest, "Unknown mount definition.") }
                mountWork.invalidate(id)
                var candidate = configuration
                candidate.mounts[index].enabled = enabled
                try ConfigurationPersistenceTransaction.commit(candidate, current: &configuration) { try store.save($0) }
                let _ = await withPersistenceIgnoreError { [weak self] in
                    try await self?.stateStore.setAutomaticRetryState(nil, for: id)
                }
                return .accepted
            case .perform(let id, let action, let confirmed):
                guard let definition = configuration.mounts.first(where: { $0.id == id }) else { return .failure(.malformedRequest, "Unknown mount definition.") }
                guard let resolved = resolvedDefinition(definition) else { return .failure(.malformedRequest, "The mount references an unknown NFS server.") }
                return queueOperation(action: action, definition: resolved, confirmed: confirmed)
            case .getOperation(let operationID):
                guard let snapshot = operationSnapshots[operationID] else {
                    return .failure(.malformedRequest, "Unknown operation.")
                }
                return .operationSnapshot(snapshot)
            case .cancelOperation(let operationID):
                return cancelOperation(operationID)
            case .verifyNetworkVolumesPermission:
                await setVerification(.checking)
                let verification = await verifyPermission()
                await setVerification(verification)
                return verification.isVerified ? .accepted : .failure(.tccDenied, "The registered daemon probe could not verify Network Volumes access.")
            case .uninstall(let unmountOwned, let removeState, let confirmed):
                guard confirmed else { return .failure(.unauthorized, "Uninstall requires explicit confirmation.") }
                invalidateMountWork(for: configuration.mounts.map(\.id))
                await coordinator.disableAndWaitUntilIdle()
                if unmountOwned {
                    for definition in configuration.mounts {
                        if try await mounts.currentSource(at: definition.mountPoint) == definition.source {
                            try await mounts.forceUnmount(definition.mountPoint, expectedSource: definition.source)
                        }
                    }
                }
                var disabledConfiguration = configuration
                disabledConfiguration.mounts = disabledConfiguration.mounts.map {
                    var disabled = $0
                    disabled.enabled = false
                    return disabled
                }
                if removeState {
                    try ConfigurationPersistenceTransaction.commit(LATCHConfiguration(), current: &configuration) { _ in
                        try store.removeAllState()
                    }
                } else {
                    try ConfigurationPersistenceTransaction.commit(disabledConfiguration, current: &configuration) { try store.save($0) }
                }
                return .accepted
            }
        } catch {
            logger.error("Request failed: \(error.localizedDescription, privacy: .public)")
            return .failure(.verificationFailed, error.localizedDescription)
        }
    }

    private func queueOperation(action: LATCHAction, definition: MountDefinition, confirmed: Bool) -> LATCHResponse {
        if OperationLifecycle.conflict(for: definition.id, in: operationSnapshots.values) != nil {
            return .failure(.mountConflict, "Another operation is already active for this mount.")
        }
        let operationID = UUID()
        let receipt = OperationReceipt(id: operationID, mountID: definition.id, action: action)
        let cancellation = OperationCancellationToken()
        operationSnapshots[operationID] = OperationSnapshot(
            id: operationID,
            mountID: definition.id,
            action: action,
            state: .accepted,
            canCancel: true,
            detail: "Operation queued.",
            updatedAt: receipt.startedAt
        )
        operationCancellations[operationID] = cancellation
        operationMountIDs[operationID] = definition.id
        let operation = Task { [weak self] in
            guard let self else { return }
            if cancellation.isCancelled || Task.isCancelled {
                await self.updateOperation(operationID, state: .cancelled, canCancel: false, detail: "Operation cancelled.")
                await self.finishQueuedOperation(operationID)
                return
            }
            self.logger.notice("Queued operation started: \(action.rawValue, privacy: .public) / \(operationID.uuidString, privacy: .public)")
            await self.updateOperation(
                operationID,
                state: .running,
                canCancel: true,
                detail: "Operation in progress."
            )
            let response = await self.perform(
                action,
                definition: definition,
                confirmed: confirmed,
                operationCancellation: cancellation
            )
            switch OperationLifecycle.completion(response: response, interruption: cancellation.observedInterruption) {
            case .cancelled:
                self.logger.notice("Queued operation cancelled: \(operationID.uuidString, privacy: .public)")
                await self.updateOperation(
                    operationID,
                    state: .cancelled,
                    canCancel: false,
                    detail: "Operation cancelled."
                )
            case .failed(let code, let detail):
                self.logger.error("Queued operation failed: \(code.rawValue, privacy: .public) / \(detail, privacy: .public)")
                await self.updateOperation(operationID, state: .failed, canCancel: false, detail: detail)
            case .succeeded:
                self.logger.notice("Queued operation completed: \(operationID.uuidString, privacy: .public)")
                await self.updateOperation(operationID, state: .succeeded, canCancel: false, detail: "Operation completed.")
            }
            await self.finishQueuedOperation(operationID)
        }
        operationTasks[operationID] = operation
        return .operationAccepted(receipt)
    }

    private func finishQueuedOperation(_ operationID: UUID) {
        operationTasks.removeValue(forKey: operationID)
        operationCancellations.removeValue(forKey: operationID)
        operationMountIDs.removeValue(forKey: operationID)
        trimOperationSnapshots()
    }

    private func updateOperation(
        _ operationID: UUID,
        state: OperationState,
        canCancel: Bool,
        detail: String?
    ) {
        guard let current = operationSnapshots[operationID] else { return }
        operationSnapshots[operationID] = OperationSnapshot(
            id: current.id,
            mountID: current.mountID,
            action: current.action,
            state: state,
            canCancel: canCancel,
            detail: detail,
            updatedAt: Date()
        )
    }

    private func cancelOperation(_ operationID: UUID) -> LATCHResponse {
        guard let current = operationSnapshots[operationID] else {
            return .failure(.malformedRequest, "Unknown operation.")
        }
        guard current.state == .accepted || current.state == .running else {
            return .operationSnapshot(current)
        }
        operationCancellations[operationID]?.cancel()
        operationTasks[operationID]?.cancel()
        logger.notice("Queued operation cancellation requested: \(operationID.uuidString, privacy: .public)")
        let requested = OperationSnapshot(
            id: current.id,
            mountID: current.mountID,
            action: current.action,
            state: current.state,
            canCancel: false,
            detail: "Cancellation requested.",
            updatedAt: Date()
        )
        operationSnapshots[operationID] = requested
        return .operationSnapshot(requested)
    }

    private func trimOperationSnapshots() {
        guard operationSnapshots.count > 100 else { return }
        for operationID in OperationLifecycle.pruningIDs(from: operationSnapshots.values, limit: 100) {
            operationSnapshots.removeValue(forKey: operationID)
        }
    }

    func perform(
        _ action: LATCHAction,
        definition: MountDefinition,
        confirmed: Bool,
        operationCancellation: OperationCancellationToken? = nil
    ) async -> LATCHResponse {
        guard operationCancellation?.observeCancellation() != true else { return .accepted }
        var activeToken: MountWorkToken?
        defer {
            if let activeToken { mountWork.finishManual(activeToken) }
        }
        do {
            switch action {
            case .check:
                let token = mountWork.beginManual(for: definition.id)
                activeToken = token
                let cancellation = mountCancellation(for: token, operationCancellation: operationCancellation)
                let evaluation = await ruleEvaluation(for: definition)
                guard manualOperationIsCurrent(token, definition: definition, operationCancellation: operationCancellation) else { return .accepted }
                if let evaluation, !evaluation.isSatisfied {
                    await record(waitingForRulesStatus(definition, evaluation: evaluation, at: Date()))
                    guard manualOperationIsCurrent(token, definition: definition, operationCancellation: operationCancellation) else { return .accepted }
                    return .accepted
                }
                guard manualOperationIsCurrent(token, definition: definition, operationCancellation: operationCancellation) else { return .accepted }
                let networkAvailable = await mounts.networkAvailable(for: definition.host)
                guard manualOperationIsCurrent(token, definition: definition, operationCancellation: operationCancellation) else { return .accepted }
                guard networkAvailable else {
                    await record(status(definition, source: nil, state: .networkUnavailable, code: .networkUnavailable, detail: "The NFS server is not reachable.", at: Date()))
                    guard manualOperationIsCurrent(token, definition: definition, operationCancellation: operationCancellation) else { return .accepted }
                    return .accepted
                }
                guard manualOperationIsCurrent(token, definition: definition, operationCancellation: operationCancellation) else { return .accepted }
                let source = try await mounts.currentSource(at: definition.mountPoint)
                guard manualOperationIsCurrent(token, definition: definition, operationCancellation: operationCancellation) else { return .accepted }
                guard let source else {
                    await record(status(definition, source: nil, state: .unmounted, code: .none, detail: "The configured volume is not mounted.", at: Date()))
                    guard manualOperationIsCurrent(token, definition: definition, operationCancellation: operationCancellation) else { return .accepted }
                    return .accepted
                }
                guard source == definition.source else {
                    await record(status(definition, source: source, state: .probeError, code: .sourceMismatch, detail: "A different source owns the configured mountpoint.", at: Date()))
                    guard manualOperationIsCurrent(token, definition: definition, operationCancellation: operationCancellation) else { return .accepted }
                    return .accepted
                }
                guard manualOperationIsCurrent(token, definition: definition, operationCancellation: operationCancellation) else { return .accepted }
                let rawProbe = try await mounts.probe(definition, cancellation: cancellation)
                guard manualOperationIsCurrent(token, definition: definition, operationCancellation: operationCancellation) else { return .accepted }
                let probe = annotatePermission(rawProbe)
                await observeRuntimePermission(probe)
                guard manualOperationIsCurrent(token, definition: definition, operationCancellation: operationCancellation) else { return .accepted }
                await record(HealthMonitor.decision(definition: definition, observedSource: source, result: probe, previous: statuses[definition.id], at: Date()).status)
                guard manualOperationIsCurrent(token, definition: definition, operationCancellation: operationCancellation) else { return .accepted }
            case .mount:
                let token = mountWork.beginManual(for: definition.id)
                activeToken = token
                let cancellation = mountCancellation(for: token, operationCancellation: operationCancellation)
                do {
                    let committed = try await stateStore.setMonitoringState(
                        paused: false,
                        automaticRetry: nil,
                        for: definition.id,
                        ifCurrent: { [mountWork] in mountWork.isCurrent(token) }
                    )
                    guard committed else {
                        operationCancellation?.observeSupersession()
                        return .accepted
                    }
                } catch {
                    let detail = "Mount was not attempted because monitoring state could not be persisted: \(error.localizedDescription)"
                    await record(status(definition, source: nil, state: .probeError, code: .verificationFailed, detail: detail, at: Date()))
                    return .failure(.verificationFailed, detail)
                }
                guard manualOperationIsCurrent(token, definition: definition, operationCancellation: operationCancellation) else { return .accepted }
                await record(status(definition, source: nil, state: .mounting, code: .none, detail: "Mounting the configured NFS volume.", at: Date()))
                guard manualOperationIsCurrent(token, definition: definition, operationCancellation: operationCancellation) else { return .accepted }
                let currentSource = try await mounts.currentSource(at: definition.mountPoint)
                guard manualOperationIsCurrent(token, definition: definition, operationCancellation: operationCancellation) else { return .accepted }
                switch MountRequestDisposition.classify(
                    currentSource: currentSource,
                    expectedSource: definition.source
                ) {
                case .alreadyMounted:
                    await didMount(definition, previousSource: currentSource, token: token)
                    guard manualOperationIsCurrent(token, definition: definition, operationCancellation: operationCancellation) else { return .accepted }
                    return .accepted
                case .sourceConflict:
                    guard manualOperationIsCurrent(token, definition: definition, operationCancellation: operationCancellation) else { return .accepted }
                    await record(status(
                        definition,
                        source: currentSource,
                        state: .probeError,
                        code: .sourceMismatch,
                        detail: "A different source owns the configured mountpoint.",
                        at: Date()
                    ))
                    guard manualOperationIsCurrent(token, definition: definition, operationCancellation: operationCancellation) else { return .accepted }
                    return .failure(.sourceMismatch, "A different source owns the configured mountpoint.")
                case .mount:
                    guard manualOperationIsCurrent(token, definition: definition, operationCancellation: operationCancellation) else { return .accepted }
                    await withPersistenceIgnoreError { [weak self] in
                        try await self?.stateStore.clearPostMountActions(for: definition.id)
                    }
                    guard manualOperationIsCurrent(token, definition: definition, operationCancellation: operationCancellation) else { return .accepted }
                    break
                }
                let live = try externalMounts()
                try ConfigurationValidator().validate(configuration, liveMounts: live)
                try await mountExecutor.mount(definition, cancellation: cancellation)
                guard manualOperationIsCurrent(token, definition: definition, operationCancellation: operationCancellation) else { return .accepted }
                await didMount(definition, previousSource: currentSource, token: token)
                guard manualOperationIsCurrent(token, definition: definition, operationCancellation: operationCancellation) else { return .accepted }
            case .unmount:
                guard confirmed else { return .failure(.mountConflict, "Unmounting requires explicit confirmation.") }
                let token = mountWork.beginManual(for: definition.id)
                activeToken = token
                let cancellation = mountCancellation(for: token, operationCancellation: operationCancellation)
                await coordinator.waitUntilIdle()
                guard manualOperationIsCurrent(token, definition: definition, operationCancellation: operationCancellation) else { return .accepted }
                let source = try await mounts.currentSource(at: definition.mountPoint)
                guard manualOperationIsCurrent(token, definition: definition, operationCancellation: operationCancellation) else { return .accepted }
                if let source, source != definition.source {
                    return .failure(.sourceMismatch, "A different source owns the configured mountpoint.")
                }
                let previousPaused = await stateStore.isPaused(definition.id)
                let previousRetry = await stateStore.automaticRetryState(for: definition.id)
                do {
                    let committed = try await stateStore.setMonitoringState(
                        paused: true,
                        automaticRetry: nil,
                        for: definition.id,
                        ifCurrent: { [mountWork] in mountWork.isCurrent(token) }
                    )
                    guard committed else {
                        operationCancellation?.observeSupersession()
                        return .accepted
                    }
                } catch {
                    let detail = "Unmount was not attempted because monitoring could not be paused: \(error.localizedDescription)"
                    await record(status(definition, source: source, state: source == nil ? .unmounted : .probeError, code: .verificationFailed, detail: detail, at: Date()))
                    return .failure(.verificationFailed, detail)
                }
                do {
                    if source != nil {
                        try await mounts.forceUnmount(
                            definition.mountPoint,
                            expectedSource: definition.source,
                            cancellation: cancellation
                        )
                    }
                } catch {
                    do {
                        let rolledBack = try await stateStore.setMonitoringState(
                            paused: previousPaused,
                            automaticRetry: previousRetry,
                            for: definition.id,
                            ifCurrent: { [mountWork] in mountWork.isCurrent(token) }
                        )
                        if !rolledBack { operationCancellation?.observeSupersession() }
                    } catch {
                        let detail = "Unmount failed and the previous monitoring state could not be restored: \(error.localizedDescription)"
                        await record(status(definition, source: source, state: .probeError, code: .verificationFailed, detail: detail, at: Date()))
                        return .failure(.verificationFailed, detail)
                    }
                    throw error
                }
                guard manualOperationIsCurrent(token, definition: definition, operationCancellation: operationCancellation) else { return .accepted }
                await withPersistenceIgnoreError { [weak self] in
                    try await self?.stateStore.clearPostMountActions(for: definition.id)
                }
                guard manualOperationIsCurrent(token, definition: definition, operationCancellation: operationCancellation) else { return .accepted }
                await record(status(definition, source: nil, state: .disabled, code: .none, detail: "Monitoring is paused for this mount.", at: Date()))
                guard manualOperationIsCurrent(token, definition: definition, operationCancellation: operationCancellation) else { return .accepted }
            case .recover:
                guard confirmed else { return .failure(.unauthorized, "Manual recovery requires explicit confirmation.") }
                let token = mountWork.beginManual(for: definition.id)
                activeToken = token
                let evaluation = await ruleEvaluation(for: definition)
                guard manualOperationIsCurrent(token, definition: definition, operationCancellation: operationCancellation) else { return .accepted }
                if let evaluation, !evaluation.isSatisfied {
                    await record(waitingForRulesStatus(definition, evaluation: evaluation, at: Date()))
                    guard manualOperationIsCurrent(token, definition: definition, operationCancellation: operationCancellation) else { return .accepted }
                    return .accepted
                }
                guard manualOperationIsCurrent(token, definition: definition, operationCancellation: operationCancellation) else { return .accepted }
                await record(status(definition, source: definition.source, state: .recovering, code: .none, detail: "Manual guarded recovery is in progress.", at: Date()))
                guard manualOperationIsCurrent(token, definition: definition, operationCancellation: operationCancellation) else { return .accepted }
                let result = await coordinator.recover(
                    definition,
                    trigger: .manual,
                    isCancelled: { [mountWork, operationCancellation] in
                        if operationCancellation?.observeCancellation() == true { return true }
                        let isCurrent = mountWork.isCurrent(token)
                        if !isCurrent { operationCancellation?.observeSupersession() }
                        return !isCurrent
                    }
                )
                guard manualWorkIsCurrent(token, definition: definition, observingSupersession: operationCancellation) else { return .accepted }
                if result.state == .healthy || (result.code != .none && AutomaticRetryState.disposition(after: result.code) == .clear) {
                    switch await setAutomaticRetryState(nil, definition: definition, token: token, automatic: false) {
                    case .committed:
                        break
                    case .superseded:
                        operationCancellation?.observeSupersession()
                        return .accepted
                    case .failed(let detail):
                        return .failure(.verificationFailed, "Recovery completed, but its retry state could not be persisted: \(detail)")
                    }
                }
                guard manualWorkIsCurrent(token, definition: definition, observingSupersession: operationCancellation) else { return .accepted }
                await record(status(definition, source: definition.source, state: result.state, code: result.code, detail: result.detail, at: Date(), recovered: result.didAttemptRecovery))
                guard manualWorkIsCurrent(token, definition: definition, observingSupersession: operationCancellation) else { return .accepted }
                return OperationLifecycle.recoveryResponse(
                    state: result.state,
                    code: result.code,
                    detail: result.detail,
                    interruption: operationCancellation?.observedInterruption ?? .none
                )
            case .reveal:
                let token = mountWork.beginManual(for: definition.id)
                activeToken = token
                guard manualOperationIsCurrent(token, definition: definition, operationCancellation: operationCancellation) else { return .accepted }
                guard try await mounts.currentSource(at: definition.mountPoint) == definition.source else {
                    return .failure(.sourceMismatch, "The configured source is not mounted at this location.")
                }
                guard manualOperationIsCurrent(token, definition: definition, operationCancellation: operationCancellation) else { return .accepted }
                let response = try await agent.request(.revealManagedMount(mountPoint: definition.mountPoint))
                guard manualOperationIsCurrent(token, definition: definition, operationCancellation: operationCancellation) else { return .accepted }
                guard response == .succeeded else {
                    if case .failed(let detail) = response { return .failure(.verificationFailed, detail) }
                    return .failure(.verificationFailed, "The signed user agent could not reveal this mount.")
                }
            }
            return .accepted
        } catch {
            if let activeToken,
               !manualOperationIsCurrent(
                   activeToken,
                   definition: definition,
                   operationCancellation: operationCancellation
               ) {
                return .accepted
            }
            switch action {
            case .mount:
                guard let token = activeToken else { return .failure(.verificationFailed, error.localizedDescription) }
                let code = mountFailureCode(for: error)
                let retryDisposition = AutomaticRetryState.disposition(after: code)
                if retryDisposition != .schedule {
                    if retryDisposition == .clear {
                        switch await setAutomaticRetryState(nil, definition: definition, token: token, automatic: false) {
                        case .committed:
                            break
                        case .superseded:
                            operationCancellation?.observeSupersession()
                            return .accepted
                        case .failed(let detail):
                            return .failure(.verificationFailed, "Mount failed and its retry state could not be persisted: \(detail)")
                        }
                    }
                    guard manualOperationIsCurrent(token, definition: definition, operationCancellation: operationCancellation) else { return .accepted }
                    await record(status(definition, source: nil, state: .probeError, code: code, detail: "Mount failed: \(error.localizedDescription)", at: Date()))
                    guard manualOperationIsCurrent(token, definition: definition, operationCancellation: operationCancellation) else { return .accepted }
                    return .failure(code, error.localizedDescription)
                } else {
                    let retry: AutomaticRetryState
                    switch await scheduleRetry(kind: .missingMount, definition: definition, token: token, automatic: false, at: Date()) {
                    case .scheduled(let scheduled):
                        retry = scheduled
                    case .superseded:
                        operationCancellation?.observeSupersession()
                        return .accepted
                    case .failed(let detail):
                        return .failure(.verificationFailed, "Mount failed and its automatic retry could not be persisted: \(detail)")
                    }
                    guard manualOperationIsCurrent(token, definition: definition, operationCancellation: operationCancellation) else { return .accepted }
                    await record(status(definition, source: nil, state: .retryScheduled, code: .remountFailed, detail: "Mount failed: \(error.localizedDescription)", at: Date(), nextAutomaticAttempt: retry.nextAttempt))
                    guard manualOperationIsCurrent(token, definition: definition, operationCancellation: operationCancellation) else { return .accepted }
                }
            case .check:
                guard let token = activeToken, manualOperationIsCurrent(token, definition: definition, operationCancellation: operationCancellation) else { return .accepted }
                await record(status(definition, source: nil, state: .probeError, code: .verificationFailed, detail: "Check failed: \(error.localizedDescription)", at: Date()))
                guard manualOperationIsCurrent(token, definition: definition, operationCancellation: operationCancellation) else { return .accepted }
            case .unmount, .recover, .reveal:
                break
            }
            return .failure(.verificationFailed, error.localizedDescription)
        }
    }

    func verifyPermission() async -> NetworkVolumesVerificationState {
        for definition in configuration.mounts where definition.enabled {
            guard let resolved = resolvedDefinition(definition), (try? await mounts.currentSource(at: resolved.mountPoint)) == resolved.source else { continue }
            if ProbeClassifier.classify(await mounts.probe(resolved)).state == .healthy { return .verified }
        }
        return .failed
    }

    func restoreVerification(_ verification: NetworkVolumesVerificationState) async {
        networkVolumesVerification = verification
        await permissionGate.set(verification.isVerified)
    }

    func setVerification(_ verification: NetworkVolumesVerificationState) async {
        await restoreVerification(verification)
        await withPersistenceIgnoreError { [weak self] in
            try await self?.stateStore.setNetworkVolumesVerification(verification)
        }
    }

    func restoreRuntime(statuses: [UUID: MountStatus], events: [LATCHEvent]) {
        self.statuses = statuses.filter { id, _ in configuration.mounts.contains { $0.id == id } }
        self.events = Array(events.suffix(500))
        onStatusesChanged(Array(self.statuses.values))
        onEventsChanged(Array(self.events.suffix(100)))
    }
}

actor PermissionGate {
    var value = false
    func set(_ newValue: Bool) { value = newValue }
}
