import Foundation
import Testing
import Observation
@testable import FCPLibraryCleanerApp

@MainActor
struct LibraryScanQueueTests {
    @Test("queue respects capacity, selected priority and request merging")
    func capacityPriorityAndMerge() throws {
        let queue = LibraryScanQueue(limit: 1)
        let first = LibraryRecord(url: URL(fileURLWithPath: "/tmp/first.fcpbundle"))
        let second = LibraryRecord(url: URL(fileURLWithPath: "/tmp/second.fcpbundle"))
        let preferred = LibraryRecord(url: URL(fileURLWithPath: "/tmp/preferred.fcpbundle"))
        queue.enqueue(first, preserveLastCleanup: false, force: false)
        queue.enqueue(second, preserveLastCleanup: false, force: false)
        queue.enqueue(preferred, preserveLastCleanup: false, force: false)
        queue.enqueue(preferred, preserveLastCleanup: true, force: true)
        let selected = try #require(queue.takeNext(preferredID: preferred.id))
        #expect(selected.record.id == preferred.id)
        #expect(selected.force && selected.preserveLastCleanup)
        #expect(!preferred.isQueued)
        #expect(queue.takeNext(preferredID: nil) == nil)
        queue.finish(preferred)
        #expect(queue.takeNext(preferredID: nil)?.record.id == first.id)
        #expect(queue.removePending(second))
        #expect(!second.isQueued)
        queue.finish(first)
        #expect(!queue.isPending)
    }

    @Test("active records stay alive until the scan slot finishes")
    func activeRecordLifetime() throws {
        let queue = LibraryScanQueue(limit: 1)
        var record: LibraryRecord? = LibraryRecord(url: URL(fileURLWithPath: "/tmp/active.fcpbundle"))
        weak let weakRecord = record
        queue.enqueue(try #require(record), preserveLastCleanup: false, force: false)
        _ = queue.takeNext(preferredID: nil)
        record = nil
        let active = try #require(weakRecord)
        #expect(queue.isPending)
        queue.finish(active)
        #expect(!queue.isPending)
    }

    @Test("pending-state changes are observable by the interface")
    func pendingStateIsObservable() {
        final class Signal: @unchecked Sendable {
            private let lock = NSLock()
            private var changed = false
            func set() { lock.lock(); changed = true; lock.unlock() }
            var value: Bool { lock.lock(); defer { lock.unlock() }; return changed }
        }
        let queue = LibraryScanQueue(limit: 1)
        let signal = Signal()
        withObservationTracking { _ = queue.isPending } onChange: { signal.set() }
        queue.enqueue(LibraryRecord(url: URL(fileURLWithPath: "/tmp/observation.fcpbundle")), preserveLastCleanup: false, force: false)
        #expect(signal.value)
    }
}
