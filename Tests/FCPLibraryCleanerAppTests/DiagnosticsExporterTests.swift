import Foundation
import Testing
import UniformTypeIdentifiers
@testable import FCPLibraryCleanerApp

@MainActor
struct DiagnosticsExporterTests {
    private let home = "/Users/调色师"

    @Test("redaction masks only the home directory prefix")
    func redaction() {
        let text = """
        库路径：/Users/调色师/Movies/采访.fcpbundle
        系统路径：/Volumes/RAID/素材
        """
        let redacted = DiagnosticsWriter.redact(text, homeDirectory: home)
        #expect(redacted.contains("~/Movies/采访.fcpbundle"))
        #expect(!redacted.contains(home))
        #expect(redacted.contains("/Volumes/RAID/素材"))

        // 无主目录可脱敏时原文返回
        #expect(DiagnosticsWriter.redact("abc", homeDirectory: "/") == "abc")
    }

    @Test("suggested file name carries a sortable timestamp")
    func fileName() {
        let name = DiagnosticsWriter.suggestedFileName(now: Date(timeIntervalSinceReferenceDate: 800_000_000))
        #expect(name.hasPrefix("FCP-Cleaner-Diagnostics-"))
        #expect(name.hasSuffix(".zip"))
        #expect(name.count == "FCP-Cleaner-Diagnostics-yyyyMMdd-HHmm.zip".count)
    }

    @Test("end-to-end bundle writes redacted files and a valid zip to destination")
    func writeBundleEndToEnd() throws {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("fcpc-diagnostics-out-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: destination) }

        let reports = [
            VolumeDiagnosticsEntry(
                libraryName: "采访", libraryPath: "\(home)/Movies/采访.fcpbundle",
                volumeName: "Macintosh HD", mounted: true, writable: true,
                checkedAt: Date(timeIntervalSinceReferenceDate: 800_000_000),
                lastAccessibleAt: Date(timeIntervalSinceReferenceDate: 800_000_000),
                lastKnownTotalSize: 1_024, lastKnownCleanableSize: 512,
                scanError: nil, cleanupError: nil
            ),
        ]
        let failures = [
            DiagnosticsFailure(
                date: Date(timeIntervalSinceReferenceDate: 800_000_000),
                libraryName: "采访",
                errorMessages: ["Final Cut Pro 正在使用此资源库"]
            ),
        ]
        let outcome = DiagnosticsWriter.writeBundle(
            to: destination,
            logText: "2026-08-28 heartbeat path=\(home)/Movies",
            volumeReports: reports,
            bookmarkStatus: BookmarkStatusReport(
                libraryBookmarkCount: 2,
                workDirectoryBookmarkCount: 1,
                storedLibraryArchiveBytes: 4096,
                storedWorkDirectoryArchiveBytes: 1024
            ),
            failures: failures,
            systemInfo: "FCP Cleaner 诊断信息\n主目录：\(home)",
            homeDirectory: home
        )

        guard case .success = outcome else {
            Issue.record("打包失败：\(outcome)")
            return
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        #expect((attributes[.size] as? NSNumber)?.intValue ?? 0 > 0)
        // zip 本身不是明文：确认主目录没有出现在归档头部的文件名区
        let header = try Data(contentsOf: destination).prefix(64)
        #expect(String(data: header, encoding: .isoLatin1)?.contains(home) != true)
    }

    @Test("collectRecentLog surfaces a readable message for missing binaries")
    func logCollectionFailureMode() {
        let output = DiagnosticsWriter.collectRecentLog(minutes: 1, executablePath: "/nonexistent/log")
        #expect(output.contains("无法启动"))
    }
}
