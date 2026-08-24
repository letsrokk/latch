import Foundation
import LATCHShared

enum AutomaticRetryPersistenceResult: Sendable, Equatable {
    case committed
    case superseded
    case failed(String)
}

enum AutomaticRetryScheduleResult: Sendable, Equatable {
    case scheduled(AutomaticRetryState)
    case superseded
    case failed(String)
}

extension DaemonController {
    func annotatePermission(_ result: ProbeResult) -> ProbeResult {
        result.annotatingNetworkVolumesDenial(permissionVerified: networkVolumesVerification.isVerified)
    }

    func observeRuntimePermission(_ result: ProbeResult) async {
        let verification = NetworkVolumesPermissionPolicy.afterRuntimeProbe(
            current: networkVolumesVerification,
            result: result
        )
        if verification != networkVolumesVerification { await setVerification(verification) }
    }

    func finishSaving(_ definition: MountDefinition, isNew: Bool) async {
        let transition = SavedMountTransition(isNew: isNew, enabled: definition.enabled)
        await withPersistenceIgnoreError { [weak self] in
            try await self?.stateStore.setAutomaticRetryState(nil, for: definition.id)
        }
        if isNew {
            await withPersistenceIgnoreError { [weak self] in
                try await self?.stateStore.setPaused(false, for: definition.id)
            }
        }
        lastChecks[definition.id] = transition.lastCheck
        mountedAt[definition.id] = nil
        if let initialState = transition.initialState {
            let detail = initialState == .mounting
                ? "Preparing the configured NFS mount."
                : "Monitoring is disabled for this mount."
            await record(status(definition, source: nil, state: initialState, code: .none, detail: detail, at: Date()))
        }
        if transition.shouldScheduleAutomaticCheck {
            Task { [weak self] in await self?.runDueChecks() }
        }
    }

    func ruleEvaluation(for definition: MountDefinition) async -> NetworkRuleEvaluation? {
        guard let server = configuration.servers.first(where: { $0.hostname == definition.host }), !server.networkMountRules.rules.isEmpty else { return nil }
        return NetworkMountRuleEvaluator.evaluate(server.networkMountRules, snapshot: await networkSnapshots.snapshot(for: server.hostname))
    }

    func waitingForRulesStatus(_ definition: MountDefinition, evaluation: NetworkRuleEvaluation, at date: Date) -> MountStatus {
        status(
            definition,
            source: nil,
            state: .waitingForRules,
            code: .none,
            detail: "Waiting for the server's network rules.",
            at: date,
            unmetRuleSummaries: evaluation.unmetRuleSummaries
        )
    }

    func didMount(
        _ definition: MountDefinition,
        previousSource: String?,
        token: MountWorkToken? = nil,
        automatic: Bool = false
    ) async {
        guard await mountWorkIsCurrent(token, definition: definition, automatic: automatic) else { return }
        let date = Date()
        mountedAt[definition.id] = date
        lastChecks[definition.id] = nil
        await record(status(
            definition,
            source: definition.source,
            state: .mounting,
            code: .none,
            detail: "Mounted. Waiting for the first health check.",
            at: date
        ))
        guard await mountWorkIsCurrent(token, definition: definition, automatic: automatic) else { return }
        await executePostMountActions(
            definition,
            token: token,
            automatic: automatic,
            createIfNeeded: PostMountDispatchPolicy.shouldDispatch(
                previousSource: previousSource,
                verifiedSource: definition.source
            )
        )
    }

    func executePostMountActions(
        _ definition: MountDefinition,
        token: MountWorkToken?,
        automatic: Bool,
        createIfNeeded: Bool
    ) async {
        guard await mountWorkIsCurrent(token, definition: definition, automatic: automatic) else { return }
        guard await stateStore.postMountActionSource(for: definition.id) != definition.source else { return }
        guard await mountWorkIsCurrent(token, definition: definition, automatic: automatic) else { return }

        let delivery: PostMountActionDelivery
        do {
            if let pending = await stateStore.pendingPostMountActionDelivery(for: definition.id),
               pending.source == definition.source,
               pending.mountPoint == definition.mountPoint,
               pending.items.map(\.action) == definition.postMountActions {
                delivery = pending
            } else {
                guard createIfNeeded else { return }
                delivery = try await stateStore.preparePostMountActionDelivery(
                    mountID: definition.id,
                    source: definition.source,
                    mountPoint: definition.mountPoint,
                    actions: definition.postMountActions
                )
            }
        } catch {
            await recordPostMountActionFailure(definition, detail: "Post-mount actions were not persisted: \(error.localizedDescription)")
            return
        }
        guard await mountWorkIsCurrent(token, definition: definition, automatic: automatic) else { return }

        let response: AgentResponse
        do {
            response = try await agent.request(.executePostMountActions(delivery))
        } catch {
            // Keep the delivery pending. The next healthy check retries it after
            // the login agent reconnects, without reporting a mount failure.
            return
        }
        guard await mountWorkIsCurrent(token, definition: definition, automatic: automatic) else { return }
        guard case .postMountActionsAcknowledged(let acknowledgement) = response,
              acknowledgement.deliveryID == delivery.id else {
            await recordPostMountActionFailure(definition, detail: "Post-mount actions returned an invalid acknowledgement.")
            return
        }
        do {
            try await stateStore.acknowledgePostMountActionDelivery(acknowledgement.deliveryID)
        } catch {
            await recordPostMountActionFailure(definition, detail: "Post-mount actions could not be acknowledged: \(error.localizedDescription)")
            return
        }
        guard await mountWorkIsCurrent(token, definition: definition, automatic: automatic) else { return }
        for failure in acknowledgement.failures {
            await recordPostMountActionFailure(definition, detail: "Post-mount action failed: \(failure)")
        }
    }

    func mountWorkIsCurrent(
        _ token: MountWorkToken?,
        definition: MountDefinition,
        automatic: Bool
    ) async -> Bool {
        guard let token else { return true }
        if automatic { return await automaticWorkIsCurrent(token, definition: definition) }
        return manualWorkIsCurrent(token, definition: definition)
    }

    func recordPostMountActionFailure(_ definition: MountDefinition, detail: String) async {
        appendEvent(.init(
            date: Date(),
            mountID: definition.id,
            state: statuses[definition.id]?.state,
            code: .verificationFailed,
            detail: detail
        ))
        await persistRuntime()
    }

    func status(_ definition: MountDefinition, source: String?, state: MountState, code: LATCHErrorCode, detail: String, at date: Date, recovered: Bool = false, nextAutomaticAttempt: Date? = nil, unmetRuleSummaries: [String] = []) -> MountStatus {
        let previous = statuses[definition.id]
        return MountStatus(
            definitionID: definition.id,
            observedSource: source,
            observedMountPoint: definition.mountPoint,
            state: state,
            lastProbe: date,
            lastStateChange: previous?.state == state ? (previous?.lastStateChange ?? date) : date,
            lastHealthyTime: state == .healthy ? date : previous?.lastHealthyTime,
            lastRecoveryTime: recovered ? date : previous?.lastRecoveryTime,
            detail: detail,
            errorCode: code,
            nextAutomaticAttempt: nextAutomaticAttempt,
            unmetRuleSummaries: unmetRuleSummaries
        )
    }

    func resolvedDefinition(_ definition: MountDefinition) -> MountDefinition? {
        if let resolved = configuration.resolve(definition) { return definition.resolved(using: resolved.server) }
        return definition.host.isEmpty ? nil : definition
    }

    func scheduleRetry(
        kind: AutomaticRetryKind,
        definition: MountDefinition,
        token: MountWorkToken,
        automatic: Bool,
        at date: Date
    ) async -> AutomaticRetryScheduleResult {
        guard await mountWorkIsCurrent(token, definition: definition, automatic: automatic) else { return .superseded }
        let previous = await stateStore.automaticRetryState(for: definition.id)
        guard await mountWorkIsCurrent(token, definition: definition, automatic: automatic) else { return .superseded }
        let failures = previous?.kind == kind ? (previous?.failures ?? 0) + 1 : 0
        let interval: TimeInterval = switch kind {
        case .missingMount: AutomaticRetryState.missingMountInterval(afterFailures: failures)
        case .staleRecovery: AutomaticRetryState.staleInterval(recoveryCooldownSeconds: definition.recoveryCooldownSeconds, afterFailures: failures)
        }
        let retry = AutomaticRetryState(kind: kind, failures: failures, nextAttempt: date.addingTimeInterval(interval))
        switch await setAutomaticRetryState(retry, definition: definition, token: token, automatic: automatic) {
        case .committed: return .scheduled(retry)
        case .superseded: return .superseded
        case .failed(let detail): return .failed(detail)
        }
    }

    func setAutomaticRetryState(
        _ retry: AutomaticRetryState?,
        definition: MountDefinition,
        token: MountWorkToken,
        automatic: Bool
    ) async -> AutomaticRetryPersistenceResult {
        guard await mountWorkIsCurrent(token, definition: definition, automatic: automatic) else { return .superseded }
        let committed: Bool
        do {
            committed = try await stateStore.setAutomaticRetryState(
                retry,
                for: definition.id,
                ifCurrent: { [mountWork] in mountWork.isCurrent(token) }
            )
        } catch {
            persistenceLogger.notice("Unable to persist automatic retry state for \(definition.id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return .failed(error.localizedDescription)
        }
        guard committed else { return .superseded }
        return await mountWorkIsCurrent(token, definition: definition, automatic: automatic) ? .committed : .superseded
    }

    func mountCancellation(
        for token: MountWorkToken,
        operationCancellation: OperationCancellationToken? = nil
    ) -> MountOperationCancellation {
        MountOperationCancellation(isCancelled: { [mountWork, operationCancellation] in
            !mountWork.isCurrent(token) || operationCancellation?.isCancelled == true
        })
    }

    func mountFailureCode(for error: Error) -> LATCHErrorCode {
        if let validation = error as? ConfigurationValidationError {
            switch validation {
            case .externalSourceConflict, .duplicateSource: return .sourceMismatch
            case .externalMountPointConflict, .duplicateMountPoint: return .mountConflict
            default: break
            }
        }
        if let posix = error as? POSIXError {
            if posix.code == .EACCES || posix.code == .EPERM { return .permissionDenied }
        }
        let detail = error.localizedDescription.lowercased()
        if detail.contains("tcc") { return .tccDenied }
        if detail.contains("permission denied") || detail.contains("operation not permitted") { return .permissionDenied }
        return .remountFailed
    }

    func externalMounts(excluding definitions: [MountDefinition]? = nil) throws -> [ExternalMountSnapshot] {
        let owned = definitions ?? configuration.mounts
        return try table.snapshots().filter { snapshot in
            !owned.contains { definition in
                guard let resolved = resolvedDefinition(definition) else { return false }
                return resolved.source == snapshot.source && resolved.mountPoint == snapshot.mountPoint
            }
        }
    }

    func invalidateMountWork<S: Sequence>(for mountIDs: S) where S.Element == UUID {
        for mountID in mountIDs { mountWork.invalidate(mountID) }
    }

    func automaticWorkIsCurrent(_ token: MountWorkToken, definition: MountDefinition) async -> Bool {
        guard mountWork.isCurrent(token), !(await stateStore.isPaused(definition.id)), mountWork.isCurrent(token) else {
            return false
        }
        guard let current = configuration.mounts.first(where: { $0.id == definition.id }),
              current.enabled,
              resolvedDefinition(current) == definition else {
            return false
        }
        return true
    }

    func manualWorkIsCurrent(_ token: MountWorkToken, definition: MountDefinition) -> Bool {
        guard mountWork.isCurrent(token),
              let current = configuration.mounts.first(where: { $0.id == definition.id }),
              resolvedDefinition(current) == definition else {
            return false
        }
        return true
    }

    func manualWorkIsCurrent(
        _ token: MountWorkToken,
        definition: MountDefinition,
        observingSupersession operationCancellation: OperationCancellationToken?
    ) -> Bool {
        let isCurrent = manualWorkIsCurrent(token, definition: definition)
        if !isCurrent { operationCancellation?.observeSupersession() }
        return isCurrent
    }

    func manualOperationIsCurrent(
        _ token: MountWorkToken,
        definition: MountDefinition,
        operationCancellation: OperationCancellationToken?
    ) -> Bool {
        if operationCancellation?.observeCancellation() == true { return false }
        let isCurrent = manualWorkIsCurrent(token, definition: definition)
        if !isCurrent { operationCancellation?.observeSupersession() }
        return isCurrent
    }

    func record(_ status: MountStatus) async {
        let old = statuses[status.id]
        statuses[status.id] = status
        onStatusesChanged(Array(statuses.values))
        let requiresImmediateWrite = RuntimePersistencePolicy.requiresImmediateWrite(previous: old, next: status)
        if requiresImmediateWrite {
            stateLogger.notice("Mount \(status.id.uuidString, privacy: .public) changed to \(status.state.rawValue, privacy: .public): \(status.detail, privacy: .public)")
            appendEvent(.init(
                id: UUID(),
                date: Date(),
                mountID: status.id,
                state: status.state,
                code: status.errorCode,
                detail: status.detail
            ))
        }
        if requiresImmediateWrite {
            await persistRuntime()
        } else {
            scheduleRuntimePersistence()
        }
    }

    func appendEvent(_ event: LATCHEvent) {
        events.append(event)
        if events.count > 500 { events.removeFirst(events.count - 500) }
        onEventsChanged(Array(events.suffix(100)))
    }

    func persistRuntime() async {
        cancelScheduledRuntimePersistence()
        await writeRuntimeSnapshot()
    }

    func scheduleRuntimePersistence() {
        runtimePersistenceTask?.cancel()
        runtimePersistenceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await self?.flushScheduledRuntimePersistence()
        }
    }

    func cancelScheduledRuntimePersistence() {
        runtimePersistenceTask?.cancel()
        runtimePersistenceTask = nil
    }

    private func flushScheduledRuntimePersistence() async {
        runtimePersistenceTask = nil
        await writeRuntimeSnapshot()
    }

    private func writeRuntimeSnapshot() async {
        let statusSnapshot = statuses
        let eventSnapshot = events
        let generation = nextRuntimePersistenceGeneration()
        let started = DispatchTime.now().uptimeNanoseconds
        let persisted = await withPersistenceIgnoreError { [weak self] in
            try await self?.stateStore.setRuntime(
                statuses: statusSnapshot,
                events: eventSnapshot,
                minimumGeneration: generation
            )
        }
        let milliseconds = (DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        persistenceLogger.debug("Runtime persistence completed in \(milliseconds, privacy: .public) ms; success=\(persisted, privacy: .public)")
    }

    func nextRuntimePersistenceGeneration() -> UInt64 {
        runtimePersistenceGeneration &+= 1
        return runtimePersistenceGeneration
    }

    @discardableResult
    func withPersistenceIgnoreError(_ operation: @escaping () async throws -> Void) async -> Bool {
        do {
            try await operation()
            return true
        } catch {
            persistenceLogger.notice("Persistence write failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func recordWakeEvent(server: NFSServerProfile, detail: String) async {
        stateLogger.notice("Wake-on-LAN for server \(server.id.uuidString, privacy: .public): \(detail, privacy: .public)")
        appendEvent(.init(date: Date(), mountID: nil, state: .waking, code: .none, detail: detail))
        await persistRuntime()
    }
}

struct NativeAutomaticWakePerformer: AutomaticWakePerforming {
    let controller: WakeOnLANController
    let reachability: any WakeOnLANReachabilityChecking

    func wake(serverID: UUID, settings: WakeOnLANSettings) async throws -> Bool {
        try await controller.wake(serverID: serverID, settings: settings, trigger: .automatic)
    }

    func waitUntilReachable(hostname: String) async -> Bool {
        await controller.waitUntilReachable(hostname: hostname, reachability: reachability)
    }
}
