import Foundation
import Testing
import FCPLibraryCleanerCore
@testable import FCPLibraryCleanerApp

@MainActor
struct IgnoreAndSnoozeTests {
    private func makeFakeLibrary(at directory: URL, name: String) throws -> URL {
        let bundle = directory.appendingPathComponent("\(name).fcpbundle", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data().write(to: bundle.appendingPathComponent(FCPStructureRules.libraryDatabaseName))
        return bundle
    }

    @Test("snooze marks a record ignored until the deadline; resume clears it")
    func snoozeRoundTrip() {
        let store = LibraryStore.shared
        let record = LibraryRecord(url: URL(fileURLWithPath: "/tmp/fcpc-ignore-snooze/项目.fcpbundle"))
        defer { record.ignoredUntil = nil }

        #expect(!store.isLibraryIgnored(record))
        store.snoozeLibrary(record)
        #expect(store.isLibraryIgnored(record))
        #expect(record.ignoredUntil?.timeIntervalSinceNow ?? 0 > 0 || (record.ignoredUntil ?? Date()) > Date())
        store.resumeLibrary(record)
        #expect(record.ignoredUntil == nil)
        #expect(!store.isLibraryIgnored(record))
    }

    @Test("directory-level ignore covers descendants and resume clears the directory entry")
    func directoryIgnoreRoundTrip() {
        let store = LibraryStore.shared
        let saved = store.ignoredLibraryDirectories
        defer { store.ignoredLibraryDirectories = saved }

        let directory = "/tmp/fcpc-ignore-dir-test"
        store.ignoreDirectory(URL(fileURLWithPath: directory))
        #expect(store.ignoredLibraryDirectories.contains(directory))

        let record = LibraryRecord(url: URL(fileURLWithPath: directory + "/采访.fcpbundle"))
        #expect(store.isLibraryIgnored(record))

        // 显式恢复目录内的库时，目录级忽略一并解除
        store.resumeLibrary(record)
        #expect(!store.ignoredLibraryDirectories.contains(directory))
        #expect(!store.isLibraryIgnored(record))
    }

    @Test("directory ignore gates automatic discovery but not manual add")
    func discoveryGateVersusManualAdd() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fcpc-ignore-discovery-\(UUID().uuidString)", isDirectory: true)
        let ignoredDir = root.appendingPathComponent("归档", isDirectory: true)
        let freeDir = root.appendingPathComponent("进行中", isDirectory: true)
        try FileManager.default.createDirectory(at: ignoredDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: freeDir, withIntermediateDirectories: true)
        let ignoredLibrary = try makeFakeLibrary(at: ignoredDir, name: "旧采访")
        let freeLibrary = try makeFakeLibrary(at: freeDir, name: "新采访")
        defer { try? FileManager.default.removeItem(at: root) }

        let ignoredPaths = [ignoredDir.path]
        let autoFound = LibraryStore.validateCandidates(
            [ignoredLibrary, freeLibrary],
            source: .workDirectory,
            ignoredDirectoryPaths: ignoredPaths
        )
        #expect(autoFound == [freeLibrary.standardizedFileURL])

        let manuallyAdded = LibraryStore.validateCandidates(
            [ignoredLibrary, freeLibrary],
            source: .manualAdd,
            ignoredDirectoryPaths: ignoredPaths
        )
        #expect(Set(manuallyAdded) == Set([ignoredLibrary, freeLibrary].map(\.standardizedFileURL)))
    }

    @Test("ignored libraries leave waiting and skipped lists and appear under the ignored filter")
    func filterMembership() {
        let store = LibraryStore.shared
        let saved = store.ignoredLibraryDirectories
        defer { store.ignoredLibraryDirectories = saved }

        let record = LibraryRecord(url: URL(fileURLWithPath: "/tmp/fcpc-ignore-filter/项目.fcpbundle"))
        store.libraries.append(record)
        store.snoozeLibrary(record)
        defer {
            store.libraries.removeAll { $0.id == record.id }
            record.ignoredUntil = nil
        }

        #expect(!store.waitingLibraries.contains { $0.id == record.id })
        #expect(!store.skippedLibraries.contains { $0.id == record.id })
        #expect(store.ignoredLibraries.contains { $0.id == record.id })
        #expect(store.count(for: .ignored) >= 1)
    }
}
