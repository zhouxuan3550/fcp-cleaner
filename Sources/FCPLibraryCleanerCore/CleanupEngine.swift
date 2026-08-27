import Foundation
import OSLog

public struct CleanupEngine: Sendable {
    private static let logger = Logger(subsystem: "com.fcplibrarycleaner", category: "CleanupEngine")
    private let isLibraryInUse: @Sendable (URL) -> Bool

    public init() {
        isLibraryInUse = { LibraryUseDetector().libraryIsInUse($0) }
    }

    /// Dependency injection exists for deterministic tests; production callers use init().
    public init(isFinalCutProRunning: @escaping @Sendable () -> Bool) {
        isLibraryInUse = { _ in isFinalCutProRunning() }
    }

    public init(isLibraryInUse: @escaping @Sendable (URL) -> Bool) {
        self.isLibraryInUse = isLibraryInUse
    }

    public func preflight(plan: CleanupPlan, verifyContents: Bool = true) async throws {
        _ = try await Task.detached(priority: .userInitiated) {
            try Self.validatePreflight(
                plan: plan,
                isLibraryInUse: isLibraryInUse,
                verifyContents: verifyContents
            )
        }.value
    }

    public func execute(plan: CleanupPlan) async throws -> CleanupResult {
        return try await Task.detached(priority: .userInitiated) {
            try Self.executeSynchronously(plan: plan, isLibraryInUse: isLibraryInUse)
        }.value
    }

    private static func executeSynchronously(
        plan: CleanupPlan,
        isLibraryInUse: @escaping @Sendable (URL) -> Bool
    ) throws -> CleanupResult {
        let libraryVolume = try validatePreflight(
            plan: plan,
            isLibraryInUse: isLibraryInUse,
            verifyContents: false
        )
        let fileManager = FileManager.default
        var movedToTrash: [URL] = []
        var trashedItems: [TrashedItem] = []
        var freedAllocatedSize: Int64 = 0
        var errors: [CleanupError] = []

        for entry in plan.entries {
            try Task.checkCancellation()
            if isLibraryInUse(plan.libraryURL) {
                errors.append(.libraryInUse)
                break
            }
            do {
                try validateLibraryStorage(for: plan)
                try validateEntryStorage(entry, fallbackVolume: libraryVolume, fileManager: fileManager)
                try validateCoreData(plan.coreDataSnapshots)
                try validate(entry, libraryURL: plan.libraryURL, fileManager: fileManager, verifyContents: true)
                var resultingURL: NSURL?
                try fileManager.trashItem(at: entry.item.url, resultingItemURL: &resultingURL)
                movedToTrash.append(entry.item.url)
                if let trashURL = resultingURL as URL? {
                    trashedItems.append(TrashedItem(originalURL: entry.item.url, trashURL: trashURL))
                }
                freedAllocatedSize += entry.item.allocatedSize
            } catch let error as CleanupError {
                errors.append(error)
            } catch {
                errors.append(.trashFailed(entry.item.url, error.localizedDescription))
            }
        }

        logger.info("Cleanup attempted for \(plan.entries.count) confirmed entries")
        return CleanupResult(
            movedToTrash: movedToTrash,
            trashedItems: trashedItems,
            freedAllocatedSize: freedAllocatedSize,
            errors: errors
        )
    }

    private static func validatePreflight(
        plan: CleanupPlan,
        isLibraryInUse: @escaping @Sendable (URL) -> Bool,
        verifyContents: Bool
    ) throws -> URL {
        let libraryVolume = try validateLibraryStorage(for: plan)
        guard !isLibraryInUse(plan.libraryURL) else { throw CleanupError.libraryInUse }
        try validateCoreData(plan.coreDataSnapshots)
        for entry in plan.entries {
            try validateEntryStorage(entry, fallbackVolume: libraryVolume, fileManager: .default)
            try validate(
                entry,
                libraryURL: plan.libraryURL,
                fileManager: .default,
                verifyContents: verifyContents
            )
        }
        return libraryVolume
    }

    @discardableResult
    private static func validateLibraryStorage(for plan: CleanupPlan) throws -> URL {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: plan.libraryURL.path) else {
            throw CleanupError.volumeOffline(plan.libraryURL)
        }
        let values: URLResourceValues
        do {
            values = try plan.libraryURL.resourceValues(forKeys: [.volumeIsReadOnlyKey, .volumeURLKey])
        } catch {
            throw CleanupError.volumeOffline(plan.libraryURL)
        }
        let volumeURL = values.allValues[.volumeURLKey] as? URL ?? plan.libraryURL
        guard values.volumeIsReadOnly != true else { throw CleanupError.readOnlyVolume(volumeURL) }
        guard plan.libraryURL.pathExtension.lowercased() == "fcpbundle",
              fileManager.fileExists(atPath: plan.libraryURL.appendingPathComponent(FCPStructureRules.libraryDatabaseName).path) else {
            throw CleanupError.invalidLibrary(plan.libraryURL)
        }
        return volumeURL
    }

    private static func validateEntryStorage(
        _ entry: CleanupPlanEntry,
        fallbackVolume: URL,
        fileManager: FileManager
    ) throws {
        guard fileManager.fileExists(atPath: entry.item.url.path) else {
            if entry.item.storage == .external { throw CleanupError.volumeOffline(entry.item.url) }
            throw CleanupError.fileChanged(entry.item.url)
        }
        let values: URLResourceValues
        do {
            values = try entry.item.url.resourceValues(forKeys: [.volumeIsReadOnlyKey, .volumeURLKey])
        } catch {
            throw CleanupError.volumeOffline(entry.item.url)
        }
        let volume = values.allValues[.volumeURLKey] as? URL ?? fallbackVolume
        guard values.volumeIsReadOnly != true,
              fileManager.isWritableFile(atPath: entry.item.url.deletingLastPathComponent().path) else {
            throw CleanupError.readOnlyVolume(volume)
        }
    }

    private static func validate(
        _ entry: CleanupPlanEntry,
        libraryURL: URL,
        fileManager: FileManager,
        verifyContents: Bool
    ) throws {
        guard entry.item.confidence == .confirmed,
              FCPStructureRules.matchesConfirmedCandidate(
                entry.item.url,
                in: libraryURL,
                ruleID: entry.item.ruleID,
                fileManager: fileManager
              ) else {
            throw CleanupError.unknownStructure(entry.item.url)
        }

        guard fileManager.fileExists(atPath: entry.item.url.path) else {
            throw CleanupError.fileChanged(entry.item.url)
        }

        let values: URLResourceValues
        do {
            values = try entry.item.url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        } catch {
            throw CleanupError.fileChanged(entry.item.url)
        }
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw CleanupError.fileChanged(entry.item.url)
        }
        if verifyContents {
            guard try CleanupPlan.fingerprint(for: entry.item.url) == entry.fingerprint else {
                throw CleanupError.fileChanged(entry.item.url)
            }
        }
    }

    private static func validateCoreData(_ snapshots: [CoreDataSnapshot]) throws {
        for snapshot in snapshots {
            let attributes = try FileManager.default.attributesOfItem(atPath: snapshot.url.path)
            let current = CoreDataSnapshot(
                url: snapshot.url,
                size: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
                modificationTime: (attributes[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
            )
            guard current == snapshot else { throw CleanupError.fileChanged(snapshot.url) }
        }
    }
}
