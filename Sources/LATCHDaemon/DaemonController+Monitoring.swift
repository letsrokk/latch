import Foundation
import LATCHShared

private struct AutomaticCheckJob: Sendable {
    let definition: MountDefinition
    let token: MountWorkToken
    let date: Date
    let forceRuleTransition: Bool
}

extension DaemonController {
    func runDueChecks(forceRuleTransition: Bool = false) async {
        let date = Date()
        var jobs: [AutomaticCheckJob] = []
        for definition in configuration.mounts {
            guard let token = mountWork.beginAutomatic(for: definition.id) else { continue }
            guard let resolved = resolvedDefinition(definition) else {
                if mountWork.isCurrent(token) {
                    await record(status(definition, source: nil, state: .probeError, code: .malformedRequest, detail: "The mount references an unknown NFS server.", at: date))
                }
                mountWork.finishAutomatic(token)
                continue
            }
            if await stateStore.isPaused(definition.id) || !mountWork.isCurrent(token) {
                mountWork.finishAutomatic(token)
                continue
            }
            let due = MountCheckSchedule.isDue(
                lastCheck: lastChecks[definition.id],
                mountedAt: mountedAt[definition.id],
                now: date,
                interval: definition.probeIntervalSeconds,
                mountGrace: firstHealthCheckGrace
            )
            guard due else {
                mountWork.finishAutomatic(token)
                continue
            }
            lastChecks[definition.id] = date
            mountedAt[definition.id] = nil
            jobs.append(.init(definition: resolved, token: token, date: date, forceRuleTransition: forceRuleTransition))
        }
        let reachability = SweepValueCache<Bool>()
        await BoundedAsyncWork.run(jobs, limit: 2) { [weak self] job in
            await self?.performAutomaticCheck(job, reachability: reachability)
        }
    }

    private func performAutomaticCheck(_ job: AutomaticCheckJob, reachability: SweepValueCache<Bool>) async {
        await checkAutomatically(
            job.definition,
            token: job.token,
            at: job.date,
            forceRuleTransition: job.forceRuleTransition,
            reachability: reachability
        )
        mountWork.finishAutomatic(job.token)
    }

    func networkPathChanged() async {
        for definition in configuration.mounts where definition.enabled {
            lastChecks[definition.id] = nil
            mountedAt[definition.id] = nil
        }
        await runDueChecks(forceRuleTransition: true)
    }

    func applicationCoordinatorBecameAvailable() async {
        for definition in configuration.mounts where definition.enabled {
            lastChecks[definition.id] = nil
            mountedAt[definition.id] = nil
        }
        await runDueChecks()
    }

    func checkAutomatically(
        _ definition: MountDefinition,
        token: MountWorkToken,
        at date: Date,
        forceRuleTransition: Bool,
        reachability: SweepValueCache<Bool>? = nil
    ) async {
        guard await automaticWorkIsCurrent(token, definition: definition) else { return }
        let evaluation = await ruleEvaluation(for: definition)
        guard await automaticWorkIsCurrent(token, definition: definition) else { return }
        let retry = await stateStore.automaticRetryState(for: definition.id)
        guard await automaticWorkIsCurrent(token, definition: definition) else { return }
        let wasSatisfied = lastRuleSatisfaction[definition.id]
        if let evaluation { lastRuleSatisfaction[definition.id] = evaluation.isSatisfied }
        let rulesJustSatisfied = NetworkRuleTransition.isJustSatisfied(
            previousSatisfaction: wasSatisfied,
            persistedState: statuses[definition.id]?.state,
            evaluation: evaluation,
            isForcedReevaluation: forceRuleTransition
        )
        switch NetworkAutomaticWorkDisposition.resolve(ruleEvaluation: evaluation, retry: retry, now: date, rulesJustSatisfied: rulesJustSatisfied) {
        case .waitingForRules(let unmet):
            guard await automaticWorkIsCurrent(token, definition: definition) else { return }
            await record(waitingForRulesStatus(definition, evaluation: .init(isSatisfied: false, unmetRuleSummaries: unmet), at: date))
            return
        case .retryScheduled:
            guard await automaticWorkIsCurrent(token, definition: definition) else { return }
            await record(status(definition, source: nil, state: .retryScheduled, code: .none, detail: "Automatic retry is scheduled.", at: date, nextAutomaticAttempt: retry?.nextAttempt))
            return
        case .proceed:
            break
        }
        guard await automaticWorkIsCurrent(token, definition: definition) else { return }
        let mountOperator = mounts
        let reachabilityStarted = DispatchTime.now().uptimeNanoseconds
        let networkAvailable: Bool
        if let reachability {
            networkAvailable = await reachability.value(for: definition.host) {
                await mountOperator.networkAvailable(for: definition.host)
            }
        } else {
            networkAvailable = await mountOperator.networkAvailable(for: definition.host)
        }
        let reachabilityMilliseconds = (DispatchTime.now().uptimeNanoseconds - reachabilityStarted) / 1_000_000
        stateLogger.debug("NFS reachability completed in \(reachabilityMilliseconds, privacy: .public) ms; available=\(networkAvailable, privacy: .public)")
        guard await automaticWorkIsCurrent(token, definition: definition) else { return }
        guard networkAvailable else {
            if let server = configuration.servers.first(where: { $0.id == definition.serverID }) {
                let transition = try? await automaticWake.transition(
                    rulesSatisfied: true,
                    nfsReachable: false,
                    serverID: server.id,
                    settings: server.wakeOnLAN,
                    hostname: definition.host,
                    onWakeSent: { [weak self] in
                        guard let self else { return }
                        guard await self.automaticWorkIsCurrent(token, definition: definition) else { return }
                        await self.record(status(definition, source: nil, state: .waking, code: .none, detail: "Wake-on-LAN sent. Waiting for the NFS service.", at: date))
                        guard await self.automaticWorkIsCurrent(token, definition: definition) else { return }
                        await self.recordWakeEvent(server: server, detail: "Sent Wake-on-LAN after TCP port 2049 was unavailable.")
                    }
                )
                guard await automaticWorkIsCurrent(token, definition: definition) else { return }
                if transition == .continueMonitoring {
                    await reachability?.invalidate(definition.host)
                    await checkAutomatically(
                        definition,
                        token: token,
                        at: Date(),
                        forceRuleTransition: false,
                        reachability: reachability
                    )
                    return
                } else if transition == .scheduleMissingMountRetry {
                    guard await automaticWorkIsCurrent(token, definition: definition) else { return }
                    switch await scheduleRetry(kind: .missingMount, definition: definition, token: token, automatic: true, at: Date()) {
                    case .scheduled(let retry):
                        guard await automaticWorkIsCurrent(token, definition: definition) else { return }
                        await record(status(definition, source: nil, state: .retryScheduled, code: .networkUnavailable, detail: "The NFS service did not respond after Wake-on-LAN.", at: Date(), nextAutomaticAttempt: retry.nextAttempt))
                    case .superseded:
                        return
                    case .failed(let persistenceDetail):
                        await record(status(definition, source: nil, state: .networkUnavailable, code: .networkUnavailable, detail: "The NFS service did not respond after Wake-on-LAN. Automatic retry could not be persisted: \(persistenceDetail)", at: Date()))
                    }
                    return
                }
            }
            let decision = HealthMonitor.decision(definition: definition, observedSource: nil, result: ProbeResult(networkUnavailable: true), previous: statuses[definition.id], at: date)
            guard await automaticWorkIsCurrent(token, definition: definition) else { return }
            await record(decision.status)
            return
        }
        let source: String?
        do {
            guard await automaticWorkIsCurrent(token, definition: definition) else { return }
            source = try await mounts.currentSource(at: definition.mountPoint)
            guard await automaticWorkIsCurrent(token, definition: definition) else { return }
        }
        catch {
            guard await automaticWorkIsCurrent(token, definition: definition) else { return }
            await record(status(definition, source: nil, state: .probeError, code: .verificationFailed, detail: "The system mount table could not be read.", at: date))
            return
        }
        guard let source else {
            guard await automaticWorkIsCurrent(token, definition: definition) else { return }
            await withPersistenceIgnoreError { [weak self] in
                try await self?.stateStore.clearPostMountActions(for: definition.id)
            }
            guard await automaticWorkIsCurrent(token, definition: definition) else { return }
            await mountAutomatically(definition, token: token, at: date)
            return
        }
        guard source == definition.source else {
            guard await automaticWorkIsCurrent(token, definition: definition) else { return }
            switch await setAutomaticRetryState(nil, definition: definition, token: token, automatic: true) {
            case .committed:
                await record(status(definition, source: source, state: .probeError, code: .sourceMismatch, detail: "A different source owns the configured mountpoint.", at: date))
            case .superseded:
                return
            case .failed(let persistenceDetail):
                await record(status(definition, source: source, state: .probeError, code: .sourceMismatch, detail: "A different source owns the configured mountpoint. Automatic retry state could not be cleared: \(persistenceDetail)", at: date))
            }
            return
        }
        guard await automaticWorkIsCurrent(token, definition: definition) else { return }
        let rawProbe: ProbeResult
        do {
            rawProbe = try await mounts.probe(definition, cancellation: mountCancellation(for: token))
        } catch {
            guard await automaticWorkIsCurrent(token, definition: definition) else { return }
            await record(status(definition, source: source, state: .probeError, code: .verificationFailed, detail: "Probe failed: \(error.localizedDescription)", at: date))
            return
        }
        guard await automaticWorkIsCurrent(token, definition: definition) else { return }
        let probe = annotatePermission(rawProbe)
        await observeRuntimePermission(probe)
        guard await automaticWorkIsCurrent(token, definition: definition) else { return }
        let decision = HealthMonitor.decision(definition: definition, observedSource: source, result: probe, previous: statuses[definition.id], at: date)
        await record(decision.status)
        guard await automaticWorkIsCurrent(token, definition: definition) else { return }
        if decision.status.state == .healthy {
            guard await automaticWorkIsCurrent(token, definition: definition) else { return }
            switch await setAutomaticRetryState(nil, definition: definition, token: token, automatic: true) {
            case .committed:
                break
            case .superseded:
                return
            case .failed(let persistenceDetail):
                await record(status(definition, source: source, state: decision.status.state, code: decision.status.errorCode, detail: "\(decision.status.detail) Automatic retry state could not be cleared: \(persistenceDetail)", at: date))
                return
            }
            await executePostMountActions(definition, token: token, automatic: true, createIfNeeded: false)
            guard await automaticWorkIsCurrent(token, definition: definition) else { return }
        }
        guard decision.shouldRecover else { return }
        guard await automaticWorkIsCurrent(token, definition: definition) else { return }
        recoveryLogger.notice("Starting automatic recovery for \(definition.id.uuidString, privacy: .public)")
        await record(status(definition, source: source, state: .recovering, code: .staleHandle, detail: "Guarded stale-handle recovery is in progress.", at: Date()))
        guard await automaticWorkIsCurrent(token, definition: definition) else { return }
        let result = await coordinator.recover(
            definition,
            trigger: .automatic(probe),
            isCancelled: { [mountWork] in !mountWork.isCurrent(token) }
        )
        guard await automaticWorkIsCurrent(token, definition: definition) else { return }
        if result.state == .failedClosed {
            recoveryLogger.fault("Recovery failed closed for \(definition.id.uuidString, privacy: .public): \(result.detail, privacy: .public)")
        } else {
            recoveryLogger.notice("Recovery completed for \(definition.id.uuidString, privacy: .public) with state \(result.state.rawValue, privacy: .public)")
        }
        let retryDisposition = AutomaticRetryState.recoveryDisposition(state: result.state, code: result.code)
        if retryDisposition == .clear {
            switch await setAutomaticRetryState(nil, definition: definition, token: token, automatic: true) {
            case .committed:
                await record(status(definition, source: definition.source, state: result.state, code: result.code, detail: result.detail, at: Date(), recovered: result.didAttemptRecovery))
            case .superseded:
                return
            case .failed(let persistenceDetail):
                await record(status(definition, source: definition.source, state: result.state, code: result.code, detail: "\(result.detail) Automatic retry state could not be cleared: \(persistenceDetail)", at: Date(), recovered: result.didAttemptRecovery))
            }
        } else if retryDisposition == .schedule {
            guard await automaticWorkIsCurrent(token, definition: definition) else { return }
            switch await scheduleRetry(kind: .staleRecovery, definition: definition, token: token, automatic: true, at: date) {
            case .scheduled(let retry):
                guard await automaticWorkIsCurrent(token, definition: definition) else { return }
                await record(status(definition, source: definition.source, state: .retryScheduled, code: result.code, detail: result.detail, at: Date(), recovered: result.didAttemptRecovery, nextAutomaticAttempt: retry.nextAttempt))
            case .superseded:
                return
            case .failed(let persistenceDetail):
                await record(status(definition, source: definition.source, state: result.state, code: result.code, detail: "\(result.detail) Automatic retry could not be persisted: \(persistenceDetail)", at: Date(), recovered: result.didAttemptRecovery))
            }
        } else {
            guard await automaticWorkIsCurrent(token, definition: definition) else { return }
            await record(status(definition, source: definition.source, state: result.state, code: result.code, detail: result.detail, at: Date(), recovered: result.didAttemptRecovery))
        }
    }

    func mountAutomatically(_ definition: MountDefinition, token: MountWorkToken, at date: Date) async {
        guard await automaticWorkIsCurrent(token, definition: definition) else { return }
        await record(status(definition, source: nil, state: .mounting, code: .none, detail: "Restoring the configured NFS mount.", at: date))
        guard await automaticWorkIsCurrent(token, definition: definition) else { return }
        do {
            try ConfigurationValidator().validate(configuration, liveMounts: try externalMounts())
            try await mountExecutor.mount(definition, cancellation: mountCancellation(for: token))
            guard await automaticWorkIsCurrent(token, definition: definition) else { return }
            switch await setAutomaticRetryState(nil, definition: definition, token: token, automatic: true) {
            case .committed:
                break
            case .superseded:
                return
            case .failed(let persistenceDetail):
                await didMount(definition, previousSource: nil, token: token, automatic: true)
                guard await automaticWorkIsCurrent(token, definition: definition) else { return }
                await record(status(definition, source: definition.source, state: .mounting, code: .verificationFailed, detail: "Mounted, but automatic retry state could not be cleared: \(persistenceDetail)", at: Date()))
                return
            }
            await didMount(definition, previousSource: nil, token: token, automatic: true)
            guard await automaticWorkIsCurrent(token, definition: definition) else { return }
        } catch {
            guard await automaticWorkIsCurrent(token, definition: definition) else { return }
            logger.error("Automatic mount failed for \(definition.id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            let code = mountFailureCode(for: error)
            let retryDisposition = AutomaticRetryState.disposition(after: code)
            if retryDisposition != .schedule {
                if retryDisposition == .clear {
                    switch await setAutomaticRetryState(nil, definition: definition, token: token, automatic: true) {
                    case .committed:
                        break
                    case .superseded:
                        return
                    case .failed(let persistenceDetail):
                        await record(status(definition, source: nil, state: .probeError, code: code, detail: "Automatic mount failed: \(error.localizedDescription). Automatic retry state could not be cleared: \(persistenceDetail)", at: Date()))
                        return
                    }
                }
                guard await automaticWorkIsCurrent(token, definition: definition) else { return }
                await record(status(definition, source: nil, state: .probeError, code: code, detail: "Automatic mount failed: \(error.localizedDescription)", at: Date()))
            } else {
                guard await automaticWorkIsCurrent(token, definition: definition) else { return }
                switch await scheduleRetry(kind: .missingMount, definition: definition, token: token, automatic: true, at: date) {
                case .scheduled(let retry):
                    guard await automaticWorkIsCurrent(token, definition: definition) else { return }
                    await record(status(definition, source: nil, state: .retryScheduled, code: .remountFailed, detail: "Automatic mount failed: \(error.localizedDescription)", at: Date(), nextAutomaticAttempt: retry.nextAttempt))
                case .superseded:
                    return
                case .failed(let persistenceDetail):
                    await record(status(definition, source: nil, state: .probeError, code: .remountFailed, detail: "Automatic mount failed: \(error.localizedDescription). Automatic retry could not be persisted: \(persistenceDetail)", at: Date()))
                }
            }
        }
    }
}
