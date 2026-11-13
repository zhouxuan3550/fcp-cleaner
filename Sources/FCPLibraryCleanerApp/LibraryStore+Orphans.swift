import AppKit
import Foundation
import UniformTypeIdentifiers
import FCPLibraryCleanerCore

// MARK: - 忽略/稍后、孤儿缓存清理、健康摘要、诊断导出与存档
extension LibraryStore {
    // MARK: 忽略与稍后（仅作用于发现/列表分层，绝不进入清理链路）

    private func ignoredDirectoryPrefixes() -> [String] {
        if let ignoredPrefixCache, ignoredPrefixCache.source == ignoredLibraryDirectories {
            return ignoredPrefixCache.prefixes
        }
        let prefixes = ignoredLibraryDirectories.map { path -> String in
            let standardized = path.standardizedFilePath
            return standardized.hasSuffix("/") ? standardized : standardized + "/"
        }
        ignoredPrefixCache = (ignoredLibraryDirectories, prefixes)
        return prefixes
    }

    func isLibraryIgnored(_ record: LibraryRecord) -> Bool {
        if LibraryIgnoreRules.isSnoozed(until: record.ignoredUntil) { return true }
        // record.url 建档时已标准化，绝对路径的波浪号展开是恒等操作，直接前缀比较。
        let path = record.url.path
        return ignoredDirectoryPrefixes().contains { path.hasPrefix($0) }
    }

    /// 行操作「7 天内不再提醒」：到期后自动回到原分层。
    func snoozeLibrary(_ record: LibraryRecord, days: Int = LibraryIgnoreRules.defaultSnoozeDays) {
        record.ignoredUntil = Calendar.current.date(byAdding: .day, value: days, to: Date())
        reconcileFilteredLibraries()
        saveRecents()
        scheduleSnoozeExpiryRefresh()
    }

    func resumeLibrary(_ record: LibraryRecord) {
        record.ignoredUntil = nil
        // 处于目录级忽略中的库被显式恢复时，连同所在目录一起解除，
        // 否则该库会立即被目录规则重新吞回"已忽略"。
        if let directory = ignoredLibraryDirectories.first(where: {
            LibraryIgnoreRules.isInsideIgnoredDirectory(recordPath: record.url.path, directoryPaths: [$0])
        }) {
            ignoredLibraryDirectories.removeAll { $0 == directory }
        }
        reconcileFilteredLibraries()
        saveRecents()
        scheduleSnoozeExpiryRefresh()
    }

    func ignoreDirectory(_ url: URL) {
        let path = url.standardizedFileURL.path
        guard !ignoredLibraryDirectories.contains(path) else { return }
        ignoredLibraryDirectories.append(path)
        reconcileFilteredLibraries()
        saveRecents()
    }

    func resumeDirectory(_ path: String) {
        ignoredLibraryDirectories.removeAll { $0 == path }
        reconcileFilteredLibraries()
        saveRecents()
    }

    func scheduleSnoozeExpiryRefresh() {
        snoozeExpiryTask?.cancel()
        let now = Date()
        for record in libraries where record.ignoredUntil.map({ $0 <= now }) == true {
            record.ignoredUntil = nil
        }
        guard let nextExpiry = libraries.compactMap(\.ignoredUntil).filter({ $0 > now }).min() else {
            snoozeExpiryTask = nil
            return
        }
        snoozeExpiryTask = Task { [weak self] in
            let delay = max(0, nextExpiry.timeIntervalSinceNow)
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            scheduleSnoozeExpiryRefresh()
            reconcileFilteredLibraries()
            saveRecents()
        }
    }

    /// 启动卫生：清扫已不在列表中的扫描缓存文件与体积趋势样本。
    /// 全部后台执行；键为路径哈希，只按集合差比对，绝不触碰现役条目。
    func pruneOrphanedCaches() {
        let currentURLs = libraries.map(\.url)
        let scanCache = scanCache
        Task {
            await scanCache.prune(keeping: currentURLs)
        }
        LibrarySizeTrend.prune(keepingKeys: Set(currentURLs.map { LibrarySizeTrend.key(for: $0) }))
    }

    /// 扫描健康度：让"自动扫描是否真正完成"不依赖日志即可判断。
    var scanHealthSummary: ScanHealthSummary {
        let failed = libraries.filter { $0.scanError != nil }.map(\.displayName)
        return ScanHealthSummary(
            total: libraries.count,
            scanned: libraries.count(where: { $0.scanResult != nil }),
            cacheReused: libraries.count(where: { $0.usedCachedScan }),
            failed: failed,
            neverScanned: libraries.count(where: { $0.scanResult == nil && $0.scanError == nil && !$0.isScanning && !$0.isQueued })
        )
    }

    var totalCleanableSize: Int64 {
        libraries.reduce(Int64(0)) { partial, record in
            let size = effectiveCleanableSize(for: record)
            return size >= Self.minimumCleanableSize ? partial + size : partial
        }
    }

    func showMainWindow() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        if let window = NSApplication.shared.windows.first(where: { $0.title == "FCP Cleaner" || $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        }
    }

    func requestMenuBarCleanup() {
        guard !isPreflighting, !isCleaning else { return }
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

    /// 诊断包：菜单项「导出诊断信息」→ 保存面板 → 后台收集打包。
    /// 内存态快照在主线程取值，日志、zip 等 I/O 全部后台执行。
    func exportDiagnostics() {
        guard !isExportingDiagnosticsInternal else { return }
        let panel = NSSavePanel()
        panel.title = "导出诊断信息"
        panel.nameFieldStringValue = DiagnosticsWriter.suggestedFileName()
        panel.allowedContentTypes = [UTType.zip]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        isExportingDiagnosticsInternal = true
        let volumeReports = libraries.map { record in
            VolumeDiagnosticsEntry(
                libraryName: record.displayName,
                libraryPath: record.url.path,
                volumeName: record.volumeName,
                mounted: record.accessReport?.mounted,
                writable: record.accessReport?.writable,
                checkedAt: record.accessReport?.checkedAt,
                lastAccessibleAt: record.lastAccessibleAt,
                lastKnownTotalSize: record.lastKnownTotalSize,
                lastKnownCleanableSize: record.lastKnownCleanableSize,
                scanError: record.scanError,
                cleanupError: record.cleanupError
            )
        }
        let bookmarkStatus = bookmarks.statusReport()
        let failures = cleanupHistory.recentFailures()
        let libraryCount = libraries.count
        let health = scanHealthSummary

        Task {
            let outcome = await Task.detached(priority: .utility) {
                let logText = DiagnosticsWriter.collectRecentLog()
                let systemInfo = DiagnosticsWriter.systemInfo(libraryCount: libraryCount, scanHealth: health)
                return DiagnosticsWriter.writeBundle(
                    to: destination,
                    logText: logText,
                    volumeReports: volumeReports,
                    bookmarkStatus: bookmarkStatus,
                    failures: failures,
                    systemInfo: systemInfo
                )
            }.value
            isExportingDiagnosticsInternal = false
            switch outcome {
            case .success:
                showCleanupNotice(CleanupNotice(
                    title: "诊断信息已导出",
                    libraryCount: 0,
                    freedSize: 0,
                    cleanedItemCount: 0,
                    categories: [],
                    errorCount: 0,
                    errorMessage: nil
                ))
            case .failure(let message):
                showCleanupNotice(CleanupNotice(
                    title: "诊断信息导出失败",
                    libraryCount: 0,
                    freedSize: 0,
                    cleanedItemCount: 0,
                    categories: [],
                    errorCount: 1,
                    errorMessage: message
                ))
            }
        }
    }

    /// 扫描完成、清理落账、忽略切换都会触发存档，突发时可达每秒十余次；
    /// 防抖合并后每次状态风暴只做一次书签编码与 UserDefaults 写入，
    /// 退出前（willTerminate）强制落盘，崩溃最多丢最后一次元数据快照。
    func saveRecents() {
        saveRecentsTask?.cancel()
        saveRecentsTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            self.saveRecentsNow()
        }
    }

    private func saveRecentsNow() {
        saveRecentsTask?.cancel()
        saveRecentsTask = nil
        bookmarks.save(currentRecentsMetadata())
    }

    /// 应用退出时把尚未落盘的元数据立即写入，避免防抖窗口内的变更丢失。
    func flushRecentsOnTermination() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.saveRecentsNow()
            }
        }
    }

    func currentRecentsMetadata() -> [RecentLibraryMetadata] {
        libraries.map {
            RecentLibraryMetadata(
                url: $0.url,
                lastScanned: $0.lastScanned,
                totalAllocatedSize: $0.lastKnownTotalSize,
                cleanableSize: $0.lastKnownCleanableSize,
                lastActivity: $0.lastActivity,
                discoverySourceRaw: $0.discoverySource?.rawValue,
                volumeUUIDRaw: $0.volumeID,
                ignoredUntil: $0.ignoredUntil
            )
        }
    }
}
