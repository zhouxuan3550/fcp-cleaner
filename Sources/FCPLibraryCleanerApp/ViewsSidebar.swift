// [INPUT]: LibraryStore 的筛选、选择、扫描与批量清理状态。
// [OUTPUT]: 主工作区、资源库侧栏、单行扫描进度与批量操作入口。
// [POS]: App 导航层；侧栏选择决定详情内容，不执行文件清理。
// [PROTOCOL]: Update this header on change, then check AGENTS.md
import AppKit

import SwiftUI

import FCPLibraryCleanerCore



struct MainWorkspace: View {

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let store: LibraryStore

    let isDropTargeted: Bool

    var searchFocused: FocusState<Bool>.Binding



    var body: some View {

        if store.libraries.isEmpty {

            EmptyDropZone(store: store, isDropTargeted: isDropTargeted)

                .frame(maxWidth: .infinity, maxHeight: .infinity)

        } else {

            HStack(alignment: .top, spacing: 12) {

                LibrarySidebar(store: store, searchFocused: searchFocused)

                    .frame(width: LayoutMetrics.sidebarWidth)



                ZStack(alignment: .bottomTrailing) {

                    Group {

                        if store.showsDashboard {

                            DashboardView(store: store)

                        } else if let library = store.selectedLibrary {

                            LibraryPanel(library: library, store: store)

                        } else {

                            NoCleanupView(store: store)

                        }

                    }

                    .frame(maxWidth: .infinity, maxHeight: .infinity)



                    if !store.batchSelectedIDs.isEmpty {

                        BatchActionBar(store: store)

                            .padding(.trailing, LayoutMetrics.batchBarTrailingInset)

                            .padding(.bottom, LayoutMetrics.batchBarBottomInset)

                            .transition(.asymmetric(

                                insertion: .opacity.combined(with: .offset(y: 16)),

                                removal: .opacity.combined(with: .offset(y: 8))

                            ))

                            .zIndex(10)

                    }

                }

                .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: store.batchSelectedIDs.isEmpty)

                .frame(maxWidth: .infinity, maxHeight: .infinity)

            }

            .frame(maxWidth: .infinity, maxHeight: .infinity)

        }

    }

}



struct LibrarySidebar: View {

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @FocusState private var isListFocused: Bool

    @Bindable var store: LibraryStore

    var searchFocused: FocusState<Bool>.Binding



    var body: some View {

        let fastestGrowingID = store.fastestGrowingLibraryID

        VStack(spacing: 0) {

            controls

            Divider().overlay(AppColor.border)

            ScrollViewReader { scrollProxy in

            ScrollView {

                LazyVStack(alignment: .leading, spacing: 3, pinnedViews: .sectionHeaders) {

                    ForEach(sections) { section in

                        Section {

                            ForEach(section.libraries) { library in

                                LibraryRow(library: library, store: store, searchFocused: searchFocused,
                                           listFocused: $isListFocused,
                                           isFastestGrowing: library.id == fastestGrowingID)
                                    .id(library.id)

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

            .focusable()

            .focused($isListFocused)

            .onMoveCommand { direction in

                guard !searchFocused.wrappedValue else { return }

                switch direction {

                case .up: store.moveSelection(by: -1)

                case .down: store.moveSelection(by: 1)

                default: break

                }

            }

            .onChange(of: store.lastKeyboardSelectionID) { _, id in

                guard let id else { return }

                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {

                    scrollProxy.scrollTo(id, anchor: .center)

                }

            }

            }



            Divider().overlay(AppColor.border)

            scanHealthFooter

        }

        .frame(maxHeight: .infinity)

        .compatibleGlassEffect(

            in: RoundedRectangle(cornerRadius: 20, style: .continuous),

            fallbackColor: AppColor.workspace

        )

    }



    private var scanHealthFooter: some View {

        let health = store.scanHealthSummary

        return HStack(spacing: 6) {

            if health.failed.isEmpty && health.neverScanned == 0 {

                Image(systemName: "checkmark.circle.fill")

                    .foregroundStyle(AppColor.success)

                Text("全部扫描完成")

                    .foregroundStyle(AppColor.secondaryText)

            } else {

                Image(systemName: "exclamationmark.circle.fill")

                    .foregroundStyle(AppColor.danger)

                Text(health.failed.isEmpty ? String(format: String(localized: "待扫描 %@ 个"), String(health.neverScanned)) : String(format: String(localized: "扫描失败 %@ 个"), String(health.failed.count)))

                    .foregroundStyle(AppColor.secondaryText)

                    .lineLimit(1)

            }

            Spacer(minLength: 0)

            Text(String(format: String(localized: "资源库 %@ 个"), String(health.total)))

                .foregroundStyle(AppColor.tertiaryText)

        }

        .font(AppFont.small(.medium))

        .padding(.horizontal, 12)

        .padding(.vertical, 8)

    }



    private var controls: some View {

        let counts = store.countsByFilter

        return VStack(spacing: 8) {

            // 原生胶囊分段条：整体底槽 + 均分自适应，保证紧凑与原生整洁感

            HStack(spacing: 0) {

                ForEach(LibraryFilter.allCases) { filter in

                    let count = counts[filter] ?? 0

                    Button {

                        withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) {

                            store.setFilter(filter)

                        }

                    } label: {

                        HStack(spacing: 3) {

                            Text(filter.title)

                                .font(AppFont.small(.medium))

                                .lineLimit(1)

                                .minimumScaleFactor(0.8)

                            Text(count.formatted())

                                .monospacedDigit()

                                .font(AppFont.caption(.semibold))

                                .foregroundStyle(filter == store.libraryFilter ? Color.white.opacity(0.9) : AppColor.tertiaryText)

                        }

                        .frame(maxWidth: .infinity)

                        .frame(height: 24)

                        .background {

                            if filter == store.libraryFilter {

                                Capsule()

                                    .fill(AppColor.accent)

                                    .shadow(color: AppColor.accent.opacity(0.25), radius: 3, y: 1)

                            }

                        }

                        .contentShape(Rectangle())

                    }

                    .buttonStyle(.plain)

                    .foregroundStyle(filter == store.libraryFilter ? Color.white : AppColor.secondaryText)

                    .accessibilityLabel(String(format: String(localized: "%@，%@ 个资源库"), String(filter.title), String(count)))

                    .accessibilityAddTraits(filter == store.libraryFilter ? [.isButton, .isSelected] : .isButton)

                }

            }

            .padding(3)

            .background(AppColor.control)

            .clipShape(Capsule())



            HStack(spacing: 6) {

                HStack(spacing: 6) {

                    Image(systemName: "magnifyingglass")

                        .font(AppFont.small(.semibold))

                        .foregroundStyle(AppColor.tertiaryText)

                    TextField("搜索资源库", text: $store.searchText)

                        .textFieldStyle(.plain)

                        .font(AppFont.callout(.medium))

                        .focused(searchFocused)

                        .onSubmit {

                            // 回车选中首个搜索结果并退出搜索，形成 ⌘F → 输入 → 回车 的键盘流。

                            if let first = store.filteredLibraries.first {

                                store.select(first)

                            }

                            searchFocused.wrappedValue = false

                        }

                    if !store.searchText.isEmpty {

                        Button {

                            store.searchText = ""

                        } label: {

                            Image(systemName: "xmark.circle.fill")

                                .font(AppFont.callout())

                                .foregroundStyle(AppColor.tertiaryText)

                                .frame(width: 20, height: 20)

                                .contentShape(Rectangle())

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

                        .font(AppFont.small(.semibold))

                        .foregroundStyle(AppColor.secondaryText)

                        .frame(width: 28, height: 28)

                        .background(AppColor.control)

                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                }

                .accessibilityLabel(String(format: String(localized: "排序：%@"), String(store.librarySort.title)))

                .menuStyle(.borderlessButton)

                .fixedSize()

                .help(String(format: String(localized: "排序：%@"), String(store.librarySort.title)))



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

                        .font(AppFont.callout(.semibold))

                        .foregroundStyle(AppColor.secondaryText)

                        .frame(width: 28, height: 28)

                        .background(AppColor.control)

                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                }

                .accessibilityLabel(String(format: String(localized: "筛选：%@"), String(store.inactivityFilter.title)))

                .menuStyle(.borderlessButton)

                .fixedSize()

                .help(store.inactivityFilter.title)



                if store.libraryFilter == .waiting {

                    Button {

                        withAnimation(reduceMotion ? nil : .snappy(duration: 0.22)) {

                            store.toggleSelectAllCleanableLibraries()

                        }

                    } label: {

                        Image(systemName: store.areAllCleanableLibrariesSelected ? "checkmark.circle.fill" : "checkmark.circle")

                            .font(AppFont.small(.semibold))

                            .foregroundStyle(store.areAllCleanableLibrariesSelected ? AppColor.accent : AppColor.secondaryText)

                            .frame(width: 28, height: 28)

                            .background(AppColor.control)

                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                    }

                    .buttonStyle(.plain)

                    .disabled(store.batchCleanableLibraries.isEmpty || store.isBatchCleaning || store.isPreflighting)

                    .accessibilityLabel(store.areAllCleanableLibrariesSelected ? String(localized: "取消全选") : String(localized: "全选"))

                    .help(store.areAllCleanableLibrariesSelected ? String(localized: "取消全选") : String(localized: "全选"))

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

            .sorted {

                if $0.totalCleanable != $1.totalCleanable { return $0.totalCleanable > $1.totalCleanable }

                return $0.volumeURL.path < $1.volumeURL.path

            }

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

                .font(AppFont.small(.semibold))

                .foregroundStyle(isSelected ? AppColor.accent : (isLowSpace ? AppColor.danger : AppColor.tertiaryText))

            Text(section.name)

                .font(AppFont.small(.semibold))

                .foregroundStyle(isSelected ? AppColor.primaryText : AppColor.secondaryText)

                .lineLimit(1)

            Text(FormatHelpers.bytes(section.totalCleanable))

                .font(AppFont.small(.medium))

                .foregroundStyle(AppColor.secondaryText)

                .monospacedDigit()

            Spacer(minLength: 4)

            Text(String(format: String(localized: "%@ 个"), String(section.libraries.count)))

                .font(AppFont.small(.medium))

                .foregroundStyle(AppColor.tertiaryText)

        }

        .padding(.horizontal, 8)

        .padding(.vertical, 6)

        .background(Color.clear)

        .contentShape(Rectangle())

        .onTapGesture {

            guard store.libraryFilter == .waiting else { return }

            store.selectVolume(section.volumeURL)

        }

        .accessibilityElement(children: .ignore)

        .accessibilityLabel(String(format: String(localized: "%@，%@ 个资源库，可清理 %@"), String(section.name), String(section.libraries.count), String(FormatHelpers.bytes(section.totalCleanable))))

        .accessibilityHint(store.libraryFilter == .waiting ? String(localized: "点按只显示此磁盘的资源库") : "")

        .accessibilityAddTraits(.isButton)

        .help(store.libraryFilter == .waiting ? (isSelected ? String(localized: "显示全部磁盘") : String(localized: "只显示此磁盘")) : section.name)

    }

}



struct LibraryRow: View {

    let library: LibraryRecord

    let store: LibraryStore

    var searchFocused: FocusState<Bool>.Binding

    var listFocused: FocusState<Bool>.Binding

    var isFastestGrowing = false

    @State private var isHovered = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion



    private var isSelected: Bool { library.id == store.selectedID }

    private var isBatchSelected: Bool { store.batchSelectedIDs.contains(library.id) }



    var body: some View {

        HStack(spacing: 9) {

            leadingMark

            Button {

                store.selectedID = library.id

                store.showsDashboard = false

                searchFocused.wrappedValue = false

                listFocused.wrappedValue = true

            } label: {

                HStack(spacing: 8) {

                    VStack(alignment: .leading, spacing: 2) {

                        HStack(spacing: 5) {

                            Text(library.displayName)

                                .font(AppFont.body(.medium))

                                .foregroundStyle(AppColor.primaryText)

                                .lineLimit(1)

                            if isFastestGrowing {

                                Label("增长最快", systemImage: "arrow.up.forward")

                                    .font(AppFont.caption(.bold))

                                    .foregroundStyle(AppColor.accent)

                                    .padding(.horizontal, 5)

                                    .padding(.vertical, 2)

                                    .background(AppColor.accent.opacity(0.14))

                                    .clipShape(Capsule())

                                    .help("该资源库一周内体积增长最快")

                            }

                        }

                        Text(subtitle)

                            .font(AppFont.small(.medium))

                            .foregroundStyle(library.scanError != nil || library.cleanupError != nil ? AppColor.danger : AppColor.tertiaryText)

                            .lineLimit(1)

                        if library.isScanning {

                            let partial = library.scanPartialResults

                            GeometryReader { geometry in

                                ZStack(alignment: .leading) {

                                    Capsule().fill(AppColor.control)

                                    if let partial, partial.totalDirectories > 0 {

                                        Capsule()

                                            .fill(AppColor.accent)

                                            .frame(width: geometry.size.width * min(1, Double(partial.completedDirectories) / Double(partial.totalDirectories)))

                                    }

                                }

                            }

                                .frame(height: 2)

                                .accessibilityLabel("扫描进度")

                                .accessibilityValue(partial.map { "\($0.completedDirectories)/\($0.totalDirectories)" } ?? String(localized: "准备中"))

                        }

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

        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovered)

        .contextMenu {

            if store.isLibraryIgnored(library) {

                Button("取消忽略") { store.resumeLibrary(library) }

                if let until = library.ignoredUntil, until > Date() {

                    Text(String(format: String(localized: "已忽略至 %@"), String(until.formatted(date: .abbreviated, time: .shortened))))

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

                withAnimation(reduceMotion ? nil : .snappy(duration: 0.22)) {

                    store.toggleBatchSelection(library)

                }

            } label: {

                Image(systemName: isBatchSelected ? "checkmark.circle.fill" : "circle")

                    .font(AppFont.heading(.medium))

                    .foregroundStyle(isBatchSelected ? AppColor.accent : AppColor.tertiaryText)

            }

            .buttonStyle(.plain)

            .disabled(library.scanResult == nil || library.isScanning || library.spaceToFree < LibraryStore.minimumCleanableSize)

            .help(isBatchSelected ? String(localized: "取消勾选") : String(localized: "加入批量清理"))

        } else {

            Image(systemName: store.libraryFilter == .scanning ? "hourglass" : (store.libraryFilter == .ignored ? "bell.slash" : "minus.circle"))

                .font(AppFont.heading(.medium))

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

                .font(AppFont.small(.medium))

                .foregroundStyle(AppColor.secondaryText)

                .monospacedDigit()

        }

    }



    private var subtitle: String {

        var status: String

        if library.isScanning {

            status = library.usedCachedScan ? String(localized: "缓存") : String(localized: "扫描中")

        } else if library.isQueued {

            status = String(localized: "等待扫描")

        } else if store.isLibraryIgnored(library) {

            status = String(localized: "已忽略")

            if let until = library.ignoredUntil, until > Date() {

                let days = max(1, Int(ceil(until.timeIntervalSinceNow / 86_400)))

                status += String(format: String(localized: " · %@ 天后恢复"), String(days))

            }

        } else if library.accessReport?.mounted == false {

            status = String(localized: "磁盘已断开")

        } else if library.scanError != nil {

            status = String(localized: "扫描失败")

        } else if library.cleanupError != nil {

            status = String(localized: "预检未通过")

        } else if library.usedCachedScan && store.libraryFilter != .skipped {

            status = String(localized: "增量复用")

        } else if store.libraryFilter == .skipped {

            // 在"已跳过"分组里，被跳过的原因是体积低于门槛——"已就绪"在这里是误导

            status = String(localized: "低于门槛")

        } else {

            status = String(localized: "已就绪")

        }

        if let tag = library.discoverySource?.title {

            status += " · \(tag)"

        }

        return status

    }

}



struct BatchActionBar: View {

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let store: LibraryStore



    var body: some View {

        HStack(spacing: 12) {

            HStack(spacing: 6) {

                Image(systemName: "checkmark.circle.fill")

                    .font(AppFont.heading(.semibold))

                    .foregroundStyle(AppColor.accent)

                Text(String(format: String(localized: "已选 %@ 个资源库"), String(store.batchSelectedIDs.count)))

                    .font(AppFont.callout(.semibold))

            }



            Text(FormatHelpers.bytes(store.selectedBatchSpace))

                .font(AppFont.small(.semibold))

                .foregroundStyle(AppColor.accent)

                .monospacedDigit()

                .padding(.horizontal, 8)

                .padding(.vertical, 3)

                .background(AppColor.accent.opacity(0.12))

                .clipShape(Capsule())



            Divider()

                .frame(height: 14)

                .overlay(AppColor.border)



            Button("取消") {

                withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) {

                    store.batchSelectedIDs.removeAll()

                }

            }

            .buttonStyle(QueueActionButtonStyle(enabled: !store.isBatchCleaning && !store.isPreflighting))

            .disabled(store.isBatchCleaning || store.isPreflighting)

            .accessibilityLabel("取消批量选择")



            Button {

                store.requestBatchClean()

            } label: {

                Label(batchActionTitle, systemImage: store.isPreflighting ? "hourglass" : "trash")

            }

            .buttonStyle(QueueActionButtonStyle(emphasized: true, enabled: !store.isBatchCleaning && !store.isPreflighting))

            .disabled(store.isBatchCleaning || store.isPreflighting)

            .accessibilityLabel(batchActionTitle)

        }

        .padding(.horizontal, 16)

        .padding(.vertical, 8)

        .fixedSize()

        .compatibleGlassEffect(in: Capsule(), interactive: true, fallbackColor: AppColor.panel)

        .shadow(color: Color.black.opacity(0.28), radius: 16, y: 6)

    }



    private var batchActionTitle: String {

        if store.isPreflighting {

            return String(format: String(localized: "正在检查 %@/%@"), String(store.cleanupPreparationCompleted), String(store.cleanupPreparationTotal))

        }

        if store.isBatchCleaning {

            return String(format: String(localized: "正在清理 %@/%@"), String(store.batchCleanupCompleted), String(store.batchCleanupTotal))

        }

        return String(format: String(localized: "清理所选 %@"), String(store.batchSelectedIDs.count))

    }

}



struct NoCleanupView: View {

    let store: LibraryStore

    @ScaledMetric(relativeTo: .title2) private var emptyIconSize: CGFloat = 36

    @ScaledMetric(relativeTo: .title2) private var emptyTitleSize: CGFloat = 19



    var body: some View {

        VStack(spacing: 13) {

            Image(systemName: emptyIcon)

                .font(.system(size: emptyIconSize, weight: .light))

                .foregroundStyle(store.libraryFilter == .waiting ? AppColor.success : AppColor.secondaryText)

            Text(emptyTitle)

                .font(.system(size: emptyTitleSize, weight: .semibold, design: .rounded))

            Text(emptySubtitle)

                .font(AppFont.callout(.medium))

                .foregroundStyle(AppColor.secondaryText)

            Button("重新扫描") { store.discoverLibraries() }

                .buttonStyle(HeaderButtonStyle())

        }

        .frame(maxWidth: .infinity, maxHeight: .infinity)

        .compatibleGlassEffect(

            in: RoundedRectangle(cornerRadius: 20, style: .continuous),

            fallbackColor: AppColor.workspace

        )

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

        case .waiting: String(localized: "暂无需要清理的资源库")

        case .scanning: String(localized: "没有扫描任务")

        case .skipped: String(localized: "没有已跳过的资源库")

        case .ignored: String(localized: "没有已忽略的资源库")

        }

    }



    private var emptySubtitle: String {

        switch store.libraryFilter {

        case .waiting: String(format: String(localized: "可清理空间低于 %@ 的项目会自动跳过"), String(FormatHelpers.bytes(LibraryStore.minimumCleanableSize)))

        case .scanning: String(localized: "扫描任务最多同时运行 3 个")

        case .skipped: String(format: String(localized: "低于 %@ 的资源库会显示在这里"), String(FormatHelpers.bytes(LibraryStore.minimumCleanableSize)))

        case .ignored: String(localized: "右键资源库可选择「7 天内不再提醒」")

        }

    }

}



struct EmptyDropZone: View {

    let store: LibraryStore

    let isDropTargeted: Bool

    @ScaledMetric(relativeTo: .largeTitle) private var dropIconSize: CGFloat = 39

    @ScaledMetric(relativeTo: .title2) private var dropTitleSize: CGFloat = 20



    var body: some View {

        VStack(spacing: 14) {

            if store.isDiscovering {

                ProgressView()

                    .controlSize(.large)

                    .tint(AppColor.accent)

            } else {

                Image(systemName: "folder.badge.plus")

                    .font(.system(size: dropIconSize, weight: .light))

                    .foregroundStyle(AppColor.secondaryText)

            }

            Text(store.isDiscovering ? String(localized: "正在查找 FCP 资源库") : String(localized: "拖入 .fcpbundle 资源库"))

                .font(.system(size: dropTitleSize, weight: .semibold, design: .rounded))

            Text(store.isDiscovering ? String(localized: "发现后将自动扫描") : String(localized: "双击此处选择"))

                .font(AppFont.body(.medium))

                .foregroundStyle(AppColor.secondaryText)

            if let error = store.discoveryError {

                Text(error)

                    .font(.caption)

                    .foregroundStyle(AppColor.danger)

            }

        }

        .frame(maxWidth: .infinity, maxHeight: .infinity)

        .compatibleGlassEffect(

            in: RoundedRectangle(cornerRadius: 20, style: .continuous),

            tint: isDropTargeted ? AppColor.accent : nil,

            fallbackColor: isDropTargeted ? AppColor.accent.opacity(0.12) : AppColor.workspace

        )

        .overlay {

            // 保留虚线拖放落点指示

            RoundedRectangle(cornerRadius: 20, style: .continuous)

                .stroke(

                    isDropTargeted ? AppColor.accent : AppColor.dashedBorder,

                    style: StrokeStyle(lineWidth: 2, dash: [11, 9])

                )

        }

        .contentShape(Rectangle())

        .onTapGesture(count: 2, perform: store.openLibraryPanel)

        .accessibilityElement(children: .ignore)

        .accessibilityLabel(store.isDiscovering ? String(localized: "正在查找 FCP 资源库") : String(localized: "拖入 .fcpbundle 资源库，或双击选择"))

        .accessibilityAddTraits(.isButton)

    }

}
