import SwiftUI

/// What the icon at the top of the screen offers: the app's main actions,
/// reachable from any app, and the way back in when the Dock icon is hidden.
struct MenuBarMenu: View {
    @EnvironmentObject private var vm: OCRViewModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("Capture Screenshot") { vm.captureScreenshot() }
            // Shown only while the global shortcut is actually in place.
            .keyboardShortcut(vm.globalCaptureShortcut && !vm.captureShortcutTaken
                              ? KeyboardShortcut("2", modifiers: [.command, .shift, .option]) : nil)
        Button("Capture Same Area Again") { vm.captureSameAreaAgain() }
            .keyboardShortcut(vm.globalCaptureShortcut && !vm.captureAgainShortcutTaken
                              ? KeyboardShortcut("3", modifiers: [.command, .shift, .option]) : nil)
            .disabled(vm.lastCaptureTarget == nil)
        Button("Capture Page by Page…") { vm.capturePageByPage() }
        Button("Open Images…") {
            OCRFlowApp.showMainWindow(openWindow)
            vm.openFilePicker()
        }

        if vm.isProcessing {
            Divider()
            Text("Recognizing… \(vm.totalProgress.formatted(.percent.precision(.fractionLength(0))))")
        }

        Divider()
        Toggle("Floating Capture Button", isOn: $vm.showFloatingButton)

        Divider()
        Button("Open OCRFlow") { OCRFlowApp.showMainWindow(openWindow) }
        Button("Settings…") {
            // With the Dock icon hidden the app is not in front, and the
            // window would open behind whatever is.
            NSApp.activate()
            openSettings()
        }
        .keyboardShortcut(",")

        Divider()
        Button("Quit OCRFlow") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
