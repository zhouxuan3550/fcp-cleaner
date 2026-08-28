import Foundation
import Testing
@testable import FCPLibraryCleanerApp

@MainActor
struct ScheduledCheckTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test("off schedule never becomes due")
    func offIsNeverDue() {
        #expect(ScheduledCheckController.dueDate(frequency: .off, lastRun: nil, now: now) == nil)
        #expect(ScheduledCheckController.dueDate(frequency: .off, lastRun: now, now: now) == nil)
    }

    @Test("first run schedules a full period out instead of firing immediately")
    func firstRunStartsOnePeriodOut() {
        #expect(ScheduledCheckController.dueDate(frequency: .daily, lastRun: nil, now: now) == now.addingTimeInterval(86_400))
        #expect(ScheduledCheckController.dueDate(frequency: .weekly, lastRun: nil, now: now) == now.addingTimeInterval(7 * 86_400))
    }

    @Test("missed periods catch up immediately on the next launch")
    func overdueRunsNow() {
        let lastRun = now.addingTimeInterval(-3 * 86_400)
        #expect(ScheduledCheckController.dueDate(frequency: .daily, lastRun: lastRun, now: now) == now)
    }

    @Test("future deadline is preserved without drift")
    func upcomingRunKeepsSchedule() {
        let lastRun = now.addingTimeInterval(-3600)
        #expect(ScheduledCheckController.dueDate(frequency: .daily, lastRun: lastRun, now: now) == lastRun.addingTimeInterval(86_400))
    }

    @Test("frequency intervals cover a day and a week")
    func intervalMapping() {
        #expect(ScheduledCheckFrequency.daily.interval == TimeInterval(86_400))
        #expect(ScheduledCheckFrequency.weekly.interval == TimeInterval(7 * 86_400))
        #expect(ScheduledCheckFrequency.off.interval == nil)
    }
}
