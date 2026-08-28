import Foundation
import FCPLibraryCleanerCore

struct ScanResultCache: Sendable {
    /// 缓存条目格式版本。改动 Core 模型结构时 +1：旧缓存因缺少新键解码失败，
    /// 自动触发完整重扫——把"隐式解码崩溃"变成显式的版本门槛。
    private static let schemaVersion = 3

    private struct Entry: Codable, Sendable {
        let schemaVersion: Int
        let token: LibraryChangeToken
        let result: LibraryScanResult
    }

    func loadIfCurrent(libraryURL: URL) async -> LibraryScanResult? {
        guard let entry = await load(libraryURL: libraryURL),
              let currentToken = try? await LibraryScanner().changeToken(libraryURL: libraryURL),
              currentToken == entry.token else { return nil }
        return entry.result
    }

    func save(_ result: LibraryScanResult) async {
        guard let token = try? await LibraryScanner().changeToken(libraryURL: result.libraryURL) else { return }
        let entry = Entry(
            schemaVersion: Self.schemaVersion,
            token: token,
            result: result
        )
        let destination = cacheURL(for: result.libraryURL)
        await Task.detached(priority: .utility) {
            do {
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let data = try JSONEncoder().encode(entry)
                try data.write(to: destination, options: .atomic)
            } catch {
                // A cache write failure must never block scanning or cleanup.
            }
        }.value
    }

    private func load(libraryURL: URL) async -> Entry? {
        let source = cacheURL(for: libraryURL)
        return await Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: source) else { return nil }
            return try? JSONDecoder().decode(Entry.self, from: data)
        }.value
    }

    private func cacheURL(for libraryURL: URL) -> URL {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.fcpcleaner.app", isDirectory: true)
            .appendingPathComponent("ScanResults", isDirectory: true)
        return root.appendingPathComponent(stableKey(libraryURL.standardizedFileURL.path) + ".json")
    }

    private func stableKey(_ value: String) -> String {
        let hash = value.utf8.reduce(UInt64(1_469_598_103_934_665_603)) { partial, byte in
            (partial ^ UInt64(byte)) &* 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}
