import Foundation

/// Shared by all scans so independent libraries cannot each consume the full
/// concurrency limit of the same volume.
actor VolumeTraversalScheduler {
    static let shared = VolumeTraversalScheduler()

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }
    private struct State {
        var active = 0
        var limit: Int
        var waiters: [Waiter] = []
    }
    private var volumes: [String: State] = [:]

    func withPermit<T: Sendable>(
        volumeID: String,
        limit: Int,
        control: ScanControl? = nil,
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        let id = UUID()
        try await acquire(volumeID: volumeID, limit: max(1, limit), id: id, control: control)
        defer { release(volumeID: volumeID) }
        try Task.checkCancellation()
        if control?.isCancelled == true { throw CancellationError() }
        return try await operation()
    }

    private func acquire(volumeID: String, limit: Int, id: UUID, control: ScanControl?) async throws {
        try Task.checkCancellation()
        if control?.isCancelled == true { throw CancellationError() }
        var state = volumes[volumeID] ?? State(limit: limit)
        state.limit = min(state.limit, limit)
        if state.active < state.limit && state.waiters.isEmpty {
            state.active += 1
            volumes[volumeID] = state
            return
        }
        volumes[volumeID] = state
        let handler = control?.registerCancellationHandler { Task { await self.cancelWaiter(volumeID: volumeID, id: id) } }
        defer { control?.removeCancellationHandler(handler) }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled || control?.isCancelled == true {
                    continuation.resume(throwing: CancellationError())
                } else {
                    enqueue(volumeID: volumeID, id: id, continuation: continuation)
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(volumeID: volumeID, id: id) }
        }
    }

    private func enqueue(volumeID: String, id: UUID, continuation: CheckedContinuation<Void, any Error>) {
        guard var state = volumes[volumeID] else {
            continuation.resume(throwing: CancellationError())
            return
        }
        state.waiters.append(Waiter(id: id, continuation: continuation))
        volumes[volumeID] = state
    }

    private func cancelWaiter(volumeID: String, id: UUID) {
        guard var state = volumes[volumeID], let index = state.waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = state.waiters.remove(at: index)
        if state.active == 0 && state.waiters.isEmpty { volumes.removeValue(forKey: volumeID) }
        else { volumes[volumeID] = state }
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func release(volumeID: String) {
        guard var state = volumes[volumeID] else { return }
        state.active -= 1
        if state.active < state.limit && !state.waiters.isEmpty {
            let waiter = state.waiters.removeFirst()
            state.active += 1
            volumes[volumeID] = state
            waiter.continuation.resume()
        } else if state.active == 0 && state.waiters.isEmpty {
            volumes.removeValue(forKey: volumeID)
        } else {
            volumes[volumeID] = state
        }
    }
}
