import Foundation
import FCPLibraryCleanerCore

struct CleanupSummaryLibrary: Identifiable, Sendable {
    let id = UUID()
    let name: String
    let url: URL
    let freedSize: Int64
    let itemCount: Int
    let errorCount: Int
    let errorMessage: String?
    let succeeded: Bool
}

struct CleanupSummary: Identifiable, Sendable {
    let id = UUID()
    let date = Date()
    let title: String
    let libraryCount: Int
    let totalFreedSize: Int64
    let totalItemCount: Int
    let categories: Set<CacheCategory>
    let errorCount: Int
    let errorMessage: String?
    let elapsedSeconds: Double
    let libraries: [CleanupSummaryLibrary]
}
