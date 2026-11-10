import Foundation
import FCPLibraryCleanerCore

/// Run only on a newly created, uniquely named fixture directory. This helper
/// intentionally never accepts an existing library as a cleanup target.
@main
struct ScannerBenchmark {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { fatalError("usage: ScannerBenchmark <writable-volume-directory>") }
        let volume = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: volume.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            fatalError("benchmark volume is not mounted or accessible")
        }
        let runID = UUID().uuidString
        let root = volume.appendingPathComponent("FCP-Cleaner-Benchmark-" + runID, isDirectory: true)
        let library = root.appendingPathComponent("Fixture.fcpbundle", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: library, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let event = library.appendingPathComponent("Event", isDirectory: true)
        let directories = ["Render Files", "Transcoded Media/Proxy Media", "Transcoded Media/High Quality Media", "Analysis Files"]
        let filesPerDirectory = min(50_000, max(1, Int(ProcessInfo.processInfo.environment["FCP_BENCH_FILES_PER_DIRECTORY"] ?? "2000") ?? 2_000))
        for directory in directories {
            let target = event.appendingPathComponent(directory, isDirectory: true)
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            let data = Data(repeating: 0x43, count: 1024)
            for index in 0..<filesPerDirectory {
                try data.write(to: target.appendingPathComponent(String(format: "%05d.bin", index)))
            }
        }
        try Data("library".utf8).write(to: library.appendingPathComponent("CurrentVersion.flexolibrary"))
        try Data("event".utf8).write(to: event.appendingPathComponent("CurrentVersion.fcpevent"))

        let scanner = LibraryScanner()
        let startScan = ContinuousClock.now
        let scan = try await scanner.scan(libraryURL: library)
        let scanTime = seconds(since: startScan)
        guard scan.cacheItems.count == 3 else { fatalError("fixture was not classified as expected") }
        var validationTimes: [Double] = []
        for _ in 0..<3 {
            let started = ContinuousClock.now
            _ = try await scanner.changeToken(libraryURL: library)
            validationTimes.append(seconds(since: started))
        }
        let plan = try CleanupPlan(scanResult: scan, categories: Set(CacheCategory.cleanableCases))
        let startCleanup = ContinuousClock.now
        let result = try await CleanupEngine(isFinalCutProRunning: { false }).execute(plan: plan)
        let cleanupTime = seconds(since: startCleanup)
        defer {
            for item in result.trashedItems where item.originalURL.path.hasPrefix(library.path + "/") {
                try? fm.removeItem(at: item.trashURL)
            }
        }
        guard result.errors.isEmpty, result.movedToTrash.count == 3 else { fatalError("fixture cleanup failed: \(result.errors)") }
        let output: [String: Any] = ["fixtureFiles": filesPerDirectory * directories.count, "bytesPerFile": 1024,
                                     "scanSeconds": scanTime, "fullTokenSeconds": validationTimes,
                                     "cleanupSeconds": cleanupTime, "fixtureID": runID]
        let data = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }

    private static func seconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }
}
