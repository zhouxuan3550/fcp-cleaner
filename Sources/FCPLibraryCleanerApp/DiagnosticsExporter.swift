import AppKit
import Foundation
import UniformTypeIdentifiers
import FCPLibraryCleanerCore

// MARK: - 诊断数据模型

struct VolumeDiagnosticsEntry: Codable, Sendable {
    let libraryName: String
    let libraryPath: String
    let volumeName: String
    let mounted: Bool?
    let writable: Bool?
    let checkedAt: Date?
    let lastAccessibleAt: Date?
    let lastKnownTotalSize: Int64?
    let lastKnownCleanableSize: Int64?
    let scanError: String?
    let cleanupError: String?
}

struct BookmarkStatusReport: Codable, Sendable {
    let libraryBookmarkCount: Int
    let workDirectoryBookmarkCount: Int
    let storedLibraryArchiveBytes: Int?
    let storedWorkDirectoryArchiveBytes: Int?
}

struct DiagnosticsFailure: Codable, Sendable {
    let date: Date
    let libraryName: String
    let errorMessages: [String]
}

enum DiagnosticsOutcome: Sendable {
    case success
    case failure(String)
}

// MARK: - 打包器（无副作用纯流程，便于测试）

enum DiagnosticsWriter {
    /// 隐私防线：输出文本一律将用户主目录前缀替换为 `~`。应用自身的 os.log 已在源头做路径哈希脱敏，
    /// 这里是导出侧的第二道防线。
    static func redact(_ text: String, homeDirectory: String) -> String {
        guard !homeDirectory.isEmpty, homeDirectory != "/" else { return text }
        return text.replacingOccurrences(of: homeDirectory, with: "~")
    }

    static func suggestedFileName(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return "FCP-Cleaner-Diagnostics-\(formatter.string(from: now)).zip"
    }

    /// 组装诊断包：写文件 → /usr/bin/zip → 移动到用户选择的位置。全部在调用方提供的后台上下文执行。
    static func writeBundle(
        to destination: URL,
        logText: String,
        volumeReports: [VolumeDiagnosticsEntry],
        bookmarkStatus: BookmarkStatusReport,
        failures: [DiagnosticsFailure],
        systemInfo: String,
        homeDirectory: String = NSHomeDirectory()
    ) -> DiagnosticsOutcome {
        let fileManager = FileManager.default
        let staging = fileManager.temporaryDirectory
            .appendingPathComponent("fcpc-diagnostics-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: staging) }
        do {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)

            try redact(logText, homeDirectory: homeDirectory)
                .data(using: .utf8)
                .map { try $0.write(to: staging.appendingPathComponent("os-log.txt"), options: .atomic) }

            try encode(volumeReports).map {
                try $0.write(to: staging.appendingPathComponent("volume-access.json"), options: .atomic)
            }
            try encode(bookmarkStatus).map {
                try $0.write(to: staging.appendingPathComponent("bookmarks.json"), options: .atomic)
            }
            try encode(failures).map {
                try $0.write(to: staging.appendingPathComponent("recent-failures.json"), options: .atomic)
            }
            try redact(systemInfo, homeDirectory: homeDirectory)
                .data(using: .utf8)
                .map { try $0.write(to: staging.appendingPathComponent("system-info.txt"), options: .atomic) }

            let archive = staging.deletingLastPathComponent()
                .appendingPathComponent("FCP-Cleaner-Diagnostics-\(UUID().uuidString).zip")
            try runZip(sourceDirectory: staging, outputURL: archive)
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: archive, to: destination)
            return .success
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    /// 近 1 小时应用日志。subsystem 与 CleanupEngine/扫描心跳一致；路径脱敏已在打点时内建。
    static func collectRecentLog(minutes: Int = 60, executablePath: String = "/usr/bin/log") -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = [
            "show", "--style", "compact", "--last", "\(minutes)m",
            "--predicate", "subsystem == \"com.fcplibrarycleaner\"",
        ]
        let pipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = pipe
        process.standardError = errorPipe
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = errorPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = String(data: data, encoding: .utf8) ?? ""
            if process.terminationStatus != 0 {
                let message = String(data: stderr, encoding: .utf8) ?? "未知错误"
                return "log show 失败（exit \(process.terminationStatus)）：\(message)"
            }
            return output.isEmpty ? "（近 \(minutes) 分钟无日志）" : output
        } catch {
            return "log show 无法启动：\(error.localizedDescription)"
        }
    }

    static func systemInfo(libraryCount: Int, scanHealth: ScanHealthSummary, homeDirectory: String = NSHomeDirectory()) -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let processInfo = ProcessInfo.processInfo
        let lines = [
            "FCP Cleaner 诊断信息",
            "导出时间：\(Date().formatted(date: .abbreviated, time: .standard))",
            "应用版本：\(version)（Build \(build)）",
            "系统：\(processInfo.operatingSystemVersionString)",
            "架构：\(processInfo.activeProcessorCount) 核 / \(processInfo.physicalMemory.formatted()) 内存",
            "资源库：\(libraryCount) 个（已扫描 \(scanHealth.scanned)，失败 \(scanHealth.failed.count)）",
            "主目录：\(homeDirectory)",
        ]
        return lines.joined(separator: "\n")
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }

    private static func runZip(sourceDirectory: URL, outputURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-qr", outputURL.path, "."]
        process.currentDirectoryURL = sourceDirectory
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "未知错误"
            throw CleanupError.trashFailed(outputURL, "zip 打包失败：\(message)")
        }
    }
}
