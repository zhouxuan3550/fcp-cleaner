import Foundation
import Testing
@testable import FCPLibraryCleanerCore

/// candidateLocation expects the candidate *directory* URL exactly as stored in
/// CacheItem.url — scanner-produced candidates are always directories, never leaves.
struct FCPStructureRulesTests {
    private let renderFilesDirectory = URL(
        fileURLWithPath: "/Volumes/Backups/My Library.fcpbundle/Nested Event/Render Files"
    )

    @Test func sharedCacheRulesOmitEventName() {
        let location = FCPStructureRules.candidateLocation(for: renderFilesDirectory, ruleID: "library.shared-render-files")

        #expect(location?.eventName == nil)
        #expect(location?.categoryPath == "Shared Render Files")
    }

    @Test func eventRuleDerivesEventNameFromCandidateURL() {
        let location = FCPStructureRules.candidateLocation(for: renderFilesDirectory, ruleID: "event.render-files")

        #expect(location?.eventName == "Nested Event")
        #expect(location?.categoryPath == "Render Files")
    }

    @Test func multiComponentEventRuleStripsEveryPathComponent() {
        let proxyMediaDirectory = URL(fileURLWithPath: "/Lib.fcpbundle/Event A/Transcoded Media/Proxy Media")

        let location = FCPStructureRules.candidateLocation(for: proxyMediaDirectory, ruleID: "event.proxy-media")

        #expect(location?.eventName == "Event A")
        #expect(location?.categoryPath == "Transcoded Media / Proxy Media")
    }

    @Test func externalPrefixIsStrippedBeforeMatchingLibraryRule() {
        let location = FCPStructureRules.candidateLocation(for: renderFilesDirectory, ruleID: "external.library.shared-render-files")

        #expect(location?.eventName == nil)
        #expect(location?.categoryPath == "Shared Render Files")
    }

    @Test func externalPrefixIsStrippedBeforeMatchingEventRule() {
        let location = FCPStructureRules.candidateLocation(for: renderFilesDirectory, ruleID: "external.event.render-files")

        #expect(location?.eventName == "Nested Event")
        #expect(location?.categoryPath == "Render Files")
    }

    @Test func unknownRuleIDReturnsNil() {
        #expect(FCPStructureRules.candidateLocation(for: renderFilesDirectory, ruleID: "event.does-not-exist") == nil)
        #expect(FCPStructureRules.candidateLocation(for: renderFilesDirectory, ruleID: "external.event.does-not-exist") == nil)
    }
}

extension FCPStructureRulesTests {
    @Test("event candidate outside the library is rejected even with matching structure")
    func eventCandidateMustBeAnchoredInsideLibrary() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let library = base.appendingPathComponent("Lib.fcpbundle", isDirectory: true)
        let decoy = base.appendingPathComponent("Decoy.fcpbundle", isDirectory: true)
        for root in [library, decoy] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("Event A/Render Files"), withIntermediateDirectories: true)
            try Data("db".utf8).write(
                to: root.appendingPathComponent("Event A/CurrentVersion.fcpevent"))
        }
        defer { try? FileManager.default.removeItem(at: base) }

        let inside = library.appendingPathComponent("Event A/Render Files")
        let outside = decoy.appendingPathComponent("Event A/Render Files")
        #expect(FCPStructureRules.matchesConfirmedCandidate(inside, in: library, ruleID: "event.render-files"))
        // 同构目录 + 相同 fcpevent 标记，但在库外：复用的计划条目绝不能放行。
        #expect(!FCPStructureRules.matchesConfirmedCandidate(outside, in: library, ruleID: "event.render-files"))
    }
}
