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
            // Replaces the standard New group, which this app has no use for.
            CommandGroup(replacing: .newItem) {
                Button("打开图片…") {
                    viewModel.openFilePicker()
                }
                .keyboardShortcut("o", modifiers: .command)
            }

            CommandGroup(after: .newItem) {
                Divider()

                Button("开始识别") {
                    viewModel.startProcessing()
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(viewModel.actionableCount == 0)

                Button("导出全部结果…") {
                    viewModel.exportResults()
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(viewModel.exportableCount == 0)

                Button("导出选中结果…") {
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
        }

        // Its own window rather than a sheet on top of the settings sheet:
        // downloading gigabytes of models is a task in its own right.
        Window("模型管理", id: ModelManagerView.windowID) {
            ModelManagerView(downloader: viewModel.modelDownloader)
        }
        .defaultSize(width: 620, height: 580)
    }
}
