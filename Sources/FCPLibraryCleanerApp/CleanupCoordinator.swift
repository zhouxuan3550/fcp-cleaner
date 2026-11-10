import Foundation
import FCPLibraryCleanerCore

/// Owns the shared preflight and execution path for single and batch cleanup.
@MainActor
final class CleanupCoordinator {
    private let check: @Sendable (CleanupPlan) async throws -> Void
    private let perform: @Sendable (CleanupPlan) async throws -> CleanupResult
    private let recordThroughput: @MainActor (String?, Int64, Double) -> Void

    init(
        check: @escaping @Sendable (CleanupPlan) async throws -> Void = { try await CleanupEngine().preflight(plan: $0, verifyContents: false) },
        perform: @escaping @Sendable (CleanupPlan) async throws -> CleanupResult = { try await CleanupEngine().execute(plan: $0) },
        recordThroughput: @escaping @MainActor (String?, Int64, Double) -> Void = { CleanupThroughputStore.record(volumeID: $0, bytes: $1, seconds: $2) }
    ) {
        self.check = check
        self.perform = perform
        self.recordThroughput = recordThroughput
    }

    func preflight(_ plan: CleanupPlan) async throws { try await check(plan) }

    func execute(_ plan: CleanupPlan, volumeID: String?) async throws -> CleanupResult {
        let start = ContinuousClock.now
        let result = try await perform(plan)
        let elapsed = ContinuousClock.now - start
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        recordThroughput(volumeID, result.freedAllocatedSize, seconds)
        return result
    }
}
