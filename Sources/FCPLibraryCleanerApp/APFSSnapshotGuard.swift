import Foundation
import FCPLibraryCleanerCore
import os

/// 清理前的 APFS 本地快照保护（设置可关，默认开）。
///
/// 实测约束（2026-11-15，macOS 27.2）：`tmutil localsnapshot` 的卷参数会被
/// 忽略，快照恒落在启动卷组——因此只有内置卷上的资源库受益；外置卷清理
/// 仍以废纸篓为唯一回滚保障。快照是 purgeable 的，系统可随时自动回收；
/// 创建失败绝不阻塞清理——它只是废纸篓之外的附加保险层。
enum APFSSnapshotGuard {
    private static let logger = Logger(subsystem: "com.fcplibrarycleaner", category: "snapshot")

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        return formatter
    }()

    /// 对计划涉及的库创建本地快照；返回快照时间，失败/外置卷返回 nil。
    /// tmutil 进程在后台线程运行，不占主线程。
    static func prepareSnapshot(for plan: CleanupPlan, tmutilPath: String = "/usr/bin/tmutil") async -> Date? {
        guard isOnBootDataVolume(plan.libraryURL) else { return nil }
        return await Task.detached(priority: .userInitiated) {
            run(tmutilPath: tmutilPath)
        }.value
    }

    /// 内置卷判定：实测 /tmp、/var/folders、/Users 的 volumeURL 均为 "/"。
    static func isOnBootDataVolume(_ url: URL, fileManager: FileManager = .default) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.volumeURLKey]),
              let volumeURL = values.allValues[.volumeURLKey] as? URL else { return false }
        return volumeURL.path == "/"
    }

    private static func run(tmutilPath: String) -> Date? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmutilPath)
        process.arguments = ["localsnapshot"]
        let pipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = pipe
        process.standardError = errorPipe
        do {
            try process.run()
            // stderr 与 stdout 并行排空：串行读会让管道写满互锁
            // （与 DiagnosticsExporter 同一坑，同一解法）。
            let stderrData = DispatchQueue.global(qos: .utility).sync {
                errorPipe.fileHandleForReading.readDataToEndOfFile()
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let message = String(data: stderrData, encoding: .utf8) ?? "退出码 \(process.terminationStatus)"
                logger.error("本地快照创建失败: \(message, privacy: .public)")
                return nil
            }
            let output = String(data: data, encoding: .utf8) ?? ""
            guard let marker = output.range(of: "Created local snapshot with date: "),
                  let date = dateFormatter.date(from: String(output[marker.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)) else {
                logger.error("本地快照输出无法解析")
                return nil
            }
            logger.info("已创建清理前本地快照")
            return date
        } catch {
            logger.error("tmutil 无法启动: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
