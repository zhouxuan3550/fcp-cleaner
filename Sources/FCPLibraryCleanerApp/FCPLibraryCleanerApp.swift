// [INPUT]: LibraryStore、系统菜单与应用生命周期事件。
// [OUTPUT]: 主窗口、菜单栏面板与键盘命令。
// [POS]: App 入口；把系统命令转发给现有状态流。
// [PROTOCOL]: Update this header on change, then check AGENTS.md
import AppKit

import SwiftUI



/// ⌘F 菜单项 → ContentView 聚焦侧栏搜索框的桥接（FocusState 无法跨场景直达）。

extension Notification.Name {

    static let focusLibrarySearch = Notification.Name("com.fcpcleaner.focusLibrarySearch")

}

enum AuxiliaryWindowID {
    static let history = "cleanup-history"
}



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

        .windowStyle(.hiddenTitleBar)

        .windowBackgroundDragBehavior(.enabled)

        .commands {

            CommandGroup(replacing: .newItem) {

                Button("选择资源库…") {

                    LibraryStore.shared.openLibraryPanel()

                }

                .keyboardShortcut("o", modifiers: [.command])



                Button("搜索资源库") {

                    NotificationCenter.default.post(name: .focusLibrarySearch, object: nil)

                }

                .keyboardShortcut("f", modifiers: [.command])

                .disabled(LibraryStore.shared.libraries.isEmpty)



                Button("全选可清理资源库") {

                    LibraryStore.shared.toggleSelectAllCleanableLibraries()

                }

                .keyboardShortcut("a", modifiers: [.command])

                .disabled(!LibraryStore.shared.hasSelectableBatchCandidates)

                Button("切换当前资源库的批量勾选") {

                    let store = LibraryStore.shared

                    if let selected = store.selectedLibrary { store.toggleBatchSelection(selected) }

                }

                .keyboardShortcut("n", modifiers: [.command])

                .disabled(!LibraryStore.shared.canToggleSelectedLibraryInBatch)



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

            CommandMenu("筛选") {

                Button("待清理") { LibraryStore.shared.setFilter(.waiting) }
                    .keyboardShortcut("1", modifiers: [.command])

                Button("扫描中") { LibraryStore.shared.setFilter(.scanning) }
                    .keyboardShortcut("2", modifiers: [.command])

                Button("已跳过") { LibraryStore.shared.setFilter(.skipped) }
                    .keyboardShortcut("3", modifiers: [.command])

                Button("已忽略") { LibraryStore.shared.setFilter(.ignored) }
                    .keyboardShortcut("4", modifiers: [.command])

            }

            CommandGroup(after: .appInfo) {

                Button("检查更新…") {

                    UpdateController.shared.checkForUpdates()

                }

                .disabled(!UpdateController.shared.isConfigured)



                Button("导出诊断信息…") {

                    LibraryStore.shared.exportDiagnostics()

                }

                .disabled(LibraryStore.shared.isExportingDiagnostics)

            }

        }

        Settings {
            ScrollView {
                AppSettings(store: LibraryStore.shared)
            }
            .frame(minWidth: 520, minHeight: 540)
            .background(AppColor.workspace)
            .preferredColorScheme(LibraryStore.shared.appearanceMode.colorScheme)
        }

        Window("清理记录", id: AuxiliaryWindowID.history) {
            CleanupHistoryView(store: LibraryStore.shared.cleanupHistory, libraryStore: LibraryStore.shared)
                .background(AppColor.workspace)
                .preferredColorScheme(LibraryStore.shared.appearanceMode.colorScheme)
        }
        .defaultSize(width: 720, height: 560)



        MenuBarExtra("FCP Cleaner", systemImage: "sparkles") {

            MenuBarPanel(store: LibraryStore.shared)

        }

        .menuBarExtraStyle(.window)

    }

}



private struct MenuBarPanel: View {

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Bindable var store: LibraryStore



    var body: some View {

        VStack(alignment: .leading, spacing: 12) {

            HStack {

                CleanerMenuMark()

                Text("FCP Cleaner")

                    .font(AppFont.heading(.semibold, design: .rounded))

                Spacer()

                Text(FormatHelpers.bytes(store.totalCleanableSize))

                    .font(AppFont.body(.bold, design: .rounded))

                    .contentTransition(.numericText())

                    .animation(reduceMotion ? nil : .snappy, value: store.totalCleanableSize)

            }

            if let warning = store.lowSpaceWarnings.first {

                Label(String(format: String(localized: "%@ 剩余 %@"), String(warning.name), String(FormatHelpers.bytes(warning.availableSize))), systemImage: "exclamationmark.triangle.fill")

                    .font(AppFont.small(.medium))

                    .foregroundStyle(AppColor.warning)

            }

            HStack {

                Button("打开") { store.showMainWindow() }

                Button(store.isScanPending ? String(localized: "扫描中…") : String(localized: "扫描")) { store.discoverLibraries() }

                    .disabled(store.isScanPending)

                Button("清理") { store.requestMenuBarCleanup() }

                    .disabled(store.totalCleanableSize < LibraryStore.minimumCleanableSize || store.isPreflighting || store.isCleaning)

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
