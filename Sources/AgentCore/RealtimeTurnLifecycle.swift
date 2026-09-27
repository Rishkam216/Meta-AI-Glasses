import Foundation

public enum RealtimeTurnLifecycleError: Error, Sendable, Equatable {
    case sessionAlreadyActive
}

/// Shared by coordinator value copies. The lock protects every entry and never
/// spans an await. Only active tasks are retained; there is no turn-ID history.
final class RealtimeTurnLifecycle: @unchecked Sendable {
    private actor CloseSignal {
        private var released = false
        private var waiter: CheckedContinuation<Void, Never>?
        func wait() async {
            if released { return }
            await withCheckedContinuation { waiter = $0 }
        }
        func release() {
            released = true
            waiter?.resume()
            waiter = nil
        }
    }
    struct Handle: Sendable {
        let generation: UUID
        let task: Task<RealtimeTurnResult, Error>
    }
    private struct Entry {
        let turnID: UUID
        let handle: Handle
        var closing: Task<Void, Never>?
    }
    private let lock = NSLock()
    private var active: [UUID: Entry] = [:]

    func start(sessionID: UUID, turnID: UUID,
               operation: @escaping @Sendable () async throws -> RealtimeTurnResult) throws -> Handle {
        try lock.withLock {
            guard active[sessionID] == nil else {
                throw RealtimeTurnLifecycleError.sessionAlreadyActive
            }
            let generation = UUID()
            let task = Task {
                // Do not begin before start() commits the handle under the lock.
                self.registrationBarrier()
                try Task.checkCancellation()
                do {
                    let result = try await operation()
                    try Task.checkCancellation()
                    return result
                } catch {
                    // A provider/runtime may translate CancellationError.
                    try Task.checkCancellation()
                    throw error
                }
            }
            let handle = Handle(generation: generation, task: task)
            active[sessionID] = Entry(turnID: turnID, handle: handle)
            return handle
        }
    }

    private func registrationBarrier() { lock.withLock {} }

    func cancel(turnID: UUID, session: any RealtimeModelSession, generation: UUID? = nil) {
        let selected: (Handle, CloseSignal)? = lock.withLock {
            guard var entry = active[session.id], entry.turnID == turnID,
                  generation == nil || entry.handle.generation == generation,
                  entry.closing == nil else { return nil }
            let signal = CloseSignal()
            entry.closing = Task {
                await signal.wait()
                await session.close()
            }
            active[session.id] = entry
            return (entry.handle, signal)
        }
        if let (handle, signal) = selected {
            // Task.cancel can synchronously invoke arbitrary cancellation
            // handlers. Never call it while holding the registry lock.
            handle.task.cancel()
            Task { await signal.release() }
        }
    }

    func finish(sessionID: UUID, generation: UUID) async {
        // Keep the session reserved until its cancellation-triggered close has
        // completed, so a delayed close cannot kill a replacement turn.
        let closing: Task<Void, Never>? = lock.withLock {
            guard let entry = active[sessionID], entry.handle.generation == generation else { return nil }
            if let closing = entry.closing { return closing }
            active.removeValue(forKey: sessionID)
            return nil
        }
        if let closing {
            await closing.value
            lock.withLock {
                if active[sessionID]?.handle.generation == generation {
                    active.removeValue(forKey: sessionID)
                }
            }
        }
    }
}
