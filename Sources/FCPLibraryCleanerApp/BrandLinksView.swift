import SwiftUI

/// 版本号与品牌链接（样式对齐 LUT Manager）：B 站 · GitHub · 小红书。
/// 图标资源在 Assets/BrandLogos.xcassets，模板渲染跟随深浅色；
/// 颜色走 AppColor 设计令牌，与本应用其余界面保持一致。
/// 资产目录仅随 xcodebuild 应用产物打包；SPM 构建产物中 Image 会静默为空
/// （CLI 产物不使用视图，应用产品始终经 xcodebuild/release.sh 构建）。
struct BrandLinksView: View {
    /// 当前软件自己的 GitHub 项目地址；没有公开仓库时传 nil（隐藏图标）。
    var repositoryURL: URL? = nil
    var repositoryName: String = "GitHub 仓库"

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    var body: some View {
        HStack(spacing: 8) {
            Text("版本 \(appVersion)")
                .foregroundStyle(AppColor.secondaryText)
            Text("·")
                .foregroundStyle(AppColor.tertiaryText)
            HStack(spacing: 10) {
                Link(destination: URL(string: "https://space.bilibili.com/14118553")!) {
                    logo("BilibiliLogo", size: 17)
                }
                .help("调色师手册开发 · B 站主页")
                .accessibilityLabel("调色师手册开发，打开 B 站主页")

                if let repositoryURL {
                    Link(destination: repositoryURL) {
                        logo("GitHubLogo", size: 15)
                    }
                    .help("\(repositoryName) · GitHub 仓库")
                    .accessibilityLabel("打开 \(repositoryName) 的 GitHub 仓库")
                }

                Link(destination: URL(string: "https://xhslink.cn/o/4hskdSSr5RL")!) {
                    logo("XiaohongshuLogo", size: 20)
                }
                .help("调色师手册 · 小红书")
                .accessibilityLabel("打开调色师手册的小红书主页")
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppColor.secondaryText)
        }
        .font(.system(size: 12, weight: .medium))
    }

    private func logo(_ name: String, size: CGFloat) -> some View {
        Image(name)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
    }
}
