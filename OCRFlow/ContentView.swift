import SwiftUI

struct ContentView: View {
    @EnvironmentObject var vm: OCRViewModel
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @AppStorage(AppAppearance.storageKey) private var appearance: AppAppearance = .system

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            Group {
                switch vm.mode {
                case .workspace: SidebarView()
                case .review:    ReviewQueueView()
                }
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 270, max: 360)
        } detail: {
            switch vm.mode {
            case .workspace: DetailView()
            case .review:    ReviewDetailView()
            }
        }
        .toolbar {
            toolbarContent
        }
        // The sidebar's minimum (240) plus the detail view's two panes
        // (280 each) already need 800, so a smaller window could only be had by
        // squeezing panes below the widths they ask for.
        .frame(minWidth: 820, minHeight: 520)
        // Global drag-and-drop on the whole window
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            DropHelper.handle(providers: providers, vm: vm)
        }
        .onAppear { appearance.apply() }
        .onChange(of: appearance) { _, value in value.apply() }
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

    /// What the segmented control says for review: how many items are left,
    /// which is the number that decides whether it is worth switching.
    private func modeTitle(_ mode: WorkspaceMode, pending: Int) -> String {
        mode == .review && pending > 0 ? "复核 \(pending)" : mode.label
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Center: the two things the window is for. Reading results and
        // working through what needs checking are different jobs, with
        // different lists down the side.
        ToolbarItem(placement: .principal) {
            let pending = vm.reviewEntries.count
            Picker("模式", selection: $vm.mode) {
                ForEach(WorkspaceMode.allCases) { mode in
                    Text(modeTitle(mode, pending: pending)).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("工作台（⌘1）· 复核（⌘2）")
        }

        // Right group
        ToolbarItemGroup(placement: .primaryAction) {
            RunProgressView()

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

/// The run, small enough to sit beside the button that starts it: a ring, the
/// count, and the clock. Which files are being read is one hover away.
private struct RunProgressView: View {
    @EnvironmentObject var vm: OCRViewModel

    var body: some View {
        if vm.isProcessing {
            let running = vm.items.filter { $0.status == .processing }
            HStack(spacing: 6) {
                ProcessingRingView(progress: vm.totalProgress)
                    .frame(width: 14, height: 14)
                // Fixed widths, so the count ticking over does not nudge the
                // buttons beside it.
                if let started = vm.runStartedAt {
                    TimelineView(.periodic(from: started, by: 1)) { context in
                        let seconds = Int(context.date.timeIntervalSince(started))
                        Text("\(vm.completedCount + vm.failedCount)/\(vm.items.count) · "
                             + String(format: "%d:%02d", seconds / 60, seconds % 60))
                    }
                }
            }
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .fixedSize()
            .help(running.isEmpty ? "识别中 \(Int((vm.totalProgress * 100).rounded()))%"
                  : "识别中 \(Int((vm.totalProgress * 100).rounded()))%：" + running.map(\.fileName).joined(separator: "、"))
        } else if !vm.items.isEmpty && vm.totalProgress > 0 {
            Label("\(vm.completedCount)/\(vm.items.count)", systemImage: "checkmark.circle.fill")
                .labelStyle(.titleAndIcon)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .fixedSize()
                .help("\(vm.completedCount) 个文件已完成")
        }
    }
}
