import Foundation
import FCPLibraryCleanerCore

/// 每库每日一个体积采样点（UserDefaults JSON），驱动详情页"周增长"徽标与列表"增长最快"标记。
/// 采样来自扫描结果，本模块绝不主动触碰文件系统；清理链路不读取本模块。
enum LibrarySizeTrend {
    struct Sample: Codable, Sendable, Equatable {
        /// 当地日历的当日零点，同日重复扫描覆盖该点。
        var day: Date
        var totalAllocatedSize: Int64
        var cleanableSize: Int64
    }

    private static let storageKey = "librarySizeSamplesV1"
    static let maxSamplesPerLibrary = 90
    /// 周增长基线窗口：取 6 天前或更早的最新样本作基线；基线早于 14 天视为过期，不计算趋势。
    static let baselineMinAge: TimeInterval = 6 * 86_400
    static let baselineMaxAge: TimeInterval = 14 * 86_400

    /// 与扫描缓存一致的 FNV 路径哈希，避免在 UserDefaults 明文铺路径。
    static func key(for libraryURL: URL) -> String {
        let hash = libraryURL.standardizedFileURL.path.utf8.reduce(UInt64(1_469_598_103_934_665_603)) { partial, byte in
            (partial ^ UInt64(byte)) &* 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    static func samples(for libraryURL: URL, defaults: UserDefaults = .standard) -> [Sample] {
        index(defaults)[key(for: libraryURL)] ?? []
    }

    static func record(
        libraryURL: URL,
        totalAllocatedSize: Int64,
        cleanableSize: Int64,
        now: Date = Date(),
        defaults: UserDefaults = .standard
    ) {
        var all = index(defaults)
        let key = key(for: libraryURL)
        var list = all[key] ?? []
        let day = Calendar.current.startOfDay(for: now)
        let sample = Sample(day: day, totalAllocatedSize: totalAllocatedSize, cleanableSize: cleanableSize)
        if let lastIndex = list.indices.last, list[lastIndex].day == day {
            list[lastIndex] = sample
        } else {
            list.append(sample)
        }
        if list.count > maxSamplesPerLibrary {
            list.removeFirst(list.count - maxSamplesPerLibrary)
        }
        all[key] = list
        if let data = try? JSONEncoder().encode(all) {
            defaults.set(data, forKey: storageKey)
        }
    }

    /// 周增长：最新样本 − 基线样本（总分配体积）。样本不足或基线过期返回 nil。
    static func weeklyGrowth(samples: [Sample], now: Date = Date()) -> Int64? {
        guard let current = samples.max(by: { $0.day < $1.day }) else { return nil }
        let cutoff = now.addingTimeInterval(-baselineMinAge)
        let staleLimit = Calendar.current.startOfDay(for: now.addingTimeInterval(-baselineMaxAge))
        guard let baseline = samples.filter({ $0.day <= cutoff }).max(by: { $0.day < $1.day }),
              baseline.day >= staleLimit else { return nil }
        return current.totalAllocatedSize - baseline.totalAllocatedSize
    }

    private static func index(_ defaults: UserDefaults) -> [String: [Sample]] {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([String: [Sample]].self, from: data) else {
            return [:]
        }
        return decoded
    }
}
