import AppKit
import SwiftUI
import FCPLibraryCleanerCore

struct AppSettings: View {
    @Bindable var store: LibraryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("设置")
                .font(.system(size: 17, weight: .semibold, design: .rounded))

            sectionHeader("通用")
            HStack {
                Text("工作目录")
                    .font(.system(size: 13, weight: .semibold))
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
                                    .font(.system(size: 12, weight: .medium))
                                    .lineLimit(1)
                                Text(url.path)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(AppColor.secondaryText)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                if let status = store.workDirectoryStatuses[url] {
                                    Text(workDirectoryStatusText(status))
                                        .font(.system(size: 10, weight: .medium))
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

            if !store.ignoredLibraryDirectories.isEmpty {
                sectionHeader("已忽略目录（自动发现不再扫描）")
                VStack(spacing: 8) {
                    ForEach(store.ignoredLibraryDirectories, id: \.self) { path in
                        HStack(spacing: 9) {
                            Image(systemName: "bell.slash.fill")
                                .foregroundStyle(AppColor.tertiaryText)
                            Text(path)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(AppColor.secondaryText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 4)
                            Button("恢复") { store.resumeDirectory(path) }
                                .buttonStyle(.borderless)
                                .font(.system(size: 11, weight: .medium))
                        }
                        .padding(9)
                        .background(AppColor.control)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
            }

            if let library = store.selectedLibrary {
                Divider()
                sectionHeader("当前资源库")
                Text(library.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppColor.primaryText)
                    .lineLimit(1)
                LibrarySettings(library: library, store: store)
            }

            Divider()
            sectionHeader("扫描健康")
            let health = store.scanHealthSummary
            VStack(alignment: .leading, spacing: 4) {
                Text("资源库 \(health.total) 个 · 已扫描 \(health.scanned) 个（缓存复用 \(health.cacheReused)）")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AppColor.secondaryText)
                if health.failed.isEmpty && health.neverScanned == 0 {
                    Label("全部扫描完成", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(AppColor.success)
                } else {
                    if health.neverScanned > 0 {
                        Text("待扫描 \(health.neverScanned) 个")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(AppColor.tertiaryText)
                    }
                    if !health.failed.isEmpty {
                        Text("扫描失败 \(health.failed.count) 个：\(health.failed.joined(separator: "、"))")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(AppColor.danger)
                            .lineLimit(2)
                    }
                }
            }

            Divider()
            sectionHeader("外观")
            Toggle("完成与空间通知", isOn: $store.notificationsEnabled)
                .toggleStyle(.switch)
            Picker("外观", selection: $store.appearanceMode) {
                Text("跟随系统").tag(AppearanceMode.system)
                Text("暗色").tag(AppearanceMode.dark)
                Text("亮色").tag(AppearanceMode.light)
            }
            .pickerStyle(.segmented)
            Stepper("磁盘预警：\(store.lowSpaceWarningGB) GB", value: $store.lowSpaceWarningGB, in: 10...500, step: 10)
                .font(.system(size: 12, weight: .medium))

            Divider()
            sectionHeader("关于")
            Button("检查更新") {
                UpdateController.shared.checkForUpdates()
            }
            .disabled(!UpdateController.shared.isConfigured)
            Label("B 站：调色师手册", systemImage: "play.tv.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AppColor.secondaryText)
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
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(AppColor.tertiaryText)
            .textCase(.uppercase)
    }
}

struct CleanupHistoryView: View {
    let store: CleanupHistoryStore
    @State private var restoreMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("清理记录")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                Spacer()
                if !store.entries.isEmpty {
                    Menu {
                        Button("导出 CSV") { store.presentExportPanel(as: .csv) }
                        Button("导出 JSON") { store.presentExportPanel(as: .json) }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    Button("清空") { store.clear() }
                        .buttonStyle(.borderless)
                }
            }
            if store.entries.isEmpty {
                Text("暂无记录")
                    .font(.system(size: 12, weight: .medium))
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
                                        .font(.system(size: 12, weight: .semibold))
                                        .lineLimit(1)
                                    Text("\(entry.date.formatted(date: .abbreviated, time: .shortened)) · \(FormatHelpers.bytes(entry.freedSize))")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(AppColor.secondaryText)
                                }
                                Spacer()
                                if !entry.trashedItems.isEmpty {
                                    Button("恢复") { restoreMessage = store.restore(entry) }
                                        .buttonStyle(.borderless)
                                    Button("废纸篓") { store.showInTrash(entry) }
                                        .buttonStyle(.borderless)
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
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AppColor.secondaryText)
            }
        }
        .padding(18)
        .frame(width: LayoutMetrics.historyPopoverWidth)
    }
}

struct LibrarySettings: View {
    let library: LibraryRecord
    let store: LibraryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button("生成扫描目录树") { store.inspect(library) }
                .disabled(library.scanResult == nil || library.isInspecting)
            Button("完整重新扫描") { store.scan(library, force: true) }
                .disabled(library.isScanning || library.isQueued)
            if library.isInspecting {
                ProgressView().controlSize(.small)
            } else if let report = library.inspectorReport {
                Text("已检查 \(report.entries.count.formatted()) 项")
                    .font(.caption)
                    .foregroundStyle(AppColor.secondaryText)
            }
            Divider()
            if store.isLibraryIgnored(library) {
                Button("取消忽略") { store.resumeLibrary(library) }
                if let until = library.ignoredUntil, until > Date() {
                    Text("已忽略至 \(until.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(AppColor.secondaryText)
                }
            } else {
                Button("7 天内不再提醒") { store.snoozeLibrary(library) }
                Button("忽略所在目录") { store.ignoreDirectory(library.url.deletingLastPathComponent()) }
            }
            Divider()
            VolumeAccessSection(library: library, store: store)
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
        }
    }
}
