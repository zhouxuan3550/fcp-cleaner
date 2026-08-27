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
            guard isRealDirectory(directory, fileManager: fileManager) else { return nil }
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
            guard isRealDirectory(candidate, fileManager: fileManager) else { return nil }
            return (rule, candidate)
        }
    }

    private func isRealDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        guard fileManager.fileExists(atPath: url.path) else { return false }
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }
}
