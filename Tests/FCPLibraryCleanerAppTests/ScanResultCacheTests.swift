import Foundation
import Testing
import FCPLibraryCleanerCore
@testable import FCPLibraryCleanerApp

struct ScanResultCacheTests {
    private struct LegacyEntry: Encodable {
        let schemaVersion: Int
        let token: LibraryChangeToken
        let result: LibraryScanResult
    }

    @Test("binary cache and legacy JSON are invalidated when generated files change")
    func binaryAndLegacyCache() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let library = root.appendingPathComponent("Test.fcpbundle", isDirectory: true)
        let render = library.appendingPathComponent("Shared Render Files", isDirectory: true)
        try fm.createDirectory(at: render, withIntermediateDirectories: true)
        try Data("database".utf8).write(to: library.appendingPathComponent("CurrentVersion.flexolibrary"))
        try Data("before".utf8).write(to: render.appendingPathComponent("frame"))
        let cache = ScanResultCache()
        defer {
            try? fm.removeItem(at: root)
        }

        let scan = try await LibraryScanner().scan(libraryURL: library)
        let token = try #require(scan.changeToken)
        let cacheRoot = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.fcpcleaner.app/ScanResults", isDirectory: true)
        let hash = library.standardizedFileURL.path.utf8.reduce(UInt64(1_469_598_103_934_665_603)) {
            ($0 ^ UInt64($1)) &* 1_099_511_628_211
        }
        let base = cacheRoot.appendingPathComponent(String(hash, radix: 16))
        let plist = base.appendingPathExtension("plist")
        let json = base.appendingPathExtension("json")
        await cache.save(scan)
        #expect(try Data(contentsOf: plist).starts(with: Data("bplist00".utf8)))
        let binaryCached = await cache.loadIfCurrent(libraryURL: library)
        #expect(binaryCached != nil)
        #expect(binaryCached?.cacheItems.first?.reclaimableEstimate == scan.cacheItems.first?.reclaimableEstimate)

        try fm.removeItem(at: plist)
        try JSONEncoder().encode(LegacyEntry(schemaVersion: 5, token: token, result: scan)).write(to: json)
        #expect(await cache.loadIfCurrent(libraryURL: library) != nil)
        if fm.fileExists(atPath: plist.path) { try fm.removeItem(at: plist) }
        try JSONEncoder().encode(LegacyEntry(schemaVersion: 4, token: token, result: scan)).write(to: json)
        #expect(await cache.loadIfCurrent(libraryURL: library) == nil)
        try JSONEncoder().encode(LegacyEntry(schemaVersion: 5, token: token, result: scan)).write(to: json)
        try Data("changed content".utf8).write(to: render.appendingPathComponent("frame"))
        #expect(await cache.loadIfCurrent(libraryURL: library) == nil)
        await cache.removeCache(for: library)
    }

    @Test("checkpointed scan is reused with a live stream and later changes invalidate it")
    func liveCache() async throws {
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var count = 0
            func increment() { lock.lock(); count += 1; lock.unlock() }
            func value() -> Int { lock.lock(); defer { lock.unlock() }; return count }
        }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let library = root.appendingPathComponent("Test.fcpbundle", isDirectory: true)
        let render = library.appendingPathComponent("Shared Render Files", isDirectory: true)
        try fm.createDirectory(at: render, withIntermediateDirectories: true)
        try Data("database".utf8).write(to: library.appendingPathComponent("CurrentVersion.flexolibrary"))
        try Data("before".utf8).write(to: render.appendingPathComponent("frame"))
        let cache = ScanResultCache()
        defer { try? fm.removeItem(at: root) }
        try await Task.sleep(for: .seconds(2))
        let checkpoint = try #require(FSEventsCheckpoint.capture(libraryURL: library))
        let scan = try await LibraryScanner().scan(libraryURL: library)
        await cache.save(scan, checkpoint: checkpoint)
        let counter = Counter()
        let control = ScanControl()
        var loaded: ScanResultCache.LiveResult?
        for _ in 0..<10 {
            loaded = await cache.loadWithLiveEvents(libraryURL: library, control: control, onChange: { counter.increment() })
            if loaded != nil { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        let live = try #require(loaded)
        #expect(live.result.confirmedCleanableSize == scan.confirmedCleanableSize)
        let before = counter.value()
        try Data("modified contents".utf8).write(to: render.appendingPathComponent("frame"))
        for _ in 0..<50 where counter.value() == before { try await Task.sleep(for: .milliseconds(100)) }
        #expect(counter.value() > before)
        #expect(await cache.loadIfCurrent(libraryURL: library) == nil)
        withExtendedLifetime(live) { }
        await cache.removeCache(for: library)
    }

    @Test("optional incremental-cache benchmark on a disposable library")
    func benchmarkLiveCache() async throws {
        guard let volume = ProcessInfo.processInfo.environment["FCP_BENCH_CACHE_VOLUME"] else { return }
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: volume, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        let root = URL(fileURLWithPath: volume, isDirectory: true)
            .appendingPathComponent("FCP-Cleaner-Benchmark-" + UUID().uuidString, isDirectory: true)
        let library = root.appendingPathComponent("Fixture.fcpbundle", isDirectory: true)
        let event = library.appendingPathComponent("Event", isDirectory: true)
        try fm.createDirectory(at: event, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let filesPerDirectory = min(50_000, max(1, Int(ProcessInfo.processInfo.environment["FCP_BENCH_FILES_PER_DIRECTORY"] ?? "2000") ?? 2_000))
        for path in ["Render Files", "Transcoded Media/Proxy Media", "Transcoded Media/High Quality Media", "Analysis Files"] {
            let folder = event.appendingPathComponent(path, isDirectory: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let bytes = Data(repeating: 0x43, count: 1024)
            for index in 0..<filesPerDirectory { try bytes.write(to: folder.appendingPathComponent(String(format: "%05d.bin", index))) }
        }
        try Data("library".utf8).write(to: library.appendingPathComponent("CurrentVersion.flexolibrary"))
        try Data("event".utf8).write(to: event.appendingPathComponent("CurrentVersion.fcpevent"))
        try await Task.sleep(for: .seconds(2))
        let checkpoint = try #require(FSEventsCheckpoint.capture(libraryURL: library))
        let scan = try await LibraryScanner().scan(libraryURL: library)
        let cache = ScanResultCache()
        await cache.save(scan, checkpoint: checkpoint)
        var times: [Double] = []
        for _ in 0..<3 {
            let start = ContinuousClock.now
            let live = try #require(await cache.loadWithLiveEvents(libraryURL: library, control: ScanControl(), onChange: {}))
            let duration = ContinuousClock.now - start
            times.append(Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18)
            #expect(live.result.confirmedCleanableSize == scan.confirmedCleanableSize)
            withExtendedLifetime(live) { }
        }
        let result = try JSONSerialization.data(withJSONObject: ["liveCacheSeconds": times, "fixtureFiles": filesPerDirectory * 4])
        print("FCP_BENCHMARK_CACHE " + String(decoding: result, as: UTF8.self))
        await cache.removeCache(for: library)
    }
}
