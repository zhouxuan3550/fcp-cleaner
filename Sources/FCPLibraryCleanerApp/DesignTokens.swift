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
    static let workspace = dynamicColor(light: "FFFFFF", dark: "202020")
    static let panel = dynamicColor(light: "F0F0F2", dark: "2A2A2A")
    static let control = dynamicColor(light: "E8E8EA", dark: "303030")
    static let primaryText = dynamicColor(light: "1C1C1E", dark: "E7E7E7")
    static let secondaryText = dynamicColor(light: "555558", dark: "A8A8AC")
    static let tertiaryText = dynamicColor(light: "6E6E73", dark: "929296")
    static let border = dynamicColor(light: "D1D1D6", dark: "3C3C3C")
    static let dashedBorder = dynamicColor(light: "8E8E93", dark: "747474")
    static let accent = dynamicColor(light: "634CD9", dark: "634CD9")
    static let success = dynamicColor(light: "248A3D", dark: "35B85A")
    /// 状态警示（未到 danger 的程度）：周增长徽标、空间预警等。
    static let warning = dynamicColor(light: "B25000", dark: "FF9F0A")
    static let danger = dynamicColor(light: "D70015", dark: "D45C57")
    /// 占用细分图例的分类色板（条形图与图例共用）：渲染=accent，代理/优化如下。
    static let chartProxyMedia = Color.teal
    static let chartOptimizedMedia = Color.orange
}

struct CompatibleGlassEffect<S: Shape>: ViewModifier {
    let shape: S
    let interactive: Bool
    let tint: Color?
    let fallbackColor: Color

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            if interactive {
                if let tint {
                    content.glassEffect(.regular.interactive().tint(tint), in: shape)
                } else {
                    content.glassEffect(.regular.interactive(), in: shape)
                }
            } else if let tint {
                content.glassEffect(.regular.tint(tint), in: shape)
            } else {
                content.glassEffect(.regular, in: shape)
            }
        } else {
            content
                .background(fallbackColor, in: shape)
                .overlay(shape.stroke(AppColor.border.opacity(0.55), lineWidth: 1))
        }
    }
}

extension View {
    func compatibleGlassEffect<S: Shape>(
        in shape: S,
        interactive: Bool = false,
        tint: Color? = nil,
        fallbackColor: Color = AppColor.workspace
    ) -> some View {
        modifier(CompatibleGlassEffect(
            shape: shape,
            interactive: interactive,
            tint: tint,
            fallbackColor: fallbackColor
        ))
    }
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
    static let contentHorizontalPadding: CGFloat = 18
    static let contentBottomPadding: CGFloat = 16
    static let headerHorizontalPadding: CGFloat = 18
    static let headerTopPadding: CGFloat = 16
    static let headerBottomPadding: CGFloat = 14
}

enum FormatHelpers {
    /// ByteCountFormatter 的类方法每次调用都会新建 formatter 实例，而侧栏行、
    /// 徽标、菜单栏面板每次渲染都会取字节串——共享实例 + 字节串缓存，
    /// 让重复渲染从「每次微秒级格式化」变成字典命中。
    private static let byteFormatterLock = NSLock()
    private nonisolated(unsafe) static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()
    private nonisolated(unsafe) static var byteStringCache: [Int64: String] = [:]

    static func bytes(_ bytes: Int64) -> String {
        byteFormatterLock.lock()
        defer { byteFormatterLock.unlock() }
        if let cached = byteStringCache[bytes] {
            return cached
        }
        let string = byteFormatter.string(fromByteCount: bytes)
        // 缓存有界：扫描期间字节数单调递增会产生大量一次性值，超限直接重置。
        if byteStringCache.count >= 512 {
            byteStringCache.removeAll(keepingCapacity: true)
        }
        byteStringCache[bytes] = string
        return string
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
