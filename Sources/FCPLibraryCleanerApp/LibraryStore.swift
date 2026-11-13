import AppKit
import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers
import FCPLibraryCleanerCore

enum DiscoverySource: String, Codable, Sendable {
    case manualAdd
    case workDirectory
    case spotlightSearch

    /// Sidebar-row suffix; manually added libraries stay unlabeled.
    var title: String? {
        switch self {
        case .manualAdd: nil
        case .workDirectory: "工作目录"
        case .spotlightSearch: "本机发现"
        }
    }
}

@Observable @MainActor
final class LibraryRecord: Identifiable {
    let id = UUID()
    let url: URL
    let volumeURL: URL
    let volumeName: String
    let volumeID: String?
    var scanResult: LibraryScanResult? {
        didSet { cachedSpaceToFree = nil }
    }
    @ObservationIgnored private var cachedSpaceToFree: Int64?
    var isScanning = false
    var isQueued = false
    var usedCachedScan = false
    var scanProgress = ScanProgress(files: 0, directories: 0, allocatedBytes: 0)
    var scanPartialResults: ScanPartialResults?
    var scanError: String?
    var cleanupError: String?
    var lastCleanup: CleanupResult?
    var failedCleanupPlan: CleanupPlan?
    var cleanupBeforeSize: Int64?
    var cleanupAfterSize: Int64?
    var inspectorReport: InspectionReport?
    var isInspecting = false
    var accessReport: VolumeAccessReport?
    var isDiagnosingVolume = false
    var lastAccessibleAt: Date?
    var lastScanned: Date?
    var lastKnownTotalSize: Int64?
    var lastKnownCleanableSize: Int64?
    var pendingFreedSize: Int64 = 0
    var lastActivity: Date?
    var ignoredUntil: Date?
    let discoverySource: DiscoverySource?
    @ObservationIgnored var scanControl: ScanControl?
    @ObservationIgnored var liveEvents: FSEventsLiveLease?
    @ObservationIgnored var eventWatchID = UUID()
    @ObservationIgnored var eventRefreshTask: Task<Void, Never>?
    @ObservationIgnored var eventRefreshPending = false

    init(url: URL, restored: RestoredLibrary? = nil, discoveredVia source: DiscoverySource? = nil, prefetched: ValidatedLibraryCandidate? = nil) {
        self.url = url
        if let prefetched, let volumeURL = prefetched.volumeURL {
            // 发现流程已在后台取齐卷信息，主线程建档零文件系统调用。
            self.volumeURL = volumeURL
            volumeName = prefetched.volumeName ?? volumeURL.lastPathComponent
            volumeID = prefetched.volumeID
        } else {
            let values = try? url.resourceValues(forKeys: [.volumeURLKey, .volumeNameKey, .volumeUUIDStringKey])
            self.volumeURL = values?.allValues[.volumeURLKey] as? URL ?? URL(fileURLWithPath: "/")
            volumeName = values?.volumeName ?? self.volumeURL.lastPathComponent
            volumeID = values?.volumeUUIDString
        }
        lastScanned = restored?.metadata.lastScanned
        lastKnownTotalSize = restored?.metadata.totalAllocatedSize
        lastKnownCleanableSize = restored?.metadata.cleanableSize
        lastActivity = restored?.metadata.lastActivity ?? prefetched?.lastActivity ?? Self.activityDate(for: url)
        ignoredUntil = restored?.metadata.ignoredUntil
        discoverySource = restored?.metadata.discoverySourceRaw.flatMap(DiscoverySource.init(rawValue:)) ?? source
    }

    /// 纯 stat 调用，无隔离状态；扫描收尾路径会从后台线程调用。
    nonisolated static func activityDate(for libraryURL: URL) -> Date? {
        let database = libraryURL.appendingPathComponent(FCPStructureRules.libraryDatabaseName)
        return (try? FileManager.default.attributesOfItem(atPath: database.path)[.modificationDate]) as? Date
    }

    var displayName: String { url.deletingPathExtension().lastPathComponent }
    func acceptPartialResults(_ partial: ScanPartialResults, control: ScanControl) {
        guard isScanning, scanControl === control, !control.isCancelled,
              partial.completedDirectories > (scanPartialResults?.completedDirectories ?? 0) else { return }
        scanPartialResults = partial
    }

    func acceptLiveCacheChange(watchID: UUID) -> Bool {
        guard eventWatchID == watchID else { return false }
        eventRefreshPending = true
        if !isScanning { scanResult = nil }
        return true
    }

    var spaceToFree: Int64 {
        if let cachedSpaceToFree { return cachedSpaceToFree }
        let total = scanResult?.cacheItems.reduce(0) { $0 + $1.allocatedSize } ?? 0
        cachedSpaceToFree = total
        return total
    }
}

enum LibraryFilter: String, CaseIterable, Identifiable {
    case waiting
    case scanning
    case skipped
    case ignored

    var id: Self { self }

    var title: String {
        switch self {
        case .waiting: "待清理"
        case .scanning: "扫描中"
        case .skipped: "已跳过"
        case .ignored: "已忽略"
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

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .dark: NSAppearance(named: .darkAqua)
        case .light: NSAppearance(named: .aqua)
        }
    }

    @MainActor
    func applyToApplication() {
        NSApplication.shared.appearance = nsAppearance
    }
}

@Observable @MainActor
final class LibraryStore: NSObject {
    static let shared = LibraryStore()
    nonisolated static let minimumCleanableSize: Int64 = 200 * 1_024 * 1_024

    var libraries: [LibraryRecord] = []
    var workDirectories: [URL] = []
    var workDirectoryStatuses: [URL: WorkDirectoryStatus] = [:]
    var possibleOrphanCaches: [PossibleOrphanCache] = []
    /// 目录级忽略集（标准化的绝对路径）。仅作用于自动发现与列表分层，
    /// 手动添加/拖入不受影响；绝不影响清理链路。
    var ignoredLibraryDirectories: [String] = UserDefaults.standard.stringArray(forKey: "ignoredLibraryDirectories") ?? [] {
        didSet {
            UserDefaults.standard.set(ignoredLibraryDirectories, forKey: "ignoredLibraryDirectories")
        }
    }
    var selectedID: LibraryRecord.ID?
    var selectedVolumeURL: URL?
    var libraryFilter: LibraryFilter = .waiting
    var inactivityFilter: InactivityFilter = .all
    var librarySort = LibrarySort(rawValue: UserDefaults.standard.string(forKey: "librarySort") ?? "") ?? .sizeDescending {
        didSet {
            UserDefaults.standard.set(librarySort.rawValue, forKey: "librarySort")
        }
    }
    var searchText = ""
    var showsSettings = false
    var showsHistory = false
    var appearanceMode = AppearanceMode(rawValue: UserDefaults.standard.integer(forKey: "appearanceMode")) ?? .dark {
        didSet {
            UserDefaults.standard.set(appearanceMode.rawValue, forKey: "appearanceMode")
        }
    }
    var batchSelectedIDs = Set<LibraryRecord.ID>()
    var cleanConfirmation: CleanConfirmation?
    var batchCleanConfirmation: BatchCleanConfirmation?
    var isBatchCleaning = false
    var isCleaning = false
    var isPreflighting = false
    var cleanupPreparationCompleted = 0
    var cleanupPreparationTotal = 0
    var batchCleanupCompleted = 0
    var batchCleanupTotal = 0
    var isDiscovering = false
    var discoveryError: String?
    var cleanupNotice: CleanupNotice?
    var cleanupSummary: CleanupSummary?
    /// 上次清理中断后重建的待清计划摘要（历史页入口），处置完毕自动清空。
    var interruptedCleanups: [InterruptedCleanupSummary] = []
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
    var scheduledCheckFrequency = ScheduledCheckFrequency(
        rawValue: UserDefaults.standard.string(forKey: ScheduledCheckController.frequencyStorageKey) ?? ""
    ) ?? .off {
        didSet {
            UserDefaults.standard.set(scheduledCheckFrequency.rawValue, forKey: ScheduledCheckController.frequencyStorageKey)
            scheduledCheckController.restart()
        }
    }
    let cleanupHistory = CleanupHistoryStore()
    @ObservationIgnored let cleanupCoordinator = CleanupCoordinator()
    @ObservationIgnored let bookmarks = SecurityScopedBookmarkManager()
    @ObservationIgnored lazy var scheduledCheckController = ScheduledCheckController(store: self)
    @ObservationIgnored let cleanupJournal = CleanupTransactionJournal()
    @ObservationIgnored var interruptedReconciliationID = UUID()
    @ObservationIgnored let scanCache = ScanResultCache()
    @ObservationIgnored var metadataQuery: NSMetadataQuery?
    @ObservationIgnored var didBeginAutomaticDiscovery = false
    @ObservationIgnored var discoveryRunID = UUID()
    @ObservationIgnored var orphanDiscoveryTask: Task<Void, Never>?
    @ObservationIgnored var pendingMergeCount = 0
    @ObservationIgnored let scanQueue = LibraryScanQueue()
    @ObservationIgnored var noticeDismissalTask: Task<Void, Never>?
    @ObservationIgnored var lastLowSpaceNotification: [URL: Date] = [:]
    @ObservationIgnored var lastAutomaticLowSpaceScan: [URL: Date] = [:]
    @ObservationIgnored var spaceMonitorTask: Task<Void, Never>?
    @ObservationIgnored var isEvaluatingLowSpace = false
    /// 评估在途期间又有新请求（快速拖动预警阈值、扫描风暴）时置位；
    /// 本轮结束后按最新状态重跑一次，保证最后一次变更不被吞掉。
    @ObservationIgnored var needsLowSpaceReevaluation = false
    @ObservationIgnored var workDirectoryMonitor: WorkDirectoryMonitor?
    @ObservationIgnored var volumeMountMonitor: VolumeMountMonitor?
    @ObservationIgnored var snoozeExpiryTask: Task<Void, Never>?
    @ObservationIgnored var saveRecentsTask: Task<Void, Never>?
    @ObservationIgnored var isExportingDiagnosticsInternal = false
    /// 忽略目录的标准前缀缓存（供 LibraryStore+Orphans 的 isLibraryIgnored 使用）。
    @ObservationIgnored var ignoredPrefixCache: (source: [String], prefixes: [String])?
    /// 菜单项禁用态（诊断导出进行中）。
    var isExportingDiagnostics: Bool { isExportingDiagnosticsInternal }

    private override init() {
        super.init()
        let restored = bookmarks.restore()
        // 卷身份绑定：同一路径当前挂载的若是另一块盘（UUID 不同），拒绝复活旧条目，
        // 防止把上一块盘的扫描元数据安到异盘同名资源库上。
        libraries = restored.compactMap { entry -> LibraryRecord? in
            let record = LibraryRecord(url: entry.metadata.url, restored: entry, prefetched: entry.prefetched)
            if let saved = entry.metadata.volumeUUIDRaw,
               let current = record.volumeID,
               saved != current {
                return nil
            }
            return record
        }
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
            !record.isScanning && !record.isQueued
                && !isLibraryIgnored(record)
                && knownCleanableSize(for: record) >= Self.minimumCleanableSize
        }
    }

    var scanningLibraries: [LibraryRecord] {
        libraries.filter { $0.isScanning || $0.isQueued }
    }

    /// 还有排队或运行中的扫描（定时检查与 Shortcuts 意图据此等待静默）。
    var isScanPending: Bool {
        scanQueue.isPending
    }

    var skippedLibraries: [LibraryRecord] {
        libraries.filter { record in
            !record.isScanning && !record.isQueued
                && !isLibraryIgnored(record)
                && knownCleanableSize(for: record) < Self.minimumCleanableSize
        }
    }

    var ignoredLibraries: [LibraryRecord] {
        libraries.filter { record in
            !record.isScanning && !record.isQueued && isLibraryIgnored(record)
        }
    }

    var filteredLibraries: [LibraryRecord] {
        let base: [LibraryRecord]
        switch libraryFilter {
        case .waiting:
            base = selectedVolumeURL == nil ? waitingLibraries : waitingLibraries.filter { $0.volumeURL == selectedVolumeURL }
        case .scanning: base = scanningLibraries
        case .skipped: base = skippedLibraries
        case .ignored:
            base = selectedVolumeURL == nil ? ignoredLibraries : ignoredLibraries.filter { $0.volumeURL == selectedVolumeURL }
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

    var countsByFilter: [LibraryFilter: Int] {
        var counts: [LibraryFilter: Int] = [
            .waiting: 0,
            .scanning: 0,
            .skipped: 0,
            .ignored: 0
        ]
        for record in libraries {
            guard matchesInactivity(record) else { continue }
            if record.isScanning || record.isQueued {
                counts[.scanning, default: 0] += 1
            } else if isLibraryIgnored(record) {
                counts[.ignored, default: 0] += 1
            } else if knownCleanableSize(for: record) >= Self.minimumCleanableSize {
                counts[.waiting, default: 0] += 1
            } else {
                counts[.skipped, default: 0] += 1
            }
        }
        return counts
    }

    func count(for filter: LibraryFilter) -> Int {
        countsByFilter[filter] ?? 0
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
        if !cleanableIDs.isEmpty && cleanableIDs.isSubset(of: batchSelectedIDs) {
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
        if workDirectoryMonitor == nil { workDirectoryMonitor = WorkDirectoryMonitor(store: self) }
        workDirectoryMonitor?.updateWatched(paths: workDirectories.map(\.path))
        if volumeMountMonitor == nil { volumeMountMonitor = VolumeMountMonitor(store: self) }
        volumeMountMonitor?.start()
        flushRecentsOnTermination()
        pruneOrphanedCaches()
        scheduledCheckController.restart()
        reconcileInterruptedCleanup()
        scheduleSnoozeExpiryRefresh()

        for library in libraries where library.scanResult == nil && !library.isScanning && !isLibraryIgnored(library) {
            scan(library, force: false)
        }
        discoverLibraries()
    }

    /// 按筛选档缓存的截止时刻：Calendar.date(byAdding:) 单次微秒级，但
    /// filteredLibraries/countsByFilter 每次渲染都会对全部记录各调一次，
    /// 截止值在渲染帧内不变，缓存后整轮只剩一次日历运算。
    @ObservationIgnored private var inactivityCutoffCache: (filter: InactivityFilter, cutoff: Date)?

    private func inactivityCutoff() -> Date? {
        guard inactivityFilter != .all else { return nil }
        let now = Date()
        if let inactivityCutoffCache,
           inactivityCutoffCache.filter == inactivityFilter,
           now.timeIntervalSince(inactivityCutoffCache.cutoff) < 60 {
            return inactivityCutoffCache.cutoff
        }
        let cutoff = Calendar.current.date(byAdding: .day, value: -inactivityFilter.rawValue, to: now) ?? now
        inactivityCutoffCache = (inactivityFilter, cutoff)
        return cutoff
    }

    private func matchesInactivity(_ record: LibraryRecord) -> Bool {
        guard let cutoff = inactivityCutoff() else { return true }
        guard let lastActivity = record.lastActivity else { return true }
        return lastActivity <= cutoff
    }

    private func filter(for record: LibraryRecord) -> LibraryFilter {
        if record.isScanning || record.isQueued { return .scanning }
        if isLibraryIgnored(record) { return .ignored }
        return knownCleanableSize(for: record) >= Self.minimumCleanableSize ? .waiting : .skipped
    }

}

/// 后台发现流程取齐的建档元数据；已入库 URL 的字段为 nil（复用现有记录，不再探测）。
struct ValidatedLibraryCandidate: Sendable {
    let url: URL
    var volumeURL: URL? = nil
    var volumeName: String? = nil
    var volumeID: String? = nil
    var lastActivity: Date? = nil
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

struct ScanHealthSummary: Sendable {
    let total: Int
    let scanned: Int
    let cacheReused: Int
    let failed: [String]
    let neverScanned: Int
}

struct WorkDirectoryStatus: Sendable {
    let discoveredCount: Int
    let failed: Bool
    let updatedAt: Date
}

struct DiskSpaceWarning: Identifiable {
    var id: URL { volumeURL }
    let volumeURL: URL
    let name: String
    let availableSize: Int64
    let cleanableSize: Int64
}

struct VolumeAccessReport: Identifiable {
    var id: URL { libraryURL }
    let libraryURL: URL
    let volumeName: String?
    let mounted: Bool
    let writable: Bool
    let checkedAt: Date
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
