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
