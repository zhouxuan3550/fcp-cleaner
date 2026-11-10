import Foundation
import Darwin
import AppKit
import Testing
@testable import FCPLibraryCleanerCore

struct LibraryUseDetectorTests {
    @Test("optional live Final Cut Pro inspection recognizes an open library")
    func liveFinalCutInspection() throws {
        guard ProcessInfo.processInfo.environment["FCP_TEST_LIVE_INSPECTION"] == "1" else { return }
        let app = try #require(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.FinalCut").first)
        let command = Process()
        let pipe = Pipe()
        command.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        command.arguments = ["-a", "-p", String(app.processIdentifier), "-Fn"]
        command.standardOutput = pipe
        command.standardError = FileHandle.nullDevice
        try command.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        command.waitUntilExit()
        #expect(command.terminationStatus == 0)
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
        let library = try #require(lines.lazy.compactMap { line -> String? in
            guard line.first == "n" else { return nil }
            let path = String(line.dropFirst())
            guard let suffix = path.range(of: ".fcpbundle/", options: [.caseInsensitive]) else { return nil }
            return String(path[..<path.index(before: suffix.upperBound)])
        }.first)
        let inUse = LibraryUseDetector.inspectProcess(processIdentifier: app.processIdentifier, libraryPath: library)
        #expect(inUse == true)
    }

    @Test("mapped files remain detectable after their file descriptor closes")
    func detectsMappedFile() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let file = root.appendingPathComponent("mapped")
        try Data(repeating: 1, count: 4096).write(to: file)
        let fd = open(file.path, O_RDONLY)
        guard fd >= 0 else { throw CocoaError(.fileReadUnknown) }
        let mapped = mmap(nil, 4096, PROT_READ, MAP_PRIVATE, fd, 0)
        close(fd)
        guard let mapped, mapped != MAP_FAILED else { throw CocoaError(.fileReadUnknown) }
        defer { munmap(mapped, 4096) }
        #expect(LibraryUseDetector.mappedFileMatches(processIdentifier: getpid(), libraryPath: root.path) == true)
        #expect(LibraryUseDetector.inspectProcess(processIdentifier: getpid(), libraryPath: root.path) == true)
    }

    @Test("current working directory is considered in use")
    func detectsWorkingDirectory() {
        #expect(LibraryUseDetector.processDirectoriesMatch(processIdentifier: getpid(), libraryPath: FileManager.default.currentDirectoryPath) == true)
    }

    @Test("uninspectable processes never report a successful negative")
    func unavailableProcessIsUnknown() {
        #expect(LibraryUseDetector.inspectProcess(processIdentifier: 999_999, libraryPath: "/tmp") == nil)
    }

    @Test("a fully inspectable unrelated process can be ruled out without lsof")
    func detectsUnrelatedProcess() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        defer { if process.isRunning { process.terminate() }; process.waitUntilExit() }
        // Process.run can return while dyld is still opening and closing files;
        // wait until the child has finished launching before asserting a stable
        // negative. Production continues to fail closed during that transition.
        let deadline = Date().addingTimeInterval(3)
        var stable = 0
        while Date() < deadline && stable < 3 {
            stable = LibraryUseDetector.inspectProcess(processIdentifier: process.processIdentifier, libraryPath: root.path) == false ? stable + 1 : 0
            if stable < 3 { usleep(20_000) }
        }
        #expect(stable == 3)
        #expect(LibraryUseDetector.inspectProcess(processIdentifier: process.processIdentifier, libraryPath: root.path) == false)
        let detector = LibraryUseDetector(lsofPath: "/nonexistent/lsof", timeoutSeconds: 1)
        #expect(detector.detectInUse(processIdentifier: process.processIdentifier, libraryPath: root.path) == false)
    }

    @Test("descriptor inspection detects an open file in the target library")
    func detectsOpenFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("open-file")
        try Data("test".utf8).write(to: file)
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let actualPath = root.resolvingSymlinksInPath().path
        #expect(LibraryUseDetector.openFileDescriptorMatches(processIdentifier: getpid(), libraryPath: actualPath) == true)
    }

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
