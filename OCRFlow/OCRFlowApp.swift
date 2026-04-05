import SwiftUI

@main
struct OCRFlowApp: App {
    @StateObject private var viewModel = OCRViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 1100, height: 700)
        .commands {
            // File menu additions
            CommandGroup(after: .newItem) {
                Button("打开图片…") {
                    viewModel.openFilePicker()
                }
                .keyboardShortcut("o", modifiers: .command)

                Divider()

                Button("开始识别") {
                    viewModel.startProcessing()
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(viewModel.items.isEmpty)

                Button("导出结果…") {
                    viewModel.exportResults()
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(viewModel.completedCount == 0)
            }

            // Remove default new window command
            CommandGroup(replacing: .newItem) {
                Button("打开图片…") {
                    viewModel.openFilePicker()
                }
                .keyboardShortcut("o", modifiers: .command)
            }
        }
    }
}
