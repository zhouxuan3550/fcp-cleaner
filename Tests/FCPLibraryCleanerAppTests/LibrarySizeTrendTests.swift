import Foundation
import Testing
import FCPLibraryCleanerCore
@testable import FCPLibraryCleanerApp

@MainActor
struct LibrarySizeTrendTests {
    private let defaults: UserDefaults
    private let suiteName = "fcpc-size-trend-tests-\(UUID().uuidString)"

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
    }

    private func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test("same-day scans overwrite the single daily sample")
    func sameDayDeduplicates() {
        defer { cleanUp() }
        let url = URL(fileURLWithPath: "/tmp/fcpc-trend/项目.fcpbundle")
        let morning = date(2026, 8, 28, 9)
        let evening = date(2026, 8, 28, 21)

        LibrarySizeTrend.record(libraryURL: url, totalAllocatedSize: 100, cleanableSize: 40, now: morning, defaults: defaults)
        LibrarySizeTrend.record(libraryURL: url, totalAllocatedSize: 150, cleanableSize: 60, now: evening, defaults: defaults)

        let samples = LibrarySizeTrend.samples(for: url, defaults: defaults)
        #expect(samples.count == 1)
        #expect(samples.first?.totalAllocatedSize == 150)
    }

    @Test("distinct days append and history is capped at 90 points")
    func appendsAndCapsHistory() {
        defer { cleanUp() }
        let url = URL(fileURLWithPath: "/tmp/fcpc-trend/增长.fcpbundle")
        for offset in 0..<120 {
            LibrarySizeTrend.record(
                libraryURL: url,
                totalAllocatedSize: Int64(offset),
                cleanableSize: 0,
                now: date(2026, 8, 28, 12).addingTimeInterval(Double(-offset) * 86_400),
                defaults: defaults
            )
        }
        let samples = LibrarySizeTrend.samples(for: url, defaults: defaults)
        #expect(samples.count == LibrarySizeTrend.maxSamplesPerLibrary)
        #expect(samples.first?.totalAllocatedSize == 30) // 裁剪掉最旧的 30 个点后，队首是 30 天前
        #expect(samples.last?.totalAllocatedSize == 119) // 队尾是最早写入的 119 天前样本
    }

    @Test("weekly growth uses a 6-to-14-day-old baseline and rejects stale ones")
    func weeklyGrowthWindow() {
        defer { cleanUp() }
        let now = date(2026, 8, 28, 12)

        // 一周前有基线：增长 = 300 − 200
        let week = [
            Sample(day: date(2026, 8, 19), totalAllocatedSize: 200, cleanableSize: 50),
            Sample(day: date(2026, 8, 27), totalAllocatedSize: 300, cleanableSize: 50),
        ]
        #expect(LibrarySizeTrend.weeklyGrowth(samples: week, now: now) == 100)

        // 基线早于 14 天：视为过期
        let stale = [
            Sample(day: date(2026, 8, 1), totalAllocatedSize: 200, cleanableSize: 50),
            Sample(day: date(2026, 8, 27), totalAllocatedSize: 300, cleanableSize: 50),
        ]
        #expect(LibrarySizeTrend.weeklyGrowth(samples: stale, now: now) == nil)

        // 基线不足 6 天：窗口未开启
        let tooFresh = [
            Sample(day: date(2026, 8, 26), totalAllocatedSize: 200, cleanableSize: 50),
            Sample(day: date(2026, 8, 27), totalAllocatedSize: 300, cleanableSize: 50),
        ]
        #expect(LibrarySizeTrend.weeklyGrowth(samples: tooFresh, now: now) == nil)

        // 样本不足
        #expect(LibrarySizeTrend.weeklyGrowth(samples: [], now: now) == nil)
        #expect(LibrarySizeTrend.weeklyGrowth(samples: [Sample(day: date(2026, 8, 27), totalAllocatedSize: 1, cleanableSize: 0)], now: now) == nil)
    }

    @Test("different libraries keep independent sample series")
    func independentSeries() {
        defer { cleanUp() }
        let a = URL(fileURLWithPath: "/tmp/fcpc-trend/A.fcpbundle")
        let b = URL(fileURLWithPath: "/tmp/fcpc-trend/B.fcpbundle")
        LibrarySizeTrend.record(libraryURL: a, totalAllocatedSize: 10, cleanableSize: 0, now: date(2026, 8, 28), defaults: defaults)
        LibrarySizeTrend.record(libraryURL: b, totalAllocatedSize: 999, cleanableSize: 0, now: date(2026, 8, 28), defaults: defaults)
        #expect(LibrarySizeTrend.samples(for: a, defaults: defaults).first?.totalAllocatedSize == 10)
        #expect(LibrarySizeTrend.samples(for: b, defaults: defaults).first?.totalAllocatedSize == 999)
    }

    @Test("batch growth calculation returns independent URL-keyed results")
    func batchGrowth() {
        defer { cleanUp() }
        let now = date(2026, 8, 28, 12)
        let a = URL(fileURLWithPath: "/tmp/fcpc-trend/A.fcpbundle")
        let b = URL(fileURLWithPath: "/tmp/fcpc-trend/B.fcpbundle")
        for (url, oldSize, newSize) in [(a, 100, 180), (b, 500, 450)] {
            LibrarySizeTrend.record(libraryURL: url, totalAllocatedSize: Int64(oldSize), cleanableSize: 0, now: date(2026, 8, 20), defaults: defaults)
            LibrarySizeTrend.record(libraryURL: url, totalAllocatedSize: Int64(newSize), cleanableSize: 0, now: date(2026, 8, 28), defaults: defaults)
        }
        let result = LibrarySizeTrend.weeklyGrowthByLibrary([a, b], now: now, defaults: defaults)
        #expect(result[a.standardizedFileURL] == 80)
        #expect(result[b.standardizedFileURL] == -50)
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }
}

private typealias Sample = LibrarySizeTrend.Sample
