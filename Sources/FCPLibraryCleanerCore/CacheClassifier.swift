import Foundation

public struct CacheClassifier: Sendable {
    public init() {}

    public func confirmedCandidates(
        inEvent eventURL: URL,
        fileManager: FileManager = .default
    ) -> [(FCPStructureRules.CandidateRule, URL)] {
        candidates(baseURL: eventURL, rules: FCPStructureRules.eventCandidateRules, fileManager: fileManager)
    }

    public func confirmedSharedCandidates(
        inLibrary libraryURL: URL,
        fileManager: FileManager = .default
    ) -> [(FCPStructureRules.CandidateRule, URL)] {
        candidates(baseURL: libraryURL, rules: FCPStructureRules.libraryCandidateRules, fileManager: fileManager)
    }

    public func confirmedExternalCandidates(
        cacheRoot: URL,
        eventNames: [String],
        fileManager: FileManager = .default
    ) -> [(FCPStructureRules.CandidateRule, URL)] {
        var found = candidates(baseURL: cacheRoot, rules: FCPStructureRules.libraryCandidateRules, fileManager: fileManager)
        for eventName in eventNames {
            let eventRoot = cacheRoot.appendingPathComponent(eventName, isDirectory: true)
            found.append(contentsOf: candidates(baseURL: eventRoot, rules: FCPStructureRules.eventCandidateRules, fileManager: fileManager))
        }
        return found
    }

    public func observedProtectedDirectories(
        inEvent eventURL: URL,
        fileManager: FileManager = .default
    ) -> [(FCPStructureRules.ObservationRule, URL)] {
        FCPStructureRules.eventObservationRules.compactMap { rule in
            let directory = rule.relativePath.reduce(eventURL) { $0.appendingPathComponent($1, isDirectory: true) }
            guard Self.isRealDirectory(directory, fileManager: fileManager) else { return nil }
            return (rule, directory)
        }
    }

    private func candidates(
        baseURL: URL,
        rules: [FCPStructureRules.CandidateRule],
        fileManager: FileManager
    ) -> [(FCPStructureRules.CandidateRule, URL)] {
        rules.compactMap { rule in
            let candidate = rule.relativePath.reduce(baseURL) { $0.appendingPathComponent($1, isDirectory: true) }
            guard Self.isRealDirectory(candidate, fileManager: fileManager) else { return nil }
            return (rule, candidate)
        }
    }

    /// 真目录 = 目录且非符号链接；扫描、复核与清理引擎共用同一语义。
    /// 必须走 lstat 而非 URL.resourceValues：后者按 URL 对象缓存结果，
    /// 同一 URL 先扫描后删除会拿到删除前的 isDirectory=true（实测）。
    static func isRealDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return false }
        return true
    }
}
