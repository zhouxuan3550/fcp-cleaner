import AppKit
import Charts
import SwiftUI
import FCPLibraryCleanerCore

struct LibraryPanel: View {
    @Bindable var library: LibraryRecord
    let store: LibraryStore
    @ScaledMetric(relativeTo: .body) private var headerIconSize: CGFloat = 20

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 13) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: headerIconSize))
                    .foregroundStyle(AppColor.accent)
                    .frame(width: 42, height: 42)
                    .background(AppColor.control)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(library.displayName)
                        .font(AppFont.title(.semibold, design: .rounded))
                    Text(shortPath(library.url))
                        .font(AppFont.small(design: .monospaced))
                        .foregroundStyle(AppColor.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(library.url.path)
                }
                Spacer()
                LibraryStatusBadge(library: library)
                Button {
                    store.scan(library, force: false)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .background(AppColor.control)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .disabled(library.isScanning || library.isQueued)
                .accessibilityLabel("重新扫描")
                .help("重新扫描（⌘R）")
                .contextMenu {
                    Button("完整重新扫描") { store.scan(library, force: true) }
                    Button("在 Finder 中显示") {
                        NSWorkspace.shared.activateFileViewerSelecting([library.url])
                    }
                    Button("拷贝资源库路径") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(library.url.path, forType: .string)
                    }
                }

                Menu {
                    Button {
                        store.inspect(library)
                    } label: {
                        Label("生成扫描目录树", systemImage: "list.bullet.indent")
                    }
                    .disabled(library.scanResult == nil || library.isInspecting)
                    if let report = library.inspectorReport {
                        Text("已检查 \(report.entries.count.formatted()) 项")
                    }
                    Button {
                        store.scan(library, force: true)
                    } label: {
                        Label("完整重新扫描", systemImage: "arrow.clockwise")
                    }
                    .disabled(library.isScanning || library.isQueued)

                    Divider()

                    if store.isLibraryIgnored(library) {
                        Button("取消忽略") { store.resumeLibrary(library) }
                    } else {
                        Button("7 天内不再提醒") { store.snoozeLibrary(library) }
                        Button("忽略所在目录的全部资源库") {
                            store.ignoreDirectory(library.url.deletingLastPathComponent())
                        }
                    }

                    Divider()

                    Button {
                        store.diagnoseVolumeAccess(library)
                    } label: {
                        Label(library.isDiagnosingVolume ? "外置盘诊断中…" : "外置盘诊断", systemImage: "stethoscope")
                    }
                    .disabled(library.isDiagnosingVolume)
                    Button("重新授权访问") { store.reauthorizeLibraryAccess(library) }
                    if let report = library.accessReport {
                        Text(report.mounted ? (report.writable ? "磁盘在线 · 可写" : "磁盘在线 · 只读") : "磁盘已断开或未挂载")
                    }
                    if let at = library.lastAccessibleAt {
                        Text("上次可访问 \(at.formatted(date: .abbreviated, time: .shortened))")
                    }

                    Divider()

                    Button("在 Finder 中显示") {
                        NSWorkspace.shared.activateFileViewerSelecting([library.url])
                    }
                    Button("拷贝资源库路径") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(library.url.path, forType: .string)
                    }

                    Divider()

                    Button("从列表移除", role: .destructive) { store.remove([library]) }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(AppFont.body(.semibold))
                        .foregroundStyle(AppColor.secondaryText)
                        .frame(width: 32, height: 32)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .background(AppColor.control)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityLabel("资源库操作")
                .help("更多操作")
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 19)

            Divider().overlay(AppColor.border)

            Group {
                if library.isQueued {
                    QueuedScanView(library: library, store: store)
                } else if library.isScanning {
                    ScanningView(library: library, store: store)
                } else if let result = library.scanResult {
                    ScanResultsView(library: library, result: result, store: store)
                } else {
                    ScanErrorView(library: library, store: store)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .compatibleGlassEffect(
            in: RoundedRectangle(cornerRadius: 20, style: .continuous),
            fallbackColor: AppColor.workspace
        )
    }
}

struct LibraryStatusBadge: View {
    let library: LibraryRecord

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(library.accessReport?.mounted == false || library.scanError != nil ? AppColor.danger : AppColor.success)
                .frame(width: 7, height: 7)
            Text(
                library.isQueued ? "等待扫描" :
                library.isScanning ? "扫描中" :
                library.accessReport?.mounted == false ? "磁盘已断开" :
                library.scanError != nil ? "扫描失败" :
                library.cleanupError != nil ? "预检未通过" :
                library.usedCachedScan ? "增量复用" :
                "已就绪"
            )
        }
        .font(AppFont.small(.semibold))
        .foregroundStyle(AppColor.secondaryText)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(AppColor.control)
        .clipShape(Capsule())
    }
}

struct QueuedScanView: View {
    let library: LibraryRecord
    let store: LibraryStore
    @ScaledMetric(relativeTo: .largeTitle) private var queuedIconSize: CGFloat = 28
    @ScaledMetric(relativeTo: .title2) private var queuedTitleSize: CGFloat = 19

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "hourglass")
                .font(.system(size: queuedIconSize, weight: .light))
                .foregroundStyle(AppColor.accent)
            Text("等待扫描")
                .font(.system(size: queuedTitleSize, weight: .semibold, design: .rounded))
            Button("取消") { store.cancelScan(library) }
                .buttonStyle(.borderless)
                .foregroundStyle(AppColor.secondaryText)
        }
    }
}

struct ScanningView: View {
    let library: LibraryRecord
    let store: LibraryStore
    @ScaledMetric(relativeTo: .title2) private var scanningTitleSize: CGFloat = 20

    var body: some View {
        VStack(spacing: 20) {
            ProgressView()
                .controlSize(.large)
                .tint(AppColor.accent)
            Text("正在扫描资源库")
                .font(.system(size: scanningTitleSize, weight: .semibold, design: .rounded))
            HStack(spacing: 12) {
                ScanCounter(value: library.scanProgress.files.formatted(), label: "文件")
                ScanCounter(value: library.scanProgress.directories.formatted(), label: "文件夹")
                ScanCounter(value: FormatHelpers.bytes(library.scanProgress.allocatedBytes), label: "已扫描")
            }
            if let partial = library.scanPartialResults {
                HStack(spacing: 12) {
                    ForEach(CacheCategory.cleanableCases, id: \.self) { category in
                        ScanCounter(value: FormatHelpers.bytes(partial.allocatedByCategory[category, default: 0]), label: category.chineseName)
                    }
                }
            }
            Button("取消") { store.cancelScan(library) }
                .buttonStyle(.borderless)
                .foregroundStyle(AppColor.secondaryText)
            // 大库扫描是体验的情绪谷底：明确告知不阻塞操作，给用户掌控感
            Text("扫描在后台进行，可继续浏览其他资源库")
                .font(AppFont.small(.medium))
                .foregroundStyle(AppColor.tertiaryText)
        }
    }
}

struct ScanCounter: View {
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(AppFont.heading(.semibold, design: .monospaced))
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.25), value: value)
            Text(label)
                .font(.caption)
                .foregroundStyle(AppColor.secondaryText)
        }
        .frame(width: 94, height: 60)
        .background(AppColor.panel)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct ScanErrorView: View {
    let library: LibraryRecord
    let store: LibraryStore
    @ScaledMetric(relativeTo: .largeTitle) private var errorIconSize: CGFloat = 30

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: errorIconSize))
                .foregroundStyle(AppColor.danger)
            Text(library.scanError ?? "尚未扫描")
                .font(AppFont.body())
                .foregroundStyle(AppColor.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
            Button("重新扫描") { store.scan(library) }
                .buttonStyle(HeaderButtonStyle(emphasized: true))
        }
    }
}

struct ScanResultsView: View {
    @Bindable var library: LibraryRecord
    let result: LibraryScanResult
    let store: LibraryStore

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                HStack(spacing: 14) {
                    MetricCard(label: "资源库大小", value: FormatHelpers.bytes(result.totalAllocatedSize), icon: "internaldrive")
                    MetricCard(label: "可安全清理", value: FormatHelpers.bytes(result.confirmedCleanableSize), icon: "sparkles", emphasized: true)
                    MetricCard(label: "清理项目", value: result.cacheItems.count.formatted(), icon: "folder.badge.minus")
                }

                SizeTrendCard(libraryURL: library.url)

                StorageBreakdownBar(result: result)

                if result.externalCleanableSize > 0 {
                    Label("包含外置缓存 \(FormatHelpers.bytes(result.externalCleanableSize))", systemImage: "externaldrive.fill")
                        .font(AppFont.small(.medium))
                        .foregroundStyle(AppColor.accent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(alignment: .top, spacing: 14) {
                    CleanupList(result: result)
                    CleanupActionCard(library: library, result: result, store: store)
                        .frame(width: LayoutMetrics.cleanupActionCardWidth)
                }

                CleanupStatus(library: library, store: store)
            }
            .padding(22)
        }
        .scrollIndicators(.hidden)
    }
}

/// 库体积历史曲线（数据来自 LibrarySizeTrend 的每日扫描采样，最多 90 天）。
/// 采样不足两条时整体隐藏——没有趋势就不画趋势。
struct SizeTrendCard: View {
    let samples: [LibrarySizeTrend.Sample]

    init(libraryURL: URL) {
        self.samples = LibrarySizeTrend.samples(for: libraryURL)
    }

    var body: some View {
        if samples.count >= 2 {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(AppFont.small(.semibold))
                        .foregroundStyle(AppColor.secondaryText)
                    Text("体积趋势")
                        .font(AppFont.body(.semibold, design: .rounded))
                    Spacer(minLength: 0)
                    // 周增长与趋势曲线同源（同一份采样），收进卡片头部替代独立的漂浮标签
                    if let growth = LibrarySizeTrend.weeklyGrowth(samples: samples), growth > 0 {
                        Label("本周 +\(FormatHelpers.bytes(growth))", systemImage: "arrow.up.forward")
                            .font(AppFont.small(.semibold))
                            .foregroundStyle(AppColor.warning)
                            .help("与约一周前的扫描采样相比，资源库总体积的增长量")
                    }
                    Text("近 \(samples.count) 次采样")
                        .font(AppFont.small(.medium))
                        .foregroundStyle(AppColor.tertiaryText)
                }
                Chart(samples, id: \.day) { sample in
                    AreaMark(
                        x: .value("日期", sample.day),
                        y: .value("总体积", sample.totalAllocatedSize)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [AppColor.accent.opacity(0.18), AppColor.accent.opacity(0.02)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .interpolationMethod(.catmullRom)
                    LineMark(
                        x: .value("日期", sample.day),
                        y: .value("总体积", sample.totalAllocatedSize)
                    )
                    .foregroundStyle(AppColor.accent)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .interpolationMethod(.catmullRom)
                    .symbol(.circle)
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine().foregroundStyle(AppColor.border.opacity(0.4))
                        AxisValueLabel {
                            if let date = value.as(Date.self) {
                                Text(date, format: .dateTime.month().day())
                                    .font(AppFont.caption(.medium))
                                    .foregroundStyle(AppColor.tertiaryText)
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                        AxisGridLine().foregroundStyle(AppColor.border.opacity(0.4))
                        AxisValueLabel {
                            if let bytes = value.as(Int64.self) {
                                Text(FormatHelpers.bytes(bytes))
                                    .font(AppFont.caption(.medium))
                                    .foregroundStyle(AppColor.tertiaryText)
                            }
                        }
                    }
                }
                .frame(height: 110)
            }
            .padding(16)
            .background(AppColor.panel)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("体积趋势：共 \(samples.count) 次扫描采样，最新 \(FormatHelpers.bytes(samples.last?.totalAllocatedSize ?? 0))")
        }
    }
}

struct StorageBreakdownBar: View {    let result: LibraryScanResult
    let renderSize: Int64
    let proxySize: Int64
    let optimizedSize: Int64
    let protectedAnalysisSize: Int64
    let otherOrMediaSize: Int64

    init(result: LibraryScanResult) {
        self.result = result
        var render: Int64 = 0
        var proxy: Int64 = 0
        var opt: Int64 = 0
        for item in result.cacheItems {
            switch item.category {
            case .renderFiles: render += item.allocatedSize
            case .proxyMedia: proxy += item.allocatedSize
            case .optimizedMedia: opt += item.allocatedSize
            default: break
            }
        }
        self.renderSize = render
        self.proxySize = proxy
        self.optimizedSize = opt
        let protected = result.observedCacheItems.reduce(0) { $0 + $1.allocatedSize }
        self.protectedAnalysisSize = protected
        let cleanable = result.confirmedCleanableSize
        self.otherOrMediaSize = max(0, result.totalAllocatedSize - cleanable - protected)
    }

    var body: some View {
        let total = max(1, result.totalAllocatedSize)
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { proxy in
                let w = proxy.size.width
                HStack(spacing: 2) {
                    if renderSize > 0 {
                        segment(color: AppColor.accent, width: max(4, w * CGFloat(renderSize) / CGFloat(total)))
                            .help("渲染文件: \(FormatHelpers.bytes(renderSize))")
                    }
                    if proxySize > 0 {
                        segment(color: AppColor.chartProxyMedia, width: max(4, w * CGFloat(proxySize) / CGFloat(total)))
                            .help("代理媒体: \(FormatHelpers.bytes(proxySize))")
                    }
                    if optimizedSize > 0 {
                        segment(color: AppColor.chartOptimizedMedia, width: max(4, w * CGFloat(optimizedSize) / CGFloat(total)))
                            .help("优化媒体: \(FormatHelpers.bytes(optimizedSize))")
                    }
                    if protectedAnalysisSize > 0 {
                        segment(color: AppColor.tertiaryText.opacity(0.8), width: max(4, w * CGFloat(protectedAnalysisSize) / CGFloat(total)))
                            .help("分析文件(受保护): \(FormatHelpers.bytes(protectedAnalysisSize))")
                    }
                    if otherOrMediaSize > 0 {
                        segment(color: AppColor.control, width: max(4, w * CGFloat(otherOrMediaSize) / CGFloat(total)))
                            .help("原始媒体与工程数据: \(FormatHelpers.bytes(otherOrMediaSize))")
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            .frame(height: 7)

            HStack(spacing: 16) {
                if renderSize > 0 {
                    legendItem(color: AppColor.accent, label: "渲染", bytes: renderSize)
                }
                if proxySize > 0 {
                    legendItem(color: AppColor.chartProxyMedia, label: "代理", bytes: proxySize)
                }
                if optimizedSize > 0 {
                    legendItem(color: AppColor.chartOptimizedMedia, label: "优化", bytes: optimizedSize)
                }
                if protectedAnalysisSize > 0 {
                    legendItem(color: AppColor.tertiaryText.opacity(0.8), label: "分析(受保护)", bytes: protectedAnalysisSize)
                }
                legendItem(color: AppColor.tertiaryText, label: "原始媒体/工程", bytes: otherOrMediaSize)
                Spacer(minLength: 0)
            }
            .font(AppFont.small(.medium))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(AppColor.panel)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("资源库占用细分：总计 \(FormatHelpers.bytes(result.totalAllocatedSize))。其中渲染文件 \(FormatHelpers.bytes(renderSize))，代理媒体 \(FormatHelpers.bytes(proxySize))，优化媒体 \(FormatHelpers.bytes(optimizedSize))，受保护分析文件 \(FormatHelpers.bytes(protectedAnalysisSize))，原始工程素材 \(FormatHelpers.bytes(otherOrMediaSize))")
    }

    private func segment(color: Color, width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(color)
            .frame(width: width, height: 7)
    }

    private func legendItem(color: Color, label: String, bytes: Int64) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(label)
                .foregroundStyle(AppColor.secondaryText)
            Text(FormatHelpers.bytes(bytes))
                .monospacedDigit()
                .foregroundStyle(AppColor.primaryText)
        }
    }
}

struct MetricCard: View {
    let label: String
    let value: String
    let icon: String
    var emphasized = false
    @ScaledMetric(relativeTo: .title2) private var valueSize: CGFloat = 20

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: icon)
                .font(AppFont.title(.semibold))
                .foregroundStyle(emphasized ? .white : AppColor.secondaryText)
                .frame(width: 38, height: 38)
                .background(emphasized ? AppColor.accent : AppColor.control)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(AppFont.small(.medium))
                    .foregroundStyle(AppColor.secondaryText)
                Text(value)
                    .font(.system(size: valueSize, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(AppColor.panel)
        .overlay {
            if emphasized {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(AppColor.accent.opacity(0.25), lineWidth: 1)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .animation(.snappy, value: value)
    }
}

struct CleanupList: View {
    let result: LibraryScanResult
    let categorySummary: [CacheCategory: (count: Int, size: Int64)]

    init(result: LibraryScanResult) {
        self.result = result
        var summary: [CacheCategory: (count: Int, size: Int64)] = [:]
        for item in result.cacheItems {
            let current = summary[item.category] ?? (0, 0)
            summary[item.category] = (current.count + 1, current.size + item.allocatedSize)
        }
        self.categorySummary = summary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("最大安全清理")
                .font(AppFont.title(.semibold, design: .rounded))
                .padding(.bottom, 10)

            ForEach(CacheCategory.cleanableCases, id: \.self) { category in
                let info = categorySummary[category] ?? (0, 0)
                let isEmpty = info.count == 0
                HStack(spacing: 12) {
                    Image(systemName: category.iconName)
                        .foregroundStyle(isEmpty ? AppColor.tertiaryText : AppColor.accent)
                        .frame(width: 30, height: 30)
                        .background(AppColor.control)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    Text(category.chineseName)
                        .font(AppFont.body(.medium))
                    Spacer()
                    if isEmpty {
                        Text("—")
                            .font(AppFont.callout(design: .monospaced))
                            .foregroundStyle(AppColor.tertiaryText)
                    } else {
                        Text(FormatHelpers.bytes(info.size))
                            .font(AppFont.callout(design: .monospaced))
                            .foregroundStyle(AppColor.secondaryText)
                    }
                }
                .padding(.vertical, 10)
                .opacity(isEmpty ? 0.45 : 1)
                if category != CacheCategory.cleanableCases.last {
                    Divider().overlay(AppColor.border)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(AppColor.panel)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct CleanupActionCard: View {
    let library: LibraryRecord
    let result: LibraryScanResult
    let store: LibraryStore
    @ScaledMetric(relativeTo: .largeTitle) private var heroNumberSize: CGFloat = 32

    private var protectedAnalysisSize: Int64 {
        result.observedCacheItems.reduce(0) { $0 + $1.allocatedSize }
    }

    private var isBelowThreshold: Bool {
        library.spaceToFree < LibraryStore.minimumCleanableSize
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("可清理空间")
                .font(AppFont.callout(.medium))
                .foregroundStyle(AppColor.secondaryText)
            Text(FormatHelpers.bytes(library.spaceToFree))
                .font(.system(size: heroNumberSize, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .shadow(color: AppColor.accent.opacity(0.35), radius: 12)
                .animation(.snappy, value: library.spaceToFree)
            if library.pendingFreedSize == 0, let estimate = result.reclaimableEstimate {
                Text(reclaimEstimateText(estimate))
                    .font(AppFont.small(.medium))
                    .foregroundStyle(AppColor.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 5)
            Button(actionTitle) {
                store.requestClean(library)
            }
            .buttonStyle(PrimaryActionButtonStyle(enabled: !isBelowThreshold && !store.isPreflighting && !store.isCleaning))
            .disabled(isBelowThreshold || store.isPreflighting || store.isCleaning)
            .help(isBelowThreshold ? "可清理空间低于 \(FormatHelpers.bytes(LibraryStore.minimumCleanableSize))，已自动跳过" : "将生成文件移入废纸篓")

            if isBelowThreshold && !store.isPreflighting && !store.isCleaning {
                Label("低于 \(FormatHelpers.bytes(LibraryStore.minimumCleanableSize)) 的资源库会自动跳过", systemImage: "info.circle")
                    .font(AppFont.small(.medium))
                    .foregroundStyle(AppColor.tertiaryText)
                    .lineLimit(1)
            }

            if protectedAnalysisSize > 0 {
                Label("已保护分析文件 \(FormatHelpers.bytes(protectedAnalysisSize))", systemImage: "lock.fill")
                    .font(AppFont.small(.medium))
                    .foregroundStyle(AppColor.tertiaryText)
                    .lineLimit(1)
            }
            if let seconds = store.estimatedCleanupDuration(forBytes: library.spaceToFree, volumeID: library.volumeID) {
                Label("预计耗时 \(FormatHelpers.estimatedTime(seconds))", systemImage: "clock")
                    .font(AppFont.small(.medium))
                    .foregroundStyle(AppColor.tertiaryText)
                    .lineLimit(1)
            }
        }
        .padding(20)
        .background(AppColor.panel)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// min==max 时显示单值，避免「2.46 GB–2.46 GB」这类同值范围。
    private func reclaimEstimateText(_ estimate: ReclaimableSpaceEstimate) -> String {
        let minText = FormatHelpers.bytes(estimate.minimumBytes)
        let maxText = FormatHelpers.bytes(estimate.maximumBytes)
        return minText == maxText
            ? "彻底删除后预计可释放 \(minText)"
            : "彻底删除后预计 \(minText)–\(maxText)"
    }

    private var actionTitle: String {
        if store.isPreflighting {
            return "正在检查 \(store.cleanupPreparationCompleted)/\(store.cleanupPreparationTotal)"
        }
        if store.isBatchCleaning {
            return "正在清理 \(store.batchCleanupCompleted)/\(store.batchCleanupTotal)"
        }
        if isBelowThreshold {
            return "低于 \(FormatHelpers.bytes(LibraryStore.minimumCleanableSize))"
        }
        return "开始清理"
    }
}

struct CleanupStatus: View {
    let library: LibraryRecord
    let store: LibraryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Group {
                if let cleanup = library.lastCleanup {
                    HStack(spacing: 8) {
                        Image(systemName: cleanup.errors.isEmpty ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .foregroundStyle(cleanup.errors.isEmpty ? AppColor.success : AppColor.danger)
                        Text("移入废纸篓 \(FormatHelpers.bytes(cleanup.freedAllocatedSize))")
                        if let before = library.cleanupBeforeSize, let after = library.cleanupAfterSize {
                            Text("\(FormatHelpers.bytes(before)) → \(FormatHelpers.bytes(after))")
                                .foregroundStyle(AppColor.secondaryText)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else if let error = library.cleanupError {
                    Text(error)
                        .foregroundStyle(AppColor.danger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
            .font(AppFont.callout(.medium))
            if let retryPlan = library.failedCleanupPlan {
                Button("重试失败项 \(retryPlan.entries.count)") {
                    store.requestRetry(library)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(AppColor.accent)
            .disabled(store.isPreflighting || store.isCleaning)
            }
        }
    }
}
