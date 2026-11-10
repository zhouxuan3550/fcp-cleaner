import Foundation
import Testing
import FCPLibraryCleanerCore
@testable import FCPLibraryCleanerApp

@MainActor
struct CleanupCoordinatorTests {
    private enum Failure: Error { case preflight, execution }
    private final class Measurements {
        var samples: [(String?, Int64, Double)] = []
    }

    private func plan() throws -> CleanupPlan {
        let url = URL(fileURLWithPath: "/tmp/coordinator.fcpbundle")
        let database = CoreDataSnapshot(url: url.appendingPathComponent("CurrentVersion.flexolibrary"), size: 1, modificationTime: 0)
        let result = LibraryScanResult(libraryURL: url, totalAllocatedSize: 0, totalLogicalSize: 0,
                                       coreDataSnapshots: [database], cacheItems: [], observedCacheItems: [], protectedItems: [], issues: [])
        return try CleanupPlan(scanResult: result, categories: [])
    }

    @Test("successful cleanup records throughput for the target volume")
    func recordsSuccessfulExecution() async throws {
        let measurements = Measurements()
        let expected = CleanupResult(movedToTrash: [], freedAllocatedSize: 4096, errors: [])
        let coordinator = CleanupCoordinator(check: { _ in }, perform: { _ in expected },
                                             recordThroughput: { measurements.samples.append(($0, $1, $2)) })
        let plan = try plan()
        try await coordinator.preflight(plan)
        let result = try await coordinator.execute(plan, volumeID: "disk-a")
        #expect(result.freedAllocatedSize == 4096)
        #expect(measurements.samples.count == 1)
        #expect(measurements.samples.first?.0 == "disk-a")
        #expect(measurements.samples.first?.1 == 4096)
        #expect((measurements.samples.first?.2 ?? -1) >= 0)
    }

    @Test("preflight and cleanup failures propagate without recording throughput")
    func failuresPropagate() async throws {
        let measurements = Measurements()
        let coordinator = CleanupCoordinator(check: { _ in throw Failure.preflight }, perform: { _ in throw Failure.execution },
                                             recordThroughput: { measurements.samples.append(($0, $1, $2)) })
        let plan = try plan()
        await #expect(throws: Failure.self) { try await coordinator.preflight(plan) }
        await #expect(throws: Failure.self) { try await coordinator.execute(plan, volumeID: "disk-a") }
        #expect(measurements.samples.isEmpty)
    }
}
