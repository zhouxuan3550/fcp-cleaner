import Foundation
import Testing
@testable import FCPLibraryCleanerApp

struct CleanupHistoryFileTests {
    @Test("legacy trash records decode without a trusted snapshot")
    func legacyRecord() throws {
        let json = #"{"originalURL":"file:///tmp/example","trashURL":"file:///tmp/trash/example"}"#
        let item = try JSONDecoder().decode(CleanupHistoryFile.self, from: Data(json.utf8))
        #expect(item.snapshot == nil)
        #expect(item.trashURL.path == "/tmp/trash/example")
    }

    @Test("legacy history entries decode without a capacity measurement")
    func legacyEntry() throws {
        let json = #"{"id":"2F1BEED5-9EBA-4D46-A74E-CE9E35D14684","date":0,"libraryName":"Example","libraryURL":"file:///tmp/library.fcpbundle","freedSize":10,"itemCount":0,"categories":[],"errorMessages":[],"trashedItems":[]}"#
        let entry = try JSONDecoder().decode(CleanupHistoryEntry.self, from: Data(json.utf8))
        #expect(entry.availableSpaceChange == nil)
    }
}
