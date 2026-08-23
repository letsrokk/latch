import Foundation

public struct MountWorkToken: Sendable, Equatable {
    public let mountID: UUID
    fileprivate let generation: UInt64
    fileprivate let workID: UUID

    fileprivate init(mountID: UUID, generation: UInt64) {
        self.mountID = mountID
        self.generation = generation
        workID = UUID()
    }
}

/// Serializes automatic checks per mount and gives every manual/configuration
/// mutation a new generation. Work that resumes after an actor suspension must
/// present its token again before it can publish a result or start another side
/// effect.
public final class MountWorkCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private var generations: [UUID: UInt64] = [:]
    private var automaticWork: [UUID: UUID] = [:]
    private var manualWork: [UUID: UUID] = [:]

    public init() {}

    public func beginAutomatic(for mountID: UUID) -> MountWorkToken? {
        lock.withLock {
            guard automaticWork[mountID] == nil, manualWork[mountID] == nil else { return nil }
            let token = MountWorkToken(mountID: mountID, generation: generations[mountID, default: 0])
            automaticWork[mountID] = token.workID
            return token
        }
    }

    public func finishAutomatic(_ token: MountWorkToken) {
        lock.withLock {
            guard automaticWork[token.mountID] == token.workID else { return }
            automaticWork[token.mountID] = nil
        }
    }

    public func beginManual(for mountID: UUID) -> MountWorkToken {
        lock.withLock {
            advanceGeneration(for: mountID)
            let token = MountWorkToken(mountID: mountID, generation: generations[mountID, default: 0])
            manualWork[mountID] = token.workID
            return token
        }
    }

    public func finishManual(_ token: MountWorkToken) {
        lock.withLock {
            guard manualWork[token.mountID] == token.workID else { return }
            manualWork[token.mountID] = nil
        }
    }

    public func invalidate(_ mountID: UUID) {
        lock.withLock { advanceGeneration(for: mountID) }
    }

    public func isCurrent(_ token: MountWorkToken) -> Bool {
        lock.withLock { generations[token.mountID, default: 0] == token.generation }
    }

    private func advanceGeneration(for mountID: UUID) {
        generations[mountID, default: 0] &+= 1
    }
}
