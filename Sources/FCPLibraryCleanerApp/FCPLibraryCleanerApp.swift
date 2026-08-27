import AppKit
import SwiftUI

@main
struct FCPLibraryCleanerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        LibraryStore.shared.appearanceMode.applyToApplication()
        UpdateController.shared.startIfConfigured()
    }

    var body: some Scene {
        WindowGroup("FCP Cleaner") {
            ContentView()
        }
        .defaultSize(width: LayoutMetrics.windowDefaultWidth, height: LayoutMetrics.windowDefaultHeight)
        .commands {
            CommandGroup(after: .newItem) {
                Button("选择资源库…") {
                    LibraryStore.shared.openLibraryPanel()
                }
                .keyboardShortcut("o", modifiers: [.command])

                Button("全选可清理资源库") {
                    LibraryStore.shared.toggleSelectAllCleanableLibraries()
                }
                .keyboardShortcut("a", modifiers: [.command])
                .disabled(!LibraryStore.shared.hasSelectableBatchCandidates)

                Button("清理") {
                    let store = LibraryStore.shared
                    if !store.batchSelectedIDs.isEmpty {
                        store.requestBatchClean()
                    } else if let selected = store.selectedLibrary {
                        store.requestClean(selected)
                    }
                }
                .keyboardShortcut(.delete, modifiers: [.command])
                .disabled(!LibraryStore.shared.canRequestCleanupForSelection)

                Button("重新扫描当前资源库") {
                    if let selected = LibraryStore.shared.selectedLibrary {
                        LibraryStore.shared.scan(selected, force: false)
                    }
                }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(!LibraryStore.shared.canRescanSelectedLibrary)
            }
            CommandGroup(after: .appInfo) {
                Button("检查更新…") {
                    UpdateController.shared.checkForUpdates()
                }
                .disabled(!UpdateController.shared.isConfigured)
            }
        }

        MenuBarExtra("FCP Cleaner", systemImage: "sparkles") {
            MenuBarPanel(store: LibraryStore.shared)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuBarPanel: View {
    @Bindable var store: LibraryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                CleanerMenuMark()
                Text("FCP Cleaner")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                Spacer()
                Text(FormatHelpers.bytes(store.totalCleanableSize))
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .contentTransition(.numericText())
                    .animation(.snappy, value: store.totalCleanableSize)
            }
            if let warning = store.lowSpaceWarnings.first {
                Label("\(warning.name) 剩余 \(FormatHelpers.bytes(warning.availableSize))", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.orange)
            }
            HStack {
                Button("打开") { store.showMainWindow() }
                Button("扫描") { store.discoverLibraries() }
                    .disabled(store.isDiscovering)
                Button("清理") { store.requestMenuBarCleanup() }
                    .disabled(store.totalCleanableSize < LibraryStore.minimumCleanableSize)
                Spacer()
                Button("退出") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: LayoutMetrics.menuBarPanelWidth)
    }
}

private struct CleanerMenuMark: View {
    var body: some View {
        Image(systemName: "paintbrush.pointed.fill")
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(AppColor.brand)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
