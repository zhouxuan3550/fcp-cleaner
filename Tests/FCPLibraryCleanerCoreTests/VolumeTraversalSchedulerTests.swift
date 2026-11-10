import Foundation
import Testing
@testable import FCPLibraryCleanerCore

struct VolumeTraversalSchedulerTests {
    private actor Counter {
        private var active: [String: Int] = [:]
        private(set) var peak: [String: Int] = [:]
        private(set) var totalPeak = 0
        func begin(_ volume: String) {
            active[volume, default: 0] += 1
            peak[volume] = max(peak[volume, default: 0], active[volume, default: 0])
            totalPeak = max(totalPeak, active.values.reduce(0, +))
        }
        func end(_ volume: String) { active[volume, default: 0] -= 1 }
    }

    @Test("independent scans share a volume limit without blocking other volumes")
    func sharedLimit() async throws {
        let scheduler = VolumeTraversalScheduler()
        let counter = Counter()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<8 {
                let volume = index < 6 ? "mechanical" : "other"
                group.addTask {
                    try await scheduler.withPermit(volumeID: volume, limit: 1) {
                        await counter.begin(volume)
                        try await Task.sleep(for: .milliseconds(25))
                        await counter.end(volume)
                    }
                }
            }
            try await group.waitForAll()
        }
        let peak = await counter.peak
        let totalPeak = await counter.totalPeak
        #expect(peak["mechanical"] == 1)
        #expect(peak["other"] == 1)
        #expect(totalPeak == 2)
    }

    @Test("cancelled waiters do not consume or leak a permit")
    func cancelledWaiter() async throws {
        let scheduler = VolumeTraversalScheduler()
        let (started, startedContinuation) = AsyncStream<Void>.makeStream()
        let (release, releaseContinuation) = AsyncStream<Void>.makeStream()
        let holder = Task {
            try await scheduler.withPermit(volumeID: "disk", limit: 1) {
                startedContinuation.yield(())
                for await _ in release { break }
            }
        }
        for await _ in started { break }
        let waiter = Task {
            try await scheduler.withPermit(volumeID: "disk", limit: 1) { 1 }
        }
        let control = ScanControl()
        let controlledWaiter = Task {
            try await scheduler.withPermit(volumeID: "disk", limit: 1, control: control) { 3 }
        }
        try await Task.sleep(for: .milliseconds(30))
        waiter.cancel()
        control.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        await #expect(throws: CancellationError.self) { try await controlledWaiter.value }
        releaseContinuation.yield(())
        try await holder.value
        let next = try await scheduler.withPermit(volumeID: "disk", limit: 1) { 2 }
        #expect(next == 2)
        startedContinuation.finish()
        releaseContinuation.finish()
    }
}
