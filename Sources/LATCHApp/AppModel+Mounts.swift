import Foundation
import LATCHShared

@MainActor
extension AppModel {
    func save(_ draft: MountDraft) async -> MountEditorSaveResult {
        await save(draft, creating: nil)
    }

    func save(_ draft: MountDraft, creating server: NFSServerProfile?) async -> MountEditorSaveResult {
        do {
            let request: LATCHRequest = if let server { .saveServerAndDefinition(server, draft.definition()) } else { .saveDefinition(draft.definition()) }
            if case .failure(_, let detail) = try await send(request) { return .failed(detail) }
            await refresh()
            return .saved
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    func save(_ server: NFSServerProfile) async -> Bool {
        errorMessage = nil
        do {
            if case .failure(_, let detail) = try await send(.saveServer(server)) {
                errorMessage = detail
                return false
            }
            await refresh()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func remove(_ server: NFSServerProfile) async {
        await performRequest(.removeServer(server.id))
    }

    func remove(_ definition: MountDefinition, confirmed: Bool) async {
        await performRequest(.removeDefinition(definition.id, confirmMounted: confirmed))
    }

    func action(_ action: LATCHAction, definition: MountDefinition, confirmed: Bool = false) async {
        if ManagedMountActionExecution.route(for: action) == .foregroundApplication {
            revealInFinder(definition)
            return
        }

        errorMessage = nil
        do {
            let response = try await send(.perform(definition.id, action, confirmed: confirmed))
            switch response {
            case .operationAccepted(let receipt):
                beginMonitoring(receipt)
            case .failure(_, let detail):
                errorMessage = detail
                await refresh()
            default:
                await refresh()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func cancelOperation(_ operationID: UUID) async {
        guard operationSnapshots[operationID]?.canCancel == true else { return }
        do {
            let response = try await send(.cancelOperation(operationID))
            if case .operationSnapshot(let snapshot) = response {
                operationSnapshots[operationID] = snapshot
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func beginMonitoring(_ receipt: OperationReceipt) {
        operationSnapshots[receipt.id] = OperationSnapshot(
            id: receipt.id,
            mountID: receipt.mountID,
            action: receipt.action,
            state: .accepted,
            canCancel: true,
            detail: "Operation queued.",
            updatedAt: receipt.startedAt
        )
        startMonitoringOperation(receipt.id)
    }

    func reconcileOperations(_ snapshots: [OperationSnapshot]) {
        operationSnapshots = OperationMonitoringPolicy.reconcile(snapshots)
        let activeIDs = Set(snapshots.filter { OperationMonitoringPolicy.shouldMonitor($0.state) }.map(\.id))

        let staleMonitorIDs = operationMonitorTasks.keys.filter { !activeIDs.contains($0) }
        for operationID in staleMonitorIDs {
            operationMonitorTasks[operationID]?.cancel()
            operationMonitorTasks[operationID] = nil
        }
        for operationID in activeIDs { startMonitoringOperation(operationID) }
    }

    private func startMonitoringOperation(_ operationID: UUID) {
        guard operationMonitorTasks[operationID] == nil else { return }
        operationMonitorTasks[operationID] = Task { @MainActor [weak self] in
            await self?.monitorOperation(operationID)
        }
    }

    private func monitorOperation(_ operationID: UUID) async {
        defer { operationMonitorTasks[operationID] = nil }
        var consecutiveFailures = 0

        while !Task.isCancelled {
            do {
                let response = try await send(.getOperation(operationID))
                guard case .operationSnapshot(let snapshot) = response else {
                    errorMessage = "The daemon returned an invalid operation response."
                    return
                }
                consecutiveFailures = 0
                operationSnapshots[operationID] = snapshot
                if snapshot.state.isTerminal {
                    if snapshot.state == .failed || snapshot.state == .cancelled {
                        errorMessage = snapshot.detail
                    }
                    return
                }
                try await Task.sleep(for: .seconds(1))
            } catch is CancellationError {
                return
            } catch {
                consecutiveFailures += 1
                if consecutiveFailures == 3 { errorMessage = error.localizedDescription }
                let delay = OperationMonitoringPolicy.retryDelayMilliseconds(
                    afterConsecutiveFailure: consecutiveFailures
                )
                do {
                    try await Task.sleep(for: .milliseconds(delay))
                } catch {
                    return
                }
            }
        }
    }

    func wake(_ server: NFSServerProfile) async {
        await performRequest(.wakeServer(server.id))
        await refresh()
    }

    func verifyNetworkVolumesPermission() async {
        await performRequest(.verifyNetworkVolumesPermission)
    }
}
