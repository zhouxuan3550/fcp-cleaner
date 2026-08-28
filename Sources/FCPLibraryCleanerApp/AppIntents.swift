import AppIntents
import Foundation

/// Shortcuts / Siri 入口：三个只读意图。
/// 产品红线：刻意不提供任何清理类意图——自动化只能触发扫描与查询，
/// 实际清理永远需要用户在应用内经过预检并确认。
struct ScannedWorkDirs: AppIntent {
    static let title: LocalizedStringResource = "扫描工作目录"
    static let description = IntentDescription(
        "重新扫描已设置的工作目录，返回正在扫描的工作目录列表。"
    )

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[String]> {
        let store = LibraryStore.shared
        store.discoverLibraries()
        return .result(value: store.workDirectories.map(\.path))
    }
}

struct ScanLibrary: AppIntent {
    static let title: LocalizedStringResource = "扫描资源库"
    static let description = IntentDescription(
        "对指定资源库做增量扫描并等待完成，返回当前可安全清理的空间。名称留空则扫描全部资源库。"
    )

    @Parameter(title: "资源库名称", description: "资源库显示名，留空扫描全部", default: "")
    var libraryName: String

    static var parameterSummary: some ParameterSummary {
        Summary("扫描 \(\.$libraryName)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let store = LibraryStore.shared
        let query = libraryName.trimmingCharacters(in: .whitespacesAndNewlines)
        let targets: [LibraryRecord]
        if query.isEmpty {
            targets = store.libraries
        } else {
            targets = store.libraries.filter { Self.matchesRequested($0.displayName, query: query) }
        }
        guard !targets.isEmpty else {
            return .result(value: "未找到名为「\(query)」的资源库")
        }
        for record in targets {
            store.scan(record, force: false)
        }
        // 等待扫描静默（上限 15 分钟）；扫描本身在后台并发执行
        let deadline = Date().addingTimeInterval(900)
        while store.isScanPending, Date() < deadline {
            try? await Task.sleep(for: .seconds(1))
        }
        let scanned = targets.count(where: { $0.scanResult != nil })
        let total = targets.reduce(Int64(0)) { $0 + store.effectiveCleanableSize(for: $1) }
        return .result(value: "已扫描 \(scanned)/\(targets.count) 个资源库，可安全清理 \(FormatHelpers.bytes(total))")
    }

    /// 名称匹配：完全相等或本地化包含；纯函数便于测试。
    static func matchesRequested(_ displayName: String, query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return displayName == trimmed || displayName.localizedStandardContains(trimmed)
    }
}

struct ShowCleanableSpace: AppIntent {
    static let title: LocalizedStringResource = "查看可清理空间"
    static let description = IntentDescription(
        "汇总所有资源库当前可安全清理的空间，并打开 FCP Cleaner 主窗口。"
    )

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let store = LibraryStore.shared
        let total = store.totalCleanableSize
        store.showMainWindow()
        return .result(value: "当前可安全清理 \(FormatHelpers.bytes(total))")
    }
}

struct FCPCleanerShortcuts: AppShortcutsProvider {
    @AppShortcutsBuilder
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ScanLibrary(),
            phrases: [
                "在\(.applicationName)中扫描资源库",
                "Scan libraries in \(.applicationName)",
            ],
            shortTitle: "扫描资源库",
            systemImageName: "arrow.clockwise"
        )
        AppShortcut(
            intent: ShowCleanableSpace(),
            phrases: [
                "查看\(.applicationName)可清理空间",
                "Show cleanable space in \(.applicationName)",
            ],
            shortTitle: "查看可清理空间",
            systemImageName: "sparkles"
        )
    }
}
