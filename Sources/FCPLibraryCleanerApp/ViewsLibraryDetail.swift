// [INPUT]: SwiftUI 状态、资源库扫描结果与 LibraryStore 的清理预检入口。
// [OUTPUT]: 分段资源库详情、扫描结果、候选目录与固定清理操作栏。
// [POS]: App 详情界面；只展示扫描数据，清理决策交给 LibraryStore。
// [PROTOCOL]: Update this header on change, then check AGENTS.md
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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let value: String

    let label: String



    var body: some View {

        VStack(spacing: 4) {

            Text(value)

                .font(AppFont.heading(.semibold, design: .monospaced))

                .monospacedDigit()

                .contentTransition(.numericText())

                .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: value)

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

    private enum Section: CaseIterable {
        case overview, details, records

        var title: String {
            switch self {
            case .overview: String(localized: "概览")
            case .details: String(localized: "明细")
            case .records: String(localized: "记录")
            }
        }
    }

    @State private var section: Section = .overview

    @Bindable var library: LibraryRecord

    let result: LibraryScanResult

    let store: LibraryStore

    var body: some View {

        VStack(spacing: 0) {
            HStack {
                Picker("资源库内容", selection: $section) {
                    ForEach(Section.allCases, id: \.self) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 360)
                .accessibilityLabel("资源库内容")
                Spacer()
            }
            .padding(.horizontal, 22)
            .padding(.top, 16)
            .padding(.bottom, 4)

            ScrollView {
                VStack(spacing: 18) {
                    switch section {
                    case .overview:
                        HStack(spacing: 14) {
                            MetricCard(label: String(localized: "资源库大小"), value: FormatHelpers.bytes(result.totalAllocatedSize), icon: "internaldrive")
                            MetricCard(label: String(localized: "可安全清理"), value: FormatHelpers.bytes(result.confirmedCleanableSize), icon: "sparkles", emphasized: true)
                            MetricCard(label: String(localized: "清理项目"), value: result.cacheItems.count.formatted(), icon: "folder.badge.minus")
                        }
                        SizeTrendCard(libraryURL: library.url)
                        StorageBreakdownBar(result: result)
                        EventBreakdownCard(library: library, result: result, store: store)
                    case .details:
                        if result.externalCleanableSize > 0 {
                            Label(String(format: String(localized: "包含外置缓存 %@"), String(FormatHelpers.bytes(result.externalCleanableSize))), systemImage: "externaldrive.fill")
                                .font(AppFont.small(.medium))
                                .foregroundStyle(AppColor.accent)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        CleanupList(result: result, scannedAt: library.lastScanned)
                    case .records:
                        LibraryHistoryPanel(library: library, store: store)
                    }
                    if section != .records {
                        CleanupStatus(library: library, store: store)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(22)
            }
            .scrollIndicators(.hidden)
        }
        .onChange(of: library.id) { _, _ in section = .overview }

        .safeAreaInset(edge: .bottom, spacing: 0) {

            if store.batchSelectedIDs.isEmpty && section != .records {

                CleanupActionBar(library: library, result: result, store: store)

            }

        }

    }

}

private struct LibraryHistoryPanel: View {
    @Environment(\.openWindow) private var openWindow
    let library: LibraryRecord
    let store: LibraryStore

    private var entries: [CleanupHistoryEntry] {
        let libraryPath = library.url.standardizedFileURL.resolvingSymlinksInPath().path
        return store.cleanupHistory.entries.filter {
            $0.libraryURL.standardizedFileURL.resolvingSymlinksInPath().path == libraryPath
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("清理记录")
                    .font(AppFont.title(.semibold, design: .rounded))
                Spacer()
                Button("打开完整记录") { openWindow(id: AuxiliaryWindowID.history) }
                    .buttonStyle(.borderless)
            }

            if entries.isEmpty {
                Text("暂无记录")
                    .foregroundStyle(AppColor.secondaryText)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(entries) { entry in
                        HStack(spacing: 10) {
                            Image(systemName: entry.errorMessages.isEmpty ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                                .foregroundStyle(entry.errorMessages.isEmpty ? AppColor.success : AppColor.danger)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                                    .font(AppFont.callout(.semibold))
                                Text(String(format: String(localized: "移入废纸篓 %@"), String(FormatHelpers.bytes(entry.freedSize))))
                                    .font(AppFont.small(.medium))
                                    .foregroundStyle(AppColor.secondaryText)
                                if let error = entry.errorMessages.first {
                                    Text(error)
                                        .font(AppFont.small(.medium))
                                        .foregroundStyle(AppColor.danger)
                                        .lineLimit(2)
                                }
                            }
                            Spacer()
                            Text(String(format: String(localized: "%@ 项"), String(entry.itemCount)))
                                .font(AppFont.small(.medium))
                                .foregroundStyle(AppColor.tertiaryText)
                        }
                        .padding(12)
                        .background(AppColor.panel)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
            }

            CleanupStatus(library: library, store: store)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
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

    private struct Legend: Identifiable {
        let id: String
        let color: Color
        let bytes: Int64
    }

    let renderSize: Int64

    let proxySize: Int64

    let optimizedSize: Int64

    let protectedAnalysisSize: Int64

    let otherOrMediaSize: Int64

    private var legends: [Legend] {
        var values: [Legend] = []
        if renderSize > 0 { values.append(Legend(id: String(localized: "渲染"), color: AppColor.accent, bytes: renderSize)) }
        if proxySize > 0 { values.append(Legend(id: String(localized: "代理"), color: AppColor.chartProxyMedia, bytes: proxySize)) }
        if optimizedSize > 0 { values.append(Legend(id: String(localized: "优化"), color: AppColor.chartOptimizedMedia, bytes: optimizedSize)) }
        if protectedAnalysisSize > 0 { values.append(Legend(id: String(localized: "分析(受保护)"), color: AppColor.tertiaryText.opacity(0.8), bytes: protectedAnalysisSize)) }
        values.append(Legend(id: String(localized: "原始媒体/工程"), color: AppColor.tertiaryText, bytes: otherOrMediaSize))
        return values
    }



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



            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    ForEach(legends) { legend in legendItem(legend) }
                    Spacer(minLength: 0)
                }
                .fixedSize(horizontal: true, vertical: false)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 8) {
                    ForEach(legends) { legend in legendItem(legend) }
                }
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



    private func legendItem(_ legend: Legend) -> some View {

        HStack(spacing: 5) {

            Circle()

                .fill(legend.color)

                .frame(width: 6, height: 6)

            Text(legend.id)

                .foregroundStyle(AppColor.secondaryText)

            Text(FormatHelpers.bytes(legend.bytes))

                .monospacedDigit()

                .foregroundStyle(AppColor.primaryText)

        }

        .help(String(format: String(localized: "精确大小：%@ 字节"), String(legend.bytes.formatted())))

    }

}



struct MetricCard: View {

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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

        .animation(reduceMotion ? nil : .snappy, value: value)

    }

}



/// 按 Event 拆分的缓存分布：数据与确认弹窗的 Event 勾选完全同源，

/// 让用户在确认前就知道每个 Event 各占多少。

struct EventBreakdownCard: View {

    let library: LibraryRecord

    let result: LibraryScanResult

    let store: LibraryStore



    private struct Slice: Identifiable {

        let id: String

        let title: String

        let size: Int64

        let eventName: String?

    }



    private var slices: [Slice] {

        var totals: [String?: Int64] = [:]

        for item in result.cacheItems {

            let event = FCPStructureRules.candidateLocation(for: item.url, ruleID: item.ruleID)?.eventName

            totals[event, default: 0] += item.allocatedSize

        }

        let sorted = totals.sorted {

            if $0.value != $1.value { return $0.value > $1.value }

            return ($0.key ?? "") < ($1.key ?? "")

        }

        func slice(_ event: String?, size: Int64) -> Slice {

            Slice(id: event.map { "event:\($0)" } ?? "shared", title: event ?? String(localized: "库级共享"), size: size, eventName: event)

        }

        guard sorted.count > 8 else { return sorted.map { slice($0.key, size: $0.value) } }

        let head = sorted.prefix(7).map { slice($0.key, size: $0.value) }

        let rest = sorted.dropFirst(7)

        let tail = rest.reduce(Int64(0)) { $0 + $1.value }

        return head + [Slice(id: "other", title: String(format: String(localized: "其他 %@ 个 Event"), String(rest.count)), size: tail, eventName: nil)]

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
                    if let eventName = slice.eventName {
                        Button {
                            store.requestClean(library, selectedEventName: eventName)
                        } label: {
                            sliceRow(slice, maximum: maxSlice)
                        }
                        .buttonStyle(.plain)
                        .disabled(store.isPreflighting || store.isCleaning || library.spaceToFree < LibraryStore.minimumCleanableSize)
                        .help("选择此 Event 清理")
                    } else {
                        sliceRow(slice, maximum: maxSlice)
                    }
                }
            }


        }

        .padding(18)

        .frame(maxWidth: .infinity, alignment: .topLeading)

        .background(AppColor.panel)

        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

    }

    private func sliceRow(_ slice: Slice, maximum: Int64) -> some View {
        HStack(spacing: 10) {
            Text(slice.title)
                .font(AppFont.callout(.medium))
                .foregroundStyle(AppColor.primaryText)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(minWidth: 80, idealWidth: 132, maxWidth: 180, alignment: .leading)
                .help(slice.title)
            GeometryReader { proxy in
                let fraction = maximum > 0 ? Double(slice.size) / Double(maximum) : 0
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
                .fixedSize(horizontal: true, vertical: false)
                .monospacedDigit()
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(format: String(localized: "%@：可清理 %@"), String(slice.title), String(FormatHelpers.bytes(slice.size))))
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

    @State private var showsAllItems = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let previewLimit = 10



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

        self.itemsByCategory = items.mapValues { candidates in

            candidates.sorted {

                if $0.allocatedSize != $1.allocatedSize { return $0.allocatedSize > $1.allocatedSize }

                return $0.url.path < $1.url.path

            }

        }

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

                        .foregroundStyle(isEmpty ? AppColor.secondaryText : AppColor.primaryText)

                    Spacer()

                    if isEmpty {

                        Text("—")

                            .font(AppFont.callout(design: .monospaced))

                            .foregroundStyle(AppColor.secondaryText)

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

                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.18)) {

                        expandedCategory = isExpanded ? nil : category

                        showsAllItems = false

                    }

                } }

                .accessibilityAddTraits(isEmpty ? [] : .isButton)

                .accessibilityLabel(isEmpty
                    ? String(format: String(localized: "%@：无候选"), String(category.chineseName))
                    : String(format: String(localized: "%@：展开查看明细"), String(category.chineseName)))

                .padding(.vertical, 10)

                if isExpanded, let items = itemsByCategory[category] {

                    VStack(alignment: .leading, spacing: 8) {

                        ForEach(showsAllItems ? items : Array(items.prefix(previewLimit))) { item in

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

                                    Text(item.confidence == .confirmed ? String(localized: "已验证") : item.confidence.rawValue)

                                        .font(AppFont.caption(.medium))

                                        .foregroundStyle(AppColor.secondaryText)

                                    Text(FormatHelpers.bytes(item.allocatedSize))

                                        .font(AppFont.caption(.medium, design: .monospaced))

                                        .foregroundStyle(AppColor.secondaryText)

                                    Text(item.fingerprint.entryCount == 1 ? String(localized: "1 项") : String(format: String(localized: "%@ 项"), String(item.fingerprint.entryCount)))

                                        .font(AppFont.caption(.medium, design: .monospaced))

                                        .foregroundStyle(AppColor.tertiaryText)

                                }

                            }

                            .padding(9)

                            .frame(maxWidth: .infinity, alignment: .leading)

                            .background(AppColor.control.opacity(0.5))

                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                        }

                        if items.count > previewLimit {

                            Button(showsAllItems ? String(localized: "收起明细") : String(format: String(localized: "展开全部 %@ 项"), String(items.count))) {

                                withAnimation(reduceMotion ? nil : .snappy(duration: 0.18)) {

                                    showsAllItems.toggle()

                                }

                            }

                            .buttonStyle(.borderless)

                            .foregroundStyle(AppColor.accent)

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



struct CleanupActionBar: View {

    let library: LibraryRecord

    let result: LibraryScanResult

    let store: LibraryStore

    private var protectedAnalysisSize: Int64 {

        result.observedCacheItems.reduce(0) { $0 + $1.allocatedSize }

    }



    private var isBelowThreshold: Bool {

        library.spaceToFree < LibraryStore.minimumCleanableSize

    }



    var body: some View {

        HStack(spacing: 16) {

            VStack(alignment: .leading, spacing: 3) {

                Text("可清理空间")

                    .font(AppFont.small(.medium))

                    .foregroundStyle(AppColor.secondaryText)

                Text(FormatHelpers.bytes(library.spaceToFree))

                    .font(AppFont.heading(.bold, design: .rounded))

                    .monospacedDigit()

                if library.pendingFreedSize == 0, let estimate = result.reclaimableEstimate {

                    Text(reclaimEstimateText(estimate))

                        .font(AppFont.caption(.medium))

                        .foregroundStyle(AppColor.tertiaryText)

                        .lineLimit(1)

                        .help(reclaimEstimateText(estimate))

                }

            }

            Spacer(minLength: 0)

            Button(actionTitle) {

                store.requestClean(library)

            }

            .buttonStyle(PrimaryActionButtonStyle(enabled: !isBelowThreshold && !store.isPreflighting && !store.isCleaning))

            .frame(width: LayoutMetrics.cleanupActionCardWidth)

            .disabled(isBelowThreshold || store.isPreflighting || store.isCleaning)

            .help(actionHelp)



        }

        .padding(.horizontal, 22)

        .padding(.vertical, 12)

        .frame(maxWidth: .infinity)

        .background(AppColor.workspace)

        .overlay(alignment: .top) { Divider().overlay(AppColor.border) }

        .help(protectedAnalysisSize > 0 ? String(format: String(localized: "已保护分析文件 %@"), String(FormatHelpers.bytes(protectedAnalysisSize))) : "")

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

        if store.isCleaning && store.cleaningLibraryID == library.id {

            return String(format: String(localized: "正在清理 %@/%@"), String(store.singleCleanupCompleted), String(store.singleCleanupTotal))

        }

        if isBelowThreshold {

            return String(format: String(localized: "低于 %@"), String(FormatHelpers.bytes(LibraryStore.minimumCleanableSize)))

        }

        return String(localized: "开始清理")

    }

    private var actionHelp: String {

        if isBelowThreshold {

            return String(format: String(localized: "可清理空间低于 %@，已自动跳过"), String(FormatHelpers.bytes(LibraryStore.minimumCleanableSize)))

        }

        if let seconds = store.estimatedCleanupDuration(forBytes: library.spaceToFree, volumeID: library.volumeID) {

            return String(format: String(localized: "预计耗时 %@"), String(FormatHelpers.estimatedTime(seconds)))

        }

        return String(localized: "将生成文件移入废纸篓")

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
