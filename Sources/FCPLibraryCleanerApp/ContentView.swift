import AppKit
import SwiftUI
import UniformTypeIdentifiers
import FCPLibraryCleanerCore

struct ContentView: View {
    @State private var store = LibraryStore.shared
    @State private var isDropTargeted = false
    @FocusState private var isSearchFocused: Bool

    @ViewBuilder
    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer { appContent }
        } else {
            appContent
        }
    }

    private var appContent: some View {
        ZStack {
            VStack(spacing: 0) {
                AppHeader(store: store)
                MainWorkspace(store: store, isDropTargeted: isDropTargeted, searchFocused: $isSearchFocused)
                    .padding(.horizontal, LayoutMetrics.contentHorizontalPadding)
                    .padding(.bottom, LayoutMetrics.contentBottomPadding)
            }
            .frame(minWidth: LayoutMetrics.windowMinWidth, minHeight: LayoutMetrics.windowMinHeight)

            if let notice = store.cleanupNotice {
                CleanupNoticeView(notice: notice) {
                    store.dismissCleanupNotice()
                }
                // 批量操作条同住右下角（窗口右缘 40pt 处）：通知上移到它的正上方
                // 垂直堆叠，右缘对齐，避免浮层压住操作卡与批量条。
                .padding(.top, 24)
                .padding(.leading, 24)
                .padding(.trailing, store.batchSelectedIDs.isEmpty ? 24 : 40)
                .padding(.bottom, store.batchSelectedIDs.isEmpty ? 24 : 88)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.snappy(duration: 0.22), value: store.batchSelectedIDs.isEmpty)
                .zIndex(999)
            }
        }
        .frame(minWidth: LayoutMetrics.windowMinWidth, minHeight: LayoutMetrics.windowMinHeight)
        .background(Color.clear.ignoresSafeArea())
        .preferredColorScheme(store.appearanceMode.colorScheme)
        .animation(.snappy(duration: 0.28), value: store.cleanupNotice?.id)
        .onKeyPress(.space) {
            guard !isSearchFocused, !store.isDiscovering else { return .ignored }
            // 空格是 macOS 滚动视图的标准翻页键：焦点已落在滚动内容上时让位给系统滚动，
            // 只在无滚动焦点的空闲场景才触发自动扫描。
            if let responder = NSApp.keyWindow?.firstResponder,
               responder is NSScrollView || responder is NSClipView {
                return .ignored
            }
            store.discoverLibraries()
            return .handled
        }
        .task { store.beginAutomaticDiscovery() }
        .onReceive(NotificationCenter.default.publisher(for: .focusLibrarySearch)) { _ in
            isSearchFocused = true
        }
        .onChange(of: store.appearanceMode) { _, mode in
            mode.applyToApplication()
        }
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
        .sheet(item: $store.cleanupSummary) { summary in
            CleanupSummarySheet(summary: summary)
        }
    }
}

func shortPath(_ url: URL, maxComponents: Int = 3) -> String {
    let components = url.pathComponents.filter { $0 != "/" }
    if components.count <= maxComponents { return url.path }
    return ".../" + components.suffix(maxComponents).joined(separator: "/")
}

extension LibraryRecord {
    var cleanableDisplaySize: Int64 {
        let base = scanResult?.confirmedCleanableSize ?? lastKnownCleanableSize ?? 0
        let penalty = scanResult != nil ? pendingFreedSize : 0
        return max(0, base - penalty)
    }
}

extension CacheCategory {
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
