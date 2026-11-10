import Darwin
import Foundation
import CoreServices
import Testing
@testable import FCPLibraryCleanerApp

struct FSEventsCheckpointTests {
    @Test("event history eventually detects modified libraries")
    func replaysRealHistory() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let library = root.appendingPathComponent("Library.fcpbundle", isDirectory: true)
        try fm.createDirectory(at: library, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try await Task.sleep(for: .seconds(1))
        let checkpoint = try #require(FSEventsCheckpoint.capture(libraryURL: library))
        try Data("changed".utf8).write(to: library.appendingPathComponent("changed"))
        var result: FSEventsHistoryResult = .unavailable
        for _ in 0..<8 {
            try await Task.sleep(for: .seconds(1))
            result = await FSEventsHistoryProbe.compare(checkpoint, libraryURL: library)
            if result == .changed { break }
        }
        #expect(result == .changed)
    }

    @Test("one-shot replay cannot guarantee immediate visibility", .disabled("FSEvents may deliver a recent write after HistoryDone and FlushSync; production keeps the stream alive and invalidates on late events."))
    func immediateWritesAreNotMissed() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let checkpoint = try #require(FSEventsCheckpoint.capture(libraryURL: root))
        try Data("changed".utf8).write(to: root.appendingPathComponent("changed"))
        #expect(await FSEventsHistoryProbe.compare(checkpoint, libraryURL: root) != .unchanged)
    }

    @Test("dropped or wrapped history is never treated as unchanged")
    func invalidHistoryFlags() {
        for flag in [kFSEventStreamEventFlagMustScanSubDirs, kFSEventStreamEventFlagUserDropped,
                     kFSEventStreamEventFlagKernelDropped, kFSEventStreamEventFlagEventIdsWrapped,
                     kFSEventStreamEventFlagRootChanged] {
            let state = FSEventsReplayState()
            let flags = [FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone | flag)]
            flags.withUnsafeBufferPointer { state.receive($0.baseAddress!, count: $0.count) }
            #expect(state.result == .changed)
        }
    }

    @Test("a burst of live changes needs only one invalidation per stream")
    func coalescesLiveChanges() {
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var count = 0
            func increment() { lock.lock(); count += 1; lock.unlock() }
            func value() -> Int { lock.lock(); defer { lock.unlock() }; return count }
        }
        let counter = Counter()
        let state = FSEventsReplayState(onChange: { counter.increment() })
        let historyDone = [FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone)]
        let change = [FSEventStreamEventFlags(0)]
        historyDone.withUnsafeBufferPointer { state.receive($0.baseAddress!, count: $0.count) }
        for _ in 0..<100 { change.withUnsafeBufferPointer { state.receive($0.baseAddress!, count: $0.count) } }
        #expect(counter.value() == 1)
    }

    @Test("network and ExFAT volumes cannot use event-history shortcuts")
    func unsupportedVolumesAreRejected() {
        #expect(FSEventsCheckpoint.supports(local: true, filesystem: "apfs"))
        #expect(FSEventsCheckpoint.supports(local: true, filesystem: "hfs"))
        #expect(!FSEventsCheckpoint.supports(local: true, filesystem: "exfat"))
        #expect(!FSEventsCheckpoint.supports(local: false, filesystem: "apfs"))
    }

    @Test("checkpoint tracks both library and external cache identities")
    func capturesLibraryAndCache() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let library = root.appendingPathComponent("Library.fcpbundle", isDirectory: true)
        let cache = root.appendingPathComponent("External Cache", isDirectory: true)
        try fm.createDirectory(at: library, withIntermediateDirectories: true)
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createSymbolicLink(at: library.appendingPathComponent(".fcpcache"), withDestinationURL: cache)
        let checkpoint = try #require(FSEventsCheckpoint.capture(libraryURL: library))
        #expect(checkpoint.roots.count == 2)
        #expect(checkpoint.roots.allSatisfy { $0.relativePath.hasPrefix("/") && !$0.volumeUUID.isEmpty && $0.eventID != 0 })
        #expect(checkpoint.roots.contains { $0.relativePath.hasSuffix("/\(root.lastPathComponent)/Library.fcpbundle") })
        #expect(checkpoint.roots.contains { $0.relativePath.hasSuffix("/\(root.lastPathComponent)/External Cache") })
        #expect(checkpoint.hasSameRoots(as: checkpoint))
        let changed = checkpoint.roots.map { root in
            FSEventsCheckpoint.Root(canonicalPath: root.canonicalPath, relativePath: root.relativePath,
                                    volumeUUID: "changed", inode: root.inode, eventID: root.eventID)
        }
        #expect(!checkpoint.hasSameRoots(as: FSEventsCheckpoint(roots: changed)))
        let earlier = checkpoint.roots.map { root in
            FSEventsCheckpoint.Root(canonicalPath: root.canonicalPath, relativePath: root.relativePath,
                                    volumeUUID: root.volumeUUID, inode: root.inode, eventID: 0)
        }
        #expect(!checkpoint.hasSameRoots(as: FSEventsCheckpoint(roots: earlier)))
        #expect(!FSEventsCheckpoint(roots: earlier).hasSameRoots(as: checkpoint))
    }

    @Test("a broken external cache link prevents an incomplete checkpoint")
    func brokenLinkIsRejected() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createSymbolicLink(at: root.appendingPathComponent(".fcpcache"), withDestinationURL: root.appendingPathComponent("missing"))
        #expect(FSEventsCheckpoint.capture(libraryURL: root) == nil)
    }

    @Test("an internal cache link is covered by the library root")
    func internalLinkIsCovered() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent(".fcpcache").path, withDestinationPath: ".")
        #expect(FSEventsCheckpoint.capture(libraryURL: root)?.roots.count == 1)
    }

    @Test("live replay remains subscribed after the historical boundary")
    func liveLeaseReportsLaterChanges() async throws {
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var count = 0
            func increment() { lock.lock(); count += 1; lock.unlock() }
            func value() -> Int { lock.lock(); defer { lock.unlock() }; return count }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await Task.sleep(for: .seconds(2))
        let checkpoint = try #require(FSEventsCheckpoint.capture(libraryURL: root))
        let counter = Counter()
        let lease = try #require(await FSEventsLiveLease.open(checkpoint: checkpoint, libraryURL: root, onChange: { counter.increment() }))
        let before = counter.value()
        try Data("change".utf8).write(to: root.appendingPathComponent("changed"))
        for _ in 0..<40 where counter.value() == before { try await Task.sleep(for: .milliseconds(100)) }
        #expect(counter.value() > before)
        withExtendedLifetime(lease) { }
    }

    @Test("an immediate write either rejects replay or triggers the live stream")
    func immediateWriteEventuallyInvalidatesLiveLease() async throws {
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var count = 0
            func increment() { lock.lock(); count += 1; lock.unlock() }
            func value() -> Int { lock.lock(); defer { lock.unlock() }; return count }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await Task.sleep(for: .seconds(2))
        let checkpoint = try #require(FSEventsCheckpoint.capture(libraryURL: root))
        try Data("changed".utf8).write(to: root.appendingPathComponent("changed"))
        let counter = Counter()
        let lease = await FSEventsLiveLease.open(checkpoint: checkpoint, libraryURL: root, onChange: { counter.increment() })
        guard let lease else { return }
        for _ in 0..<50 where counter.value() == 0 { try await Task.sleep(for: .milliseconds(100)) }
        #expect(counter.value() > 0)
        withExtendedLifetime(lease) { }
    }

    @Test("library and external cache streams both remain active")
    func liveLeaseWatchesBothRoots() async throws {
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var count = 0
            func increment() { lock.lock(); count += 1; lock.unlock() }
            func value() -> Int { lock.lock(); defer { lock.unlock() }; return count }
        }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let library = root.appendingPathComponent("Library.fcpbundle", isDirectory: true)
        let externalBase = ProcessInfo.processInfo.environment["FCP_FSEVENTS_EXTERNAL_VOLUME"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? root
        if ProcessInfo.processInfo.environment["FCP_FSEVENTS_EXTERNAL_VOLUME"] != nil {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: externalBase.path, isDirectory: &isDirectory), isDirectory.boolValue else { throw CocoaError(.fileReadNoSuchFile) }
        }
        let external = externalBase.appendingPathComponent("FCP-Cleaner-Events-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: library, withIntermediateDirectories: true)
        try fm.createDirectory(at: external, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root); try? fm.removeItem(at: external) }
        try fm.createSymbolicLink(at: library.appendingPathComponent(".fcpcache"), withDestinationURL: external)
        try await Task.sleep(for: .seconds(2))
        let checkpoint = try #require(FSEventsCheckpoint.capture(libraryURL: library))
        #expect(checkpoint.roots.count == 2)
        let counter = Counter()
        var lease: FSEventsLiveLease?
        for _ in 0..<10 {
            lease = await FSEventsLiveLease.open(checkpoint: checkpoint, libraryURL: library, onChange: { counter.increment() })
            if lease != nil { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        let active = try #require(lease)
        var before = counter.value()
        try Data("library".utf8).write(to: library.appendingPathComponent("changed"))
        for _ in 0..<50 where counter.value() == before { try await Task.sleep(for: .milliseconds(100)) }
        #expect(counter.value() > before)
        before = counter.value()
        try Data("external".utf8).write(to: external.appendingPathComponent("changed"))
        for _ in 0..<50 where counter.value() == before { try await Task.sleep(for: .milliseconds(100)) }
        #expect(counter.value() > before)
        withExtendedLifetime(active) { }
    }
}
