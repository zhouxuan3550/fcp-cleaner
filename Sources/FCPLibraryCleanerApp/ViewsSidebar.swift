import AppKit
import SwiftUI
import FCPLibraryCleanerCore

struct MainWorkspace: View {
    let store: LibraryStore
    let isDropTargeted: Bool
    var searchFocused: FocusState<Bool>.Binding

    var body: some View {
        VStack(spacing: 12) {
            if store.libraries.isEmpty {
                EmptyDropZone(store: store, isDropTargeted: isDropTargeted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(alignment: .top, spacing: 12) {
                    LibrarySidebar(store: store, searchFocused: searchFocused)
                        .frame(width: LayoutMetrics.sidebarWidth)
                    Group {
                        if let library = store.selectedLibrary {
                            LibraryPanel(library: library, store: store)
                        } else {
                            NoCleanupView(store: store)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if !store.batchSelectedIDs.isEmpty {
                BatchActionBar(store: store)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct LibrarySidebar: View {
    @Bindable var store: LibraryStore
    var searchFocused: FocusState<Bool>.Binding

    var body: some View {
        let fastestGrowingID = store.fastestGrowingLibraryID
        VStack(spacing: 0) {
            controls
            Divider().overlay(AppColor.border)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3, pinnedViews: .sectionHeaders) {
                    ForEach(sections) { section in
                        Section {
                            ForEach(section.libraries) { library in
                                LibraryRow(library: library, store: store, isFastestGrowing: library.id == fastestGrowingID)
                            }
                        } header: {
                            SidebarDiskHeader(section: section, store: store)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
            }
            .scrollIndicators(.hidden)
        }
        .frame(maxHeight: .infinity)
        .background(AppColor.workspace)
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(AppColor.border, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var controls: some View {
        VStack(spacing: 8) {
            // 筛选 chips 独占一行：四个固定文案 chip + 计数的最小宽约 310pt，
            // 若再与其他控件同行会超出侧栏框架，把整列撑宽压到详情面板下面。
            HStack(spacing: 5) {
                ForEach(LibraryFilter.allCases) { filter in
                    Button {
                        store.setFilter(filter)
                    } label: {
                        HStack(spacing: 5) {
                            Text(filter.title)
                            Text(store.count(for: filter).formatted())
                                .monospacedDigit()
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(filter == store.libraryFilter ? Color.white.opacity(0.85) : AppColor.secondaryText)
                        }
                    }
                    .buttonStyle(FilterButtonStyle(isSelected: filter == store.libraryFilter, isDefault: filter == .waiting))
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AppColor.tertiaryText)
                    TextField("搜索资源库", text: $store.searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .focused(searchFocused)
                    if !store.searchText.isEmpty {
                        Button {
                            store.searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(AppColor.tertiaryText)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("清除搜索")
                    }
                }
                .padding(.horizontal, 9)
                .frame(height: 28)
                .background(AppColor.control)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                Menu {
                    ForEach(LibrarySort.allCases) { sort in
                        Button {
                            store.librarySort = sort
                        } label: {
                            if sort == store.librarySort {
                                Label(sort.title, systemImage: "checkmark")
                            } else {
                                Text(sort.title)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AppColor.secondaryText)
                        .frame(width: 28, height: 28)
                        .background(AppColor.control)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .accessibilityLabel("排序：\(store.librarySort.title)")
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("排序：\(store.librarySort.title)")

                Menu {
                    ForEach(InactivityFilter.allCases) { filter in
                        Button {
                            store.setInactivityFilter(filter)
                        } label: {
                            if filter == store.inactivityFilter {
                                Label(filter.title, systemImage: "checkmark")
                            } else {
                                Text(filter.title)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "clock")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AppColor.secondaryText)
                        .frame(width: 28, height: 28)
                        .background(AppColor.control)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .accessibilityLabel("筛选：\(store.inactivityFilter.title)")
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(store.inactivityFilter.title)

                if store.libraryFilter == .waiting {
                    Button {
                        store.toggleSelectAllCleanableLibraries()
                    } label: {
                        Image(systemName: store.areAllCleanableLibrariesSelected ? "checkmark.circle.fill" : "checkmark.circle")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(store.areAllCleanableLibrariesSelected ? AppColor.accent : AppColor.secondaryText)
                            .frame(width: 28, height: 28)
                            .background(AppColor.control)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(store.batchCleanableLibraries.isEmpty || store.isBatchCleaning || store.isPreflighting)
                    .accessibilityLabel(store.areAllCleanableLibrariesSelected ? "取消全选" : "全选")
                    .help(store.areAllCleanableLibrariesSelected ? "取消全选" : "全选")
                }
            }
        }
        .padding(12)
    }

    private var sections: [SidebarSection] {
        let grouped = Dictionary(grouping: store.filteredLibraries, by: \.volumeURL)
        return grouped
            .map { volumeURL, records in
                SidebarSection(
                    volumeURL: volumeURL,
                    name: records.first?.volumeName ?? volumeURL.lastPathComponent,
                    libraries: records,
                    totalCleanable: records.reduce(0) { $0 + $1.cleanableDisplaySize }
                )
            }
            .sorted { $0.totalCleanable > $1.totalCleanable }
    }
}

struct SidebarSection: Identifiable {
    let volumeURL: URL
    let name: String
    let libraries: [LibraryRecord]
    let totalCleanable: Int64

    var id: URL { volumeURL }
}

struct SidebarDiskHeader: View {
    let section: SidebarSection
    let store: LibraryStore

    private var isSelected: Bool { store.selectedVolumeURL == section.volumeURL }
    private var isLowSpace: Bool { store.lowSpaceWarnings.contains { $0.volumeURL == section.volumeURL } }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: isLowSpace ? "externaldrive.badge.exclamationmark" : "externaldrive.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isSelected ? AppColor.accent : (isLowSpace ? AppColor.danger : AppColor.tertiaryText))
            Text(section.name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isSelected ? AppColor.primaryText : AppColor.secondaryText)
                .lineLimit(1)
            Text(FormatHelpers.bytes(section.totalCleanable))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AppColor.secondaryText)
                .monospacedDigit()
            Spacer(minLength: 4)
            Text("\(section.libraries.count) 个")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AppColor.tertiaryText)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(AppColor.workspace)
        .contentShape(Rectangle())
        .onTapGesture {
            guard store.libraryFilter == .waiting else { return }
            store.selectVolume(section.volumeURL)
        }
        .help(store.libraryFilter == .waiting ? (isSelected ? "显示全部磁盘" : "只显示此磁盘") : section.name)
    }
}

struct LibraryRow: View {
    let library: LibraryRecord
    let store: LibraryStore
    var isFastestGrowing = false
    @State private var isHovered = false

    private var isSelected: Bool { library.id == store.selectedID }
    private var isBatchSelected: Bool { store.batchSelectedIDs.contains(library.id) }

    var body: some View {
        HStack(spacing: 9) {
            leadingMark
            Button {
                store.selectedID = library.id
            } label: {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(library.displayName)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(AppColor.primaryText)
                                .lineLimit(1)
                            if isFastestGrowing {
                                Label("增长最快", systemImage: "arrow.up.forward")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(AppColor.accent)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(AppColor.accent.opacity(0.14))
                                    .clipShape(Capsule())
                                    .help("该资源库一周内体积增长最快")
                            }
                        }
                        Text(subtitle)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(library.scanError != nil || library.cleanupError != nil ? AppColor.danger : AppColor.tertiaryText)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    trailingDetail
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(isSelected ? AppColor.control : (isHovered ? AppColor.control.opacity(0.55) : Color.clear))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .contextMenu {
            if store.isLibraryIgnored(library) {
                Button("取消忽略") { store.resumeLibrary(library) }
                if let until = library.ignoredUntil, until > Date() {
                    Text("已忽略至 \(until.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                }
            } else {
                Button("7 天内不再提醒") { store.snoozeLibrary(library) }
                Button("忽略所在目录的全部资源库") { store.ignoreDirectory(library.url.deletingLastPathComponent()) }
            }
        }
    }

    @ViewBuilder
    private var leadingMark: some View {
        if store.libraryFilter == .waiting {
            Button {
                store.toggleBatchSelection(library)
            } label: {
                Image(systemName: isBatchSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(isBatchSelected ? AppColor.accent : AppColor.tertiaryText)
            }
            .buttonStyle(.plain)
            .disabled(library.scanResult == nil || library.isScanning || library.spaceToFree < LibraryStore.minimumCleanableSize)
            .help(isBatchSelected ? "取消勾选" : "加入批量清理")
        } else {
            Image(systemName: store.libraryFilter == .scanning ? "hourglass" : (store.libraryFilter == .ignored ? "bell.slash" : "minus.circle"))
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(AppColor.tertiaryText)
        }
    }

    @ViewBuilder
    private var trailingDetail: some View {
        if library.isScanning || library.isQueued {
            ProgressView()
                .controlSize(.mini)
                .tint(AppColor.accent)
        } else {
            Text(FormatHelpers.bytes(library.cleanableDisplaySize))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AppColor.secondaryText)
                .monospacedDigit()
        }
    }

    private var subtitle: String {
        var status: String
        if library.isScanning {
            status = library.usedCachedScan ? "缓存" : "扫描中"
        } else if library.isQueued {
            status = "等待扫描"
        } else if store.isLibraryIgnored(library) {
            status = "已忽略"
            if let until = library.ignoredUntil, until > Date() {
                let days = max(1, Int(ceil(until.timeIntervalSinceNow / 86_400)))
                status += " · \(days) 天后恢复"
            }
        } else if library.accessReport?.mounted == false {
            status = "磁盘已断开"
        } else if library.scanError != nil {
            status = "扫描失败"
        } else if library.cleanupError != nil {
            status = "预检未通过"
        } else if library.usedCachedScan {
            status = "增量复用"
        } else {
            status = "已就绪"
        }
        if let tag = library.discoverySource?.title {
            status += " · \(tag)"
        }
        return status
    }
}

struct BatchActionBar: View {
    let store: LibraryStore

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(AppColor.accent)
            Text("已选 \(store.batchSelectedIDs.count) 个资源库")
                .font(.system(size: 12, weight: .semibold))
            Text(FormatHelpers.bytes(store.selectedBatchSpace))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppColor.accent)
                .monospacedDigit()
            Spacer()
            Button("取消全选") {
                store.batchSelectedIDs.removeAll()
            }
            .buttonStyle(QueueActionButtonStyle(enabled: !store.isBatchCleaning && !store.isPreflighting))
            .disabled(store.isBatchCleaning || store.isPreflighting)

            Button {
                store.requestBatchClean()
            } label: {
                Label(batchActionTitle, systemImage: store.isPreflighting ? "hourglass" : "trash")
            }
            .buttonStyle(QueueActionButtonStyle(emphasized: true, enabled: !store.isBatchCleaning && !store.isPreflighting))
            .disabled(store.isBatchCleaning || store.isPreflighting)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(AppColor.panel)
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AppColor.border, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var batchActionTitle: String {
        if store.isPreflighting {
            return "正在检查 \(store.cleanupPreparationCompleted)/\(store.cleanupPreparationTotal)"
        }
        if store.isBatchCleaning {
            return "正在清理 \(store.batchCleanupCompleted)/\(store.batchCleanupTotal)"
        }
        return "清理所选 \(store.batchSelectedIDs.count)"
    }
}

struct NoCleanupView: View {
    let store: LibraryStore

    var body: some View {
        VStack(spacing: 13) {
            Image(systemName: emptyIcon)
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(store.libraryFilter == .waiting ? AppColor.success : AppColor.secondaryText)
            Text(emptyTitle)
                .font(.system(size: 19, weight: .semibold, design: .rounded))
            Text(emptySubtitle)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(AppColor.secondaryText)
            Button("重新扫描") { store.discoverLibraries() }
                .buttonStyle(HeaderButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppColor.workspace)
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(AppColor.border, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var emptyIcon: String {
        switch store.libraryFilter {
        case .waiting: "checkmark.circle.fill"
        case .scanning: "clock"
        case .skipped: "line.3.horizontal.decrease.circle"
        case .ignored: "bell.slash"
        }
    }

    private var emptyTitle: String {
        switch store.libraryFilter {
        case .waiting: "暂无需要清理的资源库"
        case .scanning: "没有扫描任务"
        case .skipped: "没有已跳过的资源库"
        case .ignored: "没有已忽略的资源库"
        }
    }

    private var emptySubtitle: String {
        switch store.libraryFilter {
        case .waiting: "可清理空间低于 \(FormatHelpers.bytes(LibraryStore.minimumCleanableSize)) 的项目会自动跳过"
        case .scanning: "扫描任务最多同时运行 3 个"
        case .skipped: "低于 \(FormatHelpers.bytes(LibraryStore.minimumCleanableSize)) 的资源库会显示在这里"
        case .ignored: "右键资源库可选择「7 天内不再提醒」"
        }
    }
}

struct EmptyDropZone: View {
    let store: LibraryStore
    let isDropTargeted: Bool

    var body: some View {
        VStack(spacing: 14) {
            if store.isDiscovering {
                ProgressView()
                    .controlSize(.large)
                    .tint(AppColor.accent)
            } else {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 39, weight: .light))
                    .foregroundStyle(AppColor.secondaryText)
            }
            Text(store.isDiscovering ? "正在查找 FCP 资源库" : "拖入 .fcpbundle 资源库")
                .font(.system(size: 20, weight: .semibold, design: .rounded))
            Text(store.isDiscovering ? "发现后将自动扫描" : "双击此处选择")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(AppColor.secondaryText)
            if let error = store.discoveryError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(AppColor.danger)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(isDropTargeted ? AppColor.accent.opacity(0.08) : AppColor.workspace)
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(
                    isDropTargeted ? AppColor.accent : AppColor.dashedBorder,
                    style: StrokeStyle(lineWidth: 2, dash: [11, 9])
                )
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: store.openLibraryPanel)
    }
}
