import AppKit
import Foundation

@MainActor
final class FinderServiceProvider: NSObject {
    @objc(scanLibraries:userData:error:)
    func scanLibraries(
        _ pasteboard: NSPasteboard,
        userData: String,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        let urls = (pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []).filter { $0.pathExtension.lowercased() == "fcpbundle" }
        guard !urls.isEmpty else {
            error.pointee = "请选择 .fcpbundle 资源库" as NSString
            return
        }
        LibraryStore.shared.add(libraryURLs: urls)
        LibraryStore.shared.showMainWindow()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let serviceProvider = FinderServiceProvider()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.servicesProvider = serviceProvider
        NSUpdateDynamicServices()
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let urls = filenames.map(URL.init(fileURLWithPath:)).filter { $0.pathExtension.lowercased() == "fcpbundle" }
        LibraryStore.shared.add(libraryURLs: urls)
        LibraryStore.shared.showMainWindow()
        sender.reply(toOpenOrPrint: .success)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        let libraryURLs = urls.compactMap(Self.libraryURL(from:))
        if !libraryURLs.isEmpty {
            LibraryStore.shared.add(libraryURLs: libraryURLs)
        }
        LibraryStore.shared.showMainWindow()
    }

    nonisolated static func libraryURL(from callbackURL: URL) -> URL? {
        guard callbackURL.scheme == "fcp-cleaner",
              callbackURL.host == "library",
              let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
              let path = components.queryItems?.first(where: { $0.name == "path" })?.value else {
            return nil
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        return url.pathExtension.lowercased() == "fcpbundle" ? url : nil
    }
}
