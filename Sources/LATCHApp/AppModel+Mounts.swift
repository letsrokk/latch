import Foundation
import LATCHShared

@MainActor
extension AppModel {
    func save(_ draft: MountDraft) async {
        _ = await save(draft, creating: nil)
    }

    func save(_ draft: MountDraft, creating server: NFSServerProfile?) async -> Bool {
        do {
            let request: LATCHRequest = if let server { .saveServerAndDefinition(server, draft.definition()) } else { .saveDefinition(draft.definition()) }
            if case .failure(_, let detail) = try await send(request) {
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
        await performRequest(.perform(definition.id, action, confirmed: confirmed))
        if action == .mount, errorMessage == nil {
            try? await Task.sleep(for: .seconds(4))
            await refresh()
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
