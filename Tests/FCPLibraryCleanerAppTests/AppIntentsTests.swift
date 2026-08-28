import Foundation
import Testing
@testable import FCPLibraryCleanerApp

@MainActor
struct AppIntentsTests {
    @Test("library name matching supports exact and localized-contains queries")
    func nameMatching() {
        #expect(ScanLibrary.matchesRequested("采访项目", query: "采访项目"))
        #expect(ScanLibrary.matchesRequested("采访项目", query: "采访"))
        #expect(ScanLibrary.matchesRequested("Interview A-Roll", query: "a-roll"))
        #expect(!ScanLibrary.matchesRequested("采访项目", query: "婚礼"))
        // 空查询代表"全部资源库"，由 perform 分支处理，不落入单个匹配
        #expect(!ScanLibrary.matchesRequested("采访项目", query: ""))
        #expect(!ScanLibrary.matchesRequested("采访项目", query: "   "))
    }
}
