import SwiftUI

private func dynamicColor(light: String, dark: String) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
        let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        let value = UInt64(hex, radix: 16) ?? 0
        return NSColor(
            srgbRed: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            alpha: 1
        )
    })
}

enum AppColor {
    static let brand = Color(hex: "634CD9")
    static let canvas = dynamicColor(light: "F5F5F7", dark: "242424")
    static let workspace = dynamicColor(light: "FFFFFF", dark: "202020")
    static let panel = dynamicColor(light: "F0F0F2", dark: "2A2A2A")
    static let control = dynamicColor(light: "E8E8EA", dark: "303030")
    static let primaryText = dynamicColor(light: "1C1C1E", dark: "E7E7E7")
    static let secondaryText = dynamicColor(light: "636366", dark: "A0A0A0")
    static let tertiaryText = dynamicColor(light: "8E8E93", dark: "747474")
    static let border = dynamicColor(light: "D1D1D6", dark: "3C3C3C")
    static let dashedBorder = dynamicColor(light: "8E8E93", dark: "747474")
    static let accent = dynamicColor(light: "5D72D8", dark: "5D72D8")
    static let success = dynamicColor(light: "248A3D", dark: "35B85A")
    static let danger = dynamicColor(light: "D70015", dark: "D45C57")
}

extension Color {
    init(hex: String) {
        let value = UInt64(hex, radix: 16) ?? 0
        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            opacity: 1
        )
    }
}

enum LayoutMetrics {
    /// 340 = 四个筛选 chip（紧凑样式、三位数计数）的最小宽 + 余量。
    /// 侧栏内容最小宽一旦超过此值，整列会溢出框架压到详情面板上（P4-2 教训）。
    static let sidebarWidth: CGFloat = 340
    static let cleanupActionCardWidth: CGFloat = 270
    static let settingsPopoverWidth: CGFloat = 340
    static let historyPopoverWidth: CGFloat = 370
    static let singleConfirmSheetWidth: CGFloat = 400
    static let batchConfirmSheetWidth: CGFloat = 440
    static let noticeWidth: CGFloat = 390
    static let menuBarPanelWidth: CGFloat = 280
    static let headerHeight: CGFloat = 42
    static let controlHeight: CGFloat = 30
    static let sheetButtonHeight: CGFloat = 38
    static let primaryButtonHeight: CGFloat = 44
    static let windowMinWidth: CGFloat = 940
    static let windowMinHeight: CGFloat = 660
    static let windowDefaultWidth: CGFloat = 1_080
    static let windowDefaultHeight: CGFloat = 760
    static let contentHorizontalPadding: CGFloat = 38
    static let contentBottomPadding: CGFloat = 34
    static let headerHorizontalPadding: CGFloat = 38
    static let headerTopPadding: CGFloat = 28
    static let headerBottomPadding: CGFloat = 26
}

enum FormatHelpers {
    static func bytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func estimatedTime(_ seconds: Double) -> String {
        if seconds < 60 { return "1 分钟以内" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "约 \(minutes) 分钟" }
        let hours = minutes / 60
        let remaining = minutes % 60
        return "约 \(hours) 小时 \(remaining) 分钟"
    }

    static func duration(_ seconds: Double) -> String {
        if seconds < 1 { return "不到 1 秒" }
        if seconds < 60 { return "\(Int(seconds)) 秒" }
        let totalSeconds = Int(seconds)
        let mins = totalSeconds / 60
        let secs = totalSeconds % 60
        if mins < 60 { return secs == 0 ? "\(mins) 分钟" : "\(mins) 分 \(secs) 秒" }
        let hours = mins / 60
        let remainingMins = mins % 60
        return remainingMins == 0 ? "\(hours) 小时" : "\(hours) 小时 \(remainingMins) 分"
    }
}
