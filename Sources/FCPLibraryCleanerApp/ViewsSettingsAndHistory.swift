import AppKit
import SwiftUI
import FCPLibraryCleanerCore

struct AppSettings: View {
    @Bindable var store: LibraryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("设置")
                .font(AppFont.title(.semibold, design: .rounded))

            sectionHeader("扫描")
            HStack {
                Text("工作目录")
                    .font(AppFont.body(.semibold))
                Spacer()
                Button("添加") { store.openWorkDirectoryPanel() }
                    .buttonStyle(.borderless)
            }

            if store.workDirectories.isEmpty {
                Text("未设置")
                    .font(.caption)
                    .foregroundStyle(AppColor.secondaryText)
            } else {
                VStack(spacing: 8) {
                    ForEach(store.workDirectories, id: \.self) { url in
                        HStack(spacing: 9) {
                            Image(systemName: "folder.fill")
                                .foregroundStyle(AppColor.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(url.lastPathComponent)
                                    .font(AppFont.callout(.medium))
                                    .lineLimit(1)
                                Text(url.path)
                                    .font(AppFont.caption(design: .monospaced))
                                    .foregroundStyle(AppColor.secondaryText)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                if let status = store.workDirectoryStatuses[url] {
                                    Text(workDirectoryStatusText(status))
                                        .font(AppFont.caption(.medium))
                                        .foregroundStyle(status.failed ? AppColor.danger : AppColor.tertiaryText)
                                        .lineLimit(1)
                                }
                            }
                            Spacer(minLength: 4)
                            Button {
                                store.removeWorkDirectory(url)
                            } label: {
                                Image(systemName: "xmark")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(AppColor.secondaryText)
                            .accessibilityLabel("移除 \(url.lastPathComponent)")
                        }
                        .padding(9)
                        .background(AppColor.control)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
            }

            if !store.possibleOrphanCaches.isEmpty {
                DisclosureGroup("疑似孤立缓存（\(store.possibleOrphanCaches.count)）") {
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(store.possibleOrphanCaches) { cache in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(cache.url.lastPathComponent).lineLimit(1)
                                        Text(cache.allocatedBytes.map { "识别缓存 \(FormatHelpers.bytes($0))" } ?? "大小不可用")
                                            .font(.caption)
                                            .foregroundStyle(AppColor.secondaryText)
                                    }
                                    Spacer()
                                    Button("显示") { NSWorkspace.shared.activateFileViewerSelecting([cache.url]) }
                                        .buttonStyle(.borderless)
                                }
                                .help(cache.url.path)
                            }
                        }
                    }
                    .frame(maxHeight: 150)
                    .padding(.top, 4)
                }
                .font(AppFont.callout(.medium))
                .help("仅识别工作目录中的疑似缓存文件夹，无法确认其是否被其他资源库使用。")
            }

            if !store.ignoredLibraryDirectories.isEmpty {
                sectionHeader("已忽略目录（自动发现不再扫描）")
                VStack(spacing: 8) {
                    ForEach(store.ignoredLibraryDirectories, id: \.self) { path in
                        HStack(spacing: 9) {
                            Image(systemName: "bell.slash.fill")
                                .foregroundStyle(AppColor.tertiaryText)
                            Text(path)
                                .font(AppFont.caption(design: .monospaced))
                                .foregroundStyle(AppColor.secondaryText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 4)
                            Button("恢复") { store.resumeDirectory(path) }
                                .buttonStyle(.borderless)
                                .font(AppFont.small(.medium))
                        }
                        .padding(9)
                        .background(AppColor.control)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
            }

            Picker("定时检查", selection: $store.scheduledCheckFrequency) {
                ForEach(ScheduledCheckFrequency.allCases) { frequency in
                    Text(frequency.title).tag(frequency)
                }
            }
            .pickerStyle(.segmented)
            Text("到点自动发现并增量扫描，完成后仅发送通知，绝不自动清理")
                .font(AppFont.caption(.medium))
                .foregroundStyle(AppColor.tertiaryText)
            Stepper("磁盘预警：\(store.lowSpaceWarningGB) GB", value: $store.lowSpaceWarningGB, in: 10...500, step: 10)
                .font(AppFont.callout(.medium))

            Divider()
            sectionHeader("通知与外观")
            Toggle("完成与空间通知", isOn: $store.notificationsEnabled)
                .toggleStyle(.switch)
            Picker("外观", selection: $store.appearanceMode) {
                Text("跟随系统").tag(AppearanceMode.system)
                Text("暗色").tag(AppearanceMode.dark)
                Text("亮色").tag(AppearanceMode.light)
            }
            .pickerStyle(.segmented)

            Divider()
            sectionHeader("关于")
            BrandLinksView(
                repositoryURL: URL(string: "https://github.com/zhouxuan3550/fcp-cleaner"),
                repositoryName: "FCP Cleaner"
            )
            Button("检查更新") {
                UpdateController.shared.checkForUpdates()
            }
            .disabled(!UpdateController.shared.isConfigured)
        }
        .padding(20)
        .frame(width: LayoutMetrics.settingsPopoverWidth)
    }

    private func workDirectoryStatusText(_ status: WorkDirectoryStatus) -> String {
        if status.failed { return "无法访问（检查磁盘连接与权限）" }
        if status.discoveredCount == 0 { return "此目录内未发现 .fcpbundle" }
        let time = status.updatedAt.formatted(date: .omitted, time: .shortened)
        return "发现 \(status.discoveredCount) 个资源库 · \(time)"
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(AppFont.small(.semibold))
            .foregroundStyle(AppColor.tertiaryText)
            .textCase(.uppercase)
    }
}

struct CleanupHistoryView: View {
    let store: CleanupHistoryStore
    var libraryStore: LibraryStore?
    @State private var restoreMessage: String?
    @State private var isRestoring = false
    @State private var entryToPurge: CleanupHistoryEntry?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("清理记录")
                    .font(AppFont.title(.semibold, design: .rounded))
                Spacer()
                if !store.entries.isEmpty {
                    Menu {
                        Button("导出 CSV") { store.presentExportPanel(as: .csv) }
                        Button("导出 JSON") { store.presentExportPanel(as: .json) }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .font(AppFont.callout(.medium))
                    }
                    .accessibilityLabel("导出清理记录")
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    Button("清空") { store.clear() }
                        .buttonStyle(.borderless)
                        .disabled(isRestoring || store.isBusy)
                }
            }
            if let monthly = monthlySummary {
                Label("本月已清理 \(monthly.count) 次 · 移入废纸篓 \(FormatHelpers.bytes(monthly.freed))", systemImage: "calendar.badge.checkmark")
                    .font(AppFont.small(.semibold))
                    .foregroundStyle(AppColor.accent)
                    .help("按清理记录所在月份统计（当地时间）")
            }
            if let libraryStore {
                interruptedCleanupBanners(libraryStore)
            }
            if store.entries.isEmpty {
                Text("暂无记录")
                    .font(AppFont.callout(.medium))
                    .foregroundStyle(AppColor.secondaryText)
                    .frame(maxWidth: .infinity, minHeight: 90)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(store.entries) { entry in
                            HStack(spacing: 10) {
                                Image(systemName: entry.errorMessages.isEmpty ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                                    .foregroundStyle(entry.errorMessages.isEmpty ? AppColor.success : AppColor.danger)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(entry.libraryName)
                                        .font(AppFont.callout(.semibold))
                                        .lineLimit(1)
                                    Text("\(entry.date.formatted(date: .abbreviated, time: .shortened)) · 移入废纸篓 \(FormatHelpers.bytes(entry.freedSize))")
                                        .font(AppFont.small(.medium))
                                        .foregroundStyle(AppColor.secondaryText)
                                    if let delta = entry.availableSpaceChange {
                                        Text("可用空间变化 \(delta < 0 ? "−" : "+")\(FormatHelpers.bytes(delta.magnitude > UInt64(Int64.max) ? Int64.max : Int64(delta.magnitude)))")
                                            .font(AppFont.small(.medium))
                                            .foregroundStyle(AppColor.secondaryText)
                                            .help("此值包含操作期间磁盘上其他活动造成的变化")
                                    }
                                }
                                Spacer()
                                if !entry.trashedItems.isEmpty {
                                    Button("恢复") {
                                        guard !isRestoring else { return }
                                        isRestoring = true
                                        Task {
                                            restoreMessage = await store.restore(entry)
                                            isRestoring = false
                                        }
                                    }
                                    .buttonStyle(.borderless)
                                    .disabled(isRestoring || store.isBusy)
                                    Button("废纸篓") { store.showInTrash(entry) }
                                        .buttonStyle(.borderless)
                                        .disabled(isRestoring || store.isBusy)
                                    if entry.trashedItems.contains(where: { $0.snapshot != nil }) {
                                        Button("清空本次") { entryToPurge = entry }
                                            .buttonStyle(.borderless)
                                            .disabled(isRestoring || store.isBusy)
                                    }
                                }
                            }
                            .padding(10)
                            .background(AppColor.control)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                    }
                }
                .frame(maxHeight: 360)
            }
            if let restoreMessage {
                Text(restoreMessage)
                    .font(AppFont.small(.medium))
                    .foregroundStyle(AppColor.secondaryText)
            }
        }
        .padding(18)
        .frame(width: LayoutMetrics.historyPopoverWidth)
        .alert("永久删除本次清理的项目？", isPresented: Binding(
            get: { entryToPurge != nil },
            set: { if !$0 { entryToPurge = nil } }
        ), presenting: entryToPurge) { entry in
            Button("永久删除", role: .destructive) {
                isRestoring = true
                Task {
                    restoreMessage = await store.purge(entry.id)
                    isRestoring = false
                }
            }
            Button("取消", role: .cancel) { }
        } message: { _ in
            Text("仅清空本次记录中可验证的废纸篓项目，删除后无法恢复。")
        }
    }

    /// 本月（当地时区）清理汇总：数据全部来自既有历史，无额外持久化。
    private var monthlySummary: (freed: Int64, count: Int)? {
        let calendar = Calendar.current
        let monthEntries = store.entries.filter {
            calendar.isDate($0.date, equalTo: Date(), toGranularity: .month)
        }
        guard !monthEntries.isEmpty else { return nil }
        return (monthEntries.reduce(0) { $0 + $1.freedSize }, monthEntries.count)
    }

    /// 上次清理中断的待清计划入口：重建走普通确认流程，绝不自动清理。
    @ViewBuilder
    private func interruptedCleanupBanners(_ libraryStore: LibraryStore) -> some View {
        if !libraryStore.interruptedCleanups.isEmpty {
            VStack(spacing: 8) {
                ForEach(libraryStore.interruptedCleanups) { item in
                    HStack(spacing: 9) {
                        Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                            .foregroundStyle(AppColor.warning)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("上次清理中断：\(item.libraryName)")
                                .font(AppFont.callout(.semibold))
                                .lineLimit(1)
                            Text("\(item.pendingCount) 项未完成 · \(FormatHelpers.bytes(item.pendingSize))")
                                .font(AppFont.small(.medium))
                                .foregroundStyle(AppColor.secondaryText)
                        }
                        Spacer(minLength: 6)
                        Button("重建待清计划") { libraryStore.rebuildInterruptedCleanup(item) }
                            .buttonStyle(.borderless)
                            .foregroundStyle(AppColor.accent)
                        Button("忽略") { libraryStore.discardInterruptedCleanup(item) }
                            .buttonStyle(.borderless)
                            .foregroundStyle(AppColor.secondaryText)
                    }
                    .padding(10)
                    .background(AppColor.control)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
        }
    }
}
