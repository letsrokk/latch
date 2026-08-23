import Foundation

public enum MountOperationCancellationError: Error, Sendable, Equatable {
    case cancelled
}

public struct MountOperationCancellation: Sendable {
    public static let never = MountOperationCancellation(isCancelled: { false })

    private let predicate: @Sendable () -> Bool

    public init(isCancelled: @escaping @Sendable () -> Bool) {
        predicate = isCancelled
    }

    public var isCancelled: Bool { predicate() }

    public func throwIfCancelled() throws {
        if predicate() { throw MountOperationCancellationError.cancelled }
    }
}

/// Runs a direct mount as one generation-bound operation. The concrete mount
/// operator receives the same cancellation token so it can recheck after actor
/// queueing and immediately before invoking the system mount operation.
public struct GuardedMountExecutor: Sendable {
    private let mounts: any MountOperating

    public init(mounts: any MountOperating) {
        self.mounts = mounts
    }

    public func mount(
        _ definition: MountDefinition,
        cancellation: MountOperationCancellation
    ) async throws {
        try cancellation.throwIfCancelled()
        try await mounts.validateEmptyMountPoint(definition.mountPoint, cancellation: cancellation)
        try cancellation.throwIfCancelled()
        try await mounts.mount(definition, cancellation: cancellation)
        try cancellation.throwIfCancelled()
        try await mounts.verifySource(definition.source, at: definition.mountPoint, cancellation: cancellation)
        try cancellation.throwIfCancelled()
    }
}
