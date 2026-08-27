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
        content.title = errorCount == 0 ? "FCP Cleaner 清理完成" : "FCP Cleaner 清理结束"
        content.body = "释放 \(format(freedSize)) · \(libraryCount) 个资源库" + (errorCount > 0 ? " · \(errorCount) 项失败" : "")
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func lowSpace(volumeName: String, availableSize: Int64, cleanableSize: Int64, enabled: Bool) {
        guard enabled else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(volumeName) 空间不足"
        content.body = "剩余 \(format(availableSize))，FCP Cleaner 可释放 \(format(cleanableSize))"
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: "low-space-\(volumeName)",
            content: content,
            trigger: nil
        ))
    }
}
