import Foundation
import FCPLibraryCleanerCore

// MARK: - 清理请求、中断恢复、预检与执行
extension LibraryStore {
    func requestClean(_ record: LibraryRecord) {
        guard !isPreflighting, !isCleaning else { return }
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

    var canRescanSelectedLibrary: Bool {
        guard let selected = selectedLibrary else { return false }
        return !selected.isScanning && !selected.isQueued
    }

    var canRequestCleanupForSelection: Bool {
        guard !isPreflighting, !isCleaning, !isBatchCleaning else { return false }
        if !batchSelectedIDs.isEmpty { return true }
        guard let selected = selectedLibrary else { return false }
        return selected.scanResult != nil
            && selected.spaceToFree >= Self.minimumCleanableSize
            && !selected.isScanning
    }

    var hasSelectableBatchCandidates: Bool {
        !batchCleanableLibraries.isEmpty && !isPreflighting && !isCleaning && !isBatchCleaning
    }

    func requestRetry(_ record: LibraryRecord) {
        guard !isPreflighting, !isCleaning else { return }
        guard let plan = record.failedCleanupPlan else { return }
        preflight(record: record, plan: plan, isRetry: true)
    }

    // MARK: 中断事务恢复（P4-7）

    /// 启动及每次清理收尾时对账：依据事务日志与清理历史的差集重建待清计划。
    /// 磁盘存在性检查在后台执行（外置盘可能离线），绝不上主线程。
    func reconcileInterruptedCleanup() {
        interruptedReconciliationID = UUID()
        let reconciliationID = interruptedReconciliationID
        guard let transaction = cleanupJournal.load() else {
            if !interruptedCleanups.isEmpty { interruptedCleanups = [] }
            return
        }
        // 历史里已记录移入废纸篓的原始路径视为"已完成"
        let completedURLs = Set(cleanupHistory.entries.flatMap { $0.trashedItems.map(\.originalURL) })
        let plans = transaction.plans
        let startedAt = transaction.startedAt
        Task { [weak self] in
            let summaries = await Task.detached(priority: .utility) {
                Self.resolvePending(from: plans, startedAt: startedAt, completedURLs: completedURLs)
            }.value
            guard let self, reconciliationID == interruptedReconciliationID else { return }
            interruptedCleanups = summaries
            if summaries.isEmpty { cleanupJournal.clear() }
        }
    }

    nonisolated private static func resolvePending(
        from plans: [CleanupPlan],
        startedAt: Date,
        completedURLs: Set<URL>
    ) -> [InterruptedCleanupSummary] {
        var summaries: [InterruptedCleanupSummary] = []
        for plan in plans {
            guard let pendingPlan = plan.planForPendingEntries(
                exists: { FileManager.default.fileExists(atPath: $0.path) },
                isCompleted: { completedURLs.contains($0) }
            ) else { continue }
            summaries.append(InterruptedCleanupSummary(
                startedAt: startedAt,
                libraryName: plan.libraryURL.deletingPathExtension().lastPathComponent,
                libraryURL: plan.libraryURL,
                plan: pendingPlan
            ))
        }
        return summaries
    }

    /// 历史页入口：重建的待清计划走与普通清理完全相同的预检 + 用户确认流程，
    /// 绝不自动清理（产品红线）。
    func rebuildInterruptedCleanup(_ summary: InterruptedCleanupSummary) {
        guard !isPreflighting, !isCleaning, !isBatchCleaning else { return }
        guard let record = libraries.first(where: {
            $0.url.standardizedFileURL == summary.libraryURL.standardizedFileURL
        }) else {
            showCleanupNotice(CleanupNotice(
                title: "无法重建待清计划",
                libraryCount: 1,
                freedSize: 0,
                cleanedItemCount: 0,
                categories: [],
                errorCount: 1,
                errorMessage: "资源库「\(summary.libraryName)」当前不在线或已从列表移除，请先连接磁盘"
            ))
            return
        }
        preflight(record: record, plan: summary.plan, isRetry: false)
    }

    func discardInterruptedCleanup(_ summary: InterruptedCleanupSummary) {
        interruptedCleanups.removeAll { $0.id == summary.id }
        cleanupJournal.finish(libraryURLs: [summary.libraryURL])
        reconcileInterruptedCleanup()
    }

    func requestBatchClean() {
        guard !isPreflighting, !isCleaning else { return }
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
            // 移动大目录期间避免系统休眠/节流
            let batchActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep],
                reason: "FCP Cleaner 批量预检与清理"
            )
            defer { ProcessInfo.processInfo.endActivity(batchActivity) }
            var failure: (Error, LibraryRecord)?
            for entry in entries {
                do {
                    try await cleanupCoordinator.preflight(entry.plan)
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
                try await cleanupCoordinator.preflight(plan)
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
        record?.cleanupError = message
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
        guard !isCleaning else { return }
        batchCleanConfirmation = nil
        isBatchCleaning = true
        isCleaning = true
        batchCleanupCompleted = 0
        batchCleanupTotal = confirmation.entries.count
        // 批量事务一并落盘，中断后按库分组重建
        cleanupJournal.begin(plans: confirmation.entries.map(\.plan))
        Task {
            let batchStart = ContinuousClock.now
            var freedSize: Int64 = 0
            var cleanedItemCount = 0
            var errorCount = 0
            var firstErrorMessage: String?
            var categories = Set<CacheCategory>()
            var recordsToRescan: [LibraryRecord] = []
            var summaryLibraries: [CleanupSummaryLibrary] = []
            for entry in confirmation.entries {
                let record = entry.record
                record.cleanupBeforeSize = record.scanResult?.totalAllocatedSize
                record.cleanupAfterSize = nil
                do {
                    let result = try await cleanupCoordinator.execute(entry.plan, volumeID: entry.record.volumeID)
                    record.lastCleanup = result
                    applyImmediateCleanupDelta(record, freed: result.freedAllocatedSize)
                    cleanupHistory.append(libraryName: record.displayName, libraryURL: record.url, plan: entry.plan, result: result)
                    record.failedCleanupPlan = result.errors.isEmpty
                        ? nil
                        : entry.plan.retryingItemsNotCompleted(in: result)
                    freedSize += result.freedAllocatedSize
                    cleanedItemCount += result.movedToTrash.count
                    errorCount += result.errors.count
                    firstErrorMessage = firstErrorMessage ?? result.errors.first?.localizedDescription
                    categories.formUnion(entry.plan.entries.map(\.item.category))
                    record.cleanupError = result.errors.isEmpty
                        ? nil
                        : result.errors.map(\.localizedDescription).joined(separator: "\n")
                    recordsToRescan.append(record)
                    summaryLibraries.append(CleanupSummaryLibrary(
                        name: record.displayName,
                        freedSize: result.freedAllocatedSize,
                        itemCount: result.movedToTrash.count,
                        errorCount: result.errors.count,
                        errorMessage: result.errors.first?.localizedDescription,
                        succeeded: result.errors.isEmpty
                    ))
                } catch {
                    errorCount += 1
                    firstErrorMessage = firstErrorMessage ?? error.localizedDescription
                    record.failedCleanupPlan = entry.plan
                    record.cleanupError = error.localizedDescription
                    cleanupHistory.appendFailure(libraryName: record.displayName, libraryURL: record.url, plan: entry.plan, error: error)
                    summaryLibraries.append(CleanupSummaryLibrary(
                        name: record.displayName,
                        freedSize: 0,
                        itemCount: 0,
                        errorCount: 1,
                        errorMessage: error.localizedDescription,
                        succeeded: false
                    ))
                }
                batchCleanupCompleted += 1
            }
            let batchElapsed = ContinuousClock.now - batchStart
            let batchSeconds = Double(batchElapsed.components.seconds) + Double(batchElapsed.components.attoseconds) / 1e18
            batchSelectedIDs.removeAll()
            isBatchCleaning = false
            isCleaning = false
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
            cleanupSummary = CleanupSummary(
                title: "批量清理完成",
                libraryCount: confirmation.entries.count,
                totalFreedSize: freedSize,
                totalItemCount: cleanedItemCount,
                categories: categories,
                errorCount: errorCount,
                errorMessage: firstErrorMessage,
                elapsedSeconds: batchSeconds,
                libraries: summaryLibraries
            )
            NotificationController.shared.cleanupFinished(
                freedSize: freedSize,
                libraryCount: confirmation.entries.count,
                errorCount: errorCount,
                enabled: notificationsEnabled
            )
            cleanupJournal.finish(libraryURLs: Set(confirmation.entries.map { $0.plan.libraryURL }))
            reconcileInterruptedCleanup()
        }
    }

    func performConfirmedCleanup(_ confirmation: CleanConfirmation) {
        guard !isCleaning else { return }
        cleanConfirmation = nil
        isCleaning = true
        let record = confirmation.record
        record.cleanupBeforeSize = record.scanResult?.totalAllocatedSize
        record.cleanupAfterSize = nil
        // 事务日志先于执行落盘：崩溃/断电后可依据它与重扫差集重建待清计划
        cleanupJournal.begin(plans: [confirmation.plan])
        Task {
            // 单库清理同样不可被节流打断
            let cleanActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep],
                reason: "FCP Cleaner 清理资源库"
            )
            defer { ProcessInfo.processInfo.endActivity(cleanActivity) }
            do {
                let result = try await cleanupCoordinator.execute(confirmation.plan, volumeID: record.volumeID)
                record.lastCleanup = result
                applyImmediateCleanupDelta(record, freed: result.freedAllocatedSize)
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
                record.cleanupError = result.errors.isEmpty
                    ? nil
                    : result.errors.map(\.localizedDescription).joined(separator: "\n")
                scan(record, preserveLastCleanup: true, force: true)
                NotificationController.shared.cleanupFinished(
                    freedSize: result.freedAllocatedSize,
                    libraryCount: 1,
                    errorCount: result.errors.count,
                    enabled: notificationsEnabled
                )
            } catch {
                record.cleanupError = error.localizedDescription
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
            // 事务已有结局（成功或已记录的失败），日志使命完成
            cleanupJournal.finish(libraryURLs: [confirmation.plan.libraryURL])
            reconcileInterruptedCleanup()
            isCleaning = false
        }
    }

    func remove(_ records: [LibraryRecord]) {
        let ids = Set(records.map(\.id))
        let removedURLs = records.map(\.url)
        for record in records {
            scanQueue.removePending(record)
            record.scanControl?.cancel()
            record.eventRefreshTask?.cancel()
            record.liveEvents = nil
            record.eventWatchID = UUID()
        }
        libraries.removeAll { ids.contains($0.id) }
        batchSelectedIDs.subtract(ids)
        selectedID = nil
        reconcileFilteredLibraries()
        saveRecents()
        // 缓存清理与列表变更解耦：慢盘上删除文件也不阻塞界面。
        let scanCache = scanCache
        Task {
            for url in removedURLs {
                await scanCache.removeCache(for: url)
            }
        }
    }

    func reconcileFilteredLibraries() {
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

    /// 待清理列表中周增长最大者（须为正增长），供列表突出显示。
    var fastestGrowingLibraryID: LibraryRecord.ID? {
        let records = waitingLibraries
        let growthByURL = LibrarySizeTrend.weeklyGrowthByLibrary(records.map(\.url))
        var bestID: LibraryRecord.ID?
        var bestGrowth: Int64 = 0
        for record in records {
            guard let growth = growthByURL[record.url.standardizedFileURL], growth > bestGrowth else { continue }
            bestGrowth = growth
            bestID = record.id
        }
        return bestID
    }

    func effectiveCleanableSize(for record: LibraryRecord) -> Int64 {
        let base = knownCleanableSize(for: record)
        let penalty = record.scanResult != nil ? record.pendingFreedSize : 0
        return max(0, base - penalty)
    }

    func estimatedCleanupDuration(forBytes bytes: Int64, volumeID: String?) -> Double? {
        guard let volumeID,
              let bytesPerSecond = CleanupThroughputStore.averageBytesPerSecond(volumeID: volumeID),
              bytesPerSecond > 0 else { return nil }
        return Double(bytes) / bytesPerSecond
    }

    /// Batch ETA sums per-entry estimates; nil when any involved volume lacks history.
    func estimatedBatchCleanupDuration(entries: [(bytes: Int64, volumeID: String?)]) -> Double? {
        guard !entries.isEmpty else { return nil }
        var total = 0.0
        for entry in entries {
            guard let duration = estimatedCleanupDuration(forBytes: entry.bytes, volumeID: entry.volumeID) else {
                return nil
            }
            total += duration
        }
        return total
    }

    private func applyImmediateCleanupDelta(_ record: LibraryRecord, freed: Int64) {
        guard freed > 0 else { return }
        record.pendingFreedSize += freed
        let known = record.lastKnownCleanableSize ?? knownCleanableSize(for: record)
        record.lastKnownCleanableSize = max(0, known - freed)
        if let total = record.lastKnownTotalSize {
            record.lastKnownTotalSize = max(0, total - freed)
        }
        saveRecents()
    }
}
