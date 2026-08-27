import Foundation
import Testing
@testable import FCPLibraryCleanerCore

struct LibraryUseDetectorTests {
    @Test("missing lsof binary fails closed as in-use")
    func missingBinaryFailsClosed() {
        let detector = LibraryUseDetector(lsofPath: "/nonexistent/lsof", timeoutSeconds: 1)
        let started = Date()

        let inUse = detector.detectInUse(processIdentifier: 999_999, libraryPath: "/tmp/any.fcpbundle")

        #expect(inUse)
        #expect(Date().timeIntervalSince(started) < 3)
    }

    @Test("a hanging inspection tool times out and fails closed")
    func hangingToolTimesOutFailsClosed() throws {
        let script = FileManager.default.temporaryDirectory
            .appendingPathComponent("fcp-fake-lsof-\(UUID().uuidString).sh")
        try Data("#!/bin/sh\nsleep 30\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        defer { try? FileManager.default.removeItem(at: script) }

        let detector = LibraryUseDetector(lsofPath: script.path, timeoutSeconds: 0.2)
        let started = Date()

        let inUse = detector.detectInUse(processIdentifier: 999_999, libraryPath: "/tmp/any.fcpbundle")

        #expect(inUse)
        #expect(Date().timeIntervalSince(started) < 5, "Timeout must return promptly instead of blocking on the tool")
    }

    @Test("a tool that exits successfully with no matching handle reports not-in-use")
    func cleanExitWithoutMatchReportsFree() throws {
        // /usr/bin/true exits 0 immediately without printing any "n<path>" line.
        let detector = LibraryUseDetector(lsofPath: "/usr/bin/true", timeoutSeconds: 5)

        let inUse = detector.detectInUse(processIdentifier: 999_999, libraryPath: "/tmp/any.fcpbundle")

        #expect(inUse == false)
    }
}
