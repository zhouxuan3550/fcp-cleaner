import SwiftUI

struct QueueActionButtonStyle: ButtonStyle {
    var emphasized = false
    var enabled = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AppFont.callout(.semibold))
            .foregroundStyle(emphasized ? Color.white : AppColor.primaryText)
            .padding(.horizontal, 11)
            .frame(height: LayoutMetrics.controlHeight)
            .compatibleGlassEffect(
                in: RoundedRectangle(cornerRadius: 10, style: .continuous),
                interactive: true,
                tint: emphasized ? AppColor.accent : nil,
                fallbackColor: emphasized ? AppColor.accent : AppColor.control
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
            .font(AppFont.body(.semibold))
            .foregroundStyle(emphasized ? Color.white : AppColor.primaryText)
            .padding(.horizontal, 17)
            .frame(height: LayoutMetrics.headerHeight)
            .compatibleGlassEffect(
                in: RoundedRectangle(cornerRadius: 12, style: .continuous),
                interactive: true,
                tint: emphasized ? AppColor.accent : nil,
                fallbackColor: emphasized ? AppColor.accent : AppColor.control
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
            .font(AppFont.heading(.bold))
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
            .font(AppFont.body(.semibold))
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
            .font(AppFont.body(.bold))
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
