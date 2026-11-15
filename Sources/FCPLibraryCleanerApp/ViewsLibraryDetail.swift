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

                        Text(String(format: String(localized: "已检查 %@ 项"), String(report.entries.count.formatted())))

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

                        Label(library.isDiagnosingVolume ? String(localized: "外置盘诊断中…") : String(localized: "外置盘诊断"), systemImage: "stethoscope")

                    }

                    .disabled(library.isDiagnosingVolume)

                    Button("重新授权访问") { store.reauthorizeLibraryAccess(library) }

                    if let report = library.accessReport {

                        Text(report.mounted ? (report.writable ? String(localized: "磁盘在线 · 可写") : String(localized: "磁盘在线 · 只读")) : String(localized: "磁盘已断开或未挂载"))

                    }

                    if let at = library.lastAccessibleAt {

                        Text(String(format: String(localized: "上次可访问 %@"), String(at.formatted(date: .abbreviated, time: .shortened))))

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

                library.isQueued ? String(localized: "等待扫描") :

                library.isScanning ? String(localized: "扫描中") :

                library.accessReport?.mounted == false ? String(localized: "磁盘已断开") :

                library.scanError != nil ? String(localized: "扫描失败") :

                library.cleanupError != nil ? String(localized: "预检未通过") :

                library.usedCachedScan ? String(localized: "增量复用") :

                String(localized: "已就绪")

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

                ScanCounter(value: library.scanProgress.files.formatted(), label: String(localized: "文件"))

                ScanCounter(value: library.scanProgress.directories.formatted(), label: String(localized: "文件夹"))

                ScanCounter(value: FormatHelpers.bytes(library.scanProgress.allocatedBytes), label: String(localized: "已扫描"))

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

                    MetricCard(label: String(localized: "资源库大小"), value: FormatHelpers.bytes(result.totalAllocatedSize), icon: "internaldrive")

                    MetricCard(label: String(localized: "可安全清理"), value: FormatHelpers.bytes(result.confirmedCleanableSize), icon: "sparkles", emphasized: true)

                    MetricCard(label: String(localized: "清理项目"), value: result.cacheItems.count.formatted(), icon: "folder.badge.minus")

                }



                SizeTrendCard(libraryURL: library.url)



                StorageBreakdownBar(result: result)



                EventBreakdownCard(result: result)



                if result.externalCleanableSize > 0 {

                    Label(String(format: String(localized: "包含外置缓存 %@"), String(FormatHelpers.bytes(result.externalCleanableSize))), systemImage: "externaldrive.fill")

                        .font(AppFont.small(.medium))

                        .foregroundStyle(AppColor.accent)

                        .frame(maxWidth: .infinity, alignment: .leading)

                }



                HStack(alignment: .top, spacing: 14) {

                    CleanupList(result: result, scannedAt: library.lastScanned)

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

                        Label(String(format: String(localized: "本周 +%@"), String(FormatHelpers.bytes(growth))), systemImage: "arrow.up.forward")

                            .font(AppFont.small(.semibold))

                            .foregroundStyle(AppColor.warning)

                            .help("与约一周前的扫描采样相比，资源库总体积的增长量")

                    }

                    Text(String(format: String(localized: "近 %@ 次采样"), String(samples.count)))

                        .font(AppFont.small(.medium))

                        .foregroundStyle(AppColor.tertiaryText)

                }

                Chart(samples, id: \.day) { sample in

                    AreaMark(

                        x: .value(String(localized: "日期"), sample.day),

                        y: .value(String(localized: "总体积"), sample.totalAllocatedSize)

                    )

                    .foregroundStyle(

                        LinearGradient(

                            colors: [AppColor.accent.opacity(0.18), AppColor.accent.opacity(0.02)],

                            startPoint: .top, endPoint: .bottom

                        )

                    )

                    .interpolationMethod(.catmullRom)

                    LineMark(

                        x: .value(String(localized: "日期"), sample.day),

                        y: .value(String(localized: "总体积"), sample.totalAllocatedSize)

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

            .accessibilityLabel(String(format: String(localized: "体积趋势：共 %@ 次扫描采样，最新 %@"), String(samples.count), String(FormatHelpers.bytes(samples.last?.totalAllocatedSize ?? 0))))

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

                            .help(String(format: String(localized: "渲染文件: %@"), String(FormatHelpers.bytes(renderSize))))

                    }

                    if proxySize > 0 {

                        segment(color: AppColor.chartProxyMedia, width: max(4, w * CGFloat(proxySize) / CGFloat(total)))

                            .help(String(format: String(localized: "代理媒体: %@"), String(FormatHelpers.bytes(proxySize))))

                    }

                    if optimizedSize > 0 {

                        segment(color: AppColor.chartOptimizedMedia, width: max(4, w * CGFloat(optimizedSize) / CGFloat(total)))

                            .help(String(format: String(localized: "优化媒体: %@"), String(FormatHelpers.bytes(optimizedSize))))

                    }

                    if protectedAnalysisSize > 0 {

                        segment(color: AppColor.tertiaryText.opacity(0.8), width: max(4, w * CGFloat(protectedAnalysisSize) / CGFloat(total)))

                            .help(String(format: String(localized: "分析文件(受保护): %@"), String(FormatHelpers.bytes(protectedAnalysisSize))))

                    }

                    if otherOrMediaSize > 0 {

                        segment(color: AppColor.control, width: max(4, w * CGFloat(otherOrMediaSize) / CGFloat(total)))

                            .help(String(format: String(localized: "原始媒体与工程数据: %@"), String(FormatHelpers.bytes(otherOrMediaSize))))

                    }

                }

                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

            }

            .frame(height: 7)



            HStack(spacing: 16) {

                if renderSize > 0 {

                    legendItem(color: AppColor.accent, label: String(localized: "渲染"), bytes: renderSize)

                }

                if proxySize > 0 {

                    legendItem(color: AppColor.chartProxyMedia, label: String(localized: "代理"), bytes: proxySize)

                }

                if optimizedSize > 0 {

                    legendItem(color: AppColor.chartOptimizedMedia, label: String(localized: "优化"), bytes: optimizedSize)

                }

                if protectedAnalysisSize > 0 {

                    legendItem(color: AppColor.tertiaryText.opacity(0.8), label: String(localized: "分析(受保护)"), bytes: protectedAnalysisSize)

                }

                legendItem(color: AppColor.tertiaryText, label: String(localized: "原始媒体/工程"), bytes: otherOrMediaSize)

                Spacer(minLength: 0)

            }

            .font(AppFont.small(.medium))

        }

        .padding(.horizontal, 16)

        .padding(.vertical, 12)

        .background(AppColor.panel)

        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

        .accessibilityElement(children: .combine)

        .accessibilityLabel(String(format: String(localized: "资源库占用细分：总计 %@。其中渲染文件 %@，代理媒体 %@，优化媒体 %@，受保护分析文件 %@，原始工程素材 %@"), String(FormatHelpers.bytes(result.totalAllocatedSize)), String(FormatHelpers.bytes(renderSize)), String(FormatHelpers.bytes(proxySize)), String(FormatHelpers.bytes(optimizedSize)), String(FormatHelpers.bytes(protectedAnalysisSize)), String(FormatHelpers.bytes(otherOrMediaSize))))

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



/// 按 Event 拆分的缓存分布：数据与确认弹窗的 Event 勾选完全同源，

/// 让用户在确认前就知道每个 Event 各占多少。

struct EventBreakdownCard: View {

    let result: LibraryScanResult



    private struct Slice: Identifiable {

        let id: String

        let size: Int64

    }



    private var slices: [Slice] {

        var totals: [String: Int64] = [:]

        for item in result.cacheItems {

            let event = FCPStructureRules.candidateLocation(for: item.url, ruleID: item.ruleID)?.eventName ?? String(localized: "库级共享")

            totals[event, default: 0] += item.allocatedSize

        }

        let sorted = totals.sorted { $0.value > $1.value }

        guard sorted.count > 8 else { return sorted.map { Slice(id: $0.key, size: $0.value) } }

        let head = sorted.prefix(7).map { Slice(id: $0.key, size: $0.value) }

        let rest = sorted.dropFirst(7)

        let tail = rest.reduce(Int64(0)) { $0 + $1.value }

        return head + [Slice(id: String(format: String(localized: "其他 %@ 个 Event"), String(rest.count)), size: tail)]

    }



    var body: some View {

        VStack(alignment: .leading, spacing: 10) {

            Text("按 Event 拆分")

                .font(AppFont.title(.semibold, design: .rounded))

            if slices.isEmpty {

                Text("本次扫描没有候选目录")

                    .font(AppFont.callout(.medium))

                    .foregroundStyle(AppColor.tertiaryText)

            } else {
                // 自定义行布局（与仪表盘卷压力条同构）：Charts 的分类轴标签
                // 会压进绘图区与条形重叠，行式布局从结构上消除该问题。
                let maxSlice = slices.first?.size ?? 0
                ForEach(slices) { slice in
                    HStack(spacing: 10) {
                        Text(slice.id)
                            .font(AppFont.callout(.medium))
                            .foregroundStyle(AppColor.primaryText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(width: 132, alignment: .leading)
                            .help(slice.id)
                        GeometryReader { proxy in
                            let fraction = maxSlice > 0 ? Double(slice.size) / Double(maxSlice) : 0
                            ZStack(alignment: .leading) {
                                Capsule().fill(AppColor.control)
                                Capsule()
                                    .fill(AppColor.accent.gradient)
                                    .frame(width: max(4, proxy.size.width * fraction))
                            }
                        }
                        .frame(height: 10)
                        Text(FormatHelpers.bytes(slice.size))
                            .font(AppFont.caption(.medium, design: .monospaced))
                            .foregroundStyle(AppColor.secondaryText)
                            .frame(width: 68, alignment: .trailing)
                            .monospacedDigit()
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(String(format: String(localized: "%@：可清理 %@"), slice.id, FormatHelpers.bytes(slice.size)))
                }
            }


        }

        .padding(18)

        .frame(maxWidth: .infinity, alignment: .topLeading)

        .background(AppColor.panel)

        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

    }

}



/// 「为什么可清理」透明化：每个类目可展开为逐目录明细——

/// 实际路径、命中的规则 ID、置信度与体积，全部来自扫描缓存的原始数据。

struct CleanupList: View {

    let result: LibraryScanResult

    let scannedAt: Date?

    let categorySummary: [CacheCategory: (count: Int, size: Int64)]

    private let itemsByCategory: [CacheCategory: [CacheItem]]

    @State private var expandedCategory: CacheCategory?



    init(result: LibraryScanResult, scannedAt: Date?) {

        self.result = result

        self.scannedAt = scannedAt

        var summary: [CacheCategory: (count: Int, size: Int64)] = [:]

        var items: [CacheCategory: [CacheItem]] = [:]

        for item in result.cacheItems {

            let current = summary[item.category] ?? (0, 0)

            summary[item.category] = (current.count + 1, current.size + item.allocatedSize)

            items[item.category, default: []].append(item)

        }

        self.categorySummary = summary

        self.itemsByCategory = items

    }



    var body: some View {

        VStack(alignment: .leading, spacing: 0) {

            Text("最大安全清理")

                .font(AppFont.title(.semibold, design: .rounded))

                .padding(.bottom, 2)

            if let scannedAt {

                Text(String(format: String(localized: "以下判定基于 %@ 的扫描指纹"), String(scannedAt.formatted(date: .abbreviated, time: .shortened))))

                    .font(AppFont.caption(.medium))

                    .foregroundStyle(AppColor.tertiaryText)

                    .padding(.bottom, 8)

            }



            ForEach(CacheCategory.cleanableCases, id: \.self) { category in

                let info = categorySummary[category] ?? (0, 0)

                let isEmpty = info.count == 0

                let isExpanded = expandedCategory == category && !isEmpty

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

                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")

                            .font(AppFont.caption(.semibold))

                            .foregroundStyle(AppColor.tertiaryText)

                    }

                }

                .contentShape(Rectangle())

                .onTapGesture { if !isEmpty {

                    withAnimation(.snappy(duration: 0.18)) {

                        expandedCategory = isExpanded ? nil : category

                    }

                } }

                .accessibilityAddTraits(isEmpty ? [] : .isButton)

                .accessibilityLabel("\(category.chineseName)，\(isEmpty ? "无候选" : "可展开查看明细")")

                .padding(.vertical, 10)

                .opacity(isEmpty ? 0.45 : 1)



                if isExpanded, let items = itemsByCategory[category] {

                    VStack(alignment: .leading, spacing: 8) {

                        ForEach(items) { item in

                            VStack(alignment: .leading, spacing: 3) {

                                Text(item.url.path)

                                    .font(AppFont.caption(design: .monospaced))

                                    .foregroundStyle(AppColor.primaryText)

                                    .lineLimit(1)

                                    .truncationMode(.middle)

                                    .textSelection(.enabled)

                                HStack(spacing: 10) {

                                    Label(item.ruleID, systemImage: "checkmark.seal")

                                        .font(AppFont.caption(.medium))

                                        .foregroundStyle(AppColor.accent)

                                    Text(item.confidence == .confirmed ? "已验证" : item.confidence.rawValue)

                                        .font(AppFont.caption(.medium))

                                        .foregroundStyle(AppColor.secondaryText)

                                    Text(FormatHelpers.bytes(item.allocatedSize))

                                        .font(AppFont.caption(.medium, design: .monospaced))

                                        .foregroundStyle(AppColor.secondaryText)

                                    Text(String(format: String(localized: "%@ 项"), String(item.fingerprint.entryCount)))

                                        .font(AppFont.caption(.medium, design: .monospaced))

                                        .foregroundStyle(AppColor.tertiaryText)

                                }

                            }

                            .padding(9)

                            .frame(maxWidth: .infinity, alignment: .leading)

                            .background(AppColor.control.opacity(0.5))

                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                        }

                    }

                    .padding(.bottom, 10)

                }

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

            .help(isBelowThreshold ? String(format: String(localized: "可清理空间低于 %@，已自动跳过"), String(FormatHelpers.bytes(LibraryStore.minimumCleanableSize))) : "将生成文件移入废纸篓")



            if isBelowThreshold && !store.isPreflighting && !store.isCleaning {

                Label(String(format: String(localized: "低于 %@ 的资源库会自动跳过"), String(FormatHelpers.bytes(LibraryStore.minimumCleanableSize))), systemImage: "info.circle")

                    .font(AppFont.small(.medium))

                    .foregroundStyle(AppColor.tertiaryText)

                    .lineLimit(1)

            }



            if protectedAnalysisSize > 0 {

                Label(String(format: String(localized: "已保护分析文件 %@"), String(FormatHelpers.bytes(protectedAnalysisSize))), systemImage: "lock.fill")

                    .font(AppFont.small(.medium))

                    .foregroundStyle(AppColor.tertiaryText)

                    .lineLimit(1)

            }

            if let seconds = store.estimatedCleanupDuration(forBytes: library.spaceToFree, volumeID: library.volumeID) {

                Label(String(format: String(localized: "预计耗时 %@"), String(FormatHelpers.estimatedTime(seconds))), systemImage: "clock")

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

            ? String(format: String(localized: "彻底删除后预计可释放 %@"), String(minText))

            : String(format: String(localized: "彻底删除后预计 %@–%@"), String(minText), String(maxText))

    }



    private var actionTitle: String {

        if store.isPreflighting {

            return String(format: String(localized: "正在检查 %@/%@"), String(store.cleanupPreparationCompleted), String(store.cleanupPreparationTotal))

        }

        if store.isBatchCleaning {

            return String(format: String(localized: "正在清理 %@/%@"), String(store.batchCleanupCompleted), String(store.batchCleanupTotal))

        }

        if isBelowThreshold {

            return String(format: String(localized: "低于 %@"), String(FormatHelpers.bytes(LibraryStore.minimumCleanableSize)))

        }

        return String(localized: "开始清理")

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

                        Text(String(format: String(localized: "移入废纸篓 %@"), String(FormatHelpers.bytes(cleanup.freedAllocatedSize))))

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

            if let snapshotDate = library.lastCleanup?.snapshotDate {

                Label(String(format: String(localized: "已创建本地快照 %@，系统可按需自动回收"), String(snapshotDate.formatted(date: .omitted, time: .shortened))), systemImage: "camera.on.rectangle")

                    .font(AppFont.small(.medium))

                    .foregroundStyle(AppColor.tertiaryText)

            }

            if let retryPlan = library.failedCleanupPlan {

                Button(String(format: String(localized: "重试失败项 %@"), String(retryPlan.entries.count))) {

                    store.requestRetry(library)

                }

                .buttonStyle(.borderless)

                .foregroundStyle(AppColor.accent)

            .disabled(store.isPreflighting || store.isCleaning)

            }

        }

    }

}
