import SwiftUI

struct FilterButtonStyle: ButtonStyle {
    let isSelected: Bool
    var isDefault: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(isSelected ? Color.white : AppColor.secondaryText)
            .padding(.horizontal, 9)
            .frame(height: LayoutMetrics.controlHeight)
            .background(isSelected ? AppColor.accent : AppColor.control)
            .overlay {
                if !isSelected && isDefault {
                    Capsule()
                        .stroke(AppColor.accent.opacity(0.35), lineWidth: 1)
                }
            }
            .clipShape(Capsule())
            .opacity(configuration.isPressed ? 0.74 : 1)
    }
}

struct QueueActionButtonStyle: ButtonStyle {
    var emphasized = false
    var enabled = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(emphasized ? Color.white : AppColor.primaryText)
            .padding(.horizontal, 11)
            .frame(height: LayoutMetrics.controlHeight)
            .background(emphasized ? AppColor.accent : AppColor.control)
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(emphasized ? Color.clear : AppColor.border, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
            .animation(.easeOut(duration: 0.12), value: enabled)
    }
}

struct HeaderButtonStyle: ButtonStyle {
    var emphasized = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(emphasized ? Color.white : AppColor.primaryText)
            .padding(.horizontal, 17)
            .frame(height: LayoutMetrics.headerHeight)
            .background(emphasized ? AppColor.accent.opacity(configuration.isPressed ? 0.72 : 1) : AppColor.control)
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(emphasized ? Color.clear : AppColor.border, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .opacity(configuration.isPressed ? 0.78 : 1)
    }
}

struct PrimaryActionButtonStyle: ButtonStyle {
    var enabled = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: LayoutMetrics.primaryButtonHeight)
            .background(AppColor.accent)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.38)
            .animation(.easeOut(duration: 0.12), value: enabled)
    }
}

struct SheetSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(AppColor.primaryText)
            .frame(height: LayoutMetrics.sheetButtonHeight)
            .frame(maxWidth: .infinity)
            .background(AppColor.control)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

struct SheetDestructiveButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(.white)
            .frame(height: LayoutMetrics.sheetButtonHeight)
            .frame(maxWidth: .infinity)
            .background(AppColor.danger)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}
