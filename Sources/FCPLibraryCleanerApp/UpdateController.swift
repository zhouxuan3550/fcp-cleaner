import Foundation
import Sparkle

@MainActor
final class UpdateController {
    static let shared = UpdateController()

    private var updaterController: SPUStandardUpdaterController?

    var isConfigured: Bool {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let url = URL(string: value) else { return false }
        return url.scheme == "https"
    }

    private init() {}

    func startIfConfigured() {
        guard isConfigured, updaterController == nil else { return }
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    func checkForUpdates() {
        startIfConfigured()
        updaterController?.checkForUpdates(nil)
    }
}
