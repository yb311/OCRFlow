import SwiftUI

struct ContentView: View {
    @EnvironmentObject var vm: OCRViewModel
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } detail: {
            DetailView()
        }
        .toolbar {
            toolbarContent
        }
        // The sidebar's minimum (220) plus the detail view's two panes
        // (280 each) already need 780, so a smaller window could only be had by
        // squeezing panes below the widths they ask for.
        .frame(minWidth: 800, minHeight: 520)
        // Global drag-and-drop on the whole window
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            DropHelper.handle(providers: providers, vm: vm)
        }
    }

    /// Names the file when there is one, and counts them when there are more:
    /// the menu item itself says what it is about to write.
    private var exportSelectionTitle: String {
        let exportable = vm.selectedItems.filter(\.isExportable)
        switch exportable.count {
        case 0:  return "导出选中结果…"
        case 1:  return "导出「\(exportable[0].fileName)」…"
        default: return "导出选中的 \(exportable.count) 个文件…"
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Center: progress
        ToolbarItem(placement: .principal) {
            // One line, fixed widths. The pieces used to be sized by their
            // contents, so a long file name pushed the percentage into
            // whatever was beside it.
            if vm.isProcessing {
                let running = vm.items.filter { $0.status == .processing }
                HStack(spacing: 8) {
                    ProgressView(value: vm.totalProgress)
                        .progressViewStyle(.linear)
                        .tint(.accentColor)
                        .frame(width: 120)
                    Text("\(Int((vm.totalProgress * 100).rounded()))%")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .leading)
                    if let current = running.first {
                        Text(running.count > 1
                             ? "\(current.fileName) 等 \(running.count) 个"
                             : current.fileName)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(width: 160, alignment: .leading)
                    }
                }
                .fixedSize()
            } else if !vm.items.isEmpty && vm.totalProgress > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                    Text("\(vm.completedCount)/\(vm.items.count) 已完成")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .fixedSize()
            }
        }

        // Right group
        ToolbarItemGroup(placement: .primaryAction) {
            if vm.isProcessing {
                Button {
                    vm.stopProcessing()
                } label: {
                    Label(vm.isStopping ? "停止中…" : "停止", systemImage: "stop.circle")
                }
                .disabled(vm.isStopping)
                .help(vm.isStopping ? "正在等待当前文件停止" : "停止识别，未完成的文件标记为「已取消」")
            } else {
                Button {
                    vm.startProcessing()
                } label: {
                    Label("开始识别", systemImage: "play.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(vm.actionableCount == 0)
                .help(vm.actionableCount > 0 ? "识别 \(vm.actionableCount) 个文件" : "没有待识别的文件")
            }

            // One export control, and it names what it would write. Two
            // identical-looking buttons — one in the toolbar, one under the
            // list — left no way to tell "this file" from "everything".
            Menu {
                Button(exportSelectionTitle) { vm.exportSelectedItems() }
                    .disabled(vm.exportableSelectedCount == 0)
                Button("导出全部结果（\(vm.exportableCount) 个文件）…") { vm.exportResults() }
                    .disabled(vm.exportableCount == 0)
            } label: {
                Label("导出", systemImage: "square.and.arrow.up")
            }
            .disabled(vm.exportableCount == 0)
            .help("导出识别结果为文本或 Markdown 文件")

            // Opens the same window as ⌘, and the app menu's 设置… item,
            // rather than a second, parallel way of showing the settings.
            SettingsLink {
                Label("设置", systemImage: "gearshape")
            }
            .help("设置（⌘,）")
        }
    }
}
