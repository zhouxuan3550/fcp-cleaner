import Foundation
import Testing
import FCPLibraryCleanerCore
@testable import FCPLibraryCleanerApp

struct APFSSnapshotGuardTests {
    private let base = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)

    /// 固定内容的假 tmutil：输出给定文本并以给定退出码结束。
    private func makeFakeTmutil(stdout: String, exitCode: Int32) throws -> URL {
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let script = base.appendingPathComponent("fake-tmutil-\(exitCode)-\(stdout.hashValue)")
        let body = """
        #!/bin/bash
        cat <<'FAKE'
        \(stdout)
        FAKE
        exit \(exitCode)
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    private func makePlan(libraryURL: URL) throws -> CleanupPlan {
        let database = CoreDataSnapshot(url: libraryURL.appendingPathComponent("CurrentVersion.flexolibrary"), size: 1, modificationTime: 0)
        let result = LibraryScanResult(libraryURL: libraryURL, totalAllocatedSize: 0, totalLogicalSize: 0,
                                       coreDataSnapshots: [database], cacheItems: [], observedCacheItems: [], protectedItems: [], issues: [])
        return try CleanupPlan(scanResult: result, categories: [])
    }

    @Test("合法输出解析出快照日期")
    func parsesSnapshotDate() async throws {
        let library = base.appendingPathComponent("Lib.fcpbundle")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let tmutil = try makeFakeTmutil(
            stdout: "NOTE: local snapshots are considered purgeable.\nCreated local snapshot with date: 2026-11-15-162203",
            exitCode: 0)

        let date = try await APFSSnapshotGuard.prepareSnapshot(
            for: makePlan(libraryURL: library), tmutilPath: tmutil.path)

        let components = try #require(date.map { Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: $0) })
        #expect(components == DateComponents(year: 2026, month: 11, day: 15, hour: 16, minute: 22))
    }

    @Test("非零退出或无法解析的输出返回 nil，不抛错")
    func failuresReturnNil() async throws {
        let library = base.appendingPathComponent("Lib.fcpbundle")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let failing = try makeFakeTmutil(stdout: "tmutil: something broke", exitCode: 1)
        let garbage = try makeFakeTmutil(stdout: "no marker here", exitCode: 0)

        #expect(try await APFSSnapshotGuard.prepareSnapshot(for: makePlan(libraryURL: library), tmutilPath: failing.path) == nil)
        #expect(try await APFSSnapshotGuard.prepareSnapshot(for: makePlan(libraryURL: library), tmutilPath: garbage.path) == nil)
    }

    @Test("volumeURL 不是 / 的路径被判定为不可快照")
    func ineligibleVolumeReturnsNil() async throws {
        let foreign = URL(fileURLWithPath: "/nonexistent-snapshot-probe/Lib.fcpbundle")
        let tmutil = try makeFakeTmutil(stdout: "Created local snapshot with date: 2026-11-15-162203", exitCode: 0)

        #expect(!APFSSnapshotGuard.isOnBootDataVolume(foreign))
        #expect(try await APFSSnapshotGuard.prepareSnapshot(for: makePlan(libraryURL: foreign), tmutilPath: tmutil.path) == nil)
    }
}

@MainActor
struct CleanupSnapshotWiringTests {
    private func plan() throws -> CleanupPlan {
        let url = URL(fileURLWithPath: "/tmp/coordinator-snapshot.fcpbundle")
        let database = CoreDataSnapshot(url: url.appendingPathComponent("CurrentVersion.flexolibrary"), size: 1, modificationTime: 0)
        let result = LibraryScanResult(libraryURL: url, totalAllocatedSize: 0, totalLogicalSize: 0,
                                       coreDataSnapshots: [database], cacheItems: [], observedCacheItems: [], protectedItems: [], issues: [])
        return try CleanupPlan(scanResult: result, categories: [])
    }

    @Test("开关开启时快照日期与耗时都回填进结果；关闭时快照为空")
    func coordinatorCarriesSnapshotDate() async throws {
        let stamp = Date(timeIntervalSince1970: 1_760_000_000)
        let coordinator = CleanupCoordinator(
            perform: { _ in CleanupResult(movedToTrash: [], freedAllocatedSize: 0, errors: []) },
            prepareSnapshot: { _ in stamp })

        let enabled = try await coordinator.execute(try plan(), volumeID: nil, snapshotEnabled: true)
        let disabled = try await coordinator.execute(try plan(), volumeID: nil, snapshotEnabled: false)

        #expect(enabled.snapshotDate == stamp)
        #expect(enabled.elapsedSeconds != nil)
        #expect(disabled.snapshotDate == nil)
        #expect(disabled.elapsedSeconds != nil)
    }
}

struct LocalizationCatalogTests {
    /// 门禁：目录里每个 zh-Hans 键都必须有非空 en 翻译，且占位符个数一致。
    /// 新增 UI 文案时若漏翻，这里直接红。
    @Test("String Catalog 全键具备 en 翻译且占位符一致")
    func everyKeyHasEnglish() throws {
        let catalogURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/FCPLibraryCleanerAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // 仓库根
            .appendingPathComponent("Sources/FCPLibraryCleanerApp/Localizable.xcstrings")
        let catalog = try JSONDecoder().decode(LocalizationCatalog.self, from: Data(contentsOf: catalogURL))

        #expect(catalog.sourceLanguage == "zh-Hans")
        #expect(catalog.strings.count > 300)

        for (key, entry) in catalog.strings {
            let en = entry.localizations?["en"]?.stringUnit?.value
            #expect(en != nil && !(en ?? "").isEmpty, "缺 en 翻译：\(key)")
            let placeholder = { (s: String) -> Int in
                s.matches(of: /%@/).count + s.matches(of: /%\d+\$@/).count
            }
            #expect(placeholder(key) == placeholder(en ?? ""), "占位符不一致：\(key)")
        }
    }
}

struct LocalizationCatalog: Decodable {
    let sourceLanguage: String
    let strings: [String: Entry]

    struct Entry: Decodable {
        let localizations: [String: Localization]?
    }

    struct Localization: Decodable {
        let stringUnit: StringUnit?
    }

    struct StringUnit: Decodable {
        let value: String
    }
}
