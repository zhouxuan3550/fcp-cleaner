import Foundation
import Testing
@testable import FCPLibraryCleanerCore

struct LibraryScannerTests {
    @Test func changeTokenIsStableWhenGeneratedDataIsUnchanged() async throws {
        let library = try MockLibrary.make()
        defer { try? FileManager.default.removeItem(at: library.root) }

        let first = try await LibraryScanner().changeToken(libraryURL: library.url)
        let second = try await LibraryScanner().changeToken(libraryURL: library.url)

        #expect(first == second)
    }

    @Test func changeTokenInvalidatesWhenGeneratedDataChanges() async throws {
        let library = try MockLibrary.make()
        defer { try? FileManager.default.removeItem(at: library.root) }
        let first = try await LibraryScanner().changeToken(libraryURL: library.url)
        let newRenderFile = library.root.appendingPathComponent("Event One/Render Files/new-render.mov")

        try Data(repeating: 0x52, count: 24_576).write(to: newRenderFile)
        let second = try await LibraryScanner().changeToken(libraryURL: library.url)

        #expect(first != second)
    }

    @Test func classifiesOnlyConfirmedEventDirectories() async throws {
        let library = try MockLibrary.make()
        defer { try? FileManager.default.removeItem(at: library.root) }

        let result = try await LibraryScanner().scan(libraryURL: library.url)

        #expect(result.cacheItems.count == 3)
        #expect(Set(result.cacheItems.map(\.category)) == [.renderFiles, .proxyMedia, .optimizedMedia])
        #expect(result.cacheItems.allSatisfy { $0.confidence == .confirmed })
        #expect(result.cacheItems.allSatisfy { $0.allocatedSize > 0 })
    }

    @Test func protectsOriginalMediaAndUnknownDirectories() async throws {
        let library = try MockLibrary.make()
        defer { try? FileManager.default.removeItem(at: library.root) }

        let result = try await LibraryScanner().scan(libraryURL: library.url)

        #expect(result.protectedItems.contains { $0.reason == .libraryDatabase })
        #expect(result.protectedItems.contains { $0.reason == .eventDatabase })
        #expect(result.protectedItems.contains { $0.reason == .originalMedia })
        #expect(result.observedCacheItems.contains { $0.url.lastPathComponent == "Analysis Files" && $0.confidence == .likely })
        #expect(!result.cacheItems.contains { $0.url.lastPathComponent == "Analysis Files" })
    }

    @Test func rejectsMissingLibraryDatabase() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".fcpbundle")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        await #expect(throws: CleanupError.self) {
            try await LibraryScanner().scan(libraryURL: root)
        }
    }

    @Test func cleanupPlanContainsOnlySelectedConfirmedCategories() async throws {
        let library = try MockLibrary.make()
        defer { try? FileManager.default.removeItem(at: library.root) }

        let result = try await LibraryScanner().scan(libraryURL: library.url)
        let plan = try CleanupPlan(scanResult: result, categories: [.renderFiles, .proxyMedia])

        #expect(plan.entries.count == 2)
        #expect(Set(plan.entries.map(\.item.category)) == [.renderFiles, .proxyMedia])
        #expect(plan.entries.allSatisfy { $0.item.confidence == .confirmed })
    }

    @Test func retryPlanContainsOnlyItemsNotMovedToTrash() async throws {
        let library = try MockLibrary.make()
        defer { try? FileManager.default.removeItem(at: library.root) }
        let scan = try await LibraryScanner().scan(libraryURL: library.url)
        let plan = try CleanupPlan(scanResult: scan, categories: Set(CacheCategory.cleanableCases))
        let completedURL = try #require(plan.entries.first?.item.url)
        let result = CleanupResult(
            movedToTrash: [completedURL],
            freedAllocatedSize: plan.entries.first?.item.allocatedSize ?? 0,
            errors: [.fileChanged(try #require(plan.entries.dropFirst().first?.item.url))]
        )

        let retry = try #require(plan.retryingItemsNotCompleted(in: result))

        #expect(retry.entries.count == plan.entries.count - 1)
        #expect(!retry.entries.contains { $0.item.url == completedURL })
    }

    @Test func planRejectsCandidateChangedAfterScan() async throws {
        let library = try MockLibrary.make()
        defer { try? FileManager.default.removeItem(at: library.root) }

        let result = try await LibraryScanner().scan(libraryURL: library.url)
        let plan = try CleanupPlan(scanResult: result, categories: [.renderFiles])
        let renderFile = library.root.appendingPathComponent("Event One/Render Files/render.mov")
        try Data(repeating: 0x42, count: 32_768).write(to: renderFile)

        await #expect(throws: CleanupError.self) {
            try await CleanupEngine(isFinalCutProRunning: { false }).preflight(plan: plan)
        }
    }

    @Test func cancelledScanNeverProducesAResult() async throws {
        let library = try MockLibrary.make()
        defer { try? FileManager.default.removeItem(at: library.root) }
        let control = ScanControl()
        control.cancel()

        await #expect(throws: CancellationError.self) {
            try await LibraryScanner().scan(libraryURL: library.url, control: control, onProgress: { _ in })
        }
    }

    @Test func scannerReportsProgress() async throws {
        let library = try MockLibrary.make()
        defer { try? FileManager.default.removeItem(at: library.root) }
        let collector = ProgressCollector()

        _ = try await LibraryScanner().scan(libraryURL: library.url, control: ScanControl()) { progress in
            collector.append(progress)
        }

        #expect(collector.latest?.files ?? 0 > 0)
        #expect(collector.latest?.allocatedBytes ?? 0 > 0)
    }

    @Test func cleanupStopsIfFinalCutProStartsAfterPreflight() async throws {
        let library = try MockLibrary.make()
        defer { try? FileManager.default.removeItem(at: library.root) }
        let result = try await LibraryScanner().scan(libraryURL: library.url)
        let plan = try CleanupPlan(scanResult: result, categories: [.renderFiles])
        let processState = ProcessState()

        let cleanup = try await CleanupEngine(isFinalCutProRunning: processState.isRunning).execute(plan: plan)
        #expect(cleanup.movedToTrash.isEmpty)
        #expect(cleanup.errors.contains { error in
            if case .libraryInUse = error { return true }
            return false
        })
    }

    @Test func inspectorKeepsOriginalMediaProtectedAndShowsCleanupRoot() async throws {
        let library = try MockLibrary.make()
        defer { try? FileManager.default.removeItem(at: library.root) }
        let result = try await LibraryScanner().scan(libraryURL: library.url)
        let report = try await LibraryInspector().inspect(scanResult: result)

        #expect(report.entries.contains { $0.url.lastPathComponent == "Render Files" && $0.disposition == .cleanupCandidate })
        #expect(report.entries.contains { $0.url.lastPathComponent == "Original Media" && $0.disposition == .protectedData })
        #expect(!report.entries.contains { $0.url.lastPathComponent == "source.mov" })
    }

    @Test func changedCoreDatabaseBlocksCleanup() async throws {
        let library = try MockLibrary.make()
        defer { try? FileManager.default.removeItem(at: library.root) }
        let scan = try await LibraryScanner().scan(libraryURL: library.url)
        let plan = try CleanupPlan(scanResult: scan, categories: [.renderFiles])
        try Data(repeating: 0x43, count: 16_384).write(to: library.root.appendingPathComponent("CurrentVersion.flexolibrary"))

        await #expect(throws: CleanupError.self) {
            try await CleanupEngine(isFinalCutProRunning: { false }).execute(plan: plan)
        }
    }

    @Test func libraryWithoutRenderFilesHasNoRenderCandidate() async throws {
        let library = try MockLibrary.make()
        let renderFiles = library.root.appendingPathComponent("Event One/Render Files")
        defer { try? FileManager.default.removeItem(at: library.root) }
        try FileManager.default.removeItem(at: renderFiles)

        let result = try await LibraryScanner().scan(libraryURL: library.url)
        #expect(!result.cacheItems.contains { $0.category == .renderFiles })
    }

    @Test func externalOriginalMediaLinkIsNeverFollowed() async throws {
        let library = try MockLibrary.make()
        let originalMedia = library.root.appendingPathComponent("Event One/Original Media")
        let externalMedia = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        defer {
            try? FileManager.default.removeItem(at: library.root)
            try? FileManager.default.removeItem(at: externalMedia)
        }
        try Data(repeating: 0x44, count: 32_768).write(to: externalMedia)
        try FileManager.default.removeItem(at: originalMedia)
        try FileManager.default.createSymbolicLink(at: originalMedia, withDestinationURL: externalMedia)

        let result = try await LibraryScanner().scan(libraryURL: library.url)
        #expect(result.protectedItems.contains { $0.url.lastPathComponent == "Original Media" && $0.reason == .originalMedia })
        #expect(result.totalAllocatedSize < 65_536)
    }

    @Test func movedCandidateIsNotCleaned() async throws {
        let library = try MockLibrary.make()
        defer { try? FileManager.default.removeItem(at: library.root) }
        let scan = try await LibraryScanner().scan(libraryURL: library.url)
        let plan = try CleanupPlan(scanResult: scan, categories: [.renderFiles])
        let original = library.root.appendingPathComponent("Event One/Render Files")
        let moved = library.root.appendingPathComponent("Event One/Render Files moved")
        try FileManager.default.moveItem(at: original, to: moved)

        await #expect(throws: CleanupError.self) {
            try await CleanupEngine(isFinalCutProRunning: { false }).preflight(plan: plan)
        }
    }

    @Test func runningFinalCutProBlocksCleanupBeforeAnyMove() async throws {
        let library = try MockLibrary.make()
        defer { try? FileManager.default.removeItem(at: library.root) }
        let scan = try await LibraryScanner().scan(libraryURL: library.url)
        let plan = try CleanupPlan(scanResult: scan, categories: [.renderFiles])

        await #expect(throws: CleanupError.self) {
            try await CleanupEngine(isFinalCutProRunning: { true }).execute(plan: plan)
        }
    }

    @Test func finalCutUsingAnotherLibraryDoesNotBlockTarget() async throws {
        let library = try MockLibrary.make()
        defer { try? FileManager.default.removeItem(at: library.root) }
        let scan = try await LibraryScanner().scan(libraryURL: library.url)
        let plan = try CleanupPlan(scanResult: scan, categories: [.renderFiles])
        let otherLibrary = FileManager.default.temporaryDirectory.appendingPathComponent("Other.fcpbundle")

        let result = try await CleanupEngine(isLibraryInUse: { url in
            url.standardizedFileURL == otherLibrary.standardizedFileURL
        }).execute(plan: plan)
        defer { result.trashedItems.forEach { try? FileManager.default.removeItem(at: $0.trashURL) } }

        #expect(result.movedToTrash.count == 1)
        #expect(result.trashedItems.count == 1)
        #expect(result.errors.isEmpty)
    }

    @Test func missingLibraryFailsPreflightAsOffline() async throws {
        let library = try MockLibrary.make()
        let scan = try await LibraryScanner().scan(libraryURL: library.url)
        let plan = try CleanupPlan(scanResult: scan, categories: [.renderFiles])
        try FileManager.default.removeItem(at: library.root)

        do {
            try await CleanupEngine(isFinalCutProRunning: { false }).preflight(plan: plan)
            Issue.record("Expected offline volume preflight failure")
        } catch let error as CleanupError {
            guard case .volumeOffline = error else {
                Issue.record("Expected volumeOffline, got \(error)")
                return
            }
        }
    }

    @Test func cleanupPlanReusesFingerprintCapturedDuringScan() async throws {
        let library = try MockLibrary.make()
        defer { try? FileManager.default.removeItem(at: library.root) }
        let scan = try await LibraryScanner().scan(libraryURL: library.url)
        let renderDirectory = library.root.appendingPathComponent("Event One/Render Files")
        try FileManager.default.removeItem(at: renderDirectory)

        let plan = try CleanupPlan(scanResult: scan, categories: [.renderFiles])

        #expect(plan.entries.count == 1)
        await #expect(throws: CleanupError.self) {
            try await CleanupEngine(isFinalCutProRunning: { false }).preflight(plan: plan)
        }
    }

    @Test func scansOnlyConfirmedDirectoriesFromLinkedExternalCache() async throws {
        let library = try MockLibrary.make()
        let external = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: library.root)
            try? FileManager.default.removeItem(at: external)
        }
        let renderFile = external.appendingPathComponent("Event One/Render Files/external-render.mov")
        let unrelatedFile = external.appendingPathComponent("Unrelated/Render Files/keep.mov")
        try FileManager.default.createDirectory(at: renderFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unrelatedFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x45, count: 16_384).write(to: renderFile)
        try Data(repeating: 0x46, count: 16_384).write(to: unrelatedFile)
        try FileManager.default.createSymbolicLink(
            at: library.root.appendingPathComponent(FCPStructureRules.cacheLinkName),
            withDestinationURL: external
        )

        let scan = try await LibraryScanner().scan(libraryURL: library.url)
        let externalItems = scan.cacheItems.filter { $0.storage == .external }

        #expect(externalItems.count == 1)
        #expect(externalItems.first?.url == renderFile.deletingLastPathComponent())
        #expect(scan.externalCleanableSize > 0)
        #expect(!externalItems.contains { $0.url.path.contains("Unrelated") })
    }

    @Test func changingExternalCacheLinkInvalidatesCleanupPlan() async throws {
        let library = try MockLibrary.make()
        let external = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let replacement = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: library.root)
            try? FileManager.default.removeItem(at: external)
            try? FileManager.default.removeItem(at: replacement)
        }
        let renderDirectory = external.appendingPathComponent("Event One/Render Files")
        try FileManager.default.createDirectory(at: renderDirectory, withIntermediateDirectories: true)
        try Data(repeating: 0x47, count: 16_384).write(to: renderDirectory.appendingPathComponent("render.mov"))
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: true)
        let link = library.root.appendingPathComponent(FCPStructureRules.cacheLinkName)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external)
        let scan = try await LibraryScanner().scan(libraryURL: library.url)
        let plan = try CleanupPlan(scanResult: scan, categories: [.renderFiles])
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: replacement)

        await #expect(throws: CleanupError.self) {
            try await CleanupEngine(isFinalCutProRunning: { false }).preflight(plan: plan)
        }
    }
}

private final class ProgressCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ScanProgress] = []

    var latest: ScanProgress? {
        lock.lock()
        defer { lock.unlock() }
        return values.last
    }

    func append(_ value: ScanProgress) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }
}

private final class ProcessState: @unchecked Sendable {
    private let lock = NSLock()
    private var checks = 0

    func isRunning() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        checks += 1
        return checks >= 2
    }
}

private enum MockLibrary {
    struct Fixture {
        let root: URL
        var url: URL { root }
    }

    static func make() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".fcpbundle")
        let event = root.appendingPathComponent("Event One")
        try FileManager.default.createDirectory(at: event, withIntermediateDirectories: true)
        try data("library database").write(to: root.appendingPathComponent("CurrentVersion.flexolibrary"))
        try data("event database").write(to: event.appendingPathComponent("CurrentVersion.fcpevent"))
        try write("render", under: event.appendingPathComponent("Render Files/render.mov"))
        try write("proxy", under: event.appendingPathComponent("Transcoded Media/Proxy Media/proxy.mov"))
        try write("optimized", under: event.appendingPathComponent("Transcoded Media/High Quality Media/optimized.mov"))
        try write("original", under: event.appendingPathComponent("Original Media/source.mov"))
        try write("analysis", under: event.appendingPathComponent("Analysis Files/tracking.data"))
        try write("decoy", under: event.appendingPathComponent("User Files/Render Files/keep.mov"))
        return Fixture(root: root)
    }

    private static func write(_ value: String, under url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data(value).write(to: url)
    }

    private static func data(_ value: String) -> Data {
        Data(repeating: 0x41, count: max(8_192, value.utf8.count))
    }
}
