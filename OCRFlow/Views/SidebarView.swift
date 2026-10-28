import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var vm: OCRViewModel
    @State private var isEmptyStateTargeted = false
    @State private var showClearAllConfirm = false
    @State private var filter: StatusFilter = .all
    /// Searches file names and everything recognised in them. The results are
    /// kept between launches, so this searches every batch still listed. Held
    /// by the view model, so the document pane can turn to what was found.
    private var query: String { vm.searchQuery }

    /// Narrows the list to one status. In a batch of a few hundred files the
    /// failures are the ones worth looking at, and scrolling for them is the
    /// main thing the list makes hard.
    fileprivate enum StatusFilter {
        case all, completed, review, failed, cancelled

        var label: String {
            switch self {
            case .all:       return String(localized: "All")
            case .completed: return String(localized: "Completed")
            case .review:    return String(localized: "Needs Review")
            case .failed:    return String(localized: "Failed")
            case .cancelled: return String(localized: "Cancelled")
            }
        }
    }

    private var visibleItems: [ImageItem] {
        let byStatus: [ImageItem]
        switch filter {
        case .all:       byStatus = vm.items
        case .completed: byStatus = vm.items.filter { $0.status == .completed }
        case .review:    byStatus = vm.items.filter(\.needsReview)
        case .failed:    byStatus = vm.items.filter { $0.status == .failed }
        case .cancelled: byStatus = vm.items.filter { $0.status == .cancelled }
        }
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return byStatus }
        return byStatus.filter {
            $0.relativePath.localizedCaseInsensitiveContains(needle)
                || $0.ocrText.localizedCaseInsensitiveContains(needle)
        }
    }

    // Defer writes back to @Published to avoid "publishing during view update"
    private var selectionBinding: Binding<Set<UUID>> {
        Binding(
            get: { vm.selectedIDs },
            set: { newVal in Task { @MainActor in vm.selectedIDs = newVal } }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            // List or empty state
            if vm.items.isEmpty {
                emptyState
            } else {
                List(visibleItems, selection: selectionBinding) { item in
                    SidebarRowView(item: item, query: query)
                        .tag(item.id)
                        .contextMenu {
                            // If right-clicked item is not in selection, switch to it alone
                            let targetIDs: Set<UUID> = vm.selectedIDs.contains(item.id)
                                ? vm.selectedIDs : [item.id]
                            let targetItems = vm.items.filter { targetIDs.contains($0.id) }
                            let allExportable = targetItems.allSatisfy(\.isExportable)
                            let allFailed    = targetItems.allSatisfy { $0.status == .failed }
                            let count = targetIDs.count

                            // Anything that has finished can be run again —
                            // re-reading a page with different settings was
                            // previously only reachable by removing and
                            // re-adding the file.
                            let anyProcessing = targetItems.contains { $0.status == .processing }
                            let anyFinished = targetItems.contains {
                                $0.status == .completed || $0.status == .failed
                                    || $0.status == .cancelled
                            }
                            // A document stopped part-way carries on from where it
                            // got to; 重新识别 below starts it over.
                            let resumable = targetItems.filter { $0.resume != nil && $0.status != .processing }
                            if !resumable.isEmpty {
                                Button(resumable.count > 1 ? String(localized: "Resume \(resumable.count) Files")
                                                           : String(localized: "Resume")) {
                                    vm.resumeItems(ids: Set(resumable.map(\.id)))
                                }
                                .disabled(vm.isProcessing)
                            }
                            if anyFinished && !anyProcessing {
                                let verb = allFailed ? String(localized: "Retry") : String(localized: "Recognize Again")
                                Button(count > 1 ? String(localized: "\(verb) \(count) Files") : verb) {
                                    vm.retryItems(ids: targetIDs)
                                }
                            }
                            if count == 1, vm.canReadWithVL(item) {
                                Button("Recognize This File Again with PaddleOCR-VL") { vm.readWithVL(id: item.id) }
                                    .disabled(vm.isProcessing)
                            }
                            if allExportable {
                                Button(count > 1 ? "Copy All Text" : "Copy Text") {
                                    if count > 1 { vm.copySelectedText() }
                                    else { vm.copyText(for: item.id) }
                                }
                                Button(count > 1 ? "Export Selected Results…" : "Export This File's Results…") {
                                    vm.exportItems(ids: targetIDs)
                                }
                            }
                            Divider()
                            if count == 1 {
                                Button("Show in Finder") {
                                    NSWorkspace.shared.selectFile(item.url.path, inFileViewerRootedAtPath: "")
                                }
                                Divider()
                            }
                            Button(count > 1 ? "Remove \(count) Files" : "Remove", role: .destructive) {
                                vm.removeItems(ids: targetIDs)
                            }
                        }
                }
                .listStyle(.sidebar)
                .onDeleteCommand { vm.removeSelectedItems() }
                // Shown over the list rather than in its place: the search
                // field lives on the list, and swapping the list out the
                // moment nothing matched took the field away mid-word.
                .overlay {
                    if visibleItems.isEmpty { filteredEmptyState }
                }
            }

            Divider()
            bottomToolbar
        }
        .searchable(text: $vm.searchQuery, placement: .sidebar, prompt: "Search names and text")
        .onChange(of: filter) { _, _ in
            // Keep the detail pane pointing at something the list still shows.
            let visible = Set(visibleItems.map(\.id))
            let survivors = vm.selectedIDs.intersection(visible)
            let replacement = survivors.isEmpty
                ? Set(visibleItems.first.map { [$0.id] } ?? [])
                : survivors
            Task { @MainActor in vm.selectedIDs = replacement }
        }
    }

    // MARK: - Filtered empty state

    private var filteredEmptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: !query.isEmpty ? "magnifyingglass"
                  : filter == .failed ? "checkmark.circle" : "line.3.horizontal.decrease.circle")
                .font(.system(size: 26))
                .foregroundStyle(Color(.tertiaryLabelColor))
            Text(!query.isEmpty ? "No Files Contain “\(query)”"
                 : filter == .failed ? "No Failed Files" : "No \(filter.label) Files")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Show All") {
                filter = .all
                vm.searchQuery = ""
            }
                .buttonStyle(.link)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isEmptyStateTargeted ? Color.accentColor : Color.secondary.opacity(0.25),
                    style: StrokeStyle(lineWidth: isEmptyStateTargeted ? 2 : 1.5, dash: [6, 4])
                )
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(isEmptyStateTargeted ? Color.accentColor.opacity(0.06) : Color.clear)
                )

            VStack(spacing: 10) {
                Image(systemName: isEmptyStateTargeted ? "arrow.down.circle.fill" : "photo.on.rectangle.angled")
                    .font(.system(size: 28))
                    .foregroundStyle(isEmptyStateTargeted ? Color.accentColor : Color(.tertiaryLabelColor))
                Text("No Images Yet")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button {
                    vm.openFilePicker()
                } label: {
                    Text("Add Files…")
                        .font(.caption)
                }
                .buttonStyle(.link)
                .controlSize(.small)
            }
            .padding(20)
            .animation(.easeInOut(duration: 0.15), value: isEmptyStateTargeted)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDrop(of: [.fileURL], isTargeted: $isEmptyStateTargeted) { providers in
            DropHelper.handle(providers: providers, vm: vm)
        }
    }

    // MARK: - Bottom toolbar

    private var bottomToolbar: some View {
        HStack(spacing: 0) {
            // Add
            Button {
                vm.openFilePicker()
            } label: {
                Image(systemName: "plus")
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Add images or folders")

            // Remove selected
            Button {
                vm.removeSelectedItems()
            } label: {
                Image(systemName: "minus")
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(vm.selectedIDs.isEmpty)
            .help(vm.selectedIDs.count > 1 ? "Remove \(vm.selectedIDs.count) selected files" : "Remove Selected Files")

            // Export lives in the toolbar's 导出 menu and in this list's
            // context menu, both of which name the files they would write. A
            // third, unlabelled arrow here only raised the question of which
            // of the two it was.

            Divider()
                .frame(height: 16)
                .padding(.horizontal, 4)

            // Clear all
            Button {
                showClearAllConfirm = true
            } label: {
                Image(systemName: "trash")
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(vm.items.isEmpty || vm.isProcessing)
            .help("Clear list")
            .confirmationDialog(
                "Clear the entire list?",
                isPresented: $showClearAllConfirm,
                titleVisibility: .visible
            ) {
                Button("Clear \(vm.items.count) Files", role: .destructive) { vm.clearAll() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This only removes them from the list. The original files on disk are not deleted.")
            }

            Spacer()

            if vm.isWatching, let folder = vm.watchFolder {
                Image(systemName: "eye")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 6)
                    .help("Watching “\(folder.lastPathComponent)”")
            }

            // One menu instead of a row of coloured counts: the counts are in
            // the menu, and the list itself says which state each file is in.
            if !vm.items.isEmpty {
                Menu {
                    Picker("Show", selection: $filter) {
                        Text("All (\(vm.items.count))").tag(StatusFilter.all)
                        Text("Completed (\(vm.completedCount))").tag(StatusFilter.completed)
                        Text("Needs Review (\(vm.reviewCount))").tag(StatusFilter.review)
                        Text("Failed (\(vm.failedCount))").tag(StatusFilter.failed)
                        Text("Cancelled (\(vm.cancelledCount))").tag(StatusFilter.cancelled)
                    }
                    .pickerStyle(.inline)
                } label: {
                    Image(systemName: filter == .all
                          ? "line.3.horizontal.decrease.circle"
                          : "line.3.horizontal.decrease.circle.fill")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(filter == .all ? Color.secondary : Color.accentColor)
                .padding(.trailing, 8)
                .help(filter == .all ? "Filter by status" : "Showing only “\(filter.label)”. Click to change")
            }
        }
        .padding(.leading, 6)
        .frame(height: 32)
        .background(.bar)
    }
}

// MARK: - Sidebar Row

struct SidebarRowView: View {
    @EnvironmentObject var vm: OCRViewModel
    let item: ImageItem
    var query = ""
    @State private var isHovering = false

    /// The words around the first match in the recognised text, when the
    /// search found the file by what it says rather than by its name.
    private var snippet: String? {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty, !item.relativePath.localizedCaseInsensitiveContains(needle),
              let range = item.ocrText.range(of: needle, options: .caseInsensitive) else { return nil }
        let start = item.ocrText.index(range.lowerBound, offsetBy: -12, limitedBy: item.ocrText.startIndex)
            ?? item.ocrText.startIndex
        let end = item.ocrText.index(range.upperBound, offsetBy: 24, limitedBy: item.ocrText.endIndex)
            ?? item.ocrText.endIndex
        return "…" + item.ocrText[start..<end].replacingOccurrences(of: "\n", with: " ") + "…"
    }

    var body: some View {
        HStack(spacing: 10) {
            thumbnailView
            VStack(alignment: .leading, spacing: 2) {
                Text(item.fileName)
                    .font(.callout)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(snippet ?? statusLine)
                    .font(.caption)
                    .foregroundStyle(item.status == .failed && snippet == nil ? Color.red : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            trailingControl
        }
        .padding(.vertical, 3)
        .onHover { isHovering = $0 }
    }

    /// How many things on this file are flagged for review.
    private var flagCount: Int {
        item.reviewNotes.filter { $0.note.severity == .warning }.count
    }

    /// The second line: where the file stands, in words — the badge on the
    /// right says the same thing at a glance.
    private var statusLine: String {
        switch item.status {
        case .pending:
            if let resume = item.resume { return Self.resumeLine(resume) }
            return "\(item.fileExtension) · \(item.fileSizeString)"
        case .processing:
            if item.pageCount > 1 { return String(localized: "Recognizing page \(item.pagesDone)/\(item.pageCount)") }
            return String(localized: "Recognizing \(item.processingProgress.percentText)")
        case .completed:
            let pages = String(localized: "\(item.pages.count) pages")
            if flagCount > 0 { return String(localized: "\(pages) · \(flagCount) to review") }
            return item.reusedCachedResult ? String(localized: "\(pages) · Reused earlier result") : pages
        case .failed:
            return item.errorMessage ?? String(localized: "Recognition Failed")
        case .cancelled:
            if let resume = item.resume { return Self.resumeLine(resume) }
            return String(localized: "Cancelled")
        }
    }

    static func resumeLine(_ resume: ResumePoint) -> String {
        String(localized: "\(resume.read)/\(resume.total) pages read; can resume")
    }

    /// On hover, failed/completed rows swap their status badge for the
    /// single most useful action, so retry/copy don't require a right-click.
    @ViewBuilder
    private var trailingControl: some View {
        if isHovering, item.status == .failed || item.status == .cancelled {
            Button {
                // Runs it, rather than only flipping the badge back to 待处理
                // and waiting for a separate 开始识别 — same as the context
                // menu's 重试 and the detail pane's button. A document
                // stopped part-way carries on rather than starting over.
                if item.resume != nil { vm.resumeItems(ids: [item.id]) }
                else { vm.retryItems(ids: [item.id]) }
            } label: {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .font(.callout)
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .help(item.resume != nil ? "Resume" : item.status == .cancelled ? "Recognize Again" : "Retry")
        } else if isHovering, item.status == .completed, !item.ocrText.isEmpty {
            Button {
                vm.copyText(for: item.id)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Copy Text")
        } else {
            statusBadge
        }
    }

    @ViewBuilder
    private var thumbnailView: some View {
        Group {
            if let thumb = item.thumbnail {
                Image(nsImage: thumb)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "doc.richtext")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
        }
        // A page's proportions rather than a square: most of what is read
        // here is a page.
        .frame(width: 28, height: 36)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(.quaternary, lineWidth: 0.5))
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch item.status {
        case .pending:
            Image(systemName: "circle.dashed")
                .foregroundStyle(.tertiary)
                .font(.caption)
        case .processing:
            ProcessingRingView(progress: item.processingProgress)
                .frame(width: 14, height: 14)
        case .completed where flagCount > 0:
            // The count, not just a warning sign: it is what decides whether
            // to deal with it now.
            Button {
                vm.startReview(itemID: item.id)
            } label: {
                Text("\(flagCount)")
                    .font(.caption2.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(.black.opacity(0.75))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.orange, in: Capsule())
            }
            .buttonStyle(.plain)
            .help("\(flagCount) items to review. Click to start reviewing")
        case .completed:
            Image(systemName: "checkmark")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.accentColor)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
                .font(.callout)
        case .cancelled:
            Image(systemName: "stop.circle")
                .foregroundStyle(.secondary)
                .font(.callout)
        }
    }
}

/// A hand-drawn ring instead of `ProgressView(value:).progressViewStyle(.circular)`:
/// on macOS a determinate circular `ProgressView` renders as two crossing arcs
/// rather than a filling ring, which reads as a rendering glitch, not progress.
struct ProcessingRingView: View {
    var progress: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.25), lineWidth: 2)
            Circle()
                // A small floor keeps a sliver visible at 0% instead of the
                // ring reading as empty rather than "just started".
                .trim(from: 0, to: min(max(progress, 0.04), 1))
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .animation(.linear(duration: 0.15), value: progress)
    }
}

