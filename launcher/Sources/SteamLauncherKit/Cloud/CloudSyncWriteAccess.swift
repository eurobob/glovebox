import Foundation

/// One launcher session's permission to mutate local cloud saves. Closing it waits only for
/// an in-progress filesystem operation, never for Steam, and permanently rejects later writes.
/// Call `close` off the main actor: a save backup or relocation may still be finishing.
public final class CloudSyncWriteAccess: @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false

    public init() {}

    public func close() {
        lock.lock()
        closed = true
        lock.unlock()
    }

    func perform<T>(_ mutation: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { throw CancellationError() }
        try Task.checkCancellation()
        return try mutation()
    }
}
