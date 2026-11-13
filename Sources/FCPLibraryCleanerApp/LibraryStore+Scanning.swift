import Foundation
import FCPLibraryCleanerCore

// MARK: - 扫描队列与执行
extension LibraryStore {
    func scan(_ record: LibraryRecord, preserveLastCleanup: Bool = false, force: Bool = true) {
        guard !record.isScanning else { return }
        scanQueue.enqueue(record, preserveLastCleanup: preserveLastCleanup, force: force)
        drainScanQueue()
    }

    func drainScanQueue() {
        while let request = scanQueue.takeNext(preferredID: selectedID) {
            startScan(request)
        }
    }

    private func startScan(_ request: ScanRequest) {
        let record = request.record
        record.eventRefreshTask?.cancel()
        record.liveEvents = nil
        record.eventRefreshPending = false
        let watchID = UUID()
        record.eventWatchID = watchID
        record.isQueued = false
        let control = ScanControl()
        record.scanControl = control
        record.isScanning = true
        record.usedCachedScan = false
        record.scanProgress = ScanProgress(files: 0, directories: 0, allocatedBytes: 0)
        record.scanPartialResults = nil
        record.scanError = nil
        if !request.preserveLastCleanup {
            record.lastCleanup = nil
            record.failedCleanupPlan = nil
            record.cleanupError = nil
        }
        record.inspectorReport = nil
        Task { [weak self, weak record] in
            guard let self, let record else { return }
            // 防止 App Nap 节流长扫描（笔记本合盖场景下吞吐会莫名劣化）
            let scanActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep],
                reason: "FCP Cleaner 扫描资源库"
            )
            defer { ProcessInfo.processInfo.endActivity(scanActivity) }
            do {
                let result: LibraryScanResult
                var scannedFresh = false
                var checkpoint: FSEventsCheckpoint?
                if !request.force, let live = await scanCache.loadWithLiveEvents(libraryURL: record.url, control: control, onChange: { [weak self, weak record] in
                    Task { @MainActor [weak self, weak record] in
                        guard let self, let record, !control.isCancelled else { return }
                        self.liveCacheChanged(record, watchID: watchID)
                    }
                }) {
                    if control.isCancelled { throw CancellationError() }
                    result = live.result
                    record.liveEvents = live.lease
                    record.usedCachedScan = true
                } else if !request.force, let cached = await scanCache.loadIfCurrent(libraryURL: record.url, control: control) {
                    if control.isCancelled { throw CancellationError() }
                    result = cached
                    record.usedCachedScan = true
                } else {
                    let checkpointURL = record.url
                    checkpoint = await Task.detached(priority: .utility) {
                        FSEventsCheckpoint.capture(libraryURL: checkpointURL)
                    }.value
                    let progressCoalescer = ScanProgressCoalescer<ScanProgress>()
                    let partialCoalescer = ScanProgressCoalescer<ScanPartialResults>()
                    result = try await LibraryScanner().scan(
                        libraryURL: record.url,
                        control: control,
                        onProgress: { [weak record] progress in
                            if let merged = progressCoalescer.consume(progress) {
                                Task { @MainActor [weak record] in
                                    guard let record, record.isScanning, record.scanControl === control, !control.isCancelled else { return }
                                    record.scanProgress = merged
                                }
                            }
                        },
                        onPartialResults: { [weak record] partial in
                            if let merged = partialCoalescer.consume(partial, force: partial.completedDirectories == partial.totalDirectories) {
                                Task { @MainActor [weak record] in
                                    record?.acceptPartialResults(merged, control: control)
                                }
                            }
                        }
                    )
                    scannedFresh = true
                }
                record.scanResult = result
                record.lastScanned = Date()
                record.lastKnownTotalSize = record.scanResult?.totalAllocatedSize
                record.lastKnownCleanableSize = record.scanResult?.confirmedCleanableSize
                // stat 可能落在网络卷上，绝不放主线程；结果只在下一帧呈现，无一致性风险。
                let activityURL = record.url
                record.lastActivity = await Task.detached(priority: .utility) {
                    LibraryRecord.activityDate(for: activityURL)
                }.value
                record.lastAccessibleAt = Date()
                // Persisting the cache costs a second traversal plus an atomic write, so it
                // must never sit between a finished scan and the UI showing its result.
                if scannedFresh {
                    let scanCache = scanCache
                    let freshResult = result
                    let freshCheckpoint = checkpoint
                    Task { await scanCache.save(freshResult, checkpoint: freshCheckpoint) }
                }
                LibrarySizeTrend.record(
                    libraryURL: record.url,
                    totalAllocatedSize: result.totalAllocatedSize,
                    cleanableSize: result.confirmedCleanableSize
                )
                saveRecents()
                evaluateLowSpace()
                if request.preserveLastCleanup, record.lastCleanup != nil {
                    record.cleanupAfterSize = record.scanResult?.totalAllocatedSize
                }
                record.pendingFreedSize = 0
            } catch is CancellationError {
                record.scanError = nil
            } catch {
                record.scanError = error.localizedDescription
                record.scanResult = nil
                record.pendingFreedSize = 0
            }
            record.isScanning = false
            if record.eventRefreshPending && record.liveEvents != nil { record.scanResult = nil }
            record.scanPartialResults = nil
            record.scanControl = nil
            scanQueue.finish(record)
            reconcileFilteredLibraries()
            drainScanQueue()
        }
    }

    func cancelScan(_ record: LibraryRecord) {
        if scanQueue.removePending(record) {
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
                record.scanError = error.localizedDescription
            }
            record.isInspecting = false
        }
    }
}
