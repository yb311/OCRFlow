import SwiftUI

/// Light, dark, or whatever the system is set to.
///
/// Applied through `NSApp.appearance` rather than `preferredColorScheme`: the
/// latter, once set, does not reliably let go again on macOS, so "跟随系统"
/// would stick on whichever scheme was picked last.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    static let storageKey = "appearance"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return String(localized: "System")
        case .light:  return String(localized: "Light")
        case .dark:   return String(localized: "Dark")
        }
    }

    @MainActor
    func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light:  NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:   NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

/// Starts the app, or — when the process is only hosting the unit tests — an
/// app with no windows, so a test run neither restores nor rewrites the
/// user's queue, settings and folder watch.
@main
enum AppLauncher {
    static func main() {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            TestHostApp.main()
        } else {
            OCRFlowApp.main()
        }
    }
}

private struct TestHostApp: App {
    var body: some Scene {
        Settings { EmptyView() }
    }
}

/// Takes the files macOS hands the app — dropped on its Dock icon, or opened
/// with it from Finder — and adds them to the list.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set once the list exists; files that arrive before then wait.
    var open: (([URL]) -> Void)? {
        didSet {
            guard let open, !waiting.isEmpty else { return }
            open(waiting)
            waiting = []
        }
    }
    private var waiting: [URL] = []

    func application(_ application: NSApplication, open urls: [URL]) {
        if let open { open(urls) } else { waiting += urls }
    }
}

struct OCRFlowApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @StateObject private var viewModel = OCRViewModel()
    @StateObject private var updater = UpdaterController()
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openURL) private var openURL

    init() {
        #if DEBUG
        PipelineBenchmark.runIfRequested()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
                .onAppear {
                    appDelegate.open = { [weak viewModel] urls in viewModel?.addImages(urls: urls) }
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 1100, height: 700)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    updater.checkForUpdates()
                }
                .disabled(!updater.canCheckForUpdates)
            }

            // Replaces the standard New group, which this app has no use for.
            CommandGroup(replacing: .newItem) {
                Button("Open Images…") {
                    viewModel.openFilePicker()
                }
                .keyboardShortcut("o", modifiers: .command)

                Button("Capture Screenshot") {
                    viewModel.captureScreenshot()
                }
                .keyboardShortcut("2", modifiers: [.command, .shift])
            }

            CommandGroup(before: .sidebar) {
                Button("Workspace") { viewModel.mode = .workspace }
                    .keyboardShortcut("1", modifiers: .command)
                Button("Review") { viewModel.startReview() }
                    .keyboardShortcut("2", modifiers: .command)
                Divider()
            }

            CommandGroup(after: .newItem) {
                Divider()

                Button("Start Recognition") {
                    viewModel.startProcessing()
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(viewModel.actionableCount == 0)

                Button("Export All Results…") {
                    viewModel.exportResults()
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(viewModel.exportableCount == 0)

                Button("Export Selected Results…") {
                    viewModel.exportSelectedItems()
                }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(viewModel.exportableSelectedCount == 0)
            }

            // The app ships no help book, so the standard item would only say
            // that help is unavailable.
            CommandGroup(replacing: .help) {
                Button("OCRFlow Help") { openURL(AppLinks.help) }
                Button("Privacy") { openURL(AppLinks.privacy) }
                Divider()
                Button("Report a Problem…") { openWindow(id: ReportProblemView.windowID) }
            }
        }

        // A real settings window: ⌘, and the app menu's 设置… item come for
        // free, and it stays open beside the main window, so detection
        // thresholds can be tuned while the result is visible.
        Settings {
            SettingsView()
                .environmentObject(viewModel)
                .environmentObject(updater)
        }

        Window("History", id: HistoryView.windowID) {
            HistoryView()
                .environmentObject(viewModel)
        }
        .defaultSize(width: 900, height: 600)
        .keyboardShortcut("y", modifiers: .command)

        Window("Report a Problem", id: ReportProblemView.windowID) {
            ReportProblemView()
                .environmentObject(viewModel)
        }
        .defaultSize(width: 620, height: 560)

        // Its own window rather than a sheet on top of the settings sheet:
        // downloading gigabytes of models is a task in its own right.
        Window("Model Manager", id: ModelManagerView.windowID) {
            ModelManagerView(downloader: viewModel.modelDownloader)
        }
        .defaultSize(width: 620, height: 580)
    }
}

/// Pages on the project site the app points to.
enum AppLinks {
    static let help = URL(string: "https://github.com/yb311/OCRFlow#readme")!
    static let privacy = URL(string: "https://github.com/yb311/OCRFlow/blob/main/docs/PRIVACY.md")!
}
