import Darwin
import Foundation

public struct PostMountActionDeliveryItem: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let action: PostMountAction

    public init(id: UUID = UUID(), action: PostMountAction) {
        self.id = id
        self.action = action
    }
}

public struct PostMountActionDelivery: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let mountID: UUID
    public let source: String
    public let mountPoint: String
    public let items: [PostMountActionDeliveryItem]

    public init(
        id: UUID = UUID(),
        mountID: UUID,
        source: String,
        mountPoint: String,
        actions: [PostMountAction]
    ) {
        self.id = id
        self.mountID = mountID
        self.source = source
        self.mountPoint = mountPoint
        items = actions.map { PostMountActionDeliveryItem(action: $0) }
    }
}

public struct PostMountActionAcknowledgement: Codable, Sendable, Equatable {
    public let deliveryID: UUID
    public let failures: [String]

    public init(deliveryID: UUID, failures: [String]) {
        self.deliveryID = deliveryID
        self.failures = failures
    }
}

public enum PostMountActionBeginDisposition: Sendable, Equatable {
    case perform
    case skip
    case indeterminate
}

public enum PostMountActionLedgerError: Error, Sendable, Equatable {
    case unreadable
    case deliveryMismatch
    case unknownDelivery
    case unknownAction
    case incompleteDelivery
}

/// User-context durability ledger. An action is recorded as started before its
/// external effect and completed afterward. A process crash between those writes
/// is intentionally treated as indeterminate and is not repeated.
public final class PostMountActionLedger: @unchecked Sendable {
    private enum Lifecycle: String, Codable { case started, completed }

    private struct ActionState: Codable {
        var lifecycle: Lifecycle
        var failure: String?
    }

    private struct DeliveryState: Codable {
        var delivery: PostMountActionDelivery
        var actions: [UUID: ActionState]
        var completed: Bool
    }

    private struct State: Codable {
        var deliveries: [UUID: DeliveryState] = [:]
    }

    private let lock = NSLock()
    private let directory: URL
    private let stateURL: URL
    private var state: State?

    public convenience init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        self.init(directory: base.appendingPathComponent(LATCHIdentity.name, isDirectory: true))
    }

    public init(directory: URL) {
        self.directory = directory
        stateURL = directory.appendingPathComponent("post-mount-actions.json")
        if FileManager.default.fileExists(atPath: stateURL.path) {
            state = try? JSONDecoder().decode(State.self, from: Data(contentsOf: stateURL))
        } else {
            state = State()
        }
    }

    public func register(_ delivery: PostMountActionDelivery) throws {
        try lock.withLock {
            var candidate = try loadedState()
            if let existing = candidate.deliveries[delivery.id] {
                guard existing.delivery == delivery else { throw PostMountActionLedgerError.deliveryMismatch }
                return
            }
            candidate.deliveries[delivery.id] = .init(delivery: delivery, actions: [:], completed: false)
            try publish(candidate)
        }
    }

    public func completedAcknowledgement(for deliveryID: UUID) throws -> PostMountActionAcknowledgement? {
        try lock.withLock {
            let state = try loadedState()
            guard let delivery = state.deliveries[deliveryID], delivery.completed else { return nil }
            return acknowledgement(for: delivery)
        }
    }

    public func beginAction(
        _ item: PostMountActionDeliveryItem,
        deliveryID: UUID
    ) throws -> PostMountActionBeginDisposition {
        try lock.withLock {
            var candidate = try loadedState()
            guard var delivery = candidate.deliveries[deliveryID] else { throw PostMountActionLedgerError.unknownDelivery }
            guard delivery.delivery.items.contains(item) else { throw PostMountActionLedgerError.unknownAction }
            if let action = delivery.actions[item.id] {
                return action.lifecycle == .completed ? .skip : .indeterminate
            }
            delivery.actions[item.id] = .init(lifecycle: .started, failure: nil)
            candidate.deliveries[deliveryID] = delivery
            try publish(candidate)
            return .perform
        }
    }

    public func completeAction(
        _ item: PostMountActionDeliveryItem,
        deliveryID: UUID,
        failure: String?
    ) throws {
        try lock.withLock {
            var candidate = try loadedState()
            guard var delivery = candidate.deliveries[deliveryID] else { throw PostMountActionLedgerError.unknownDelivery }
            guard delivery.delivery.items.contains(item), delivery.actions[item.id] != nil else {
                throw PostMountActionLedgerError.unknownAction
            }
            delivery.actions[item.id] = .init(lifecycle: .completed, failure: failure)
            candidate.deliveries[deliveryID] = delivery
            try publish(candidate)
        }
    }

    public func complete(_ delivery: PostMountActionDelivery) throws -> PostMountActionAcknowledgement {
        try lock.withLock {
            var candidate = try loadedState()
            guard var stored = candidate.deliveries[delivery.id], stored.delivery == delivery else {
                throw PostMountActionLedgerError.deliveryMismatch
            }
            guard delivery.items.allSatisfy({ stored.actions[$0.id]?.lifecycle == .completed }) else {
                throw PostMountActionLedgerError.incompleteDelivery
            }
            stored.completed = true
            candidate.deliveries[delivery.id] = stored
            try publish(candidate)
            return acknowledgement(for: stored)
        }
    }

    private func loadedState() throws -> State {
        guard let state else { throw PostMountActionLedgerError.unreadable }
        return state
    }

    private func publish(_ candidate: State) throws {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            _ = chmod(directory.path, mode_t(0o700))
            try JSONEncoder().encode(candidate).write(to: stateURL, options: [.atomic])
            guard chmod(stateURL.path, mode_t(0o600)) == 0 else { throw POSIXError(.EACCES) }
            state = candidate
        } catch {
            throw error
        }
    }

    private func acknowledgement(for state: DeliveryState) -> PostMountActionAcknowledgement {
        let failures = state.delivery.items.compactMap { state.actions[$0.id]?.failure }
        return .init(deliveryID: state.delivery.id, failures: failures)
    }
}

public actor DurablePostMountActionExecutor {
    public typealias Performer = @Sendable (PostMountActionDeliveryItem) async -> String?

    private let ledger: PostMountActionLedger
    private var inFlight: [UUID: Task<PostMountActionAcknowledgement, Error>] = [:]

    public init(ledger: PostMountActionLedger = PostMountActionLedger()) {
        self.ledger = ledger
    }

    public func execute(
        _ delivery: PostMountActionDelivery,
        perform: @escaping Performer
    ) async throws -> PostMountActionAcknowledgement {
        if let completed = try ledger.completedAcknowledgement(for: delivery.id) { return completed }
        if let existing = inFlight[delivery.id] { return try await existing.value }

        let ledger = self.ledger
        let task = Task<PostMountActionAcknowledgement, Error> {
            try ledger.register(delivery)
            if let completed = try ledger.completedAcknowledgement(for: delivery.id) { return completed }
            for item in delivery.items {
                switch try ledger.beginAction(item, deliveryID: delivery.id) {
                case .perform:
                    let failure = await perform(item)
                    try ledger.completeAction(item, deliveryID: delivery.id, failure: failure)
                case .skip:
                    continue
                case .indeterminate:
                    try ledger.completeAction(
                        item,
                        deliveryID: delivery.id,
                        failure: "The agent restarted while this action was in progress. LATCH did not repeat it because its prior effect is indeterminate."
                    )
                }
            }
            return try ledger.complete(delivery)
        }
        inFlight[delivery.id] = task
        do {
            let acknowledgement = try await task.value
            inFlight[delivery.id] = nil
            return acknowledgement
        } catch {
            inFlight[delivery.id] = nil
            throw error
        }
    }
}
