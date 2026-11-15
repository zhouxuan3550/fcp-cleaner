import Charts
import SwiftUI
import FCPLibraryCleanerCore

/// 总览仪表盘：汇总数字、各卷压力、Top 3 推荐。
/// 只是排序推荐与信息呈现——清理决策永远由用户发起（产品红线）。
struct DashboardView: View {
    let store: LibraryStore
    @State private var pressures: [LibraryStore.VolumePressure] = []

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                HStack(spacing: 14) {
                    MetricCard(label: "可清理合计", value: FormatHelpers.bytes(store.totalCleanableSize), icon: "sparkles")
                    MetricCard(label: "本周已释放", value: FormatHelpers.bytes(store.weeklyFreedSize), icon: "checkmark.circle.fill", emphasized: store.weeklyFreedSize > 0)
                    MetricCard(label: "资源库", value: store.libraries.count.formatted(), icon: "square.stack.3d.up.fill")
                }

                volumePressureCard

                topCandidatesCard
            }
            .padding(22)
        }
        .scrollIndicators(.hidden)
        .task { pressures = await store.volumePressures() }
    }

    private var volumePressureCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("各卷压力")
                .font(AppFont.title(.semibold, design: .rounded))
            if pressures.isEmpty {
                Text("正在读取卷容量…")
                    .font(AppFont.callout(.medium))
                    .foregroundStyle(AppColor.tertiaryText)
                    .padding(.vertical, 8)
            } else {
                ForEach(pressures) { pressure in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(pressure.name)
                                .font(AppFont.body(.medium))
                            Spacer()
                            Text("可用 \(pressure.available.map(FormatHelpers.bytes) ?? "未知") · 可清理 \(FormatHelpers.bytes(pressure.cleanable))")
                                .font(AppFont.caption(.medium, design: .monospaced))
                                .foregroundStyle(AppColor.secondaryText)
                        }
                        GeometryReader { proxy in
                            let denominator = max((pressure.available ?? 0) + pressure.cleanable, 1)
                            let fraction = min(1, Double(pressure.cleanable) / Double(denominator))
                            ZStack(alignment: .leading) {
                                Capsule().fill(AppColor.control)
                                Capsule()
                                    .fill(AppColor.accent.gradient)
                                    .frame(width: max(0, proxy.size.width * fraction))
                            }
                        }
                        .frame(height: 8)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(pressure.name)：可用 \(pressure.available.map(FormatHelpers.bytes) ?? "未知")，可清理 \(FormatHelpers.bytes(pressure.cleanable))")
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(AppColor.panel)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var topCandidatesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("现在最值得清理")
                .font(AppFont.title(.semibold, design: .rounded))
            let candidates = store.topCleanupCandidates(pressures: pressures)
            if candidates.isEmpty {
                Text("暂无达到门槛的候选")
                    .font(AppFont.callout(.medium))
                    .foregroundStyle(AppColor.tertiaryText)
                    .padding(.vertical, 8)
            } else {
                ForEach(candidates) { record in
                    HStack(spacing: 12) {
                        Image(systemName: "sparkles")
                            .font(AppFont.body(.semibold))
                            .foregroundStyle(AppColor.accent)
                            .frame(width: 30, height: 30)
                            .background(AppColor.control)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.displayName)
                                .font(AppFont.body(.medium))
                                .lineLimit(1)
                            Text("\(record.volumeName) · 最近使用 \(record.lastActivity.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "未知")")
                                .font(AppFont.caption(.medium))
                                .foregroundStyle(AppColor.secondaryText)
                        }
                        Spacer()
                        Text(FormatHelpers.bytes(store.effectiveCleanableSize(for: record)))
                            .font(AppFont.callout(.semibold, design: .monospaced))
                            .foregroundStyle(AppColor.accent)
                        Button("查看") {
                            store.select(record)
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(AppColor.accent)
                    }
                    .padding(.vertical, 4)
                }
                Text("仅为排序推荐；是否清理、何时清理完全由你决定")
                    .font(AppFont.caption(.medium))
                    .foregroundStyle(AppColor.tertiaryText)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(AppColor.panel)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
