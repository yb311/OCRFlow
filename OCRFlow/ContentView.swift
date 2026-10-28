import SwiftUI

struct ContentView: View {
    @EnvironmentObject var vm: OCRViewModel
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var offersCrashReport = false
    @AppStorage(AppAppearance.storageKey) private var appearance: AppAppearance = .system
    @Environment(\.openWindow) private var openWindow

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
        .alert("OCRFlow quit unexpectedly last time", isPresented: $offersCrashReport) {
            Button("Report…") { openWindow(id: ReportProblemView.windowID) }
            Button("Not Now", role: .cancel) { vm.crashLogFromLastSession = nil }
        } message: {
            Text("A report with the crash log helps fix it. You can review everything in it before sending.")
        }
        .onAppear {
            appearance.apply()
            offersCrashReport = vm.crashLogFromLastSession != nil
        }
        .onChange(of: appearance) { _, value in value.apply() }
    }

    /// Names the file when there is one, and counts them when there are more:
    /// the menu item itself says what it is about to write.
    private var exportSelectionTitle: String {
        let exportable = vm.selectedItems.filter(\.isExportable)
        switch exportable.count {
        case 0:  return String(localized: "Export Selected Results…")
        case 1:  return String(localized: "Export “\(exportable[0].fileName)”…")
        default: return String(localized: "Export \(exportable.count) Selected Files…")
        }
    }

    /// What the segmented control says for review: how many items are left,
    /// which is the number that decides whether it is worth switching.
    private func modeTitle(_ mode: WorkspaceMode, pending: Int) -> String {
        mode == .review && pending > 0 ? String(localized: "Review \(pending)") : mode.label
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Center: the two things the window is for. Reading results and
        // working through what needs checking are different jobs, with
        // different lists down the side.
        ToolbarItem(placement: .principal) {
            let pending = vm.reviewEntries.count
            Picker("Mode", selection: $vm.mode) {
                ForEach(WorkspaceMode.allCases) { mode in
                    Text(modeTitle(mode, pending: pending)).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Workspace (⌘1) · Review (⌘2)")
        }

        // Right group
        ToolbarItemGroup(placement: .primaryAction) {
            RunProgressView()

            if vm.isProcessing {
                Button {
                    vm.stopProcessing()
                } label: {
                    Label(vm.isStopping ? "Stopping…" : "Stop", systemImage: "stop.circle")
                }
                .disabled(vm.isStopping)
                .help(vm.isStopping ? "Waiting for the current files to stop" : "Stop recognition. Unfinished files are marked “Cancelled”")
            } else {
                Button {
                    vm.startProcessing()
                } label: {
                    Label("Start Recognition", systemImage: "play.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(vm.actionableCount == 0)
                .help(vm.actionableCount > 0 ? "Recognize \(vm.actionableCount) files" : "No files to recognize")
            }

            // One export control, and it names what it would write. Two
            // identical-looking buttons — one in the toolbar, one under the
            // list — left no way to tell "this file" from "everything".
            Menu {
                Button(exportSelectionTitle) { vm.exportSelectedItems() }
                    .disabled(vm.exportableSelectedCount == 0)
                Button("Export All Results (\(vm.exportableCount) Files)…") { vm.exportResults() }
                    .disabled(vm.exportableCount == 0)
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .disabled(vm.exportableCount == 0)
            .help("Export results as text or Markdown files")

            // Opens the same window as ⌘, and the app menu's 设置… item,
            // rather than a second, parallel way of showing the settings.
            SettingsLink {
                Label("Settings", systemImage: "gearshape")
            }
            .help("Settings (⌘,)")
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
            // A long document is most of a run on its own; its pages say how
            // far through it is, which the file count cannot.
            let document = running.first { $0.pageCount > 1 }
            let names = running.map { item in
                item.pageCount > 1
                    ? String(localized: "\(item.fileName) (\(item.pagesDone)/\(item.pageCount) pages read)")
                    : item.fileName
            }
            HStack(spacing: 6) {
                ProcessingRingView(progress: vm.totalProgress)
                    .frame(width: 14, height: 14)
                // Fixed widths, so the count ticking over does not nudge the
                // buttons beside it.
                if let started = vm.runStartedAt {
                    TimelineView(.periodic(from: started, by: 1)) { context in
                        let seconds = Int(context.date.timeIntervalSince(started))
                        let files = "\(vm.completedCount + vm.failedCount)/\(vm.items.count)"
                        let time = Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond))
                        Text(document.map { String(localized: "\($0.pagesDone)/\($0.pageCount) pages · \(files) · \(time)") }
                             ?? "\(files) · \(time)")
                    }
                }
            }
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .fixedSize()
            .help(running.isEmpty ? String(localized: "Recognizing \(vm.totalProgress.percentText)")
                  : String(localized: "Recognizing \(vm.totalProgress.percentText): \(names.formatted(.list(type: .and)))"))
        } else if !vm.items.isEmpty && vm.totalProgress > 0 {
            Label("\(vm.completedCount)/\(vm.items.count)", systemImage: "checkmark.circle.fill")
                .labelStyle(.titleAndIcon)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .fixedSize()
                .help("\(vm.completedCount) files done")
        }
    }
}
