import AppKit
import SwiftUI
import FCPLibraryCleanerCore

struct LibraryPanel: View {
    @Bindable var library: LibraryRecord
    let store: LibraryStore

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 13) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(AppColor.accent)
                    .frame(width: 42, height: 42)
                    .background(AppColor.control)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(library.displayName)
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                    Text(shortPath(library.url))
                        .font(.system(size: 11, design: .monospaced))
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
        .background(AppColor.workspace)
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(AppColor.border, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
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
        .font(.system(size: 11, weight: .semibold))
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

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "hourglass")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(AppColor.accent)
            Text("等待扫描")
                .font(.system(size: 19, weight: .semibold, design: .rounded))
            Button("取消") { store.cancelScan(library) }
                .buttonStyle(.borderless)
                .foregroundStyle(AppColor.secondaryText)
        }
    }
}

struct ScanningView: View {
    let library: LibraryRecord
    let store: LibraryStore

    var body: some View {
        VStack(spacing: 20) {
            ProgressView()
                .controlSize(.large)
                .tint(AppColor.accent)
            Text("正在扫描资源库")
                .font(.system(size: 20, weight: .semibold, design: .rounded))
            HStack(spacing: 12) {
                ScanCounter(value: library.scanProgress.files.formatted(), label: "文件")
                ScanCounter(value: library.scanProgress.directories.formatted(), label: "文件夹")
                ScanCounter(value: FormatHelpers.bytes(library.scanProgress.allocatedBytes), label: "已扫描")
            }
            Button("取消") { store.cancelScan(library) }
                .buttonStyle(.borderless)
                .foregroundStyle(AppColor.secondaryText)
        }
    }
}

struct ScanCounter: View {
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
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

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 30))
                .foregroundStyle(AppColor.danger)
            Text(library.scanError ?? "尚未扫描")
                .font(.system(size: 13))
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

                if result.externalCleanableSize > 0 {
                    Label("包含外置缓存 \(FormatHelpers.bytes(result.externalCleanableSize))", systemImage: "externaldrive.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(AppColor.accent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let growth = store.weeklyGrowth(for: library), growth > 0 {
                    Label("本周增长 \(FormatHelpers.bytes(growth))", systemImage: "chart.line.uptrend.xyaxis")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help("与约一周前的扫描采样相比，资源库总体积的增长量")
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

struct MetricCard: View {
    let label: String
    let value: String
    let icon: String
    var emphasized = false

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(emphasized ? .white : AppColor.secondaryText)
                .frame(width: 38, height: 38)
                .background(emphasized ? AppColor.accent : AppColor.control)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AppColor.secondaryText)
                Text(value)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("最大安全清理")
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .padding(.bottom, 10)

            ForEach(CacheCategory.cleanableCases, id: \.self) { category in
                let items = result.cacheItems.filter { $0.category == category }
                let size = items.reduce(Int64(0)) { $0 + $1.allocatedSize }
                HStack(spacing: 12) {
                    Image(systemName: category.iconName)
                        .foregroundStyle(items.isEmpty ? AppColor.tertiaryText : AppColor.accent)
                        .frame(width: 30, height: 30)
                        .background(AppColor.control)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    Text(category.chineseName)
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                    if items.isEmpty {
                        Text("—")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(AppColor.tertiaryText)
                    } else {
                        Text(FormatHelpers.bytes(size))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(AppColor.secondaryText)
                    }
                }
                .padding(.vertical, 10)
                .opacity(items.isEmpty ? 0.45 : 1)
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

    private var protectedAnalysisSize: Int64 {
        result.observedCacheItems.reduce(0) { $0 + $1.allocatedSize }
    }

    private var isBelowThreshold: Bool {
        library.spaceToFree < LibraryStore.minimumCleanableSize
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("可释放空间")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(AppColor.secondaryText)
            Text(FormatHelpers.bytes(library.spaceToFree))
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .shadow(color: AppColor.accent.opacity(0.35), radius: 12)
                .animation(.snappy, value: library.spaceToFree)
            Spacer(minLength: 5)
            Button(actionTitle) {
                store.requestClean(library)
            }
            .buttonStyle(PrimaryActionButtonStyle(enabled: !isBelowThreshold && !store.isPreflighting && !store.isCleaning))
            .disabled(isBelowThreshold || store.isPreflighting || store.isCleaning)
            .help(isBelowThreshold ? "可清理空间低于 \(FormatHelpers.bytes(LibraryStore.minimumCleanableSize))，已自动跳过" : "将生成文件移入废纸篓")

            if isBelowThreshold && !store.isPreflighting && !store.isCleaning {
                Label("低于 \(FormatHelpers.bytes(LibraryStore.minimumCleanableSize)) 的资源库会自动跳过", systemImage: "info.circle")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AppColor.tertiaryText)
                    .lineLimit(1)
            }

            if protectedAnalysisSize > 0 {
                Label("已保护分析文件 \(FormatHelpers.bytes(protectedAnalysisSize))", systemImage: "lock.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AppColor.tertiaryText)
                    .lineLimit(1)
            }
            if let seconds = store.estimatedCleanupDuration(forBytes: library.spaceToFree, volumeID: library.volumeID) {
                Label("预计耗时 \(FormatHelpers.estimatedTime(seconds))", systemImage: "clock")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AppColor.tertiaryText)
                    .lineLimit(1)
            }
        }
        .padding(20)
        .background(AppColor.panel)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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
                        Text("已清理 \(FormatHelpers.bytes(cleanup.freedAllocatedSize))")
                        if let before = library.cleanupBeforeSize, let after = library.cleanupAfterSize {
                            Text("\(FormatHelpers.bytes(before)) → \(FormatHelpers.bytes(after))")
                                .foregroundStyle(AppColor.secondaryText)
                            // APFS 延迟回收或废纸篓未清空时，实际统计可能小于计划释放
                            let actual = max(0, before - after)
                            if cleanup.freedAllocatedSize > 0,
                               Double(actual) < Double(cleanup.freedAllocatedSize) * 0.9 {
                                Text("空间统计待系统刷新（计划释放 \(FormatHelpers.bytes(cleanup.freedAllocatedSize))）")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(AppColor.tertiaryText)
                                    .lineLimit(1)
                            }
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
            .font(.system(size: 12, weight: .medium))
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

struct VolumeAccessSection: View {
    let library: LibraryRecord
    let store: LibraryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("外置盘诊断")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AppColor.tertiaryText)
                .textCase(.uppercase)
            HStack(spacing: 8) {
                statusLine
                Spacer(minLength: 6)
                if library.isDiagnosingVolume {
                    ProgressView().controlSize(.small)
                } else {
                    Button("诊断") { store.diagnoseVolumeAccess(library) }
                        .buttonStyle(.borderless)
                        .foregroundStyle(AppColor.secondaryText)
                    Button("重新授权") { store.reauthorizeLibraryAccess(library) }
                        .buttonStyle(.borderless)
                        .foregroundStyle(AppColor.accent)
                }
            }
            if let report = library.accessReport, report.mounted, !report.writable {
                Label("卷处于只读状态，清理与废纸篓移动都会失败，请重新挂载外置盘", systemImage: "lock.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(AppColor.danger)
                    .lineLimit(2)
            }
            if let at = library.lastAccessibleAt {
                Text("上次可访问 \(at.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(AppColor.tertiaryText)
            }
        }
    }

    @ViewBuilder private var statusLine: some View {
        if let report = library.accessReport {
            HStack(spacing: 5) {
                Circle()
                    .fill(report.mounted ? (report.writable ? AppColor.success : AppColor.danger) : AppColor.danger)
                    .frame(width: 7, height: 7)
                Text(report.mounted ? (report.writable ? "在线 · 可写" : "在线 · 只读") : "已断开或未挂载")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(report.mounted ? AppColor.primaryText : AppColor.danger)
            }
        } else {
            Text("尚未检测")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AppColor.secondaryText)
        }
    }
}
