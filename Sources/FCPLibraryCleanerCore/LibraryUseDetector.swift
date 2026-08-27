import AppKit
import Foundation

/// Detects whether FCP currently has the given Library open.
///
/// FCP exposes no public per-Library lock API; its open database handles give a
/// reliable process-level signal without blocking unrelated Libraries merely
/// because FCP is running. Every failure mode — spawn error, non-zero exit, or
/// timeout — fails CLOSED (treated as "in use") so an unprobeable system never
/// waves a cleanup through.
public struct LibraryUseDetector: Sendable {
    private let lsofPath: String
    private let timeoutSeconds: Double

    public init() {
        self.init(lsofPath: "/usr/sbin/lsof", timeoutSeconds: 10)
    }

    /// Injectable for deterministic tests.
    public init(lsofPath: String, timeoutSeconds: Double) {
        self.lsofPath = lsofPath
        self.timeoutSeconds = max(0.1, timeoutSeconds)
    }

    public func libraryIsInUse(_ libraryURL: URL) -> Bool {
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.FinalCut")
        guard !applications.isEmpty else { return false }
        let libraryPath = libraryURL.standardizedFileURL.path

        for application in applications {
            if detectInUse(processIdentifier: application.processIdentifier, libraryPath: libraryPath) {
                return true
            }
        }
        return false
    }

    /// Single-process inspection. Internal so tests can drive failure modes
    /// (missing binary, hanging tool) without a live Final Cut Pro instance.
    func detectInUse(processIdentifier: pid_t, libraryPath: String) -> Bool {
        final class LockedBuffer: @unchecked Sendable {
            private let lock = NSLock()
            private var data = Data()
            func append(_ chunk: Data) {
                lock.lock()
                data.append(chunk)
                lock.unlock()
            }
            var current: Data {
                lock.lock()
                defer { lock.unlock() }
                return data
            }
        }

        let process = Process()
        let buffer = LockedBuffer()
        let output = Pipe()
        output.fileHandleForReading.readabilityHandler = { handle in
            buffer.append(handle.availableData)
        }
        process.executableURL = URL(fileURLWithPath: lsofPath)
        process.arguments = ["-a", "-p", String(processIdentifier), "-Fn"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            // 无法启动检查进程 = 状态不可知，宁可阻断本次清理。
            return true
        }

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            // 超时同样按“占用”处理。
            process.terminate()
            output.fileHandleForReading.readabilityHandler = nil
            return true
        }
        output.fileHandleForReading.readabilityHandler = nil
        buffer.append(output.fileHandleForReading.readDataToEndOfFile())

        guard process.terminationStatus == 0,
              let text = String(data: buffer.current, encoding: .utf8) else {
            return true
        }
        return text.split(separator: "\n").contains(where: { line in
            guard line.first == "n" else { return false }
            let path = String(line.dropFirst())
            return path == libraryPath || path.hasPrefix(libraryPath + "/")
        })
    }
}
