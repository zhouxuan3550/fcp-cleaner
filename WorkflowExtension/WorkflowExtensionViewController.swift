import AppKit
import SwiftUI

@MainActor
final class WorkflowExtensionModel: ObservableObject {
    @Published private(set) var libraryName = "未检测到打开的项目"
    @Published private(set) var libraryURL: URL?
    @Published private(set) var hostVersion = "Final Cut Pro"

    func refresh() {
        guard let host = WorkflowHostBridge.hostObject() else {
            libraryName = "无法连接 Final Cut Pro"
            libraryURL = nil
            return
        }

        if let name = WorkflowHostBridge.stringValue(host, selector: "name"),
           let version = WorkflowHostBridge.stringValue(host, selector: "versionString") {
            hostVersion = "\(name) \(version)"
        }

        guard let library = WorkflowHostBridge.activeLibrary(from: host) else {
            libraryName = "时间线中没有打开的项目"
            libraryURL = nil
            return
        }
        libraryName = WorkflowHostBridge.stringValue(library, selector: "name") ?? "当前资源库"
        libraryURL = WorkflowHostBridge.urlValue(library, selector: "url")
    }
}

/// 通过 Apple Workflow Extension SDK 的 Objective-C 接口读取当前资源库。
enum WorkflowHostBridge {
    static func hostObject() -> NSObject? {
        ProExtensionHostSingleton() as? NSObject
    }

    static func activeLibrary(from host: NSObject) -> NSObject? {
        guard let timeline = objectValue(host, selector: "timeline"),
              var current = objectValue(timeline, selector: "activeSequence") else {
            return nil
        }

        // sequence → project → event → library。限制层数防止异常代理形成循环。
        for _ in 0..<6 {
            if let url = urlValue(current, selector: "url"),
               url.pathExtension.lowercased() == "fcpbundle" {
                return current
            }
            guard let container = objectValue(current, selector: "container") else { return nil }
            current = container
        }
        return nil
    }

    static func stringValue(_ object: NSObject, selector: String) -> String? {
        objectValue(object, selector: selector) as? String
    }

    static func urlValue(_ object: NSObject, selector: String) -> URL? {
        objectValue(object, selector: selector) as? URL
    }

    private static func objectValue(_ object: NSObject, selector: String) -> NSObject? {
        let action = NSSelectorFromString(selector)
        guard object.responds(to: action) else { return nil }
        return object.perform(action)?.takeUnretainedValue() as? NSObject
    }
}

@objc(WorkflowExtensionViewController)
final class WorkflowExtensionViewController: NSViewController {
    private let model = WorkflowExtensionModel()

    override func loadView() {
        view = NSHostingView(rootView: WorkflowExtensionView(model: model) { [weak self] in
            self?.openContainingApp()
        })
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        model.refresh()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
    }

    private func openContainingApp() {
        var components = URLComponents()
        components.scheme = "fcp-cleaner"
        components.host = model.libraryURL == nil ? "open" : "library"
        if let libraryURL = model.libraryURL {
            components.queryItems = [URLQueryItem(name: "path", value: libraryURL.path)]
        }
        guard let url = components.url else { return }
        extensionContext?.open(url)
    }
}

private struct WorkflowExtensionView: View {
    @ObservedObject var model: WorkflowExtensionModel
    let openApp: () -> Void

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.08, green: 0.08, blue: 0.10), Color(red: 0.13, green: 0.10, blue: 0.18)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(Color(red: 0.50, green: 0.27, blue: 0.94))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("FCP Cleaner")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                        Text(model.hostVersion)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        model.refresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .help("刷新当前资源库")
                }

                VStack(alignment: .leading, spacing: 7) {
                    Text("当前资源库")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(model.libraryName)
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                    if let url = model.libraryURL {
                        Text(url.path)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                Button(action: openApp) {
                    Label("在 FCP Cleaner 中打开", systemImage: "arrow.up.forward.app.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.50, green: 0.27, blue: 0.94))
                .disabled(model.libraryURL == nil)
            }
            .padding(20)
        }
        .preferredColorScheme(.dark)
        .frame(minWidth: 360, minHeight: 280)
    }
}
