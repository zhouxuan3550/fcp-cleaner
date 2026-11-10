import Foundation
import Observation

@MainActor
struct ScanRequest {
    let record: LibraryRecord
    var preserveLastCleanup: Bool
    var force: Bool
}

/// Owns queue ordering, deduplication and the global scan slot count.
@MainActor
@Observable
final class LibraryScanQueue {
    private let limit: Int
    private var pending: [ScanRequest] = []
    private var active: [LibraryRecord.ID: LibraryRecord] = [:]

    init(limit: Int = 3) { self.limit = max(1, limit) }

    var isPending: Bool { !pending.isEmpty || !active.isEmpty }

    func enqueue(_ record: LibraryRecord, preserveLastCleanup: Bool, force: Bool) {
        if let index = pending.firstIndex(where: { $0.record.id == record.id }) {
            pending[index].force = pending[index].force || force
            pending[index].preserveLastCleanup = pending[index].preserveLastCleanup || preserveLastCleanup
        } else if active[record.id] == nil {
            pending.append(ScanRequest(record: record, preserveLastCleanup: preserveLastCleanup, force: force))
            record.isQueued = true
        }
    }

    func takeNext(preferredID: LibraryRecord.ID?) -> ScanRequest? {
        guard active.count < limit, !pending.isEmpty else { return nil }
        let index = pending.firstIndex { $0.record.id == preferredID } ?? pending.startIndex
        let request = pending.remove(at: index)
        active[request.record.id] = request.record
        request.record.isQueued = false
        return request
    }

    @discardableResult
    func removePending(_ record: LibraryRecord) -> Bool {
        guard let index = pending.firstIndex(where: { $0.record.id == record.id }) else { return false }
        pending.remove(at: index)
        record.isQueued = false
        return true
    }

    func finish(_ record: LibraryRecord) { active.removeValue(forKey: record.id) }
}
