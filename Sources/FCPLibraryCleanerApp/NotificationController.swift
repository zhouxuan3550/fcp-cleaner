import Foundation

import UserNotifications



@MainActor

final class NotificationController {

    static let shared = NotificationController()



    private init() {}



    func requestAuthorizationIfNeeded(enabled: Bool) {

        guard enabled else { return }

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

    }



    func cleanupFinished(freedSize: Int64, libraryCount: Int, errorCount: Int, enabled: Bool) {

        guard enabled else { return }

        let content = UNMutableNotificationContent()

        content.title = errorCount == 0 ? String(localized: "FCP Cleaner 清理完成") : String(localized: "FCP Cleaner 清理结束")

        content.body = String(format: String(localized: "移入废纸篓 %@ · %@ 个资源库"), String(FormatHelpers.bytes(freedSize)), String(libraryCount)) + (errorCount > 0 ? String(format: String(localized: " · %@ 项失败"), String(errorCount)) : "")

        content.sound = .default

        // 每次清理用独立 identifier：通知中心保留逐次结果作为历史是有意行为；

        // 低空间/定时检查才用稳定 identifier 做去重。

        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))

    }



    func lowSpace(volumeName: String, availableSize: Int64, cleanableSize: Int64, enabled: Bool) {

        guard enabled else { return }

        let content = UNMutableNotificationContent()

        content.title = String(format: String(localized: "%@ 空间不足"), String(volumeName))

        content.body = String(format: String(localized: "剩余 %@，FCP Cleaner 可清理 %@"), String(FormatHelpers.bytes(availableSize)), String(FormatHelpers.bytes(cleanableSize)))

        content.sound = .default

        UNUserNotificationCenter.current().add(UNNotificationRequest(

            identifier: "low-space-\(volumeName)",

            content: content,

            trigger: nil

        ))

    }



    /// 定时检查完成通知。只报告结果并请用户自行确认，绝不代为清理。

    func scheduledCheckFinished(cleanableSize: Int64, libraryCount: Int, enabled: Bool) {

        guard enabled else { return }

        let content = UNMutableNotificationContent()

        content.title = String(localized: "FCP Cleaner 定时检查完成")

        content.body = cleanableSize >= LibraryStore.minimumCleanableSize

            ? String(format: String(localized: "当前可清理 %@（%@ 个资源库），请打开应用确认后清理"), String(FormatHelpers.bytes(cleanableSize)), String(libraryCount))

            : String(localized: "未发现足够可清理的空间")

        content.sound = .default

        UNUserNotificationCenter.current().add(UNNotificationRequest(

            identifier: "scheduled-check-finished",

            content: content,

            trigger: nil

        ))

    }

}
