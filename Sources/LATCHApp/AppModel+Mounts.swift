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
                await monitorOperation(receipt)
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

    private func monitorOperation(_ receipt: OperationReceipt) async {
        operationSnapshots[receipt.id] = OperationSnapshot(
            id: receipt.id,
            mountID: receipt.mountID,
            action: receipt.action,
            state: .accepted,
            canCancel: true,
            detail: "Operation queued.",
            updatedAt: receipt.startedAt
        )

        defer {
            operationSnapshots[receipt.id] = nil
            Task { @MainActor [weak self] in await self?.refresh() }
        }

        for attempt in 0..<120 where !Task.isCancelled {
            do {
                let response = try await send(.getOperation(receipt.id))
                guard case .operationSnapshot(let snapshot) = response else {
                    errorMessage = "The daemon returned an invalid operation response."
                    return
                }
                operationSnapshots[receipt.id] = snapshot
                switch snapshot.state {
                case .accepted, .running:
                    break
                case .succeeded, .failed, .cancelled:
                    if snapshot.state == .failed || snapshot.state == .cancelled {
                        errorMessage = snapshot.detail
                    }
                    return
                }
                let delayMilliseconds = min(150 + attempt * 100, 1_000)
                try await Task.sleep(for: .milliseconds(delayMilliseconds))
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }

        if errorMessage == nil {
            errorMessage = "The operation did not finish before the status timeout."
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
