import Foundation
import FCPLibraryCleanerCore

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
    /// 后台解析书签时顺带取齐的卷信息与活动时间；主线程建档零文件系统调用。
    var prefetched: ValidatedLibraryCandidate? = nil
}

@MainActor
final class SecurityScopedBookmarkManager {
    private static let storageKey = "recentLibraryBookmarks"
    private static let workDirectoryStorageKey = "workDirectoryBookmarks"
    private var activeURLs = Set<URL>()
    private var libraryBookmarkData: [URL: Data] = [:]
    private var workDirectoryBookmarkData: [URL: Data] = [:]

    private struct StoredBookmark: Codable, Sendable {
        let data: Data
        let metadata: RecentLibraryMetadata
    }

    private struct StoredURLBookmark: Codable, Sendable {
        let data: Data
    }

    /// 并行解析结果载体；concurrentPerform 闭包内经锁写入，规避数组并发变异。
    private final class LockedResults<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [T?]
        init(count: Int) { storage = .init(repeating: nil, count: count) }
        func store(_ value: T?, at index: Int) {
            lock.lock()
            storage[index] = value
            lock.unlock()
        }
        var values: [T?] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    private struct ResolvedBookmark: Sendable {
        let metadata: RecentLibraryMetadata
        let securityURL: URL
        let bookmarkData: Data
        let prefetched: ValidatedLibraryCandidate
    }

    func restore() -> [RestoredLibrary] {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let bookmarks = try? JSONDecoder().decode([StoredBookmark].self, from: data),
              !bookmarks.isEmpty else {
            return []
        }

        // 书签解析是启动时主线程最大的一笔 I/O（每枚零点几到数毫秒，几十个库可叠到数百毫秒，
        // 直接顶在首帧之前）。并行解析并顺带取齐卷信息与数据库时间戳；
        // 主线程只做安全域副作用（startAccessing）与建档。
        let results = LockedResults<ResolvedBookmark>(count: bookmarks.count)
        DispatchQueue.concurrentPerform(iterations: bookmarks.count) { index in
            results.store(Self.resolveBookmark(bookmarks[index]), at: index)
        }

        var restored: [RestoredLibrary] = []
        for resolved in results.values.compactMap({ $0 }) {
            _ = resolved.securityURL.startAccessingSecurityScopedResource()
            activeURLs.insert(resolved.metadata.url)
            libraryBookmarkData[resolved.metadata.url] = resolved.bookmarkData
            restored.append(RestoredLibrary(metadata: resolved.metadata, prefetched: resolved.prefetched))
        }
        return restored
    }

    /// 纯解析，无共享状态：书签还原、卷信息查询、数据库时间戳都在调用线程完成。
    nonisolated private static func resolveBookmark(_ bookmark: StoredBookmark) -> ResolvedBookmark? {
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark.data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ), !stale else { return nil }
        let standardizedURL = url.standardizedFileURL
        let values = try? url.resourceValues(forKeys: [.volumeURLKey, .volumeNameKey, .volumeUUIDStringKey])
        let volumeURL = values?.allValues[.volumeURLKey] as? URL ?? URL(fileURLWithPath: "/")
        let lastActivity = (try? FileManager.default.attributesOfItem(
            atPath: standardizedURL.appendingPathComponent(FCPStructureRules.libraryDatabaseName).path
        )[.modificationDate]) as? Date
        return ResolvedBookmark(
            metadata: RecentLibraryMetadata(
                url: standardizedURL,
                lastScanned: bookmark.metadata.lastScanned,
                totalAllocatedSize: bookmark.metadata.totalAllocatedSize,
                cleanableSize: bookmark.metadata.cleanableSize,
                lastActivity: bookmark.metadata.lastActivity,
                discoverySourceRaw: bookmark.metadata.discoverySourceRaw,
                volumeUUIDRaw: bookmark.metadata.volumeUUIDRaw,
                ignoredUntil: bookmark.metadata.ignoredUntil
            ),
            securityURL: url,
            bookmarkData: bookmark.data,
            prefetched: ValidatedLibraryCandidate(
                url: standardizedURL,
                volumeURL: volumeURL,
                volumeName: values?.volumeName ?? volumeURL.lastPathComponent,
                volumeID: values?.volumeUUIDString,
                lastActivity: lastActivity
            )
        )
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
              let bookmarks = try? JSONDecoder().decode([StoredURLBookmark].self, from: data),
              !bookmarks.isEmpty else {
            return []
        }
        // 与库书签同理：解析并行化，主线程只做安全域副作用与归档。
        let results = LockedResults<(url: URL, data: Data)>(count: bookmarks.count)
        DispatchQueue.concurrentPerform(iterations: bookmarks.count) { index in
            var stale = false
            guard let url = try? URL(
                resolvingBookmarkData: bookmarks[index].data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ), !stale else { return }
            results.store((url, bookmarks[index].data), at: index)
        }
        var urls: [URL] = []
        for resolved in results.values.compactMap({ $0 }) {
            _ = resolved.url.startAccessingSecurityScopedResource()
            let standardizedURL = resolved.url.standardizedFileURL
            activeURLs.insert(standardizedURL)
            workDirectoryBookmarkData[standardizedURL] = resolved.data
            urls.append(standardizedURL)
        }
        return urls
    }

    func saveWorkDirectories(_ urls: [URL]) {
        var retained: [URL: Data] = [:]
        let stored = urls.compactMap { url -> StoredURLBookmark? in
            let standardizedURL = url.standardizedFileURL
            let data: Data
            if let cached = workDirectoryBookmarkData[standardizedURL] {
                data = cached
            } else {
                _ = standardizedURL.startAccessingSecurityScopedResource()
                activeURLs.insert(standardizedURL)
                guard let created = try? standardizedURL.bookmarkData(
                    options: [.withSecurityScope],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                ) else { return nil }
                data = created
            }
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
