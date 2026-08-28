import Foundation
import Testing
@testable import FCPLibraryCleanerApp

struct WorkflowCallbackTests {
    @Test("workflow callback extracts only fcpbundle file paths")
    func extractsLibraryURL() throws {
        let callback = try #require(URL(string:
            "fcp-cleaner://library?path=%2FVolumes%2FRAID%2F%E9%A1%B9%E7%9B%AE.fcpbundle"
        ))
        #expect(AppDelegate.libraryURL(from: callback)?.path == "/Volumes/RAID/项目.fcpbundle")

        #expect(AppDelegate.libraryURL(from: URL(string: "fcp-cleaner://open")!) == nil)
        #expect(AppDelegate.libraryURL(from: URL(string: "https://example.com/library.fcpbundle")!) == nil)
        #expect(AppDelegate.libraryURL(from: URL(string: "fcp-cleaner://library?path=/tmp/file.txt")!) == nil)
    }
}
