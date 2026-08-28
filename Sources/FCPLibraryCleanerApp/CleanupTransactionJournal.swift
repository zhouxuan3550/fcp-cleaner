import Foundation
import FCPLibraryCleanerCore

/// 一次已确认待执行的清理事务（单库一个计划，批量为多个）。
/// 在用户确认后、执行前落盘；执行结果写入历史后即清除。
/// 若应用在执行中途崩溃/断电，日志会保留下来，供下次启动重建待清计划（历史页入口）。
struct CleanupTransaction: Codable, Sendable {
    let startedAt: Date
    let plans: [CleanupPlan]
}

@MainActor
final class CleanupTransactionJournal {
    private let storageURL: URL

    /// `directory` 供测试注入临时目录；生产环境用 Application Support。
    init(directory: URL? = nil) {
        let base = directory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("com.fcpcleaner.app", isDirectory: true)
        storageURL = base.appendingPathComponent("CleanupTransaction.json")
    }

    func load() -> CleanupTransaction? {
        guard let data = try? Data(contentsOf: storageURL),
              let transaction = try? JSONDecoder().decode(CleanupTransaction.self, from: data) else {
            return nil
        }
        return transaction
    }

    func save(_ transaction: CleanupTransaction) {
        do {
            try FileManager.default.createDirectory(
                at: storageURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(transaction).write(to: storageURL, options: .atomic)
        } catch {
            // 日志写失败绝不能阻止清理执行；最坏情况是中断后无法自动重建。
        }
    }

    func clear() {
        try? FileManager.default.removeItem(at: storageURL)
    }
}

/// 历史页展示用的中断事务摘要，携带重建出的待清计划。
struct InterruptedCleanupSummary: Identifiable {
    let id = UUID()
    let startedAt: Date
    let libraryName: String
    let libraryURL: URL
    let plan: CleanupPlan

    var pendingCount: Int { plan.entries.count }
    var pendingSize: Int64 { plan.spaceToFree }
}
