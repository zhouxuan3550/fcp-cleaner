import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers
import FCPLibraryCleanerCore

struct CleanupHistoryFile: Codable, Hashable, Sendable {
    let originalURL: URL
    let trashURL: URL
}

private struct RestoreOutcome: Sendable {
    let restored: Set<CleanupHistoryFile>
    let failures: Int
    let libraryInUse: Bool
}

enum HistoryExportFormat: String, CaseIterable, Identifiable {
    case csv, json
    var id: String { rawValue }
    var fileExtension: String { rawValue }
}

struct CleanupHistoryEntry: Codable, Identifiable, Sendable {
    let id: UUID
    let date: Date
    let libraryName: String
    let libraryURL: URL
    let freedSize: Int64
    let itemCount: Int
    let categories: [CacheCategory]
    let errorMessages: [String]
    var trashedItems: [CleanupHistoryFile]
}

@Observable @MainActor
final class CleanupHistoryStore {
    private(set) var entries: [CleanupHistoryEntry] = []
    @ObservationIgnored private let storageURL: URL
    /// 历史文件可达数百 KB（200 条 × 每条完整废纸篓路径清单）；
    /// 快照按调用顺序入队，串行写保证末次落盘即最新状态。
    private static let persistQueue = DispatchQueue(label: "com.fcpcleaner.cleanup-history", qos: .utility)
    private static let persistEncoder = JSONEncoder()

    init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.fcpcleaner.app", isDirectory: true)
        storageURL = directory.appendingPathComponent("CleanupHistory.json")
        if let data = try? Data(contentsOf: storageURL),
           let decoded = try? JSONDecoder().decode([CleanupHistoryEntry].self, from: data) {
            entries = decoded.sorted { $0.date > $1.date }
        }
    }

    func append(
        libraryName: String,
        libraryURL: URL,
        plan: CleanupPlan,
        result: CleanupResult
    ) {
        let entry = CleanupHistoryEntry(
            id: UUID(),
            date: Date(),
            libraryName: libraryName,
            libraryURL: libraryURL,
            freedSize: result.freedAllocatedSize,
            itemCount: result.movedToTrash.count,
            categories: Array(Set(plan.entries.map(\.item.category))).sorted { $0.rawValue < $1.rawValue },
            errorMessages: result.errors.map(\.localizedDescription),
            trashedItems: result.trashedItems.map {
                CleanupHistoryFile(originalURL: $0.originalURL, trashURL: $0.trashURL)
            }
        )
        entries.insert(entry, at: 0)
        if entries.count > 200 { entries.removeLast(entries.count - 200) }
        persist()
    }

    func appendFailure(libraryName: String, libraryURL: URL, plan: CleanupPlan, error: Error) {
        let entry = CleanupHistoryEntry(
            id: UUID(),
            date: Date(),
            libraryName: libraryName,
            libraryURL: libraryURL,
            freedSize: 0,
            itemCount: 0,
            categories: Array(Set(plan.entries.map(\.item.category))).sorted { $0.rawValue < $1.rawValue },
            errorMessages: [error.localizedDescription],
            trashedItems: []
        )
        entries.insert(entry, at: 0)
        persist()
    }

    func showInTrash(_ entry: CleanupHistoryEntry) {
        let existing = entry.trashedItems.map(\.trashURL).filter { FileManager.default.fileExists(atPath: $0.path) }
        if !existing.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(existing)
        } else if let trash = FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first {
            NSWorkspace.shared.open(trash)
        }
    }

    /// lsof 探测（FCP 运行时可达 10 秒超时）与逐项搬移全部后台执行，
    /// 主线程只在收尾时更新内存列表。
    func restore(_ entry: CleanupHistoryEntry) async -> String {
        let libraryURL = entry.libraryURL
        let trashedItems = entry.trashedItems
        let outcome = await Task.detached(priority: .userInitiated) {
            guard !LibraryUseDetector().libraryIsInUse(libraryURL) else {
                return RestoreOutcome(restored: [], failures: 0, libraryInUse: true)
            }
            let fileManager = FileManager.default
            var restored = Set<CleanupHistoryFile>()
            var failures = 0
            for item in trashedItems {
                guard fileManager.fileExists(atPath: item.trashURL.path),
                      !fileManager.fileExists(atPath: item.originalURL.path),
                      fileManager.isWritableFile(atPath: item.originalURL.deletingLastPathComponent().path) else {
                    failures += 1
                    continue
                }
                do {
                    try fileManager.moveItem(at: item.trashURL, to: item.originalURL)
                    restored.insert(item)
                } catch {
                    failures += 1
                }
            }
            return RestoreOutcome(restored: restored, failures: failures, libraryInUse: false)
        }.value

        guard !outcome.libraryInUse else {
            return "Final Cut Pro 正在使用此资源库"
        }
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index].trashedItems.removeAll { outcome.restored.contains($0) }
            persist()
        }
        if outcome.restored.isEmpty { return outcome.failures > 0 ? "没有可恢复的项目" : "项目已不在废纸篓" }
        return outcome.failures == 0 ? "已恢复 \(outcome.restored.count) 项" : "已恢复 \(outcome.restored.count) 项，\(outcome.failures) 项失败"
    }

    func exportData(as format: HistoryExportFormat) -> Data {
        switch format {
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return (try? encoder.encode(entries)) ?? Data()
        case .csv:
            var csv = "Date,Library,Freed Size,Items,Categories,Errors\n"
            let formatter = ISO8601DateFormatter()
            for entry in entries {
                let date = formatter.string(from: entry.date)
                let library = escapeCSV(entry.libraryName)
                let size = FormatHelpers.bytes(entry.freedSize)
                let items = "\(entry.itemCount)"
                let categories = entry.categories.map(\.chineseName).joined(separator: "; ")
                let errors = entry.errorMessages.joined(separator: "; ")
                csv += "\(date),\(library),\(escapeCSV(size)),\(items),\(escapeCSV(categories)),\(escapeCSV(errors))\n"
            }
            return csv.data(using: .utf8) ?? Data()
        }
    }

    /// 诊断包用：最近带错误信息的记录（新 → 旧）。
    func recentFailures(limit: Int = 20) -> [DiagnosticsFailure] {
        entries
            .filter { !$0.errorMessages.isEmpty }
            .prefix(limit)
            .map { DiagnosticsFailure(date: $0.date, libraryName: $0.libraryName, errorMessages: $0.errorMessages) }
    }

    @discardableResult
    func presentExportPanel(as format: HistoryExportFormat) -> Bool {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "FCP-Cleaner-History.\(format.fileExtension)"
        panel.allowedContentTypes = [format == .csv
            ? UTType.commaSeparatedText
            : UTType.json]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        let data = exportData(as: format)
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private func escapeCSV(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\n") {
            return "\"\(field.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return field
    }

    func clear() {
        entries.removeAll()
        persist()
    }

    private func persist() {
        let snapshot = entries
        let url = storageURL
        Self.persistQueue.async {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Self.persistEncoder.encode(snapshot).write(to: url, options: .atomic)
            } catch {
                // History persistence must never interfere with cleanup.
            }
        }
    }
}
