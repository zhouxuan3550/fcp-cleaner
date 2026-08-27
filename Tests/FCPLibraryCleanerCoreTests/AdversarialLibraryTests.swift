import Foundation
import Testing
@testable import FCPLibraryCleanerCore

/// Adversarial fixtures pinning the safety guarantees of 扫描→计划→执行 under
/// hostile filesystem shapes: symlinks, post-scan swaps, lookalike names, and
/// unreadable subtrees. Every test ends by asserting user media survives.
struct AdversarialLibraryTests {
    @Test("symlinked media dragged into Render Files leaves with the folder while its target survives")
    func symlinkContentIsTrashedButTargetMediaSurvives() async throws {
        let root = try makeBaseLibrary(named: "adv-symlink-content")
        defer { try? FileManager.default.removeItem(at: root) }
        let event = root.appendingPathComponent("Event One")
        let sourceURL = event.appendingPathComponent("Original Media/source.mov")
        let renderFiles = event.appendingPathComponent("Render Files")
        try FileManager.default.createSymbolicLink(
            at: renderFiles.appendingPathComponent("sneaky-link.mov"),
            withDestinationURL: sourceURL
        )

        let result = try await LibraryScanner().scan(libraryURL: root)
        let plan = try CleanupPlan(scanResult: result, categories: Set(CacheCategory.cleanableCases))
        let outcome = try await CleanupEngine(isLibraryInUse: neverInUse).execute(plan: plan)

        #expect(outcome.errors.isEmpty)
        #expect(outcome.movedToTrash.contains(renderFiles))
        expectExists(sourceURL, "Target media behind the symlink must survive")
        expectMissing(renderFiles.appendingPathComponent("sneaky-link.mov"), "The link leaves together with its candidate folder")
    }

    @Test("render-files directory swapped for a symlink after scanning is rejected, siblings stay isolated")
    func postScanSymlinkSwapIsRejectedAndMediaSurvives() async throws {
        let root = try makeBaseLibrary(named: "adv-postswap")
        defer { try? FileManager.default.removeItem(at: root) }
        let event = root.appendingPathComponent("Event One")
        let originalMedia = event.appendingPathComponent("Original Media")
        let swappedRenderFiles = event.appendingPathComponent("Render Files")

        let result = try await LibraryScanner().scan(libraryURL: root)
        let plan = try CleanupPlan(scanResult: result, categories: Set(CacheCategory.cleanableCases))

        // Hostile swap after scan: Render Files now points at Original Media.
        try FileManager.default.removeItem(at: swappedRenderFiles)
        try FileManager.default.createSymbolicLink(
            at: swappedRenderFiles,
            withDestinationURL: originalMedia
        )

        let outcome = try await CleanupEngine(isLibraryInUse: neverInUse).execute(plan: plan)

        #expect(outcome.movedToTrash.isEmpty == false) // unrelated candidates may proceed
        #expect(outcome.movedToTrash.contains(swappedRenderFiles) == false)
        #expect(outcome.errors.isEmpty == false) // the swapped candidate must report an error
        expectExists(
            originalMedia.appendingPathComponent("source.mov"),
            "Original Media behind the swapped link must survive"
        )
        expectExists(swappedRenderFiles, "The hostile link itself is left in place, never followed")
    }

    @Test("renaming an event between scan and cleanup deletes nothing")
    func renamedEventBetweenScanAndCleanupDeletesNothing() async throws {
        let root = try makeBaseLibrary(named: "adv-rename")
        defer { try? FileManager.default.removeItem(at: root) }
        let oldEvent = root.appendingPathComponent("Event One")
        let newEvent = root.appendingPathComponent("Event One Renamed")
        let renderFiles = newEvent.appendingPathComponent("Render Files")

        let result = try await LibraryScanner().scan(libraryURL: root)
        let plan = try CleanupPlan(scanResult: result, categories: Set(CacheCategory.cleanableCases))

        try FileManager.default.moveItem(at: oldEvent, to: newEvent)

        // Both outcomes are acceptable safety-wise: a hard throw from preflight
        // validation (database snapshot gone) or a fully-failed result object.
        do {
            let outcome = try await CleanupEngine(isLibraryInUse: neverInUse).execute(plan: plan)
            #expect(outcome.movedToTrash.isEmpty)
            #expect(outcome.errors.isEmpty == false)
        } catch {
            // rejected before touching anything — also acceptable
        }

        expectExists(renderFiles, "Renamed event's generated files must be untouched")
        expectExists(newEvent.appendingPathComponent("CurrentVersion.fcpevent"), "Renamed database must be intact")
    }

    @Test("lookalike decoy directories are classified as protected structure, never cleaned")
    func lookalikeDecoysAreNeverCleanable() async throws {
        let root = try makeBaseLibrary(named: "adv-decoy")
        defer { try? FileManager.default.removeItem(at: root) }
        let event = root.appendingPathComponent("Event One")
        // 前3个是 Event/库根的直接子目录，会被逐项列入保护清单；
        // 「User Files」深层的同名目录不逐项上报，但同样绝不被清理。
        let protectedDecoys = [
            event.appendingPathComponent("Render Files Old"),
            event.appendingPathComponent("Render Files.backup"),
            root.appendingPathComponent("Shared Render Files Backup"),
        ]
        let nestedDecoy = event.appendingPathComponent("User Files/Render Files")
        for (index, decoy) in protectedDecoys.enumerated() {
            try write("keep\(index)", to: decoy.appendingPathComponent("keep.mov"))
        }
        try write("nested", to: nestedDecoy.appendingPathComponent("keep.mov"))

        let result = try await LibraryScanner().scan(libraryURL: root)

        // Only the canonical whitelisted candidates are confirmed cleanable.
        #expect(result.cacheItems.count == 3)
        for decoy in protectedDecoys {
            #expect(
                result.protectedItems.contains { $0.url.standardizedFileURL == decoy.standardizedFileURL },
                "Decoy must be reported as protected: \(decoy.lastPathComponent)"
            )
        }

        let plan = try CleanupPlan(scanResult: result, categories: Set(CacheCategory.cleanableCases))
        let outcome = try await CleanupEngine(isLibraryInUse: neverInUse).execute(plan: plan)
        #expect(outcome.errors.isEmpty)
        for decoy in protectedDecoys {
            expectExists(decoy.appendingPathComponent("keep.mov"), "Decoy content must survive")
        }
        expectExists(nestedDecoy.appendingPathComponent("keep.mov"), "Nested lookalike content must survive")
    }

    @Test("an unreadable subtree makes the scan fail conservatively instead of guessing sizes")
    func unreadableSubtreeFailsScanConservatively() async throws {
        let root = try makeBaseLibrary(named: "adv-perm")
        let transcoded = root.appendingPathComponent("Event One/Transcoded Media")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: transcoded.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: transcoded.path)
            try? FileManager.default.removeItem(at: root)
        }

        do {
            _ = try await LibraryScanner().scan(libraryURL: root)
            Issue.record("Expected scan to throw CleanupError.permissionDenied")
        } catch is CancellationError {
            Issue.record("Unexpected cancellation")
        } catch {
            #expect(error is CleanupError)
        }

        expectExists(
            root.appendingPathComponent("Event One/Original Media/source.mov"),
            "Nothing may be removed by a failed scan"
        )
    }

    // MARK: - Fixture

    private let neverInUse: @Sendable (URL) -> Bool = { _ in false }

    /// Built under the symlink-resolved temporary root so every produced URL
    /// matches what the scanner reports back (macOS standardizes /var→/private/var).
    private var fixtureRoot: URL {
        realpathURL(FileManager.default.temporaryDirectory)
    }

    /// POSIX realpath：真正折叠 /var→/private/var 这类符号链接。
    private func realpathURL(_ url: URL) -> URL {
        let path = url.path
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard let resolved = realpath(path, &buffer),
              let str = String(validatingCString: resolved) else {
            return url
        }
        return URL(fileURLWithPath: str, isDirectory: true)
    }

    private func makeBaseLibrary(named name: String) throws -> URL {
        let root = fixtureRoot.appendingPathComponent(name + "-" + UUID().uuidString + ".fcpbundle")
        let event = root.appendingPathComponent("Event One")
        try FileManager.default.createDirectory(at: event, withIntermediateDirectories: true)
        try Data("library database".utf8).write(to: root.appendingPathComponent("CurrentVersion.flexolibrary"))
        try Data("event database".utf8).write(to: event.appendingPathComponent("CurrentVersion.fcpevent"))
        try write("render", to: event.appendingPathComponent("Render Files/render.mov"))
        try write("proxy", to: event.appendingPathComponent("Transcoded Media/Proxy Media/proxy.mov"))
        try write("optimized", to: event.appendingPathComponent("Transcoded Media/High Quality Media/optimized.mov"))
        try write("original", to: event.appendingPathComponent("Original Media/source.mov"))
        return root
    }

    private func write(_ value: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(value.utf8).write(to: url)
    }

    private func expectExists(_ url: URL, _ message: String) {
        if !FileManager.default.fileExists(atPath: url.path) {
            Issue.record("\(message) [missing: \(url.path)]")
        }
    }

    private func expectMissing(_ url: URL, _ message: String) {
        if FileManager.default.fileExists(atPath: url.path) {
            Issue.record("\(message) [still present: \(url.path)]")
        }
    }
}
