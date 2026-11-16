// [INPUT]: CleanupCoordinator 的注入接口与 Core 清理计划模型。
// [OUTPUT]: 验证吞吐记录、失败传播和 Event 预选的路径边界。
// [POS]: App 清理协作测试；不访问真实 FCP 资源库。
// [PROTOCOL]: Update this header on change, then check AGENTS.md
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
        let coordinator = CleanupCoordinator(check: { _ in }, perform: { _, _ in expected },
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
        let coordinator = CleanupCoordinator(check: { _ in throw Failure.preflight }, perform: { _, _ in throw Failure.execution },
                                             recordThroughput: { measurements.samples.append(($0, $1, $2)) })
        let plan = try plan()
        await #expect(throws: Failure.self) { try await coordinator.preflight(plan) }
        await #expect(throws: Failure.self) { try await coordinator.execute(plan, volumeID: "disk-a") }
        #expect(measurements.samples.isEmpty)
    }

    @Test("Event 预选不包含同名共享目录或其他 Event")
    func eventSelectionKeepsOnlyMatchingEvent() throws {
        let library = URL(fileURLWithPath: "/tmp/event-selection.fcpbundle")
        let database = CoreDataSnapshot(url: library.appendingPathComponent("CurrentVersion.flexolibrary"), size: 1, modificationTime: 0)
        let eventA = library.appendingPathComponent("库级共享/Render Files")
        let eventB = library.appendingPathComponent("另一事件/Render Files")
        let shared = library.appendingPathComponent("Shared Render Files")
        let fingerprint = FileFingerprint(allocatedSize: 100, logicalSize: 100, entryCount: 1, contentsSignature: 1)
        let items = [
            CacheItem(url: eventA, category: .renderFiles, allocatedSize: 100, logicalSize: 100,
                      confidence: .confirmed, ruleID: "event.render-files", fingerprint: fingerprint),
            CacheItem(url: eventB, category: .renderFiles, allocatedSize: 100, logicalSize: 100,
                      confidence: .confirmed, ruleID: "event.render-files", fingerprint: fingerprint),
            CacheItem(url: shared, category: .renderFiles, allocatedSize: 100, logicalSize: 100,
                      confidence: .confirmed, ruleID: "library.shared-render-files", fingerprint: fingerprint),
        ]
        let result = LibraryScanResult(libraryURL: library, totalAllocatedSize: 300, totalLogicalSize: 300,
                                       coreDataSnapshots: [database], cacheItems: items,
                                       observedCacheItems: [], protectedItems: [], issues: [])
        let plan = try CleanupPlan(scanResult: result, categories: [.renderFiles])
        #expect(CleanupEventSelection.matchingURLs(in: plan, eventName: "库级共享") == [eventA])
        #expect(CleanupEventSelection.matchingURLs(in: plan, eventName: "另一事件") == [eventB])
    }
}
