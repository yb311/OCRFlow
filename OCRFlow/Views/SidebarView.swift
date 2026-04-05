import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var vm: OCRViewModel

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
                List(vm.items, selection: selectionBinding) { item in
                    SidebarRowView(item: item)
                        .tag(item.id)
                        .contextMenu {
                            // If right-clicked item is not in selection, switch to it alone
                            let targetIDs: Set<UUID> = vm.selectedIDs.contains(item.id)
                                ? vm.selectedIDs : [item.id]
                            let targetItems = vm.items.filter { targetIDs.contains($0.id) }
                            let allCompleted = targetItems.allSatisfy { $0.status == .completed }
                            let allFailed    = targetItems.allSatisfy { $0.status == .failed }
                            let count = targetIDs.count

                            if allFailed {
                                Button(count > 1 ? "重试选中项" : "重试") {
                                    targetIDs.forEach { vm.retryItem(id: $0) }
                                }
                            }
                            if allCompleted {
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
            }

            Divider()
            bottomToolbar
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("尚未添加图片")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

            Divider()
                .frame(height: 16)
                .padding(.horizontal, 4)

            // Export selected
            Button {
                vm.exportSelectedItems()
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(!vm.selectedItems.contains { $0.status == .completed && !$0.ocrText.isEmpty })
            .help(vm.selectedIDs.count > 1 ? "导出 \(vm.selectedIDs.count) 个文件的识别结果" : "导出选中文件的识别结果")

            Spacer()

            // Stats
            if !vm.items.isEmpty {
                HStack(spacing: 8) {
                    Text("\(vm.items.count) 个")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if vm.completedCount > 0 {
                        Label("\(vm.completedCount)", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                    if vm.failedCount > 0 {
                        Label("\(vm.failedCount)", systemImage: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
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

// MARK: - Sidebar Row

struct SidebarRowView: View {
    let item: ImageItem

    var body: some View {
        HStack(spacing: 10) {
            thumbnailView
            VStack(alignment: .leading, spacing: 2) {
                Text(item.fileName)
                    .font(.callout)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
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
            Spacer(minLength: 0)
            statusBadge
        }
        .padding(.vertical, 3)
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
            ProgressView(value: item.processingProgress)
                .progressViewStyle(.circular)
                .scaleEffect(0.6)
                .frame(width: 20, height: 20)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.callout)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
                .font(.callout)
        }
    }
}
