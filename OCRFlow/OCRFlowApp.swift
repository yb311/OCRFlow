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
    /// Brings the main window back. Set by the app.
    var showMainWindow: (() -> Void)?
    /// Settles what has to be settled before the process goes. Set by the app.
    var willTerminate: (() -> Void)?

    func application(_ application: NSApplication, open urls: [URL]) {
        if let open { open(urls) } else { waiting += urls }
    }

    /// The Dock icon clicked, or the app opened again from Finder. AppKit
    /// only opens a window when none is visible, and the floating button and
    /// the menu bar icon count as visible ones, so it is done here.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        guard let showMainWindow else { return true }
        showMainWindow()
        return false
    }

    /// Settled before anything is on screen, so the Dock icon does not
    /// flash up at launch when no window opens.
    func applicationWillFinishLaunching(_ notification: Notification) {
        DockIcon.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        willTerminate?()
    }
}

struct OCRFlowApp: App {
    /// SwiftUI names each of the group's windows after this.
    static let mainWindowID = "main"
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var viewModel = OCRViewModel()
    @State private var updater = UpdaterController()
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openURL) private var openURL

    init() {
        #if DEBUG
        PipelineBenchmark.runIfRequested()
        #endif
    }

    var body: some Scene {
        WindowGroup(id: Self.mainWindowID) {
            ContentView()
                .environment(viewModel)
                .onAppear(perform: connect)
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

                Button("Queue Screenshots") {
                    viewModel.queueScreenshots()
                }

                Divider()

                Button("Record Actions…") {
                    viewModel.recordMacro()
                }

                Button("Recorded Actions…") {
                    openWindow(id: MacroEditorView.windowID)
                }
            }

            CommandGroup(after: .textEditing) {
                Button("Find in Files") {
                    viewModel.mode = .workspace
                    viewModel.searchFocusRequest += 1
                }
                .keyboardShortcut("f", modifiers: .command)
                Button("Deselect All") { viewModel.selectedIDs = [] }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                    .disabled(viewModel.selectedIDs.isEmpty)
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

                Button("Export Original Files…") {
                    viewModel.exportOriginals(ids: viewModel.selectedIDs)
                }
                .disabled(viewModel.selectedIDs.isEmpty)
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
            SettingsView(vm: viewModel, updater: updater)
                .environment(viewModel)
        }

        // Always there: screenshots live in the menu bar, and with no window
        // open it is the way back in.
        MenuBarExtra {
            MenuBarMenu()
                .environment(viewModel)
        } label: {
            Image(systemName: "text.viewfinder")
                // In the menu bar the app starts without a window, and this is
                // the only view that appears.
                .onAppear(perform: connect)
        }

        Window("History", id: HistoryView.windowID) {
            HistoryView()
                .environment(viewModel)
        }
        .defaultSize(width: 900, height: 600)
        .keyboardShortcut("y", modifiers: .command)

        Window("Recorded Actions", id: MacroEditorView.windowID) {
            MacroEditorView()
                .environment(viewModel)
        }
        .defaultSize(width: 780, height: 600)

        Window("Report a Problem", id: ReportProblemView.windowID) {
            ReportProblemView()
                .environment(viewModel)
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

extension OCRFlowApp {
    /// Hands the parts of the app that live outside SwiftUI what they need
    /// to reach the list and the main window.
    private func connect() {
        appDelegate.open = { [weak viewModel] urls in viewModel?.addImages(urls: urls) }
        let show = { [openWindow] in Self.showMainWindow(openWindow) }
        viewModel.showMainWindow = show
        viewModel.showMacros = { [openWindow] in
            NSApp.activate()
            openWindow(id: MacroEditorView.windowID)
        }
        appDelegate.showMainWindow = show
        appDelegate.willTerminate = { [weak viewModel] in viewModel?.prepareForTermination() }
    }

    /// Brings the main window to the front, or opens one when it was closed.
    @MainActor
    static func showMainWindow(_ openWindow: OpenWindowAction) {
        NSApp.activate()
        let existing = NSApp.windows.first { window in
            window.identifier?.rawValue.hasPrefix(mainWindowID) == true
                && (window.isVisible || window.isMiniaturized)
        }
        if let existing {
            if existing.isMiniaturized { existing.deminiaturize(nil) }
            existing.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: mainWindowID)
        }
    }
}

/// Pages on the project site the app points to.
enum AppLinks {
    static let help = URL(string: "https://github.com/yb311/OCRFlow#readme")!
    static let privacy = URL(string: "https://github.com/yb311/OCRFlow/blob/main/docs/PRIVACY.md")!
}
