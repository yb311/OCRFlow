import Sparkle
import SwiftUI

/// The app's one Sparkle updater, owned by `OCRFlowApp`.
///
/// `SPUStandardUpdaterController` schedules its first background check as soon
/// as it is constructed, so it is built once at launch rather than when a menu
/// opens. Sparkle exposes its state through KVO; `canCheckForUpdates` is
/// mirrored here so SwiftUI can observe it — it goes false while a check is
/// already running, which is what greys out the menu item.
@MainActor
@Observable
final class UpdaterController {
    private(set) var canCheckForUpdates = false

    var automaticallyChecksForUpdates: Bool {
        didSet { updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates }
    }

    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private var observation: NSKeyValueObservation?

    private var updater: SPUUpdater { controller.updater }

    init() {
        controller = SPUStandardUpdaterController(startingUpdater: true,
                                                  updaterDelegate: nil,
                                                  userDriverDelegate: nil)
        automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates

        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            // Sparkle changes it on the main thread.
            MainActor.assumeIsolated { self?.canCheckForUpdates = updater.canCheckForUpdates }
        }
    }

    func checkForUpdates() {
        updater.checkForUpdates()
    }
}
