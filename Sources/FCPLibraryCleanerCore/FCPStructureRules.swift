import Foundation

/// Exact, positional rules. A matching name outside these positions is never a cleanup candidate.
public enum FCPStructureRules {
    public static let libraryDatabaseName = "CurrentVersion.flexolibrary"
    public static let eventDatabaseName = "CurrentVersion.fcpevent"
    public static let originalMediaName = "Original Media"
    public static let cacheLinkName = ".fcpcache"
    public static let externalRulePrefix = "external."

    public struct CandidateRule: Sendable {
        public let id: String
        public let category: CacheCategory
        public let relativePath: [String]

        public init(id: String, category: CacheCategory, relativePath: [String]) {
            self.id = id
            self.category = category
            self.relativePath = relativePath
        }
    }

    public struct ObservationRule: Sendable {
        public let id: String
        public let category: ObservedCacheCategory
        public let relativePath: [String]

        public init(id: String, category: ObservedCacheCategory, relativePath: [String]) {
            self.id = id
            self.category = category
            self.relativePath = relativePath
        }
    }

    /// Rules scoped to an Event directory that itself contains CurrentVersion.fcpevent.
    public static let eventCandidateRules: [CandidateRule] = [
        CandidateRule(id: "event.render-files", category: .renderFiles, relativePath: ["Render Files"]),
        CandidateRule(id: "event.proxy-media", category: .proxyMedia, relativePath: ["Transcoded Media", "Proxy Media"]),
        CandidateRule(id: "event.high-quality-media", category: .optimizedMedia, relativePath: ["Transcoded Media", "High Quality Media"]),
        CandidateRule(id: "event.optimized-media", category: .optimizedMedia, relativePath: ["Optimized Media"]),
    ]

    /// Shared generated media may live directly under a validated Library root.
    public static let libraryCandidateRules: [CandidateRule] = [
        CandidateRule(id: "library.shared-render-files", category: .renderFiles, relativePath: ["Shared Render Files"]),
        CandidateRule(id: "library.shared-proxy-media", category: .proxyMedia, relativePath: ["Shared Proxy Media"]),
        CandidateRule(id: "library.shared-optimized-media", category: .optimizedMedia, relativePath: ["Shared Optimized Media"]),
    ]

    /// These folders are recognizable, but are deliberately not in the cleanup whitelist.
    public static let eventObservationRules: [ObservationRule] = [
        ObservationRule(id: "event.analysis-files", category: .analysisFiles, relativePath: ["Analysis Files"]),
        ObservationRule(id: "event.audio-analysis-files", category: .analysisFiles, relativePath: ["Audio Analysis Files"]),
    ]

    public static func matchesConfirmedCandidate(
        _ candidateURL: URL,
        in libraryURL: URL,
        ruleID: String,
        fileManager: FileManager = .default
    ) -> Bool {
        if ruleID.hasPrefix(externalRulePrefix) {
            let baseRuleID = String(ruleID.dropFirst(externalRulePrefix.count))
            guard let cacheRoot = externalCacheRoot(for: libraryURL, fileManager: fileManager) else { return false }
            if let rule = libraryCandidateRules.first(where: { $0.id == baseRuleID }) {
                return candidateURL.standardizedFileURL == url(base: cacheRoot, components: rule.relativePath).standardizedFileURL
            }
            guard let rule = eventCandidateRules.first(where: { $0.id == baseRuleID }) else { return false }
            var externalEventURL = candidateURL
            for _ in rule.relativePath { externalEventURL.deleteLastPathComponent() }
            let eventName = externalEventURL.lastPathComponent
            let internalEventDatabase = libraryURL
                .appendingPathComponent(eventName, isDirectory: true)
                .appendingPathComponent(eventDatabaseName)
            return fileManager.fileExists(atPath: internalEventDatabase.path) &&
                candidateURL.standardizedFileURL == url(base: cacheRoot.appendingPathComponent(eventName, isDirectory: true), components: rule.relativePath).standardizedFileURL
        }

        if let rule = libraryCandidateRules.first(where: { $0.id == ruleID }) {
            return candidateURL.standardizedFileURL == url(base: libraryURL, components: rule.relativePath).standardizedFileURL
        }

        guard let rule = eventCandidateRules.first(where: { $0.id == ruleID }) else { return false }
        var eventURL = candidateURL
        for _ in rule.relativePath { eventURL.deleteLastPathComponent() }
        let eventDatabase = eventURL.appendingPathComponent(eventDatabaseName)
        guard fileManager.fileExists(atPath: eventDatabase.path) else { return false }
        return candidateURL.standardizedFileURL == url(base: eventURL, components: rule.relativePath).standardizedFileURL
    }

    public static func externalCacheRoot(
        for libraryURL: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        let linkURL = libraryURL.appendingPathComponent(cacheLinkName)
        guard let values = try? linkURL.resourceValues(forKeys: [.isSymbolicLinkKey]),
              values.isSymbolicLink == true,
              let destination = try? fileManager.destinationOfSymbolicLink(atPath: linkURL.path) else {
            return nil
        }
        let resolved = URL(
            fileURLWithPath: destination,
            relativeTo: linkURL.deletingLastPathComponent()
        ).standardizedFileURL.resolvingSymlinksInPath()
        let library = libraryURL.standardizedFileURL.resolvingSymlinksInPath()
        guard resolved != library,
              !resolved.path.hasPrefix(library.path + "/"),
              let rootValues = try? resolved.resourceValues(forKeys: [.isDirectoryKey]),
              rootValues.isDirectory == true else { return nil }
        return resolved
    }

    private static func url(base: URL, components: [String]) -> URL {
        components.reduce(base) { $0.appendingPathComponent($1, isDirectory: true) }
    }
}
