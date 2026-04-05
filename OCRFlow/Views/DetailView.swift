import SwiftUI

struct DetailView: View {
    @EnvironmentObject var vm: OCRViewModel

    var body: some View {
        if vm.selectedIDs.count > 1 {
            multiSelectionPlaceholder
        } else if let item = vm.selectedItem {
            ItemDetailView(item: item)
        } else {
            DropZoneView()
        }
    }

    private var multiSelectionPlaceholder: some View {
        VStack(spacing: 14) {
            Image(systemName: "rectangle.stack")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("已选中 \(vm.selectedIDs.count) 个文件")
                .font(.title3)
                .fontWeight(.semibold)
            let completedCount = vm.selectedItems.filter { $0.status == .completed }.count
            if completedCount > 0 {
                Text("其中 \(completedCount) 个已完成识别")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button("导出选中结果…") { vm.exportSelectedItems() }
                        .buttonStyle(.borderedProminent)
                    Button("复制所有文本") { vm.copySelectedText() }
                        .buttonStyle(.bordered)
                }
            }
            Button("移除选中文件", role: .destructive) { vm.removeSelectedItems() }
                .buttonStyle(.bordered)
                .foregroundStyle(.red)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Item detail

struct ItemDetailView: View {
    @EnvironmentObject var vm: OCRViewModel
    let item: ImageItem

    @State private var imageScale: CGFloat = 1.0
    @State private var showCopied = false

    var body: some View {
        HSplitView {
            // Left: image preview
            imagePanel
                .frame(minWidth: 280)

            // Right: OCR result
            textPanel
                .frame(minWidth: 280)
        }
    }

    // MARK: - Image panel

    private var imagePanel: some View {
        VStack(spacing: 0) {
            HStack {
                Text("预览")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Spacer()
                // Zoom controls
                HStack(spacing: 4) {
                    Button {
                        withAnimation(.spring(duration: 0.25)) { imageScale = max(0.25, imageScale - 0.25) }
                    } label: {
                        Image(systemName: "minus.magnifyingglass")
                    }
                    .buttonStyle(.borderless)
                    .help("缩小")

                    Text("\(Int(imageScale * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 38)

                    Button {
                        withAnimation(.spring(duration: 0.25)) { imageScale = min(4.0, imageScale + 0.25) }
                    } label: {
                        Image(systemName: "plus.magnifyingglass")
                    }
                    .buttonStyle(.borderless)
                    .help("放大")

                    Button {
                        withAnimation(.spring(duration: 0.25)) { imageScale = 1.0 }
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                    }
                    .buttonStyle(.borderless)
                    .help("适合窗口")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)

            Divider()

            ScrollView([.horizontal, .vertical]) {
                if let thumb = item.thumbnail {
                    Image(nsImage: thumb)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(imageScale)
                        .padding(24)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "photo.slash")
                            .font(.system(size: 40))
                            .foregroundStyle(.tertiary)
                        Text("无法加载图片")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(40)
                }
            }
            .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
        }
    }

    // MARK: - Text panel

    private var textPanel: some View {
        VStack(spacing: 0) {
            // Header bar
            HStack {
                Text("识别结果")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Spacer()

                if item.status == .completed {
                    Button {
                        vm.copyText(for: item.id)
                        withAnimation { showCopied = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                            withAnimation { showCopied = false }
                        }
                    } label: {
                        Label(showCopied ? "已复制" : "复制", systemImage: showCopied ? "checkmark" : "doc.on.doc")
                            .font(.callout)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .foregroundStyle(showCopied ? .green : .primary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)

            Divider()

            // Content
            textContent
        }
    }

    @ViewBuilder
    private var textContent: some View {
        switch item.status {
        case .pending:
            statusPlaceholder(
                icon: "circle.dashed",
                title: "等待识别",
                subtitle: "点击工具栏的「开始识别」按钮处理该文件",
                color: .secondary
            )

        case .processing:
            VStack(spacing: 20) {
                ProgressView(value: item.processingProgress)
                    .progressViewStyle(.circular)
                    .scaleEffect(1.4)
                Text("正在识别中…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                ProgressView(value: item.processingProgress)
                    .tint(.accentColor)
                    .padding(.horizontal, 40)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .completed:
            if item.ocrText.isEmpty {
                statusPlaceholder(
                    icon: "text.slash",
                    title: "未识别到文字",
                    subtitle: "该图片可能不含可识别的文字内容",
                    color: .orange
                )
            } else {
                ScrollView {
                    Text(item.ocrText)
                        .font(.body)
                        .textSelection(.enabled)
                        .lineSpacing(4)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

        case .failed:
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.red)
                Text("识别失败")
                    .font(.title3)
                    .fontWeight(.semibold)
                if let msg = item.errorMessage {
                    Text(msg)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                Button("重试") { vm.retryItem(id: item.id) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func statusPlaceholder(icon: String, title: String, subtitle: String, color: Color) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 36))
                .foregroundStyle(color.opacity(0.7))
            Text(title)
                .font(.title3)
                .fontWeight(.semibold)
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
