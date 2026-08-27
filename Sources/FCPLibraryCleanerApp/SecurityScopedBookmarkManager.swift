import Foundation

struct RecentLibraryMetadata: Codable, Sendable {
    let url: URL
    let lastScanned: Date?
    let totalAllocatedSize: Int64?
    let cleanableSize: Int64?
    let lastActivity: Date?
}

struct RestoredLibrary: Sendable {
    let metadata: RecentLibraryMetadata
}

@MainActor
final class SecurityScopedBookmarkManager {
    private static let storageKey = "recentLibraryBookmarks"
    private static let workDirectoryStorageKey = "workDirectoryBookmarks"
    private var activeURLs = Set<URL>()

    private struct StoredBookmark: Codable {
        let data: Data
        let metadata: RecentLibraryMetadata
    }

    private struct StoredURLBookmark: Codable {
        let data: Data
    }

    func restore() -> [RestoredLibrary] {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let bookmarks = try? JSONDecoder().decode([StoredBookmark].self, from: data) else {
            return []
        }
        return bookmarks.compactMap { bookmark in
            var stale = false
            guard let url = try? URL(
                resolvingBookmarkData: bookmark.data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ), !stale else { return nil }
            _ = url.startAccessingSecurityScopedResource()
            activeURLs.insert(url.standardizedFileURL)
            return RestoredLibrary(metadata: RecentLibraryMetadata(
                url: url.standardizedFileURL,
                lastScanned: bookmark.metadata.lastScanned,
                totalAllocatedSize: bookmark.metadata.totalAllocatedSize,
                cleanableSize: bookmark.metadata.cleanableSize,
                lastActivity: bookmark.metadata.lastActivity
            ))
        }
    }

    func save(_ metadata: [RecentLibraryMetadata]) {
        let bookmarks = metadata.compactMap { entry -> StoredBookmark? in
            let url = entry.url.standardizedFileURL
            _ = url.startAccessingSecurityScopedResource()
            activeURLs.insert(url)
            guard let data = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) else {
                return nil
            }
            return StoredBookmark(data: data, metadata: RecentLibraryMetadata(
                url: url,
                lastScanned: entry.lastScanned,
                totalAllocatedSize: entry.totalAllocatedSize,
                cleanableSize: entry.cleanableSize,
                lastActivity: entry.lastActivity
            ))
        }
        UserDefaults.standard.set(try? JSONEncoder().encode(bookmarks), forKey: Self.storageKey)
    }

    func restoreWorkDirectories() -> [URL] {
        guard let data = UserDefaults.standard.data(forKey: Self.workDirectoryStorageKey),
              let bookmarks = try? JSONDecoder().decode([StoredURLBookmark].self, from: data) else {
            return []
        }
        return bookmarks.compactMap { bookmark in
            var stale = false
            guard let url = try? URL(
                resolvingBookmarkData: bookmark.data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ), !stale else { return nil }
            _ = url.startAccessingSecurityScopedResource()
            let standardizedURL = url.standardizedFileURL
            activeURLs.insert(standardizedURL)
            return standardizedURL
        }
    }

    func saveWorkDirectories(_ urls: [URL]) {
        let stored = urls.compactMap { url -> StoredURLBookmark? in
            let standardizedURL = url.standardizedFileURL
            _ = standardizedURL.startAccessingSecurityScopedResource()
            activeURLs.insert(standardizedURL)
            guard let data = try? standardizedURL.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) else { return nil }
            return StoredURLBookmark(data: data)
        }
        UserDefaults.standard.set(try? JSONEncoder().encode(stored), forKey: Self.workDirectoryStorageKey)
    }
}
