import AppKit
import SwiftUI
import FCPLibraryCleanerCore

struct AppHeader: View {
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
                Image(systemName: "clock.arrow.circlepath")
            }
            .buttonStyle(HeaderButtonStyle())
            .accessibilityLabel("记录")
            .popover(isPresented: $showsHistory, arrowEdge: .bottom) {
                CleanupHistoryView(store: store.cleanupHistory, libraryStore: store)
            }

            Button {
                showsSettings.toggle()
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .buttonStyle(HeaderButtonStyle())
            .accessibilityLabel("设置")
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
            .help("自动扫描资源库 (空格键)")

            Button(action: store.openLibraryPanel) {
                Label("添加资源库", systemImage: "plus")
            }
            .buttonStyle(HeaderButtonStyle(emphasized: true))
        }
        .padding(.horizontal, LayoutMetrics.headerHorizontalPadding)
        .padding(.top, LayoutMetrics.headerTopPadding)
        .padding(.bottom, LayoutMetrics.headerBottomPadding)
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
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(0.88))
    }
}
