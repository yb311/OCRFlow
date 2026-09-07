import Combine
import Sparkle
import SwiftUI

/// The app's one Sparkle updater, owned by `OCRFlowApp`.
///
/// `SPUStandardUpdaterController` schedules its first background check as soon
/// as it is constructed, so it is built once at launch rather than when a menu
/// opens. The two published properties exist only so SwiftUI can observe state
/// that Sparkle exposes through KVO: `canCheckForUpdates` goes false while a
/// check is already running, which is what greys out the menu item.
final class UpdaterController: ObservableObject {
    @Published private(set) var canCheckForUpdates = false

    @Published var automaticallyChecksForUpdates: Bool {
        didSet { updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates }
    }

    private let controller: SPUStandardUpdaterController
    private var cancellables: Set<AnyCancellable> = []

    private var updater: SPUUpdater { controller.updater }

    init() {
        controller = SPUStandardUpdaterController(startingUpdater: true,
                                                  updaterDelegate: nil,
                                                  userDriverDelegate: nil)
        automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates

        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.canCheckForUpdates = $0 }
            .store(in: &cancellables)
    }

    func checkForUpdates() {
        updater.checkForUpdates()
    }
}
