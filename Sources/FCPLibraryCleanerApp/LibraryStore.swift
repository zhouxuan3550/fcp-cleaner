import AppKit
import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers
import FCPLibraryCleanerCore

@Observable @MainActor
final class LibraryRecord: Identifiable {
    let id = UUID()
    let url: URL
    let volumeURL: URL
    let volumeName: String
    var scanResult: LibraryScanResult?
    var isScanning = false
    var isQueued = false
    var usedCachedScan = false
    var scanProgress = ScanProgress(files: 0, directories: 0, allocatedBytes: 0)
    var lastError: String?
    var lastCleanup: CleanupResult?
    var failedCleanupPlan: CleanupPlan?
    var cleanupBeforeSize: Int64?
    var cleanupAfterSize: Int64?
    var inspectorReport: InspectionReport?
    var isInspecting = false
    var lastScanned: Date?
    var lastKnownTotalSize: Int64?
    var lastKnownCleanableSize: Int64?
    var lastActivity: Date?
    @ObservationIgnored var scanControl: ScanControl?

    init(url: URL, restored: RestoredLibrary? = nil) {
        self.url = url
        let values = try? url.resourceValues(forKeys: [.volumeURLKey, .volumeNameKey])
        volumeURL = values?.allValues[.volumeURLKey] as? URL ?? URL(fileURLWithPath: "/")
        volumeName = values?.volumeName ?? volumeURL.lastPathComponent
        lastScanned = restored?.metadata.lastScanned
        lastKnownTotalSize = restored?.metadata.totalAllocatedSize
        lastKnownCleanableSize = restored?.metadata.cleanableSize
        lastActivity = restored?.metadata.lastActivity ?? Self.activityDate(for: url)
    }

    fileprivate static func activityDate(for libraryURL: URL) -> Date? {
        let database = libraryURL.appendingPathComponent(FCPStructureRules.libraryDatabaseName)
        return (try? FileManager.default.attributesOfItem(atPath: database.path)[.modificationDate]) as? Date
    }

    var displayName: String { url.deletingPathExtension().lastPathComponent }
    var spaceToFree: Int64 {
        guard let scanResult else { return 0 }
        return scanResult.cacheItems
            .reduce(0) { $0 + $1.allocatedSize }
    }
}

enum LibraryFilter: String, CaseIterable, Identifiable {
    case waiting
    case scanning
    case skipped

    var id: Self { self }

    var title: String {
        switch self {
        case .waiting: "待清理"
        case .scanning: "扫描中"
        case .skipped: "已跳过"
        }
    }
}

enum InactivityFilter: Int, CaseIterable, Identifiable {
    case all = 0
    case days30 = 30
    case days90 = 90
    case days180 = 180

    var id: Self { self }
    var title: String { self == .all ? "全部时间" : "\(rawValue) 天未使用" }
}

enum LibrarySort: String, CaseIterable, Identifiable {
    case sizeDescending
    case name
    case recentActivity

    var id: Self { self }

    var title: String {
        switch self {
        case .sizeDescending: "按大小"
        case .name: "按名称"
        case .recentActivity: "按最近使用"
        }
    }
}

enum AppearanceMode: Int, CaseIterable, Identifiable {
    case system = 0
    case dark = 1
    case light = 2

    var id: Self { self }

    var title: String {
        switch self {
        case .system: "跟随系统"
        case .dark: "暗色"
        case .light: "亮色"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .dark: .dark
        case .light: .light
        }
    }
}

@Observable @MainActor
final class LibraryStore: NSObject {
    static let shared = LibraryStore()
    static let minimumCleanableSize: Int64 = 500 * 1_024 * 1_024

    var libraries: [LibraryRecord] = []
    var workDirectories: [URL] = []
    var selectedID: LibraryRecord.ID?
    var selectedVolumeURL: URL?
    var libraryFilter: LibraryFilter = .waiting
    var inactivityFilter: InactivityFilter = .all
    var librarySort: LibrarySort = .sizeDescending
    var searchText = ""
    var appearanceMode = AppearanceMode(rawValue: UserDefaults.standard.integer(forKey: "appearanceMode")) ?? .dark {
        didSet {
            UserDefaults.standard.set(appearanceMode.rawValue, forKey: "appearanceMode")
        }
    }
    var batchSelectedIDs = Set<LibraryRecord.ID>()
    var cleanConfirmation: CleanConfirmation?
    var batchCleanConfirmation: BatchCleanConfirmation?
    var isBatchCleaning = false
    var isPreflighting = false
    var cleanupPreparationCompleted = 0
    var cleanupPreparationTotal = 0
    var batchCleanupCompleted = 0
    var batchCleanupTotal = 0
    var isDiscovering = false
    var discoveryError: String?
    var cleanupNotice: CleanupNotice?
    var lowSpaceWarnings: [DiskSpaceWarning] = []
    var notificationsEnabled = UserDefaults.standard.object(forKey: "notificationsEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(notificationsEnabled, forKey: "notificationsEnabled")
            NotificationController.shared.requestAuthorizationIfNeeded(enabled: notificationsEnabled)
        }
    }
    var lowSpaceWarningGB = max(10, UserDefaults.standard.integer(forKey: "lowSpaceWarningGB")) {
        didSet {
            UserDefaults.standard.set(lowSpaceWarningGB, forKey: "lowSpaceWarningGB")
            evaluateLowSpace()
        }
    }
    let cleanupHistory = CleanupHistoryStore()
    @ObservationIgnored private let bookmarks = SecurityScopedBookmarkManager()
    @ObservationIgnored private let scanCache = ScanResultCache()
    @ObservationIgnored private var metadataQuery: NSMetadataQuery?
    @ObservationIgnored private var didBeginAutomaticDiscovery = false
    @ObservationIgnored private var discoveryRunID = UUID()
    @ObservationIgnored private var scanQueue: [ScanRequest] = []
    @ObservationIgnored private var activeScanIDs = Set<LibraryRecord.ID>()
    @ObservationIgnored private var noticeDismissalTask: Task<Void, Never>?
    @ObservationIgnored private var lastLowSpaceNotification: [URL: Date] = [:]
    @ObservationIgnored private var lastAutomaticLowSpaceScan: [URL: Date] = [:]
    @ObservationIgnored private var spaceMonitorTask: Task<Void, Never>?
    private let maximumConcurrentScans = 3

    private override init() {
        super.init()
        let restored = bookmarks.restore()
        libraries = restored.map { LibraryRecord(url: $0.metadata.url, restored: $0) }
        workDirectories = bookmarks.restoreWorkDirectories()
        selectedID = libraries.first?.id
        if UserDefaults.standard.object(forKey: "lowSpaceWarningGB") == nil { lowSpaceWarningGB = 100 }
    }

    var selectedLibrary: LibraryRecord? {
        if let selectedID,
           let selected = filteredLibraries.first(where: { $0.id == selectedID }) {
            return selected
        }
        return filteredLibraries.first
    }

    var waitingLibraries: [LibraryRecord] {
        libraries.filter { record in
            !record.isScanning && !record.isQueued && knownCleanableSize(for: record) >= Self.minimumCleanableSize
        }
    }

    var scanningLibraries: [LibraryRecord] {
        libraries.filter { $0.isScanning || $0.isQueued }
    }

    var skippedLibraries: [LibraryRecord] {
        libraries.filter { record in
            !record.isScanning && !record.isQueued && knownCleanableSize(for: record) < Self.minimumCleanableSize
        }
    }

    var filteredLibraries: [LibraryRecord] {
        let base: [LibraryRecord]
        switch libraryFilter {
        case .waiting:
            base = selectedVolumeURL == nil ? waitingLibraries : waitingLibraries.filter { $0.volumeURL == selectedVolumeURL }
        case .scanning: base = scanningLibraries
        case .skipped: base = skippedLibraries
        }
        var result = base.filter(matchesInactivity)
        if !searchText.isEmpty {
            result = result.filter { $0.displayName.localizedStandardContains(searchText) }
        }
        switch librarySort {
        case .sizeDescending:
            result.sort { knownCleanableSize(for: $0) > knownCleanableSize(for: $1) }
        case .name:
            result.sort { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        case .recentActivity:
            result.sort { ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast) }
        }
        return result
    }

    var batchCleanableLibraries: [LibraryRecord] {
        filteredLibraries.filter {
            $0.scanResult != nil && $0.spaceToFree >= Self.minimumCleanableSize && !$0.isScanning
        }
    }

    func count(for filter: LibraryFilter) -> Int {
        switch filter {
        case .waiting: waitingLibraries.filter(matchesInactivity).count
        case .scanning: scanningLibraries.filter(matchesInactivity).count
        case .skipped: skippedLibraries.filter(matchesInactivity).count
        }
    }

    func setInactivityFilter(_ filter: InactivityFilter) {
        inactivityFilter = filter
        batchSelectedIDs.removeAll()
        selectedID = filteredLibraries.first?.id
    }

    func setFilter(_ filter: LibraryFilter) {
        libraryFilter = filter
        if filter != .waiting { selectedVolumeURL = nil }
        selectedID = filteredLibraries.first?.id
    }

    func selectVolume(_ volumeURL: URL) {
        libraryFilter = .waiting
        selectedVolumeURL = selectedVolumeURL == volumeURL ? nil : volumeURL
        batchSelectedIDs.removeAll()
        selectedID = filteredLibraries.first?.id
        drainScanQueue()
    }

    func select(_ record: LibraryRecord) {
        if !matchesInactivity(record) { inactivityFilter = .all }
        libraryFilter = filter(for: record)
        selectedID = record.id
        drainScanQueue()
    }

    var areAllCleanableLibrariesSelected: Bool {
        let cleanableIDs = Set(batchCleanableLibraries.map(\.id))
        return !cleanableIDs.isEmpty && cleanableIDs.isSubset(of: batchSelectedIDs)
    }

    var selectedBatchSpace: Int64 {
        batchCleanableLibraries
            .filter { batchSelectedIDs.contains($0.id) }
            .reduce(0) { $0 + $1.spaceToFree }
    }

    var diskCleanupSummaries: [DiskCleanupSummary] {
        let allCleanable = waitingLibraries.filter(matchesInactivity).filter {
            $0.scanResult != nil && $0.spaceToFree >= Self.minimumCleanableSize && !$0.isScanning
        }
        let grouped = Dictionary(grouping: allCleanable, by: \.volumeURL)
        return grouped.map { volumeURL, records in
            DiskCleanupSummary(
                volumeURL: volumeURL,
                name: records.first?.volumeName ?? volumeURL.lastPathComponent,
                cleanableSize: records.reduce(0) { $0 + $1.spaceToFree },
                libraryCount: records.count
            )
        }
        .sorted { $0.cleanableSize > $1.cleanableSize }
    }

    func toggleBatchSelection(_ record: LibraryRecord) {
        guard record.scanResult != nil,
              record.spaceToFree >= Self.minimumCleanableSize,
              !record.isScanning else { return }
        if batchSelectedIDs.contains(record.id) {
            batchSelectedIDs.remove(record.id)
        } else {
            batchSelectedIDs.insert(record.id)
        }
    }

    func toggleSelectAllCleanableLibraries() {
        let cleanableIDs = Set(batchCleanableLibraries.map(\.id))
        if areAllCleanableLibrariesSelected {
            batchSelectedIDs.subtract(cleanableIDs)
        } else {
            batchSelectedIDs.formUnion(cleanableIDs)
        }
    }

    func beginAutomaticDiscovery() {
        guard !didBeginAutomaticDiscovery else { return }
        didBeginAutomaticDiscovery = true
        NotificationController.shared.requestAuthorizationIfNeeded(enabled: notificationsEnabled)
        startSpaceMonitoring()

        for library in libraries where library.scanResult == nil && !library.isScanning {
            scan(library, force: false)
        }
        discoverLibraries()
    }

    func discoverLibraries() {
        discoveryRunID = UUID()
        if let metadataQuery {
            metadataQuery.stop()
            NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidFinishGathering, object: metadataQuery)
            NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidUpdate, object: metadataQuery)
        }

        discoveryError = nil
        isDiscovering = true
        if !workDirectories.isEmpty {
            let runID = discoveryRunID
            let roots = workDirectories
            Task {
                let urls = await Task.detached(priority: .userInitiated) {
                    Self.findLibraries(in: roots)
                }.value
                guard runID == discoveryRunID else { return }
                merge(libraryURLs: urls, selectNewest: selectedID == nil)
                isDiscovering = false
            }
            return
        }

        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryLocalComputerScope]
        query.predicate = NSPredicate(
            format: "%K ENDSWITH[c] %@",
            NSMetadataItemFSNameKey,
            ".fcpbundle"
        )
        query.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemPathKey, ascending: true)]
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(metadataQueryDidFinish(_:)),
            name: .NSMetadataQueryDidFinishGathering,
            object: query
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(metadataQueryDidUpdate(_:)),
            name: .NSMetadataQueryDidUpdate,
            object: query
        )
        metadataQuery = query
        if !query.start() {
            isDiscovering = false
            discoveryError = "自动扫描未能启动"
        }
    }

    @objc private func metadataQueryDidFinish(_ notification: Notification) {
        ingestMetadataResults()
        isDiscovering = false
    }

    @objc private func metadataQueryDidUpdate(_ notification: Notification) {
        ingestMetadataResults()
    }

    private func ingestMetadataResults() {
        guard let query = metadataQuery else { return }
        query.disableUpdates()
        let urls = query.results.compactMap { result -> URL? in
            guard let item = result as? NSMetadataItem else { return nil }
            return item.value(forAttribute: NSMetadataItemURLKey) as? URL
        }
        merge(libraryURLs: urls, selectNewest: selectedID == nil)
        query.enableUpdates()
    }

    func openLibraryPanel() {
        let panel = NSOpenPanel()
        panel.title = "选择 Final Cut Pro 资源库"
        panel.prompt = "选择资源库"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [UTType(importedAs: "com.apple.finalcutprolibrary")]
        panel.directoryURL = selectedLibrary?.url.deletingLastPathComponent() ?? workDirectories.first
        if panel.runModal() == .OK {
            add(libraryURLs: panel.urls)
        }
    }

    func openWorkDirectoryPanel() {
        let panel = NSOpenPanel()
        panel.title = "选择工作目录"
        panel.prompt = "设为工作目录"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = true
        panel.directoryURL = workDirectories.first
        if panel.runModal() == .OK {
            addWorkDirectories(panel.urls)
        }
    }

    func addWorkDirectories(_ urls: [URL]) {
        let existing = Set(workDirectories)
        workDirectories.append(contentsOf: urls.map(\.standardizedFileURL).filter { !existing.contains($0) })
        workDirectories.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        bookmarks.saveWorkDirectories(workDirectories)
        discoverLibraries()
    }

    func removeWorkDirectory(_ url: URL) {
        workDirectories.removeAll { $0 == url.standardizedFileURL }
        bookmarks.saveWorkDirectories(workDirectories)
        discoverLibraries()
    }

    func add(libraryURLs: [URL]) {
        merge(libraryURLs: libraryURLs, selectNewest: true)
    }

    private func merge(libraryURLs: [URL], selectNewest: Bool) {
        var newRecords: [LibraryRecord] = []
        let candidates = Set(libraryURLs.map(\.standardizedFileURL))
            .filter { url in
                guard url.pathExtension.lowercased() == "fcpbundle" else { return false }
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
            }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }

        for url in candidates {
            if let existing = libraries.first(where: { $0.url == url }) {
                if selectNewest { selectedID = existing.id }
                continue
            }
            let record = LibraryRecord(url: url)
            libraries.append(record)
            newRecords.append(record)
            if selectNewest { selectedID = record.id }
        }

        libraries.sort { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        if selectedID == nil { selectedID = libraries.first?.id }
        for record in newRecords { scan(record, force: false) }
        if !newRecords.isEmpty { saveRecents() }
    }

    nonisolated private static func findLibraries(in roots: [URL]) -> [URL] {
        let fileManager = FileManager.default
        var found = Set<URL>()
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]

        for root in roots {
            let standardizedRoot = root.standardizedFileURL
            if isLibraryDirectory(standardizedRoot, fileManager: fileManager) {
                found.insert(standardizedRoot)
                continue
            }
            guard let enumerator = fileManager.enumerator(
                at: standardizedRoot,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, _ in true }
            ) else { continue }

            for case let url as URL in enumerator where url.pathExtension.lowercased() == "fcpbundle" {
                if isLibraryDirectory(url, fileManager: fileManager) {
                    found.insert(url.standardizedFileURL)
                }
                enumerator.skipDescendants()
            }
        }
        return found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    nonisolated private static func isLibraryDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        guard url.pathExtension.lowercased() == "fcpbundle",
              let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    func scan(_ record: LibraryRecord, preserveLastCleanup: Bool = false, force: Bool = true) {
        guard !record.isScanning else { return }
        if let index = scanQueue.firstIndex(where: { $0.record.id == record.id }) {
            scanQueue[index].force = scanQueue[index].force || force
            scanQueue[index].preserveLastCleanup = scanQueue[index].preserveLastCleanup || preserveLastCleanup
            drainScanQueue()
            return
        }
        record.isQueued = true
        scanQueue.append(ScanRequest(record: record, preserveLastCleanup: preserveLastCleanup, force: force))
        drainScanQueue()
    }

    private func drainScanQueue() {
        while activeScanIDs.count < maximumConcurrentScans, !scanQueue.isEmpty {
            let nextIndex = scanQueue.firstIndex { $0.record.id == selectedID } ?? scanQueue.startIndex
            let request = scanQueue.remove(at: nextIndex)
            startScan(request)
        }
    }

    private func startScan(_ request: ScanRequest) {
        let record = request.record
        guard !activeScanIDs.contains(record.id) else { return }
        activeScanIDs.insert(record.id)
        record.isQueued = false
        let control = ScanControl()
        record.scanControl = control
        record.isScanning = true
        record.usedCachedScan = false
        record.scanProgress = ScanProgress(files: 0, directories: 0, allocatedBytes: 0)
        record.lastError = nil
        if !request.preserveLastCleanup {
            record.lastCleanup = nil
            record.failedCleanupPlan = nil
        }
        record.inspectorReport = nil
        Task { [weak self, weak record] in
            guard let self, let record else { return }
            do {
                let result: LibraryScanResult
                if !request.force, let cached = await scanCache.loadIfCurrent(libraryURL: record.url) {
                    result = cached
                    record.usedCachedScan = true
                } else {
                    result = try await LibraryScanner().scan(
                        libraryURL: record.url,
                        control: control,
                        onProgress: { progress in
                            Task { @MainActor [weak record] in
                                record?.scanProgress = progress
                            }
                        }
                    )
                    await scanCache.save(result)
                }
                record.scanResult = result
                record.lastScanned = Date()
                record.lastKnownTotalSize = record.scanResult?.totalAllocatedSize
                record.lastKnownCleanableSize = record.scanResult?.confirmedCleanableSize
                record.lastActivity = LibraryRecord.activityDate(for: record.url)
                saveRecents()
                evaluateLowSpace()
                if request.preserveLastCleanup, record.lastCleanup != nil {
                    record.cleanupAfterSize = record.scanResult?.totalAllocatedSize
                }
            } catch is CancellationError {
                record.lastError = nil
            } catch {
                record.lastError = error.localizedDescription
                record.scanResult = nil
            }
            record.isScanning = false
            record.scanControl = nil
            activeScanIDs.remove(record.id)
            reconcileFilteredLibraries()
            drainScanQueue()
        }
    }

    func cancelScan(_ record: LibraryRecord) {
        if let index = scanQueue.firstIndex(where: { $0.record.id == record.id }) {
            scanQueue.remove(at: index)
            record.isQueued = false
            reconcileFilteredLibraries()
            return
        }
        record.scanControl?.cancel()
    }

    func inspect(_ record: LibraryRecord) {
        guard let scanResult = record.scanResult, !record.isInspecting else { return }
        record.isInspecting = true
        Task { [weak record] in
            guard let record else { return }
            do {
                record.inspectorReport = try await LibraryInspector().inspect(scanResult: scanResult)
            } catch is CancellationError {
                record.inspectorReport = nil
            } catch {
                record.lastError = error.localizedDescription
            }
            record.isInspecting = false
        }
    }

    func requestClean(_ record: LibraryRecord) {
        guard !isPreflighting else { return }
        guard let result = record.scanResult,
              record.spaceToFree >= Self.minimumCleanableSize else { return }
        do {
            let plan = try CleanupPlan(scanResult: result, categories: Set(CacheCategory.cleanableCases))
            guard !plan.entries.isEmpty else { return }
            preflight(record: record, plan: plan, isRetry: false)
        } catch {
            showPreflightFailure(error, record: record)
        }
    }

    func requestPrimaryClean(_ record: LibraryRecord) {
        if batchSelectedIDs.count > 1 {
            requestBatchClean()
        } else {
            requestClean(record)
        }
    }

    func requestRetry(_ record: LibraryRecord) {
        guard !isPreflighting else { return }
        guard let plan = record.failedCleanupPlan else { return }
        preflight(record: record, plan: plan, isRetry: true)
    }

    func requestBatchClean() {
        guard !isPreflighting else { return }
        isPreflighting = true
        cleanupPreparationCompleted = 0
        cleanupPreparationTotal = batchSelectedIDs.count
        var entries: [BatchCleanupEntry] = []
        for record in libraries where batchSelectedIDs.contains(record.id) {
            guard let result = record.scanResult,
                  record.spaceToFree >= Self.minimumCleanableSize else { continue }
            do {
                let plan = try CleanupPlan(scanResult: result, categories: Set(CacheCategory.cleanableCases))
                if !plan.entries.isEmpty {
                    entries.append(BatchCleanupEntry(record: record, plan: plan))
                }
            } catch {
                showPreflightFailure(error, record: record)
            }
        }
        guard !entries.isEmpty else {
            isPreflighting = false
            cleanupPreparationTotal = 0
            return
        }
        cleanupPreparationTotal = entries.count
        Task {
            var failure: (Error, LibraryRecord)?
            for entry in entries {
                do {
                    try await CleanupEngine().preflight(plan: entry.plan, verifyContents: false)
                } catch {
                    failure = (error, entry.record)
                    break
                }
                cleanupPreparationCompleted += 1
            }
            if let failure {
                showPreflightFailure(failure.0, record: failure.1)
            } else {
                batchCleanConfirmation = BatchCleanConfirmation(entries: entries)
            }
            isPreflighting = false
            cleanupPreparationCompleted = 0
            cleanupPreparationTotal = 0
        }
    }

    private func preflight(record: LibraryRecord, plan: CleanupPlan, isRetry: Bool) {
        isPreflighting = true
        Task {
            do {
                cleanupPreparationCompleted = 0
                cleanupPreparationTotal = 1
                try await CleanupEngine().preflight(plan: plan, verifyContents: false)
                cleanupPreparationCompleted = 1
                cleanConfirmation = CleanConfirmation(record: record, plan: plan, isRetry: isRetry)
            } catch {
                showPreflightFailure(error, record: record)
            }
            isPreflighting = false
            cleanupPreparationCompleted = 0
            cleanupPreparationTotal = 0
        }
    }

    private func showPreflightFailure(_ error: Error, record: LibraryRecord?) {
        let message = error.localizedDescription
        record?.lastError = message
        showCleanupNotice(CleanupNotice(
            title: "清理前检查未通过",
            libraryCount: record == nil ? 0 : 1,
            freedSize: 0,
            cleanedItemCount: 0,
            categories: [],
            errorCount: 1,
            errorMessage: message
        ))
    }

    func performConfirmedBatchCleanup(_ confirmation: BatchCleanConfirmation) {
        batchCleanConfirmation = nil
        isBatchCleaning = true
        batchCleanupCompleted = 0
        batchCleanupTotal = confirmation.entries.count
        Task {
            var freedSize: Int64 = 0
            var cleanedItemCount = 0
            var errorCount = 0
            var firstErrorMessage: String?
            var categories = Set<CacheCategory>()
            var recordsToRescan: [LibraryRecord] = []
            for entry in confirmation.entries {
                let record = entry.record
                record.cleanupBeforeSize = record.scanResult?.totalAllocatedSize
                record.cleanupAfterSize = nil
                do {
                    let result = try await CleanupEngine().execute(plan: entry.plan)
                    record.lastCleanup = result
                    cleanupHistory.append(libraryName: record.displayName, libraryURL: record.url, plan: entry.plan, result: result)
                    record.failedCleanupPlan = result.errors.isEmpty
                        ? nil
                        : entry.plan.retryingItemsNotCompleted(in: result)
                    freedSize += result.freedAllocatedSize
                    cleanedItemCount += result.movedToTrash.count
                    errorCount += result.errors.count
                    firstErrorMessage = firstErrorMessage ?? result.errors.first?.localizedDescription
                    categories.formUnion(entry.plan.entries.map(\.item.category))
                    record.lastError = result.errors.isEmpty
                        ? nil
                        : result.errors.map(\.localizedDescription).joined(separator: "\n")
                    recordsToRescan.append(record)
                } catch {
                    errorCount += 1
                    firstErrorMessage = firstErrorMessage ?? error.localizedDescription
                    record.failedCleanupPlan = entry.plan
                    record.lastError = error.localizedDescription
                    cleanupHistory.appendFailure(libraryName: record.displayName, libraryURL: record.url, plan: entry.plan, error: error)
                }
                batchCleanupCompleted += 1
            }
            batchSelectedIDs.removeAll()
            isBatchCleaning = false
            batchCleanupCompleted = 0
            batchCleanupTotal = 0
            for record in recordsToRescan {
                scan(record, preserveLastCleanup: true, force: true)
            }
            showCleanupNotice(CleanupNotice(
                title: "批量清理完成",
                libraryCount: confirmation.entries.count,
                freedSize: freedSize,
                cleanedItemCount: cleanedItemCount,
                categories: categories,
                errorCount: errorCount,
                errorMessage: firstErrorMessage
            ))
            NotificationController.shared.cleanupFinished(
                freedSize: freedSize,
                libraryCount: confirmation.entries.count,
                errorCount: errorCount,
                enabled: notificationsEnabled
            )
        }
    }

    func performConfirmedCleanup(_ confirmation: CleanConfirmation) {
        cleanConfirmation = nil
        let record = confirmation.record
        record.cleanupBeforeSize = record.scanResult?.totalAllocatedSize
        record.cleanupAfterSize = nil
        Task {
            do {
                let result = try await CleanupEngine().execute(plan: confirmation.plan)
                record.lastCleanup = result
                cleanupHistory.append(libraryName: record.displayName, libraryURL: record.url, plan: confirmation.plan, result: result)
                record.failedCleanupPlan = result.errors.isEmpty
                    ? nil
                    : confirmation.plan.retryingItemsNotCompleted(in: result)
                showCleanupNotice(CleanupNotice(
                    title: record.displayName,
                    libraryCount: 1,
                    freedSize: result.freedAllocatedSize,
                    cleanedItemCount: result.movedToTrash.count,
                    categories: Set(confirmation.plan.entries.map(\.item.category)),
                    errorCount: result.errors.count,
                    errorMessage: result.errors.first?.localizedDescription
                ))
                if !result.errors.isEmpty {
                    record.lastError = result.errors.map(\.localizedDescription).joined(separator: "\n")
                }
                scan(record, preserveLastCleanup: true, force: true)
                NotificationController.shared.cleanupFinished(
                    freedSize: result.freedAllocatedSize,
                    libraryCount: 1,
                    errorCount: result.errors.count,
                    enabled: notificationsEnabled
                )
            } catch {
                record.lastError = error.localizedDescription
                record.failedCleanupPlan = confirmation.plan
                cleanupHistory.appendFailure(libraryName: record.displayName, libraryURL: record.url, plan: confirmation.plan, error: error)
                showCleanupNotice(CleanupNotice(
                    title: record.displayName,
                    libraryCount: 1,
                    freedSize: 0,
                    cleanedItemCount: 0,
                    categories: Set(confirmation.plan.entries.map(\.item.category)),
                    errorCount: 1,
                    errorMessage: error.localizedDescription
                ))
                NotificationController.shared.cleanupFinished(
                    freedSize: 0,
                    libraryCount: 1,
                    errorCount: 1,
                    enabled: notificationsEnabled
                )
            }
        }
    }

    func remove(_ records: [LibraryRecord]) {
        let ids = Set(records.map(\.id))
        libraries.removeAll { ids.contains($0.id) }
        batchSelectedIDs.subtract(ids)
        if ids.contains(selectedID ?? UUID()) {
            selectedID = libraries.first?.id
        }
        saveRecents()
    }

    private func reconcileFilteredLibraries() {
        let waitingIDs = Set(waitingLibraries.map(\.id))
        batchSelectedIDs.formIntersection(waitingIDs)
        let filteredIDs = Set(filteredLibraries.map(\.id))
        if let selectedID, filteredIDs.contains(selectedID) { return }
        selectedID = filteredLibraries.first?.id
    }

    func knownCleanableSize(for record: LibraryRecord) -> Int64 {
        if record.scanResult != nil { return record.spaceToFree }
        return record.lastKnownCleanableSize ?? 0
    }

    private func matchesInactivity(_ record: LibraryRecord) -> Bool {
        guard inactivityFilter != .all else { return true }
        guard let lastActivity = record.lastActivity else { return true }
        let cutoff = Calendar.current.date(byAdding: .day, value: -inactivityFilter.rawValue, to: Date()) ?? Date()
        return lastActivity <= cutoff
    }

    var totalCleanableSize: Int64 {
        waitingLibraries.reduce(0) { $0 + $1.spaceToFree }
    }

    func showMainWindow() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        if let window = NSApplication.shared.windows.first(where: { $0.title == "FCP Cleaner" || $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        }
    }

    func requestMenuBarCleanup() {
        libraryFilter = .waiting
        inactivityFilter = .all
        selectedVolumeURL = nil
        let records = waitingLibraries.filter {
            $0.scanResult != nil && $0.spaceToFree >= Self.minimumCleanableSize && !$0.isScanning
        }
        guard !records.isEmpty else {
            showMainWindow()
            return
        }
        batchSelectedIDs = Set(records.map(\.id))
        selectedID = records.first?.id
        showMainWindow()
        requestBatchClean()
    }

    func evaluateLowSpace() {
        let threshold = Int64(lowSpaceWarningGB) * 1_024 * 1_024 * 1_024
        let grouped = Dictionary(grouping: libraries, by: \.volumeURL)
        var warnings: [DiskSpaceWarning] = []
        for (volumeURL, records) in grouped {
            guard let values = try? volumeURL.resourceValues(forKeys: [
                .volumeAvailableCapacityForImportantUsageKey,
                .volumeAvailableCapacityKey,
            ]),
                  let available = values.volumeAvailableCapacityForImportantUsage ?? values.volumeAvailableCapacity.map(Int64.init),
                  available < threshold else { continue }
            let cleanable = records.reduce(Int64(0)) { $0 + $1.spaceToFree }
            let warning = DiskSpaceWarning(
                volumeURL: volumeURL,
                name: records.first?.volumeName ?? volumeURL.lastPathComponent,
                availableSize: available,
                cleanableSize: cleanable
            )
            warnings.append(warning)
            let lastNotification = lastLowSpaceNotification[volumeURL] ?? .distantPast
            if cleanable >= Self.minimumCleanableSize, Date().timeIntervalSince(lastNotification) > 86_400 {
                NotificationController.shared.lowSpace(
                    volumeName: warning.name,
                    availableSize: available,
                    cleanableSize: cleanable,
                    enabled: notificationsEnabled
                )
                lastLowSpaceNotification[volumeURL] = Date()
            }
        }
        lowSpaceWarnings = warnings.sorted { $0.availableSize < $1.availableSize }
    }

    private func startSpaceMonitoring() {
        guard spaceMonitorTask == nil else { return }
        spaceMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(900))
                guard !Task.isCancelled, let self else { return }
                evaluateLowSpace()
                let now = Date()
                for warning in lowSpaceWarnings {
                    let lastScan = lastAutomaticLowSpaceScan[warning.volumeURL] ?? .distantPast
                    guard now.timeIntervalSince(lastScan) >= 6 * 60 * 60 else { continue }
                    lastAutomaticLowSpaceScan[warning.volumeURL] = now
                    for record in libraries where record.volumeURL == warning.volumeURL {
                        scan(record, force: false)
                    }
                }
            }
        }
    }

    private func filter(for record: LibraryRecord) -> LibraryFilter {
        if record.isScanning || record.isQueued { return .scanning }
        return knownCleanableSize(for: record) >= Self.minimumCleanableSize ? .waiting : .skipped
    }

    func dismissCleanupNotice() {
        noticeDismissalTask?.cancel()
        cleanupNotice = nil
    }

    private func showCleanupNotice(_ notice: CleanupNotice) {
        noticeDismissalTask?.cancel()
        cleanupNotice = notice
        noticeDismissalTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, self?.cleanupNotice?.id == notice.id else { return }
            self?.cleanupNotice = nil
        }
    }

    private func saveRecents() {
        bookmarks.save(libraries.map {
            RecentLibraryMetadata(
                url: $0.url,
                lastScanned: $0.lastScanned,
                totalAllocatedSize: $0.lastKnownTotalSize,
                cleanableSize: $0.lastKnownCleanableSize,
                lastActivity: $0.lastActivity
            )
        })
    }
}

@MainActor
private struct ScanRequest {
    let record: LibraryRecord
    var preserveLastCleanup: Bool
    var force: Bool
}

struct CleanupNotice: Identifiable {
    let id = UUID()
    let title: String
    let libraryCount: Int
    let freedSize: Int64
    let cleanedItemCount: Int
    let categories: Set<CacheCategory>
    let errorCount: Int
    let errorMessage: String?
}

struct DiskCleanupSummary: Identifiable {
    var id: URL { volumeURL }
    let volumeURL: URL
    let name: String
    let cleanableSize: Int64
    let libraryCount: Int
}

struct DiskSpaceWarning: Identifiable {
    var id: URL { volumeURL }
    let volumeURL: URL
    let name: String
    let availableSize: Int64
    let cleanableSize: Int64
}

@MainActor
final class CleanConfirmation: Identifiable {
    let id = UUID()
    let record: LibraryRecord
    let plan: CleanupPlan
    let isRetry: Bool

    init(record: LibraryRecord, plan: CleanupPlan, isRetry: Bool = false) {
        self.record = record
        self.plan = plan
        self.isRetry = isRetry
    }
}

@MainActor
struct BatchCleanupEntry {
    let record: LibraryRecord
    let plan: CleanupPlan
}

@MainActor
final class BatchCleanConfirmation: Identifiable {
    let id = UUID()
    let entries: [BatchCleanupEntry]

    init(entries: [BatchCleanupEntry]) {
        self.entries = entries
    }

    var totalSpaceToFree: Int64 {
        entries.reduce(0) { $0 + $1.plan.spaceToFree }
    }
}
