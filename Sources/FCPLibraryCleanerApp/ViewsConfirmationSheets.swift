import AppKit
import SwiftUI
import FCPLibraryCleanerCore

struct SingleCleanConfirmationSheet: View {
    let confirmation: CleanConfirmation
    let store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var collapsed: Set<CacheCategory> = []
    /// 用户取消勾选的条目（Event/共享目录级）。默认全选，只允许缩小清理范围。
    @State private var excluded: Set<URL> = []

    private var includedURLs: Set<URL> {
        Set(confirmation.plan.entries.map(\.item.url)).subtracting(excluded)
    }

    /// 勾选裁剪后的实际执行计划；每一条仍走完整预检与指纹复核。
    private var selectedPlan: CleanupPlan {
        confirmation.plan.filtering(keeping: includedURLs)
    }

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
                    Text(confirmation.isRetry ? "重试失败项目？" : "将已选生成文件移入废纸篓？")
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                    Text(confirmation.record.displayName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AppColor.secondaryText)
                        .lineLimit(1)
                }
            }

            Text("可按 Event 或共享目录取消勾选；确认后仅清理所选条目，全部仍逐项复核指纹")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(AppColor.tertiaryText)

            ScrollView {
                VStack(spacing: 0) {
                    let groups = CleanupPreview.groups(from: confirmation.plan)
                    ForEach(groups, id: \.category) { group in
                        DisclosureGroup(isExpanded: Binding(
                            get: { !collapsed.contains(group.category) },
                            set: { expanded in
                                if expanded { collapsed.remove(group.category) }
                                else { collapsed.insert(group.category) }
                            }
                        )) {
                            ForEach(group.entries) { item in
                                HStack(spacing: 8) {
                                    entryCheckbox(item.id)
                                    VStack(alignment: .leading, spacing: 1) {
                                        HStack(spacing: 5) {
                                            Text(item.locationLabel)
                                                .font(.system(size: 12, weight: .medium))
                                                .lineLimit(1)
                                            if item.entry.item.storage == .external {
                                                Text("外置")
                                                    .font(.system(size: 9, weight: .semibold))
                                                    .foregroundStyle(AppColor.accent)
                                                    .padding(.horizontal, 4).padding(.vertical, 1)
                                                    .background(AppColor.accent.opacity(0.16))
                                                    .clipShape(Capsule())
                                            }
                                        }
                                        Text(item.pathDetail)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(AppColor.tertiaryText)
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 6)
                                    Text("\(item.entry.item.fingerprint.entryCount) 个文件")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(AppColor.tertiaryText)
                                        .opacity(excluded.contains(item.id) ? 0.4 : 1)
                                    Text(FormatHelpers.bytes(item.entry.item.allocatedSize))
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundStyle(AppColor.secondaryText)
                                        .opacity(excluded.contains(item.id) ? 0.4 : 1)
                                }
                                .padding(.vertical, 5)
                                .padding(.leading, 6)
                            }
                        } label: {
                            categoryHeader(group)
                        }
                        .tint(AppColor.secondaryText)
                        if group.category != groups.last?.category {
                            Divider().overlay(AppColor.border)
                        }
                    }
                    Divider().overlay(AppColor.border)
                    HStack {
                        Text("合计")
                            .font(.system(size: 12, weight: .semibold))
                        Text("已选 \(includedURLs.count)/\(confirmation.plan.entries.count) 项")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(AppColor.tertiaryText)
                        Spacer()
                        Text(FormatHelpers.bytes(selectedPlan.spaceToFree))
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                            .animation(.snappy(duration: 0.2), value: selectedPlan.spaceToFree)
                    }
                    .padding(.top, 10)
                    if let seconds = store.estimatedCleanupDuration(forBytes: selectedPlan.spaceToFree, volumeID: confirmation.record.volumeID) {
                        HStack(spacing: 4) {
                            Image(systemName: "clock")
                            Text("预计耗时 \(FormatHelpers.estimatedTime(seconds))")
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(AppColor.tertiaryText)
                        .padding(.top, 6)
                    }
                }
                .padding(.horizontal, 14)
            }
            .frame(maxHeight: 280)
            .background(AppColor.panel)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            SecurityPreflightFlowView()

            HStack(spacing: 10) {
                Button("取消") { dismiss() }
                    .buttonStyle(SheetSecondaryButtonStyle())
                Button {
                    store.performConfirmedCleanup(CleanConfirmation(
                        record: confirmation.record,
                        plan: selectedPlan,
                        isRetry: confirmation.isRetry
                    ))
                    dismiss()
                } label: {
                    Text("移入废纸篓")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SheetDestructiveButtonStyle())
                .disabled(includedURLs.isEmpty)
                .opacity(includedURLs.isEmpty ? 0.4 : 1)
                .help(includedURLs.isEmpty ? "请至少勾选一个条目" : "")
            }
        }
        .padding(22)
        .frame(width: LayoutMetrics.singleConfirmSheetWidth)
    }

    /// 条目级勾选框：默认全选（实心），取消后变空心灰。
    private func entryCheckbox(_ url: URL) -> some View {
        let isExcluded = excluded.contains(url)
        return Button {
            if isExcluded { excluded.remove(url) } else { excluded.insert(url) }
        } label: {
            Image(systemName: isExcluded ? "circle" : "checkmark.circle.fill")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(isExcluded ? AppColor.tertiaryText : AppColor.accent)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isExcluded ? "重新包含此项" : "跳过此项")
    }

    /// 类别级勾选：全选实心、全不选空心、部分选中半选；点击在"全选本类"与"全不选本类"间切换。
    private func categoryHeader(_ group: (category: CacheCategory, total: Int64, entries: [CleanupPreviewEntry])) -> some View {
        let included = group.entries.filter { !excluded.contains($0.id) }
        let allIncluded = included.count == group.entries.count
        let noneIncluded = included.isEmpty
        let includedTotal = included.reduce(Int64(0)) { $0 + $1.entry.item.allocatedSize }
        return HStack(spacing: 10) {
            Button {
                let categoryURLs = Set(group.entries.map(\.id))
                if allIncluded {
                    excluded.formUnion(categoryURLs)
                } else {
                    excluded.subtract(categoryURLs)
                }
            } label: {
                Image(systemName: noneIncluded ? "circle" : (allIncluded ? "checkmark.circle.fill" : "circle.lefthalf.filled"))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(noneIncluded ? AppColor.tertiaryText : AppColor.accent)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(allIncluded ? "取消选择全部\(group.category.chineseName)" : "选择全部\(group.category.chineseName)")

            Image(systemName: group.category.iconName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppColor.accent)
                .frame(width: 24)
            Text(group.category.chineseName)
                .font(.system(size: 12, weight: .medium))
            Text("已选 \(included.count)/\(group.entries.count) 项")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AppColor.tertiaryText)
            Spacer()
            Text(FormatHelpers.bytes(includedTotal))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(AppColor.secondaryText)
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.2), value: includedTotal)
        }
        .padding(.vertical, 8)
    }
}

struct BatchCleanConfirmationSheet: View {
    let confirmation: BatchCleanConfirmation
    let store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var expandedLibraryIDs: Set<UUID> = []

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
                    Text("共 \(FormatHelpers.bytes(confirmation.totalSpaceToFree))")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AppColor.secondaryText)
                    if let seconds = store.estimatedBatchCleanupDuration(
                        entries: confirmation.entries.map { (bytes: $0.plan.spaceToFree, volumeID: $0.record.volumeID) }
                    ) {
                        Text("预计耗时 \(FormatHelpers.estimatedTime(seconds))")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(AppColor.tertiaryText)
                    }
                }
            }

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(confirmation.entries, id: \.record.id) { entry in
                        DisclosureGroup(isExpanded: Binding(
                            get: { expandedLibraryIDs.contains(entry.record.id) },
                            set: { expanded in
                                if expanded { expandedLibraryIDs.insert(entry.record.id) }
                                else { expandedLibraryIDs.remove(entry.record.id) }
                            }
                        )) {
                            VStack(spacing: 0) {
                                ForEach(CacheCategory.cleanableCases, id: \.self) { category in
                                    let size = entry.plan.entries
                                        .filter { $0.item.category == category }
                                        .reduce(Int64(0)) { $0 + $1.item.allocatedSize }
                                    if size > 0 {
                                        HStack(spacing: 10) {
                                            Image(systemName: category.iconName)
                                                .font(.system(size: 11, weight: .semibold))
                                                .foregroundStyle(AppColor.accent)
                                                .frame(width: 20)
                                            Text(category.chineseName)
                                                .font(.system(size: 11, weight: .medium))
                                            Spacer()
                                            Text(FormatHelpers.bytes(size))
                                                .font(.system(size: 11, design: .monospaced))
                                                .foregroundStyle(AppColor.secondaryText)
                                        }
                                        .padding(.vertical, 4)
                                        .padding(.leading, 22)
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "square.stack.3d.up.fill")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(AppColor.accent)
                                Text(entry.record.displayName)
                                    .font(.system(size: 12, weight: .medium))
                                    .lineLimit(1)
                                Spacer()
                                Text(FormatHelpers.bytes(entry.plan.spaceToFree))
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(AppColor.secondaryText)
                            }
                            .padding(.vertical, 7)
                        }
                        .tint(AppColor.secondaryText)
                        if entry.record.id != confirmation.entries.last?.record.id {
                            Divider().overlay(AppColor.border)
                        }
                    }
                }
                .padding(.horizontal, 14)
            }
            .frame(maxHeight: 280)
            .background(AppColor.panel)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            SecurityPreflightFlowView()

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
        .frame(width: LayoutMetrics.batchConfirmSheetWidth)
    }
}

struct CleanupSummarySheet: View {
    let summary: CleanupSummary
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: summary.errorCount == 0 ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(summary.errorCount == 0 ? AppColor.success : AppColor.danger)
                VStack(alignment: .leading, spacing: 3) {
                    Text(summary.title)
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                    Text("移入废纸篓 \(FormatHelpers.bytes(summary.totalFreedSize)) · \(summary.totalItemCount) 项 · \(FormatHelpers.duration(summary.elapsedSeconds))")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AppColor.secondaryText)
                }
            }

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(summary.libraries) { library in
                        HStack(spacing: 10) {
                            Image(systemName: library.succeeded ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                                .foregroundStyle(library.succeeded ? AppColor.success : AppColor.danger)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(library.name)
                                    .font(.system(size: 13, weight: .semibold))
                                    .lineLimit(1)
                                if let errorMessage = library.errorMessage {
                                    Text(errorMessage)
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(AppColor.danger)
                                        .lineLimit(2)
                                }
                            }
                            Spacer(minLength: 8)
                            Text("\(FormatHelpers.bytes(library.freedSize)) · \(library.itemCount) 项")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(AppColor.secondaryText)
                        }
                        .padding(11)
                        .background(AppColor.control)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
            }
            .frame(maxHeight: 280)

            Button("完成") { dismiss() }
                .buttonStyle(HeaderButtonStyle(emphasized: true))
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(22)
        .frame(width: LayoutMetrics.batchConfirmSheetWidth)
    }
}

struct CleanupNoticeView: View {
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
            .accessibilityLabel("关闭通知")
        }
        .padding(14)
        .frame(width: LayoutMetrics.noticeWidth, alignment: .leading)
        .compatibleGlassEffect(
            in: RoundedRectangle(cornerRadius: 14, style: .continuous),
            fallbackColor: AppColor.panel
        )
        .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
    }

    private var summary: String {
        var parts = ["移入废纸篓 \(FormatHelpers.bytes(notice.freedSize))", "\(notice.cleanedItemCount) 项"]
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

struct CleanupPreviewEntry: Identifiable {
    let entry: CleanupPlanEntry
    let locationLabel: String
    let pathDetail: String
    var id: URL { entry.item.url }
}

enum CleanupPreview {
    static func groups(from plan: CleanupPlan) -> [(category: CacheCategory, total: Int64, entries: [CleanupPreviewEntry])] {
        CacheCategory.cleanableCases.compactMap { category in
            let entries = plan.entries.filter { $0.item.category == category }
            guard !entries.isEmpty else { return nil }
            let preview = entries.map { entry -> CleanupPreviewEntry in
                let location = FCPStructureRules.candidateLocation(for: entry.item.url, ruleID: entry.item.ruleID)
                let label = location?.eventName ?? "共享"
                let detail = location?.categoryPath ?? entry.item.url.lastPathComponent
                return CleanupPreviewEntry(entry: entry, locationLabel: label, pathDetail: detail)
            }
            return (category, entries.reduce(0) { $0 + $1.item.allocatedSize }, preview)
        }
    }
}

struct SecurityPreflightFlowView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppColor.success)
                Text("安全预检与保护机制")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppColor.primaryText)
                Spacer()
                Text("预检通过")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(AppColor.success)
            }

            VStack(alignment: .leading, spacing: 4) {
                stepRow(icon: "lock.shield", title: "进程检查", desc: "已检查 Final Cut Pro 是否占用资源库")
                stepRow(icon: "externaldrive.badge.checkmark", title: "磁盘权限", desc: "已检查资源库及目标位置")
                stepRow(icon: "doc.badge.gearshape", title: "快照与指纹", desc: "清理前逐项复核文件指纹")
                stepRow(icon: "trash", title: "废纸篓保护", desc: "移入废纸篓后可恢复")
            }
            .padding(.top, 2)
        }
        .padding(10)
        .background(AppColor.control.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("安全预检通过：已检查 Final Cut Pro 占用及磁盘状态，清理前会逐项复核文件指纹，并移入废纸篓。")
    }

    private func stepRow(icon: String, title: String, desc: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(AppColor.success)
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(AppColor.primaryText)
            Text("·")
                .font(.system(size: 10))
                .foregroundStyle(AppColor.tertiaryText)
            Text(desc)
                .font(.system(size: 10))
                .foregroundStyle(AppColor.secondaryText)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }
}
