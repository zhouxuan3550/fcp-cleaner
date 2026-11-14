import AppKit
import SwiftUI
import FCPLibraryCleanerCore

struct AppHeader: View {
    @Bindable var store: LibraryStore
    @ScaledMetric(relativeTo: .largeTitle) private var appNameSize: CGFloat = 25

    var body: some View {
        HStack(spacing: 18) {
            CleanerVectorMark()
                .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 4) {
                Text("FCP Cleaner")
                    .font(.system(size: appNameSize, weight: .bold, design: .rounded))
                Text("自动扫描 · 安全清理")
                    .font(AppFont.body(.medium))
                    .foregroundStyle(AppColor.secondaryText)
            }

            Spacer(minLength: 18)

            Button {
                if let library = store.selectedLibrary {
                    NSWorkspace.shared.activateFileViewerSelecting([library.url])
                }
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(HeaderButtonStyle())
            .disabled(store.selectedLibrary == nil)
            .accessibilityLabel("在 Finder 中显示")
            .help("在 Finder 中显示当前资源库")

            Button {
                store.showsHistory.toggle()
            } label: {
                Image(systemName: "clock.arrow.circlepath")
            }
            .buttonStyle(HeaderButtonStyle())
            .accessibilityLabel("记录")
            .popover(isPresented: $store.showsHistory, arrowEdge: .bottom) {
                CleanupHistoryView(store: store.cleanupHistory, libraryStore: store)
            }

            Button {
                store.showsSettings.toggle()
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .buttonStyle(HeaderButtonStyle())
            .accessibilityLabel("设置")
            .popover(isPresented: $store.showsSettings, arrowEdge: .bottom) {
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
            .accessibilityLabel(store.isDiscovering ? "正在扫描资源库" : "自动扫描资源库")
            .help("自动扫描资源库 (空格键)")

            Button(action: store.openLibraryPanel) {
                Label("添加资源库", systemImage: "plus")
            }
            .buttonStyle(HeaderButtonStyle(emphasized: true))
        }
        .padding(.horizontal, LayoutMetrics.headerHorizontalPadding)
        .padding(.top, LayoutMetrics.headerTopPadding)
        .padding(.bottom, LayoutMetrics.headerBottomPadding)
        .background(Color.clear)
    }
}

struct CleanerVectorMark: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(AppColor.brand)
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
        .shadow(color: AppColor.brand.opacity(0.35), radius: 10, y: 4)
        .accessibilityHidden(true)
    }

    private var star: some View {
        Image(systemName: "star.fill")
            .font(AppFont.small(.semibold))
            .foregroundStyle(.white.opacity(0.88))
    }
}
