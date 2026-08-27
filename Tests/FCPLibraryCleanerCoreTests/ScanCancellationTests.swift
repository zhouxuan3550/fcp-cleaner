import Foundation
import Testing
@testable import FCPLibraryCleanerCore

/// Cancellation must reach the directory walker promptly — the UI's cancel
/// button and queue eviction both depend on a bounded stop, not merely on
/// flags flipping. Bounded by wall-clock time rather than trust.
struct ScanCancellationTests {
    @Test("cancelling mid-walk stops the scan well within an interactive bound")
    func cancelStopsScanPromptly() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("fcp-cancel-\(UUID().uuidString).fcpbundle")
        let event = root.appendingPathComponent("Event One")
        try FileManager.default.createDirectory(
            at: event.appendingPathComponent("Render Files"),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        // ~4k 个小文件：足够让遍历走一阵子并触发多次进度回调。
        for index in 0..<4_096 {
            let url = event.appendingPathComponent("Render Files/f\(index).dat")
            try Data("x".utf8).write(to: url)
        }
        try Data("library database".utf8).write(to: root.appendingPathComponent("CurrentVersion.flexolibrary"))
        try Data("event database".utf8).write(to: event.appendingPathComponent("CurrentVersion.fcpevent"))

        let control = ScanControl()
        final class OnceFlag: @unchecked Sendable {
            private let lock = NSLock()
            private var fired = false
            var value: Bool {
                lock.lock(); defer { lock.unlock() }
                return fired
            }
            func fire() {
                lock.lock(); fired = true; lock.unlock()
            }
        }
        let firstProgressObserved = OnceFlag()

        // 独立计时与取消触发：收到第一批进度后立即取消，
        // 断言扫描在 3 秒内以 CancellationError 收场。
        let started = ContinuousClock.now
        do {
            _ = try await LibraryScanner().scan(libraryURL: root, control: control) { _ in
                guard !firstProgressObserved.value else { return }
                firstProgressObserved.fire()
                control.cancel()
            }
            Issue.record("Expected CancellationError after cancelling")
        } catch is CancellationError {
            #expect(firstProgressObserved.value)
            let elapsed = Duration.seconds(3) > (ContinuousClock.now - started)
            #expect(elapsed)
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }
}
