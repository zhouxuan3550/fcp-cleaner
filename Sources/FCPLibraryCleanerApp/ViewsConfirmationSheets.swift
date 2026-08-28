import AppKit
import SwiftUI
import FCPLibraryCleanerCore

struct SingleCleanConfirmationSheet: View {
    let confirmation: CleanConfirmation
    let store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var collapsed: Set<CacheCategory> = []

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
                                    Text(FormatHelpers.bytes(item.entry.item.allocatedSize))
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundStyle(AppColor.secondaryText)
                                }
                                .padding(.vertical, 5)
                                .padding(.leading, 22)
                            }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: group.category.iconName)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(AppColor.accent)
                                    .frame(width: 24)
                                Text(group.category.chineseName)
                                    .font(.system(size: 12, weight: .medium))
                                Text("\(group.entries.count) 项")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(AppColor.tertiaryText)
                                Spacer()
                                Text(FormatHelpers.bytes(group.total))
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(AppColor.secondaryText)
                            }
                            .padding(.vertical, 8)
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
                        Spacer()
                        Text(FormatHelpers.bytes(confirmation.plan.spaceToFree))
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .monospacedDigit()
                    }
                    .padding(.top, 10)
                    if let seconds = store.estimatedCleanupDuration(forBytes: confirmation.plan.spaceToFree, volumeID: confirmation.record.volumeID) {
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
        .frame(width: LayoutMetrics.singleConfirmSheetWidth)
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
                    Text("释放 \(FormatHelpers.bytes(summary.totalFreedSize)) · \(summary.totalItemCount) 项 · \(FormatHelpers.duration(summary.elapsedSeconds))")
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
        var parts = ["释放 \(FormatHelpers.bytes(notice.freedSize))", "\(notice.cleanedItemCount) 项"]
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
