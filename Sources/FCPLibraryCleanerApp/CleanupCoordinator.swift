import Foundation
import FCPLibraryCleanerCore

/// Owns the shared preflight and execution path for single and batch cleanup.
@MainActor
final class CleanupCoordinator {
    private let check: @Sendable (CleanupPlan) async throws -> Void
    private let perform: @Sendable (CleanupPlan) async throws -> CleanupResult
    private let prepareSnapshot: @MainActor (CleanupPlan) async -> Date?
    private let recordThroughput: @MainActor (String?, Int64, Double) -> Void

    init(
        check: @escaping @Sendable (CleanupPlan) async throws -> Void = { try await CleanupEngine().preflight(plan: $0, verifyContents: false) },
        perform: @escaping @Sendable (CleanupPlan) async throws -> CleanupResult = { try await CleanupEngine().execute(plan: $0) },
        prepareSnapshot: @escaping @MainActor (CleanupPlan) async -> Date? = { await APFSSnapshotGuard.prepareSnapshot(for: $0) },
        recordThroughput: @escaping @MainActor (String?, Int64, Double) -> Void = { CleanupThroughputStore.record(volumeID: $0, bytes: $1, seconds: $2) }
    ) {
        self.check = check
        self.perform = perform
        self.prepareSnapshot = prepareSnapshot
        self.recordThroughput = recordThroughput
    }

    func preflight(_ plan: CleanupPlan) async throws { try await check(plan) }

    func execute(_ plan: CleanupPlan, volumeID: String?, snapshotEnabled: Bool = false) async throws -> CleanupResult {
        // 快照必须在移动条目之前创建——它保护的是「清理动作」本身。
        var snapshotDate: Date?
        if snapshotEnabled { snapshotDate = await prepareSnapshot(plan) }
        let start = ContinuousClock.now
        var result = try await perform(plan)
        let elapsed = ContinuousClock.now - start
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        result.elapsedSeconds = seconds
        result.snapshotDate = snapshotDate
        recordThroughput(volumeID, result.freedAllocatedSize, seconds)
        return result
    }
}
