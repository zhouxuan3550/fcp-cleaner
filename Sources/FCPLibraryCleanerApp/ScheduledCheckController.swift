import Foundation

/// 定时检查频率。检查 = 自动发现 + 增量扫描 + 完成通知；
/// 产品红线：定时路径绝不触发任何清理操作，清理永远需要用户确认。
enum ScheduledCheckFrequency: String, CaseIterable, Identifiable {
    case off
    case daily
    case weekly

    var id: Self { self }

    var title: String {
        switch self {
        case .off: "关闭"
        case .daily: "每天"
        case .weekly: "每周"
        }
    }

    var interval: TimeInterval? {
        switch self {
        case .off: nil
        case .daily: 86_400
        case .weekly: 7 * 86_400
        }
    }
}

/// 周期触发定时检查的后台循环。
/// 错过周期（应用未运行）时下次启动立即补跑一轮；清理进行中则退避重试，不与清理抢磁盘 I/O。
@MainActor
final class ScheduledCheckController {
    static let frequencyStorageKey = "scheduledCheckFrequency"
    static let lastRunStorageKey = "scheduledCheckLastRun"
    /// 清理进行中被跳过时的重试等待。
    static let retryDelay: TimeInterval = 300

    private weak var store: LibraryStore?
    private let defaults: UserDefaults
    private var task: Task<Void, Never>?

    init(store: LibraryStore, defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
    }

    /// 纯函数：下次应执行时刻。从未跑过（lastRun 为 nil）时首个周期从现在起算，
    /// 避免每次启动都与启动扫描重复劳动。
    nonisolated static func dueDate(
        frequency: ScheduledCheckFrequency,
        lastRun: Date?,
        now: Date
    ) -> Date? {
        guard let interval = frequency.interval else { return nil }
        guard let lastRun else { return now.addingTimeInterval(interval) }
        let due = lastRun.addingTimeInterval(interval)
        return due <= now ? now : due
    }

    func restart() {
        task?.cancel()
        task = nil
        guard let store, store.scheduledCheckFrequency != .off else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                guard let delay = self.waitInterval() else { return }
                if delay > 0 {
                    try? await Task.sleep(for: .seconds(delay))
                }
                guard !Task.isCancelled else { return }
                let ran = await self.runDueCheck()
                if !ran {
                    try? await Task.sleep(for: .seconds(Self.retryDelay))
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func waitInterval() -> TimeInterval? {
        guard let store else { return nil }
        guard let due = Self.dueDate(
            frequency: store.scheduledCheckFrequency,
            lastRun: defaults.object(forKey: Self.lastRunStorageKey) as? Date,
            now: Date()
        ) else { return nil }
        return max(0, due.timeIntervalSinceNow)
    }

    private func runDueCheck() async -> Bool {
        guard let store else { return false }
        guard !store.isPreflighting, !store.isCleaning, !store.isBatchCleaning else { return false }
        await store.runScheduledCheck()
        defaults.set(Date(), forKey: Self.lastRunStorageKey)
        return true
    }
}
