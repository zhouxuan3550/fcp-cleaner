import AppKit
import Foundation

public struct LibraryUseDetector: Sendable {
    public init() {}

    /// FCP has no public per-Library lock API. Its open database handles provide a reliable
    /// process-level signal without blocking unrelated Libraries merely because FCP is running.
    public func libraryIsInUse(_ libraryURL: URL) -> Bool {
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.FinalCut")
        guard !applications.isEmpty else { return false }
        let libraryPath = libraryURL.standardizedFileURL.path

        for application in applications {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
            process.arguments = ["-a", "-p", String(application.processIdentifier), "-Fn"]
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0,
                      let text = String(data: data, encoding: .utf8) else {
                    return true
                }
                if text.split(separator: "\n").contains(where: { line in
                    guard line.first == "n" else { return false }
                    let path = String(line.dropFirst())
                    return path == libraryPath || path.hasPrefix(libraryPath + "/")
                }) {
                    return true
                }
            } catch {
                // If process inspection is unavailable, fail closed rather than risking an open Library.
                return true
            }
        }
        return false
    }
}
