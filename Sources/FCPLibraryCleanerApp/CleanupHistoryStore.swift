import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers
import FCPLibraryCleanerCore

struct CleanupHistoryFile: Codable, Hashable, Sendable {
    let originalURL: URL
    let trashURL: URL
    let snapshot: TrashItemSnapshot?

    init(originalURL: URL, trashURL: URL, snapshot: TrashItemSnapshot? = nil) {
        self.originalURL = originalURL
        self.trashURL = trashURL
        self.snapshot = snapshot
    }
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
    var availableSpaceChange: Int64? = nil
}

@Observable @MainActor
final class CleanupHistoryStore {
    private(set) var entries: [CleanupHistoryEntry] = []
    private(set) var isPurging = false
    private(set) var isRestoring = false
    var isBusy: Bool { isPurging || isRestoring }
    @ObservationIgnored private let storageURL: URL
    /// 历史文件可达数百 KB（200 条 × 每条完整废纸篓路径清单）；
    /// 快照按调用顺序入队，串行写保证末次落盘即最新状态。
    private static let persistQueue = DispatchQueue(label: "com.fcpcleaner.cleanup-history", qos: .utility)

    init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.fcpcleaner.app", isDirectory: true)
        storageURL = directory.appendingPathComponent("CleanupHistory.json")
        if let data = try? Data(contentsOf: storageURL),
           let decoded = try? JSONDecoder().decode([CleanupHistoryEntry].self, from: data) {
            entries = decoded.sorted { $0.date > $1.date }
        }
        recoverPendingPurge()
    }

    func recoverPendingPurge() {
        guard !isBusy else { return }
        guard let lock = TrashPurgeLock.acquire(for: TrashPurgeJournal.defaultURL) else { return }
        defer { withExtendedLifetime(lock) { } }
        if let pending = TrashPurgeJournal.recover(at: TrashPurgeJournal.defaultURL),
           let index = entries.firstIndex(where: { $0.trashedItems.contains(pending.item) }) {
            entries[index].trashedItems = entries[index].trashedItems.map { item in
                item == pending.item ? CleanupHistoryFile(originalURL: item.originalURL, trashURL: pending.stagedURL) : item
            }
            if persistImmediately() { TrashPurgeJournal.clear(at: TrashPurgeJournal.defaultURL) }
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
                CleanupHistoryFile(originalURL: $0.originalURL, trashURL: $0.trashURL, snapshot: $0.snapshot)
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

    /// Called only after explicit confirmation in the history view.
    func purge(_ entryID: UUID) async -> String {
        guard !isBusy else { return "正在处理其他项目" }
        guard let entry = entries.first(where: { $0.id == entryID }) else { return "清理记录已不存在" }
        guard let lock = TrashPurgeLock.acquire(for: TrashPurgeJournal.defaultURL) else { return "其他窗口正在处理清理记录" }
        defer { withExtendedLifetime(lock) { } }
        isPurging = true
        defer { isPurging = false }
        let items = entry.trashedItems
        let outcome = await Task.detached(priority: .userInitiated) {
            TrashPurgeService.purge(items)
        }.value
        if let index = entries.firstIndex(where: { $0.id == entryID }) {
            entries[index].trashedItems.removeAll { outcome.removed.contains($0) }
            entries[index].trashedItems = entries[index].trashedItems.map { item in
                guard let newURL = outcome.relocated[item] else { return item }
                // The staged item may have changed or only partially deleted.
                return CleanupHistoryFile(originalURL: item.originalURL, trashURL: newURL)
            }
            if let delta = outcome.availableSpaceChange {
                entries[index].availableSpaceChange = (entries[index].availableSpaceChange ?? 0) + delta
            }
            if outcome.relocated.isEmpty {
                persist()
            } else if persistImmediately() {
                TrashPurgeJournal.clear(at: TrashPurgeJournal.defaultURL)
            }
        }
        if outcome.removed.isEmpty { return "没有可清空的项目；项目可能已变化或缺少校验信息" }
        if outcome.failedCount > 0 { return "已清空 \(outcome.removed.count) 项，\(outcome.failedCount) 项未清空" }
        return "已清空 \(outcome.removed.count) 项"
    }

    /// lsof 探测（FCP 运行时可达 10 秒超时）与逐项搬移全部后台执行，
    /// 主线程只在收尾时更新内存列表。
    func restore(_ entry: CleanupHistoryEntry) async -> String {
        guard !isBusy else { return "正在处理其他项目" }
        isRestoring = true
        defer { isRestoring = false }
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
            var csv = "Date,Library,Moved to Trash,Available Space Change (bytes),Items,Categories,Errors\n"
            let formatter = ISO8601DateFormatter()
            for entry in entries {
                let date = formatter.string(from: entry.date)
                let library = escapeCSV(entry.libraryName)
                let size = FormatHelpers.bytes(entry.freedSize)
                let items = "\(entry.itemCount)"
                let spaceChange = entry.availableSpaceChange.map(String.init) ?? ""
                let categories = entry.categories.map(\.chineseName).joined(separator: "; ")
                let errors = entry.errorMessages.joined(separator: "; ")
                csv += "\(date),\(library),\(escapeCSV(size)),\(spaceChange),\(items),\(escapeCSV(categories)),\(escapeCSV(errors))\n"
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
        guard !isBusy else { return }
        entries.removeAll()
        persist()
    }

    private func persist() {
        let snapshot = entries
        let url = storageURL
        Self.persistQueue.async {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
            } catch {
                // History persistence must never interfere with cleanup.
            }
        }
    }

    private func persistImmediately() -> Bool {
        let snapshot = entries
        let url = storageURL
        return Self.persistQueue.sync {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
                return true
            } catch { return false }
        }
    }
}
