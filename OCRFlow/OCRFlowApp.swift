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

@main
struct OCRFlowApp: App {
    @StateObject private var viewModel = OCRViewModel()
    @StateObject private var updater = UpdaterController()

    init() {
        #if DEBUG
        PipelineBenchmark.runIfRequested()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
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
        }

        // A real settings window: ⌘, and the app menu's 设置… item come for
        // free, and it stays open beside the main window, so detection
        // thresholds can be tuned while the result is visible.
        Settings {
            SettingsView()
                .environmentObject(viewModel)
                .environmentObject(updater)
        }

        // Its own window rather than a sheet on top of the settings sheet:
        // downloading gigabytes of models is a task in its own right.
        Window("Model Manager", id: ModelManagerView.windowID) {
            ModelManagerView(downloader: viewModel.modelDownloader)
        }
        .defaultSize(width: 620, height: 580)
    }
}
