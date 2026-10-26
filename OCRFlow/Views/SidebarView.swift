import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var vm: OCRViewModel
    @State private var isEmptyStateTargeted = false
    @State private var showClearAllConfirm = false
    @State private var filter: StatusFilter = .all
    /// Searches file names and everything recognised in them. The results are
    /// kept between launches, so this searches every batch still listed.
    @State private var query = ""

    /// Narrows the list to one status. In a batch of a few hundred files the
    /// failures are the ones worth looking at, and scrolling for them is the
    /// main thing the list makes hard.
    fileprivate enum StatusFilter {
        case all, completed, review, failed, cancelled

        var label: String {
            switch self {
            case .all:       return "全部"
            case .completed: return "已完成"
            case .review:    return "待复核"
            case .failed:    return "失败"
            case .cancelled: return "已取消"
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
            } else if visibleItems.isEmpty {
                filteredEmptyState
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
                            if anyFinished && !anyProcessing {
                                let verb = allFailed ? "重试" : "重新识别"
                                Button(count > 1 ? "\(verb) \(count) 个文件" : verb) {
                                    vm.retryItems(ids: targetIDs)
                                }
                            }
                            if allExportable {
                                Button(count > 1 ? "复制所有文本" : "复制文本") {
                                    if count > 1 { vm.copySelectedText() }
                                    else { vm.copyText(for: item.id) }
                                }
                                Button(count > 1 ? "导出选中结果…" : "导出此文件结果…") {
                                    vm.exportItems(ids: targetIDs)
                                }
                            }
                            Divider()
                            if count == 1 {
                                Button("在 Finder 中显示") {
                                    NSWorkspace.shared.selectFile(item.url.path, inFileViewerRootedAtPath: "")
                                }
                                Divider()
                            }
                            Button(count > 1 ? "移除 \(count) 个文件" : "移除", role: .destructive) {
                                vm.removeItems(ids: targetIDs)
                            }
                        }
                }
                .listStyle(.sidebar)
                .onDeleteCommand { vm.removeSelectedItems() }
            }

            Divider()
            bottomToolbar
        }
        .searchable(text: $query, placement: .sidebar, prompt: "搜索文件名或识别内容")
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
            Text(!query.isEmpty ? "没有包含「\(query)」的文件"
                 : filter == .failed ? "没有失败的文件" : "没有\(filter.label)的文件")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("显示全部") {
                filter = .all
                query = ""
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
                Text("尚未添加图片")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button {
                    vm.openFilePicker()
                } label: {
                    Text("添加文件…")
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
            .help("添加图片或文件夹")

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
            .help(vm.selectedIDs.count > 1 ? "移除 \(vm.selectedIDs.count) 个选中文件" : "移除选中文件")

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
            .help("清空列表")
            .confirmationDialog(
                "清空整个列表？",
                isPresented: $showClearAllConfirm,
                titleVisibility: .visible
            ) {
                Button("清空 \(vm.items.count) 个文件", role: .destructive) { vm.clearAll() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("仅从列表中移除，不会删除磁盘上的原始文件。")
            }

            Spacer()

            // Counts double as status filters.
            if !vm.items.isEmpty {
                HStack(spacing: 4) {
                    filterChip(.all, count: vm.items.count, icon: nil, tint: .secondary,
                               help: "显示全部 \(vm.items.count) 个文件")
                    if vm.completedCount > 0 {
                        filterChip(.completed, count: vm.completedCount,
                                   icon: "checkmark.circle.fill", tint: .green,
                                   help: "只看已完成的 \(vm.completedCount) 个")
                    }
                    if vm.reviewCount > 0 {
                        filterChip(.review, count: vm.reviewCount,
                                   icon: "exclamationmark.triangle.fill", tint: .orange,
                                   help: "只看有待复核内容的 \(vm.reviewCount) 个")
                    }
                    if vm.failedCount > 0 {
                        filterChip(.failed, count: vm.failedCount,
                                   icon: "xmark.circle.fill", tint: .red,
                                   help: "只看失败的 \(vm.failedCount) 个")
                    }
                    if vm.cancelledCount > 0 {
                        filterChip(.cancelled, count: vm.cancelledCount,
                                   icon: "stop.circle.fill", tint: .orange,
                                   help: "只看已取消的 \(vm.cancelledCount) 个")
                    }
                }
                .padding(.trailing, 8)
            }
        }
        .padding(.leading, 6)
        .frame(height: 32)
        .background(.bar)
    }
}

extension SidebarView {
    /// Clicking an active chip other than 全部 returns to 全部, so the filter can
    /// always be cleared from the chip that set it.
    fileprivate func filterChip(_ target: StatusFilter, count: Int, icon: String?,
                                tint: Color, help: String) -> some View {
        let isActive = filter == target
        return Button {
            filter = (isActive && target != .all) ? .all : target
        } label: {
            HStack(spacing: 3) {
                if let icon { Image(systemName: icon) }
                Text("\(count)").monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(isActive ? Color.white : tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(isActive ? tint : .clear, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
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
                if let snippet {
                    Text(snippet)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                HStack(spacing: 6) {
                    Text(item.fileExtension)
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.15))
                        .foregroundStyle(Color.accentColor)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                    Text(item.fileSizeString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                }
            }
            Spacer(minLength: 0)
            trailingControl
        }
        .padding(.vertical, 3)
        .onHover { isHovering = $0 }
    }

    /// On hover, failed/completed rows swap their status badge for the
    /// single most useful action, so retry/copy don't require a right-click.
    @ViewBuilder
    private var trailingControl: some View {
        if isHovering, item.status == .failed || item.status == .cancelled {
            Button {
                // Runs it, rather than only flipping the badge back to 待处理
                // and waiting for a separate 开始识别 — same as the context
                // menu's 重试 and the detail pane's button.
                vm.retryItems(ids: [item.id])
            } label: {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .font(.callout)
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .help(item.status == .cancelled ? "重新识别" : "重试")
        } else if isHovering, item.status == .completed, !item.ocrText.isEmpty {
            Button {
                vm.copyText(for: item.id)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("复制文本")
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
        .frame(width: 40, height: 40)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary, lineWidth: 0.5))
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch item.status {
        case .pending:
            Image(systemName: "circle")
                .foregroundStyle(.tertiary)
                .font(.caption)
        case .processing:
            ProcessingRingView(progress: item.processingProgress)
                .frame(width: 16, height: 16)
        case .completed where item.needsReview:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.callout)
                .help("识别完成，有内容待复核")
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.callout)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
                .font(.callout)
        case .cancelled:
            Image(systemName: "stop.circle.fill")
                .foregroundStyle(.orange)
                .font(.callout)
        }
    }
}

/// A hand-drawn ring instead of `ProgressView(value:).progressViewStyle(.circular)`:
/// on macOS a determinate circular `ProgressView` renders as two crossing arcs
/// rather than a filling ring, which reads as a rendering glitch, not progress.
private struct ProcessingRingView: View {
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

