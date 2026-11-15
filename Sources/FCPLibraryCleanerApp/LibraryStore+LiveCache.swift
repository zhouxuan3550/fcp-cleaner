import AppKit

import Foundation

import UniformTypeIdentifiers

import FCPLibraryCleanerCore



// MARK: - 实时缓存失效、低空间监控、定时检查、通知与卷热插拔

extension LibraryStore {

    func liveCacheChanged(_ record: LibraryRecord, watchID: UUID) {

        guard libraries.contains(where: { $0.id == record.id }), record.acceptLiveCacheChange(watchID: watchID) else { return }

        record.eventRefreshTask?.cancel()

        record.eventRefreshTask = Task { [weak self, weak record] in

            try? await Task.sleep(for: .seconds(1))

            while !Task.isCancelled {

                guard let self, let record, record.eventWatchID == watchID,

                      self.libraries.contains(where: { $0.id == record.id }) else { return }

                if !record.isScanning && !self.isCleaning && !self.isBatchCleaning && !self.isPreflighting {

                    guard record.eventRefreshPending else { return }

                    record.eventRefreshPending = false

                    self.scan(record, force: true)

                    return

                }

                try? await Task.sleep(for: .seconds(1))

            }

        }

    }



    /// 卷容量探测全部在后台执行——网络卷上这类调用可能阻塞数秒，绝不能上主线程。

    func evaluateLowSpace() {

        if isEvaluatingLowSpace {

            needsLowSpaceReevaluation = true

            return

        }

        isEvaluatingLowSpace = true

        let threshold = Int64(lowSpaceWarningGB) * 1_024 * 1_024 * 1_024

        let volumeURLs = Array(Set(libraries.map(\.volumeURL)))

        let nameByVolume = Dictionary(libraries.map { ($0.volumeURL, $0.volumeName) }, uniquingKeysWith: { first, _ in first })

        let cleanableByVolume = Dictionary(grouping: libraries, by: \.volumeURL)

            .mapValues { $0.reduce(Int64(0)) { $0 + $1.spaceToFree } }

        Task { [weak self] in

            let lowSpaces = await Task.detached(priority: .utility) {

                Self.probeVolumeAvailability(volumeURLs, threshold: threshold)

            }.value

            guard let self else { return }

            isEvaluatingLowSpace = false

            applyLowSpaceResults(

                lowSpaces,

                nameByVolume: nameByVolume,

                cleanableByVolume: cleanableByVolume

            )

            if needsLowSpaceReevaluation {

                needsLowSpaceReevaluation = false

                evaluateLowSpace()

            }

        }

    }



    nonisolated private static func probeVolumeAvailability(

        _ volumeURLs: [URL],

        threshold: Int64

    ) -> [(volumeURL: URL, availableSize: Int64)] {

        volumeURLs.compactMap { volumeURL in

            guard let values = try? volumeURL.resourceValues(forKeys: [

                .volumeAvailableCapacityForImportantUsageKey,

                .volumeAvailableCapacityKey,

            ]),

                let available = values.volumeAvailableCapacityForImportantUsage

                    ?? values.volumeAvailableCapacity.map(Int64.init),

                available < threshold else { return nil }

            return (volumeURL, available)

        }

    }



    private func applyLowSpaceResults(

        _ lowSpaces: [(volumeURL: URL, availableSize: Int64)],

        nameByVolume: [URL: String],

        cleanableByVolume: [URL: Int64]

    ) {

        var warnings: [DiskSpaceWarning] = []

        for item in lowSpaces {

            let name = nameByVolume[item.volumeURL] ?? item.volumeURL.lastPathComponent

            let cleanable = cleanableByVolume[item.volumeURL] ?? 0

            warnings.append(DiskSpaceWarning(

                volumeURL: item.volumeURL,

                name: name,

                availableSize: item.availableSize,

                cleanableSize: cleanable

            ))

            let lastNotification = lastLowSpaceNotification[item.volumeURL] ?? .distantPast

            if cleanable >= Self.minimumCleanableSize, Date().timeIntervalSince(lastNotification) > 86_400 {

                NotificationController.shared.lowSpace(

                    volumeName: name,

                    availableSize: item.availableSize,

                    cleanableSize: cleanable,

                    enabled: notificationsEnabled

                )

                lastLowSpaceNotification[item.volumeURL] = Date()

            }

        }

        lowSpaceWarnings = warnings.sorted { $0.availableSize < $1.availableSize }

    }



    func startSpaceMonitoring() {

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



    /// 仪表盘：各卷压力（可用容量 + 可清理合计）。探测全部后台执行。

    struct VolumePressure: Identifiable {

        let id: URL

        let name: String

        let available: Int64?

        let cleanable: Int64

    }



    func volumePressures() async -> [VolumePressure] {

        let grouped = Dictionary(grouping: libraries, by: \ .volumeURL)

        let names = Dictionary(libraries.map { ($0.volumeURL, $0.volumeName) }, uniquingKeysWith: { first, _ in first })

        let probes = await Task.detached(priority: .utility) {

            grouped.keys.compactMap { url -> (URL, Int64?)? in

                guard let values = try? url.resourceValues(forKeys: [

                    .volumeAvailableCapacityForImportantUsageKey,

                    .volumeAvailableCapacityKey,

                ]) else { return nil }

                let available = values.volumeAvailableCapacityForImportantUsage

                    ?? values.volumeAvailableCapacity.map(Int64.init)

                return (url, available)

            }

        }.value

        return probes.compactMap { url, available in

            guard let name = names[url] else { return nil }

            let cleanable = (grouped[url] ?? []).reduce(Int64(0)) { $0 + $1.spaceToFree }

            return VolumePressure(id: url, name: name, available: available, cleanable: cleanable)

        }

        .sorted { ($0.available ?? .max) < ($1.available ?? .max) }

    }



    /// 仪表盘：最近 7 天释放总量（来自清理历史内存态）。

    var weeklyFreedSize: Int64 {

        let cutoff = Date().addingTimeInterval(-7 * 86_400)

        return cleanupHistory.entries

            .filter { $0.date >= cutoff }

            .reduce(Int64(0)) { $0 + $1.freedSize }

    }



    /// 仪表盘：现在最值得清理的候选。

    /// 推荐分 = 可清理体积 × 久未使用 × 卷压力（可用越少权重越高）；

    /// 纯排序启发式——只为把最值得看的排前面，绝不代表任何自动清理。

    func topCleanupCandidates(pressures: [VolumePressure]) -> [LibraryRecord] {

        let availableByVolume = Dictionary(

            uniqueKeysWithValues: pressures.compactMap { pressure in

                pressure.available.map { (pressure.id, $0) }

            }

        )

        return waitingLibraries

            .filter { $0.scanResult != nil }

            .sorted { rank($0, availableByVolume: availableByVolume) > rank($1, availableByVolume: availableByVolume) }

            .prefix(3)

            .map(\.self)

    }



    private func rank(_ record: LibraryRecord, availableByVolume: [URL: Int64]) -> Double {

        let size = Double(effectiveCleanableSize(for: record))

        let ageDays = record.lastActivity.map { Date().timeIntervalSince($0) / 86_400 } ?? 90

        let recency = 0.5 + min(max(ageDays, 0) / 30, 3)      // 未用越久权重越高，封顶 3.5

        let pressure = availableByVolume[record.volumeURL].map {

            1 + max(0, 1 - Double($0) / 20_000_000_000)       // 可用 <20GB 时逐步加权，封顶 2

        } ?? 1

        return size * recency * pressure

    }



    /// 定时检查：自动发现 + 全库增量扫描 + 完成通知。

    /// 产品红线：本路径绝不创建清理计划、绝不调用 CleanupEngine。

    func runScheduledCheck() async {

        discoverLibraries()

        let deadline = Date().addingTimeInterval(900)

        while (isDiscovering || pendingMergeCount > 0), Date() < deadline {

            try? await Task.sleep(for: .seconds(1))

            guard !Task.isCancelled else { return }

        }

        for record in libraries where !isLibraryIgnored(record) {

            scan(record, force: false)

        }

        // 等待扫描队列静默（上限 15 分钟），扫描本身已在后台并发执行

        while scanQueue.isPending, Date() < deadline {

            try? await Task.sleep(for: .seconds(1))

            guard !Task.isCancelled else { return }

        }

        guard !Task.isCancelled else { return }

        evaluateLowSpace()

        let cleanableRecords = libraries.filter {

            !isLibraryIgnored($0) && effectiveCleanableSize(for: $0) >= Self.minimumCleanableSize

        }

        let total = cleanableRecords.reduce(Int64(0)) { $0 + effectiveCleanableSize(for: $1) }

        NotificationController.shared.scheduledCheckFinished(

            cleanableSize: total,

            libraryCount: cleanableRecords.count,

            enabled: notificationsEnabled

        )

    }



    func dismissCleanupNotice() {

        noticeDismissalTask?.cancel()

        cleanupNotice = nil

    }



    func showCleanupNotice(_ notice: CleanupNotice) {

        noticeDismissalTask?.cancel()

        cleanupNotice = notice

        noticeDismissalTask = Task { [weak self] in

            try? await Task.sleep(for: .seconds(8))

            guard !Task.isCancelled, self?.cleanupNotice?.id == notice.id else { return }

            self?.cleanupNotice = nil

        }

    }



    func diagnoseVolumeAccess(_ record: LibraryRecord) {

        guard !record.isDiagnosingVolume else { return }

        record.isDiagnosingVolume = true

        let url = record.url

        Task { [weak record] in

            let report = await Task.detached(priority: .utility) {

                Self.probeVolumeAccess(url)

            }.value

            guard let record else { return }

            record.accessReport = report

            if report.mounted { record.lastAccessibleAt = Date() }

            record.isDiagnosingVolume = false

        }

    }



    nonisolated private static func probeVolumeAccess(_ url: URL) -> VolumeAccessReport {

        var isDirectory: ObjCBool = false

        let mounted = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue

        let writable = mounted && FileManager.default.isWritableFile(atPath: url.path)

        let volumeName = try? url.resourceValues(forKeys: [.volumeNameKey]).volumeName

        return VolumeAccessReport(

            libraryURL: url,

            volumeName: volumeName,

            mounted: mounted,

            writable: writable,

            checkedAt: Date()

        )

    }



    /// 外置卷重新挂载：库内该卷资源库入队增量扫描（有效缓存直接复用），

    /// 工作目录所在卷重连后重新发现一次。判断本身是纯路径匹配，无主线程 I/O。

    func handleVolumeMount(volumeURL: URL) {

        cleanupHistory.recoverPendingPurge()

        let volumePath = volumeURL.standardizedFileURL.path

        let affected = libraries.filter {

            VolumeMountRules.residesOnVolume(recordPath: $0.url.path, volumePath: volumePath)

        }

        let workDirsOnVolume = workDirectories.contains {

            VolumeMountRules.residesOnVolume(recordPath: $0.path, volumePath: volumePath)

        }

        guard !affected.isEmpty || workDirsOnVolume else { return }

        for record in affected where !isLibraryIgnored(record) {

            record.lastAccessibleAt = Date()

            record.accessReport = nil

            scan(record, force: false)

        }

        if workDirsOnVolume {

            discoverLibraries()

        }

    }



    /// 外置卷卸载：保留记录与 lastKnownCleanableSize 兜底显示；取消排队/运行中的扫描，

    /// 避免离线扫描产生"卷已离线"噪声错误；诊断状态联动标为已断开。

    func handleVolumeUnmount(volumeURL: URL) {

        let volumePath = volumeURL.standardizedFileURL.path

        let affected = libraries.filter {

            VolumeMountRules.residesOnVolume(recordPath: $0.url.path, volumePath: volumePath)

        }

        guard !affected.isEmpty else { return }

        for record in affected {

            scanQueue.removePending(record)

            record.scanControl?.cancel()

            record.accessReport = VolumeAccessReport(

                libraryURL: record.url,

                volumeName: record.volumeName,

                mounted: false,

                writable: false,

                checkedAt: Date()

            )

        }

        reconcileFilteredLibraries()

        saveRecents()

    }



    /// Re-mints the security-scoped bookmark by having the user pick the same

    /// package again — the standard remedy after a scope went stale.

    func reauthorizeLibraryAccess(_ record: LibraryRecord) {

        let panel = NSOpenPanel()

        panel.title = String(localized: "重新授权资源库访问")

        panel.prompt = String(localized: "重新授权")

        panel.canChooseFiles = true

        panel.canChooseDirectories = false

        panel.allowsMultipleSelection = false

        panel.allowedContentTypes = [UTType(importedAs: "com.apple.finalcutprolibrary")]

        panel.directoryURL = record.url.deletingLastPathComponent()

        guard panel.runModal() == .OK, let picked = panel.urls.first else { return }

        guard picked.standardizedFileURL == record.url.standardizedFileURL else {

            showCleanupNotice(CleanupNotice(

                title: String(localized: "重新授权未完成"),

                libraryCount: 1,

                freedSize: 0,

                cleanedItemCount: 0,

                categories: [],

                errorCount: 1,

                errorMessage: String(format: String(localized: "所选的不是原资源库（%@），请重新选择同一个 .fcpbundle"), String(record.displayName))

            ))

            return

        }

        bookmarks.save(

            currentRecentsMetadata(),

            replacementURLs: [record.url.standardizedFileURL: picked.standardizedFileURL]

        )

        // 探测涉及多次文件系统调用（网络卷上可能阻塞），面板关闭后交后台执行。

        let url = record.url

        Task { [weak record] in

            let report = await Task.detached(priority: .utility) {

                Self.probeVolumeAccess(url)

            }.value

            guard let record else { return }

            record.accessReport = report

            if report.mounted { record.lastAccessibleAt = Date() }

            scan(record, force: false)

        }

    }

}
