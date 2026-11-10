import Foundation
import Testing
@testable import FCPLibraryCleanerApp

struct OrphanCacheDiscoveryTests {
    @Test("recognized folders are grouped and known cache references are excluded")
    func groupingAndReferences() async throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let cache = work.appendingPathComponent("cache", isDirectory: true)
        let render = cache.appendingPathComponent("Event/Render Files", isDirectory: true)
        let analysis = cache.appendingPathComponent("Event/Analysis Files", isDirectory: true)
        try FileManager.default.createDirectory(at: render, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: analysis, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        try Data(repeating: 42, count: 8192).write(to: render.appendingPathComponent("frame"))
        var discovery = OrphanCacheDiscovery()
        discovery.observe(render, under: work)
        discovery.observe(analysis, under: work)
        discovery.observe(work.appendingPathComponent("unrelated"), under: work)
        let possible = discovery.candidates(referencedRoots: [])
        #expect(possible.count == 1)
        #expect(possible.first?.root == cache)
        let measured = await OrphanCacheDiscovery.measure(try #require(possible.first))
        #expect(measured.allocatedBytes ?? 0 > 0)
        #expect(discovery.candidates(referencedRoots: [cache]).isEmpty)
        #expect(discovery.candidates(referencedRoots: [cache.appendingPathComponent("Event")]).isEmpty)
        #expect(discovery.candidates(referencedRoots: [URL(fileURLWithPath: "/")]).isEmpty)
        #expect(FileManager.default.fileExists(atPath: render.appendingPathComponent("frame").path))
    }

    @Test("folders outside the chosen work directory are not reported")
    func respectsWorkRoot() {
        let root = URL(fileURLWithPath: "/tmp/work", isDirectory: true)
        var discovery = OrphanCacheDiscovery()
        discovery.observe(URL(fileURLWithPath: "/tmp/work-other/cache/Event/Render Files"), under: root)
        #expect(discovery.candidates(referencedRoots: []).isEmpty)
    }

    @Test("work directory discovery finds libraries and cache patterns in one pass")
    func discoversInOnePass() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let library = root.appendingPathComponent("Project.fcpbundle", isDirectory: true)
        let render = root.appendingPathComponent("Cache/Event/Render Files", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: render, withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("not-a-library.fcpbundle"))
        defer { try? FileManager.default.removeItem(at: root) }
        let result = LibraryStore.findLibraries(in: [root])
        #expect(result.byRoot[root.standardizedFileURL] == [library.standardizedFileURL])
        #expect(result.failedRoots.isEmpty)
        #expect(result.orphanCandidates.candidates(referencedRoots: []).map(\.root) == [root.appendingPathComponent("Cache", isDirectory: true)])
    }
}
