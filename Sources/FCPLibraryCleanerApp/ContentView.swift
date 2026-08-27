import AppKit
import SwiftUI
import UniformTypeIdentifiers
import FCPLibraryCleanerCore

struct ContentView: View {
    @State private var store = LibraryStore.shared
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            AppHeader(store: store)
            MainWorkspace(store: store, isDropTargeted: isDropTargeted)
                .padding(.horizontal, 38)
                .padding(.bottom, 34)
        }
        .frame(minWidth: 940, minHeight: 660)
        .background(AppColor.canvas.ignoresSafeArea())
        .preferredColorScheme(store.appearanceMode.colorScheme)
        .overlay(alignment: .bottomTrailing) {
            if let notice = store.cleanupNotice {
                CleanupNoticeView(notice: notice) {
                    store.dismissCleanupNotice()
                }
                .padding(24)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.28), value: store.cleanupNotice?.id)
        .task { store.beginAutomaticDiscovery() }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            for provider in providers {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    guard let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    Task { @MainActor in store.add(libraryURLs: [url]) }
                }
            }
            return !providers.isEmpty
        }
        .sheet(item: $store.cleanConfirmation) { confirmation in
            SingleCleanConfirmationSheet(confirmation: confirmation, store: store)
        }
        .sheet(item: $store.batchCleanConfirmation) { confirmation in
            BatchCleanConfirmationSheet(confirmation: confirmation, store: store)
        }
    }
}

private struct AppHeader: View {
    let store: LibraryStore
    @State private var showsSettings = false
    @State private var showsHistory = false

    var body: some View {
        HStack(spacing: 18) {
            CleanerVectorMark()
                .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 4) {
                Text("FCP Cleaner")
                    .font(.system(size: 25, weight: .bold, design: .rounded))
                Text("自动扫描 · 安全清理")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AppColor.secondaryText)
            }

            Spacer(minLength: 18)

            Button {
                showsHistory.toggle()
            } label: {
                Label("记录", systemImage: "clock.arrow.circlepath")
            }
            .buttonStyle(HeaderButtonStyle())
            .popover(isPresented: $showsHistory, arrowEdge: .bottom) {
                CleanupHistoryView(store: store.cleanupHistory)
            }

            Button {
                showsSettings.toggle()
            } label: {
                Label("设置", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(HeaderButtonStyle())
            .popover(isPresented: $showsSettings, arrowEdge: .bottom) {
                AppSettings(store: store)
            }

            Button {
                store.discoverLibraries()
            } label: {
                Label(store.isDiscovering ? "扫描中" : "自动扫描", systemImage: store.isDiscovering ? "hourglass" : "arrow.clockwise")
                    .symbolEffect(.pulse, isActive: store.isDiscovering)
            }
            .buttonStyle(HeaderButtonStyle())
            .disabled(store.isDiscovering)

            Button(action: store.openLibraryPanel) {
                Label("添加资源库", systemImage: "plus")
            }
            .buttonStyle(HeaderButtonStyle(emphasized: true))
        }
        .padding(.horizontal, 38)
        .padding(.top, 28)
        .padding(.bottom, 26)
    }
}

private struct CleanerVectorMark: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(AppColor.accent)
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    star
                    star
                }
                HStack(spacing: 6) {
                    star
                    star
                }
            }
        }
        .frame(width: 48, height: 48)
        .shadow(color: AppColor.accent.opacity(0.35), radius: 10, y: 4)
        .accessibilityHidden(true)
    }

    private var star: some View {
        Image(systemName: "star.fill")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(0.88))
    }
}

private struct MainWorkspace: View {
    let store: LibraryStore
    let isDropTargeted: Bool

    var body: some View {
        VStack(spacing: 12) {
            if store.libraries.isEmpty {
                EmptyDropZone(store: store, isDropTargeted: isDropTargeted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(alignment: .top, spacing: 12) {
                    LibrarySidebar(store: store)
                        .frame(width: 300)
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

private struct LibrarySidebar: View {
    @Bindable var store: LibraryStore

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider().overlay(AppColor.border)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3, pinnedViews: .sectionHeaders) {
                    ForEach(sections) { section in
                        Section {
                            ForEach(section.libraries) { library in
                                LibraryRow(library: library, store: store)
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
            HStack(spacing: 6) {
                ForEach(LibraryFilter.allCases) { filter in
                    Button {
                        store.setFilter(filter)
                    } label: {
                        HStack(spacing: 6) {
                            Text(filter.title)
                            Text(store.count(for: filter).formatted())
                                .monospacedDigit()
                                .foregroundStyle(filter == store.libraryFilter ? Color.white : AppColor.secondaryText)
                        }
                    }
                    .buttonStyle(FilterButtonStyle(isSelected: filter == store.libraryFilter))
                }
                Spacer(minLength: 4)
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
                        .frame(width: 28, height: 30)
                        .background(AppColor.control)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(store.inactivityFilter.title)
            }

            HStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AppColor.tertiaryText)
                    TextField("搜索资源库", text: $store.searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
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
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("排序：\(store.librarySort.title)")

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

private struct SidebarSection: Identifiable {
    let volumeURL: URL
    let name: String
    let libraries: [LibraryRecord]
    let totalCleanable: Int64

    var id: URL { volumeURL }
}

private struct SidebarDiskHeader: View {
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
            Text(format(section.totalCleanable))
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

private struct LibraryRow: View {
    let library: LibraryRecord
    let store: LibraryStore
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
                        Text(library.displayName)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(AppColor.primaryText)
                            .lineLimit(1)
                        Text(subtitle)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(library.lastError != nil ? AppColor.danger : AppColor.tertiaryText)
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
            Image(systemName: store.libraryFilter == .scanning ? "hourglass" : "minus.circle")
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
            Text(format(library.cleanableDisplaySize))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AppColor.secondaryText)
                .monospacedDigit()
        }
    }

    private var subtitle: String {
        if library.isScanning { return library.usedCachedScan ? "缓存" : "扫描中" }
        if library.isQueued { return "等待扫描" }
        if library.lastError != nil { return "扫描失败" }
        if library.usedCachedScan { return "增量复用" }
        return "已就绪"
    }
}

private struct BatchActionBar: View {
    let store: LibraryStore

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(AppColor.accent)
            Text("已选 \(store.batchSelectedIDs.count) 个资源库")
                .font(.system(size: 12, weight: .semibold))
            Text(format(store.selectedBatchSpace))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppColor.accent)
                .monospacedDigit()
            Spacer()
            Button("取消全选") {
                store.batchSelectedIDs.removeAll()
            }
            .buttonStyle(QueueActionButtonStyle())
            .disabled(store.isBatchCleaning || store.isPreflighting)

            Button {
                store.requestBatchClean()
            } label: {
                Label(batchActionTitle, systemImage: store.isPreflighting ? "hourglass" : "trash")
            }
            .buttonStyle(QueueActionButtonStyle(emphasized: true))
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

private struct FilterButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(isSelected ? Color.white : AppColor.secondaryText)
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(isSelected ? AppColor.accent : AppColor.control)
            .clipShape(Capsule())
            .opacity(configuration.isPressed ? 0.74 : 1)
    }
}

private struct QueueActionButtonStyle: ButtonStyle {
    var emphasized = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(emphasized ? Color.white : AppColor.primaryText)
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background(emphasized ? AppColor.accent : AppColor.control)
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(emphasized ? Color.clear : AppColor.border, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

private struct NoCleanupView: View {
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
        }
    }

    private var emptyTitle: String {
        switch store.libraryFilter {
        case .waiting: "暂无需要清理的资源库"
        case .scanning: "没有扫描任务"
        case .skipped: "没有已跳过的资源库"
        }
    }

    private var emptySubtitle: String {
        switch store.libraryFilter {
        case .waiting: "可清理空间低于 500 MB 的项目会自动跳过"
        case .scanning: "扫描任务最多同时运行 3 个"
        case .skipped: "低于 500 MB 的资源库会显示在这里"
        }
    }
}

private struct EmptyDropZone: View {
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

private struct LibraryPanel: View {
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
                    Text(library.url.path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(AppColor.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
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
                .help("重新扫描")
                .contextMenu {
                    Button("完整重新扫描") { store.scan(library, force: true) }
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

private struct LibraryStatusBadge: View {
    let library: LibraryRecord

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(library.lastError == nil ? AppColor.success : AppColor.danger)
                .frame(width: 7, height: 7)
            Text(
                library.isQueued ? "等待扫描" :
                library.isScanning ? "扫描中" :
                library.lastError != nil ? "扫描失败" :
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

private struct QueuedScanView: View {
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

private struct ScanningView: View {
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
                ScanCounter(value: format(library.scanProgress.allocatedBytes), label: "已扫描")
            }
            Button("取消") { store.cancelScan(library) }
                .buttonStyle(.borderless)
                .foregroundStyle(AppColor.secondaryText)
        }
    }
}

private struct ScanCounter: View {
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

private struct ScanErrorView: View {
    let library: LibraryRecord
    let store: LibraryStore

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 30))
                .foregroundStyle(AppColor.danger)
            Text(library.lastError ?? "尚未扫描")
                .font(.system(size: 13))
                .foregroundStyle(AppColor.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
            Button("重新扫描") { store.scan(library) }
                .buttonStyle(HeaderButtonStyle(emphasized: true))
        }
    }
}

private struct ScanResultsView: View {
    @Bindable var library: LibraryRecord
    let result: LibraryScanResult
    let store: LibraryStore

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                HStack(spacing: 14) {
                    MetricCard(label: "资源库大小", value: format(result.totalAllocatedSize), icon: "internaldrive")
                    MetricCard(label: "可安全清理", value: format(result.confirmedCleanableSize), icon: "sparkles", emphasized: true)
                    MetricCard(label: "清理项目", value: result.cacheItems.count.formatted(), icon: "folder.badge.minus")
                }

                if result.externalCleanableSize > 0 {
                    Label("包含外置缓存 \(format(result.externalCleanableSize))", systemImage: "externaldrive.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(AppColor.accent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(alignment: .top, spacing: 14) {
                    CleanupList(result: result)
                    CleanupActionCard(library: library, result: result, store: store)
                        .frame(width: 270)
                }

                CleanupStatus(library: library, store: store)
            }
            .padding(22)
        }
        .scrollIndicators(.hidden)
    }
}

private struct MetricCard: View {
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
        .background {
            if emphasized {
                LinearGradient(
                    colors: [AppColor.accent.opacity(0.30), AppColor.panel.opacity(0.55)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            } else {
                AppColor.panel
            }
        }
        .overlay {
            if emphasized {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(AppColor.accent.opacity(0.45), lineWidth: 1)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .animation(.snappy, value: value)
    }
}

private struct CleanupList: View {
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
                    Text(format(size))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(AppColor.secondaryText)
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

private struct CleanupActionCard: View {
    let library: LibraryRecord
    let result: LibraryScanResult
    let store: LibraryStore

    private var protectedAnalysisSize: Int64 {
        result.observedCacheItems.reduce(0) { $0 + $1.allocatedSize }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("可释放空间")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(AppColor.secondaryText)
            Text(format(library.spaceToFree))
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .shadow(color: AppColor.accent.opacity(0.35), radius: 12)
                .animation(.snappy, value: library.spaceToFree)
            Spacer(minLength: 5)
            Button(actionTitle) {
                store.requestClean(library)
            }
            .buttonStyle(PrimaryActionButtonStyle())
            .disabled(library.spaceToFree < LibraryStore.minimumCleanableSize || store.isPreflighting || store.isBatchCleaning)

            if protectedAnalysisSize > 0 {
                Label("已保护分析文件 \(format(protectedAnalysisSize))", systemImage: "lock.fill")
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
        return "开始清理"
    }
}

private struct CleanupStatus: View {
    let library: LibraryRecord
    let store: LibraryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Group {
                if let cleanup = library.lastCleanup {
                    HStack(spacing: 8) {
                        Image(systemName: cleanup.errors.isEmpty ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .foregroundStyle(cleanup.errors.isEmpty ? AppColor.success : AppColor.danger)
                        Text("已清理 \(format(cleanup.freedAllocatedSize))")
                        if let before = library.cleanupBeforeSize, let after = library.cleanupAfterSize {
                            Text("\(format(before)) → \(format(after))")
                                .foregroundStyle(AppColor.secondaryText)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else if let error = library.lastError {
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
                .disabled(store.isPreflighting || store.isBatchCleaning)
            }
        }
    }
}

private struct SingleCleanConfirmationSheet: View {
    let confirmation: CleanConfirmation
    let store: LibraryStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "trash.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(AppColor.danger)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(confirmation.isRetry ? "重试失败项目？" : "清理这些生成文件？")
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                    Text(confirmation.record.displayName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AppColor.secondaryText)
                        .lineLimit(1)
                }
            }

            VStack(spacing: 0) {
                ForEach(CacheCategory.cleanableCases, id: \.self) { category in
                    let size = confirmation.plan.entries
                        .filter { $0.item.category == category }
                        .reduce(Int64(0)) { $0 + $1.item.allocatedSize }
                    if size > 0 {
                        HStack(spacing: 10) {
                            Image(systemName: category.iconName)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(AppColor.accent)
                                .frame(width: 24)
                            Text(category.chineseName)
                                .font(.system(size: 12, weight: .medium))
                            Spacer()
                            Text(format(size))
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(AppColor.secondaryText)
                        }
                        .padding(.vertical, 8)
                    }
                }
                Divider().overlay(AppColor.border)
                HStack {
                    Text("合计")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text(format(confirmation.plan.spaceToFree))
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .monospacedDigit()
                }
                .padding(.top, 10)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(AppColor.panel)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            Label("全部移入废纸篓，可在清理记录中恢复。", systemImage: "arrow.uturn.backward.circle")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AppColor.secondaryText)

            HStack(spacing: 10) {
                Button("取消") { dismiss() }
                    .buttonStyle(SheetSecondaryButtonStyle())
                Button {
                    store.performConfirmedCleanup(confirmation)
                    dismiss()
                } label: {
                    Text("移入废纸篓")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SheetDestructiveButtonStyle())
            }
        }
        .padding(22)
        .frame(width: 400)
    }
}

private struct BatchCleanConfirmationSheet: View {
    let confirmation: BatchCleanConfirmation
    let store: LibraryStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "trash.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(AppColor.danger)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text("批量清理 \(confirmation.entries.count) 个资源库？")
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                    Text("共 \(format(confirmation.totalSpaceToFree))")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AppColor.secondaryText)
                }
            }

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(confirmation.entries, id: \.record.id) { entry in
                        HStack(spacing: 10) {
                            Image(systemName: "square.stack.3d.up.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(AppColor.accent)
                            Text(entry.record.displayName)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                            Spacer()
                            Text(format(entry.plan.spaceToFree))
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(AppColor.secondaryText)
                        }
                        .padding(.vertical, 7)
                        if entry.record.id != confirmation.entries.last?.record.id {
                            Divider().overlay(AppColor.border)
                        }
                    }
                }
                .padding(.horizontal, 14)
            }
            .frame(maxHeight: 240)
            .background(AppColor.panel)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            Label("全部移入废纸篓，可在清理记录中恢复。", systemImage: "arrow.uturn.backward.circle")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AppColor.secondaryText)

            HStack(spacing: 10) {
                Button("取消") { dismiss() }
                    .buttonStyle(SheetSecondaryButtonStyle())
                Button {
                    store.performConfirmedBatchCleanup(confirmation)
                    dismiss()
                } label: {
                    Text("全部移入废纸篓")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SheetDestructiveButtonStyle())
            }
        }
        .padding(22)
        .frame(width: 440)
    }
}

private struct SheetSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(AppColor.primaryText)
            .frame(height: 38)
            .frame(maxWidth: .infinity)
            .background(AppColor.control)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

private struct SheetDestructiveButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(.white)
            .frame(height: 38)
            .frame(maxWidth: .infinity)
            .background(AppColor.danger)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

private struct CleanupNoticeView: View {
    let notice: CleanupNotice
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: notice.errorCount == 0 ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(notice.errorCount == 0 ? AppColor.success : AppColor.danger)
            VStack(alignment: .leading, spacing: 4) {
                Text(notice.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(summary)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AppColor.secondaryText)
                    .lineLimit(1)
                if let errorMessage = notice.errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(AppColor.danger)
                        .lineLimit(2)
                }
                if !categorySummary.isEmpty {
                    Text(categorySummary)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(AppColor.tertiaryText)
                        .lineLimit(1)
                }
            }
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 24, height: 24)
                    .background(AppColor.control)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppColor.secondaryText)
        }
        .padding(14)
        .frame(width: 390, alignment: .leading)
        .background(AppColor.panel.opacity(0.72))
        .background(.ultraThinMaterial)
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AppColor.border, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.32), radius: 18, y: 8)
    }

    private var summary: String {
        var parts = ["释放 \(format(notice.freedSize))", "\(notice.cleanedItemCount) 项"]
        if notice.libraryCount > 1 { parts.append("\(notice.libraryCount) 个资源库") }
        if notice.errorCount > 0 { parts.append("\(notice.errorCount) 项失败") }
        return parts.joined(separator: " · ")
    }

    private var categorySummary: String {
        CacheCategory.cleanableCases
            .filter { notice.categories.contains($0) }
            .map(\.chineseName)
            .joined(separator: " · ")
    }
}

private struct AppSettings: View {
    @Bindable var store: LibraryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("设置")
                .font(.system(size: 17, weight: .semibold, design: .rounded))

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
                            }
                            Spacer(minLength: 4)
                            Button {
                                store.removeWorkDirectory(url)
                            } label: {
                                Image(systemName: "xmark")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(AppColor.secondaryText)
                        }
                        .padding(9)
                        .background(AppColor.control)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
            }

            if let library = store.selectedLibrary {
                Divider()
                LibrarySettings(library: library, store: store)
            }

            Divider()
            Toggle("完成与空间通知", isOn: $store.notificationsEnabled)
                .toggleStyle(.switch)
            Stepper("磁盘预警：\(store.lowSpaceWarningGB) GB", value: $store.lowSpaceWarningGB, in: 10...500, step: 10)
                .font(.system(size: 12, weight: .medium))

            Divider()
            Button("检查更新") {
                UpdateController.shared.checkForUpdates()
            }
            .disabled(!UpdateController.shared.isConfigured)
        }
        .padding(20)
        .frame(width: 340)
    }
}

private struct CleanupHistoryView: View {
    let store: CleanupHistoryStore
    @State private var restoreMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("清理记录")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                Spacer()
                if !store.entries.isEmpty {
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
                                    Text("\(entry.date.formatted(date: .abbreviated, time: .shortened)) · \(format(entry.freedSize))")
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
        .frame(width: 370)
    }
}

private struct LibrarySettings: View {
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
            Button("从列表移除", role: .destructive) { store.remove([library]) }
        }
    }
}

private struct HeaderButtonStyle: ButtonStyle {
    var emphasized = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(emphasized ? Color.white : AppColor.primaryText)
            .padding(.horizontal, 17)
            .frame(height: 42)
            .background(emphasized ? AppColor.accent.opacity(configuration.isPressed ? 0.72 : 1) : AppColor.control)
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(emphasized ? Color.clear : AppColor.border, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .opacity(configuration.isPressed ? 0.78 : 1)
    }
}

private struct PrimaryActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(AppColor.accent)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

private extension LibraryRecord {
    var cleanableDisplaySize: Int64 {
        scanResult?.confirmedCleanableSize ?? lastKnownCleanableSize ?? 0
    }
}

private extension CacheCategory {
    var chineseName: String {
        switch self {
        case .renderFiles: "渲染文件"
        case .proxyMedia: "代理媒体"
        case .optimizedMedia: "优化媒体"
        case .analysisFiles: "分析文件"
        case .opticalFlow: "光流分析"
        case .stabilization: "稳定分析"
        case .thumbnails: "缩略图缓存"
        case .waveform: "波形缓存"
        case .otherCache: "其他缓存"
        }
    }

    var iconName: String {
        switch self {
        case .renderFiles: "film"
        case .proxyMedia: "rectangle.stack"
        case .optimizedMedia: "bolt.horizontal"
        default: "folder"
        }
    }
}

private enum AppColor {
    static let canvas = Color(hex: "242424")
    static let workspace = Color(hex: "202020")
    static let panel = Color(hex: "2A2A2A")
    static let control = Color(hex: "303030")
    static let primaryText = Color(hex: "E7E7E7")
    static let secondaryText = Color(hex: "A0A0A0")
    static let tertiaryText = Color(hex: "747474")
    static let border = Color(hex: "3C3C3C")
    static let dashedBorder = Color(hex: "747474")
    static let accent = Color(hex: "5D72D8")
    static let success = Color(hex: "35B85A")
    static let danger = Color(hex: "D45C57")
}

private extension Color {
    init(hex: String) {
        let value = UInt64(hex, radix: 16) ?? 0
        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            opacity: 1
        )
    }
}

func format(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
