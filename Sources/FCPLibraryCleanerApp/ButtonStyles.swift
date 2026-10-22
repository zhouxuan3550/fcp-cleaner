import SwiftUI

struct FilterButtonStyle: ButtonStyle {
    let isSelected: Bool
    var isDefault: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .lineLimit(1)
            // 不再 fixedSize：空间不足时缩字而不是撑爆侧栏（P4-2 第四个筛选曾把
            // chips 行最小宽顶到 300pt 框架之外，导致侧栏溢出与详情面板重叠）。
            .minimumScaleFactor(0.75)
            .foregroundStyle(isSelected ? Color.white : AppColor.secondaryText)
            .padding(.horizontal, 7)
            .frame(height: LayoutMetrics.controlHeight)
            .background(isSelected ? AppColor.accent : AppColor.control)
            .overlay {
                if !isSelected && isDefault {
                    Capsule()
                        .stroke(AppColor.accent.opacity(0.35), lineWidth: 1)
                }
            }
            .clipShape(Capsule())
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1.0)
            .opacity(configuration.isPressed ? 0.74 : 1)
            .animation(.snappy(duration: 0.16), value: configuration.isPressed)
    }
}

struct QueueActionButtonStyle: ButtonStyle {
    var emphasized = false
    var enabled = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(emphasized ? Color.white : AppColor.primaryText)
            .padding(.horizontal, 11)
            .frame(height: LayoutMetrics.controlHeight)
            .glassEffect(
                emphasized
                    ? .regular.interactive().tint(AppColor.accent)
                    : .regular.interactive(),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .scaleEffect(configuration.isPressed && enabled && !reduceMotion ? 0.96 : 1.0)
            .opacity(enabled ? 1 : 0.45)
            .animation(.snappy(duration: 0.16), value: configuration.isPressed)
    }
}

struct HeaderButtonStyle: ButtonStyle {
    var emphasized = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(emphasized ? Color.white : AppColor.primaryText)
            .padding(.horizontal, 17)
            .frame(height: LayoutMetrics.headerHeight)
            .glassEffect(
                emphasized
                    ? .regular.interactive().tint(AppColor.accent)
                    : .regular.interactive(),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1.0)
            .animation(.snappy(duration: 0.16), value: configuration.isPressed)
    }
}

struct PrimaryActionButtonStyle: ButtonStyle {
    var enabled = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: LayoutMetrics.primaryButtonHeight)
            .background(AppColor.accent)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: AppColor.accent.opacity(enabled ? 0.3 : 0), radius: 8, y: 3)
            .scaleEffect(configuration.isPressed && enabled && !reduceMotion ? 0.96 : 1.0)
            .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.38)
            .animation(.snappy(duration: 0.16), value: configuration.isPressed)
    }
}

struct SheetSecondaryButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(AppColor.primaryText)
            .frame(height: LayoutMetrics.sheetButtonHeight)
            .frame(maxWidth: .infinity)
            .background(AppColor.control)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1.0)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.snappy(duration: 0.16), value: configuration.isPressed)
    }
}

struct SheetDestructiveButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(.white)
            .frame(height: LayoutMetrics.sheetButtonHeight)
            .frame(maxWidth: .infinity)
            .background(AppColor.danger)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1.0)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.snappy(duration: 0.16), value: configuration.isPressed)
    }
}
