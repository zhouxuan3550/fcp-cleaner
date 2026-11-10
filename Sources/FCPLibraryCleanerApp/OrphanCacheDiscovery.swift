import Foundation
import FCPLibraryCleanerCore

struct PossibleOrphanCache: Identifiable, Sendable {
    let url: URL
    let allocatedBytes: Int64?
    var id: URL { url }
}

/// Identifies only recognizable cache directory patterns. A matching folder
/// cannot prove ownership, so results are always presented as possible orphans.
struct OrphanCacheDiscovery: Sendable {
    static let recognizedNames: Set<String> = ["Shared Render Files", "Shared Proxy Media", "Shared Optimized Media", "Render Files", "Analysis Files", "Audio Analysis Files", "Transcoded Media", "Optimized Media"]
    private var folders: [URL: Set<URL>] = [:]

    mutating func observe(_ url: URL, under root: URL) {
        let folder = url.standardizedFileURL
        let owner: URL
        switch folder.lastPathComponent {
        case "Shared Render Files", "Shared Proxy Media", "Shared Optimized Media":
            owner = folder.deletingLastPathComponent()
        case "Render Files", "Analysis Files", "Audio Analysis Files", "Transcoded Media", "Optimized Media":
            owner = folder.deletingLastPathComponent().deletingLastPathComponent()
        default: return
        }
        let base = root.standardizedFileURL.path
        guard owner.path == base || owner.path.hasPrefix(base == "/" ? "/" : base + "/") else { return }
        folders[owner, default: []].insert(folder)
    }

    func candidates(referencedRoots: [URL]) -> [(root: URL, folders: [URL])] {
        let references = referencedRoots.map { $0.standardizedFileURL.resolvingSymlinksInPath().path }
        let found: [(root: URL, folders: [URL])] = folders.compactMap { root, children in
            let path = root.standardizedFileURL.resolvingSymlinksInPath().path
            func contains(_ parent: String, _ child: String) -> Bool {
                child == parent || child.hasPrefix(parent == "/" ? "/" : parent + "/")
            }
            guard !references.contains(where: { contains($0, path) || contains(path, $0) }) else { return nil }
            return (root, children.sorted { $0.path < $1.path })
        }.sorted { $0.root.path.count < $1.root.path.count }
        var result: [(root: URL, folders: [URL])] = []
        for candidate in found {
            let path = candidate.root.path
            if result.contains(where: { path.hasPrefix($0.root.path == "/" ? "/" : $0.root.path + "/") }) { continue }
            result.append(candidate)
        }
        return result.sorted { $0.root.path.localizedStandardCompare($1.root.path) == .orderedAscending }
    }

    static func measure(_ candidate: (root: URL, folders: [URL])) async -> PossibleOrphanCache {
        var total: Int64 = 0
        for folder in candidate.folders {
            guard let size = try? await LibraryScanner().allocatedSize(of: folder) else {
                return PossibleOrphanCache(url: candidate.root, allocatedBytes: nil)
            }
            let (sum, overflow) = total.addingReportingOverflow(size)
            guard !overflow else { return PossibleOrphanCache(url: candidate.root, allocatedBytes: nil) }
            total = sum
        }
        return PossibleOrphanCache(url: candidate.root, allocatedBytes: total)
    }
}
