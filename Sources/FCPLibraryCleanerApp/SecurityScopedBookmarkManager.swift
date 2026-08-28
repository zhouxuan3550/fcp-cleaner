import Foundation

struct RecentLibraryMetadata: Codable, Sendable {
    let url: URL
    let lastScanned: Date?
    let totalAllocatedSize: Int64?
    let cleanableSize: Int64?
    let lastActivity: Date?
    var discoverySourceRaw: String? = nil
    /// 存档时的卷 UUID：恢复时若当前同路径挂载的是另一块盘，则拒绝复活条目。
    var volumeUUIDRaw: String? = nil
    /// 「稍后提醒」到期时间；旧档案缺字段按 nil 解码，向后兼容。
    var ignoredUntil: Date? = nil
}

struct RestoredLibrary: Sendable {
    let metadata: RecentLibraryMetadata
}

@MainActor
final class SecurityScopedBookmarkManager {
    private static let storageKey = "recentLibraryBookmarks"
    private static let workDirectoryStorageKey = "workDirectoryBookmarks"
    private var activeURLs = Set<URL>()
    private var libraryBookmarkData: [URL: Data] = [:]
    private var workDirectoryBookmarkData: [URL: Data] = [:]

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
            let standardizedURL = url.standardizedFileURL
            _ = url.startAccessingSecurityScopedResource()
            activeURLs.insert(standardizedURL)
            libraryBookmarkData[standardizedURL] = bookmark.data
            return RestoredLibrary(metadata: RecentLibraryMetadata(
                url: standardizedURL,
                lastScanned: bookmark.metadata.lastScanned,
                totalAllocatedSize: bookmark.metadata.totalAllocatedSize,
                cleanableSize: bookmark.metadata.cleanableSize,
                lastActivity: bookmark.metadata.lastActivity,
                discoverySourceRaw: bookmark.metadata.discoverySourceRaw,
                volumeUUIDRaw: bookmark.metadata.volumeUUIDRaw,
                ignoredUntil: bookmark.metadata.ignoredUntil
            ))
        }
    }

    func save(_ metadata: [RecentLibraryMetadata], replacementURLs: [URL: URL] = [:]) {
        var retainedBookmarkData: [URL: Data] = [:]
        let bookmarks = metadata.compactMap { entry -> StoredBookmark? in
            let url = entry.url.standardizedFileURL
            let data: Data
            if replacementURLs[url] == nil, let cached = libraryBookmarkData[url] {
                data = cached
            } else {
                let accessURL = replacementURLs[url]?.standardizedFileURL ?? url
                _ = accessURL.startAccessingSecurityScopedResource()
                activeURLs.insert(url)
                activeURLs.insert(accessURL)
                guard let created = try? accessURL.bookmarkData(
                    options: [.withSecurityScope],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                ) else { return nil }
                data = created
            }
            retainedBookmarkData[url] = data
            return StoredBookmark(data: data, metadata: RecentLibraryMetadata(
                url: url,
                lastScanned: entry.lastScanned,
                totalAllocatedSize: entry.totalAllocatedSize,
                cleanableSize: entry.cleanableSize,
                lastActivity: entry.lastActivity,
                discoverySourceRaw: entry.discoverySourceRaw,
                volumeUUIDRaw: entry.volumeUUIDRaw,
                ignoredUntil: entry.ignoredUntil
            ))
        }
        libraryBookmarkData = retainedBookmarkData
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
        var retained: [URL: Data] = [:]
        let stored = urls.compactMap { url -> StoredURLBookmark? in
            let standardizedURL = url.standardizedFileURL
            _ = standardizedURL.startAccessingSecurityScopedResource()
            activeURLs.insert(standardizedURL)
            guard let data = try? standardizedURL.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) else { return nil }
            retained[standardizedURL] = data
            return StoredURLBookmark(data: data)
        }
        workDirectoryBookmarkData = retained
        UserDefaults.standard.set(try? JSONEncoder().encode(stored), forKey: Self.workDirectoryStorageKey)
    }

    /// 诊断包用：书签健康度的只读快照。
    func statusReport() -> BookmarkStatusReport {
        BookmarkStatusReport(
            libraryBookmarkCount: libraryBookmarkData.count,
            workDirectoryBookmarkCount: workDirectoryBookmarkData.count,
            storedLibraryArchiveBytes: UserDefaults.standard.data(forKey: Self.storageKey)?.count,
            storedWorkDirectoryArchiveBytes: UserDefaults.standard.data(forKey: Self.workDirectoryStorageKey)?.count
        )
    }
}
