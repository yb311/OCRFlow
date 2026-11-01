import SwiftUI

/// What the icon at the top of the screen offers: the app's main actions,
/// reachable from any app, and the way back in when the Dock icon is hidden.
struct MenuBarMenu: View {
    @Environment(OCRViewModel.self) private var vm
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        @Bindable var vm = vm
        Button("Capture Screenshot") { vm.captureScreenshot() }
            // Shown only while the global shortcut is actually in place.
            .keyboardShortcut(vm.globalCaptureShortcut && !vm.captureShortcutTaken
                              ? KeyboardShortcut("2", modifiers: [.command, .shift, .option]) : nil)
        Button("Queue Screenshots") { vm.queueScreenshots() }

        Divider()
        Button("Record Actions…") { vm.recordMacro() }
        if !vm.macros.macros.isEmpty {
            Menu("Run Recorded Actions") {
                ForEach(vm.macros.macros) { macro in
                    Button(macro.name) { vm.runMacro(id: macro.id) }
                        .disabled(macro.steps.isEmpty)
                }
            }
            .disabled(vm.isCapturing)
        }
        Button("Manage Recorded Actions…") {
            NSApp.activate()
            openWindow(id: MacroEditorView.windowID)
        }

        Divider()
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
