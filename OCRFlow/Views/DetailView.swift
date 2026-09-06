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
        let exportable = vm.exportableSelectedCount
        // 失败 and 已取消 both mean "no result, run it again", so one button
        // covers them rather than leaving cancelled files with nothing to press.
        let rerunnable = vm.selectedItems.filter {
            $0.status == .failed || $0.status == .cancelled
        }

        return VStack(spacing: 14) {
            Image(systemName: "rectangle.stack")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("已选中 \(vm.selectedIDs.count) 个文件")
                .font(.title3)
                .fontWeight(.semibold)
            if exportable > 0 {
                Text("其中 \(exportable) 个已完成识别")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button("导出这 \(exportable) 个文件…") { vm.exportSelectedItems() }
                        .buttonStyle(.borderedProminent)
                    Button("复制所有文本") { vm.copySelectedText() }
                        .buttonStyle(.bordered)
                }
            }
            if !rerunnable.isEmpty {
                Button("重新识别 \(rerunnable.count) 个未完成的文件") {
                    vm.retryItems(ids: Set(rerunnable.map(\.id)))
                }
                .buttonStyle(.bordered)
                .disabled(vm.isProcessing)
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

    /// Zoom, where 1 means "as large as fits the pane". The image is laid out
    /// at this size rather than drawn with `scaleEffect`, so the scroll view
    /// sees content bigger than itself and can actually scroll it — a zoomed
    /// page used to be stuck showing its middle with no way to reach the edges.
    @State private var imageZoom: CGFloat = 1.0
    /// The zoom a pinch started from, so magnification composes instead of
    /// snapping back to 1× on every gesture update.
    @State private var zoomAtGestureStart: CGFloat?
    @State private var showCopied = false
    /// Which pane the PaddleOCR-VL result is shown in. Ignored by the other
    /// engines, which have nothing but plain text to show.
    @State private var resultPane: ResultPane = .markdown

    /// The parsed document behind the Markdown pane, plus the figure crops it
    /// needs. Both are rebuilt only when the result itself changes: parsing and
    /// cropping on every layout pass would make scrolling a dense page crawl.
    @State private var renderedBlocks: [MDBlock] = []
    @State private var figures: [NSImage?] = []

    private static let minZoom: CGFloat = 0.25
    private static let maxZoom: CGFloat = 8.0

    private enum ResultPane: String, CaseIterable, Identifiable {
        case markdown = "Markdown"
        case plain    = "纯文本"
        case source   = "源码"
        var id: String { rawValue }
    }

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
                if !item.textLines.isEmpty {
                    Button {
                        vm.showTextBoxes.toggle()
                    } label: {
                        Image(systemName: vm.showTextBoxes
                              ? "viewfinder.circle.fill" : "viewfinder.circle")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(vm.showTextBoxes ? Color.accentColor : Color.secondary)
                    .help(vm.showTextBoxes ? "隐藏识别框" : "显示识别框（PP-OCR 文本行 / VL 版面块）")
                    Divider().frame(height: 14)
                }
                // Zoom controls
                HStack(spacing: 4) {
                    Button {
                        zoom(to: imageZoom - zoomStep(below: imageZoom))
                    } label: {
                        Image(systemName: "minus.magnifyingglass")
                    }
                    .buttonStyle(.borderless)
                    .disabled(imageZoom <= Self.minZoom)
                    .help("缩小")

                    Text("\(Int((imageZoom * 100).rounded()))%")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 42)

                    Button {
                        zoom(to: imageZoom + zoomStep(above: imageZoom))
                    } label: {
                        Image(systemName: "plus.magnifyingglass")
                    }
                    .buttonStyle(.borderless)
                    .disabled(imageZoom >= Self.maxZoom)
                    .help("放大")

                    Button {
                        zoom(to: 1.0)
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                    }
                    .buttonStyle(.borderless)
                    .disabled(imageZoom == 1.0)
                    .help("适合窗口")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)

            Divider()

            if let thumb = item.thumbnail {
                GeometryReader { geo in
                    // The size the image would take at 1× — what `scaledToFit`
                    // used to work out on its own — scaled by the zoom, so the
                    // frame really grows and the scroll view has somewhere to
                    // scroll to.
                    let fitted = Self.fittedSize(for: item.pixelSize, in: geo.size,
                                                 inset: Self.previewInset)
                    ScrollView([.horizontal, .vertical]) {
                        Image(nsImage: thumb)
                            .resizable()
                            .interpolation(imageZoom > 2 ? .none : .high)
                            .frame(width: fitted.width * imageZoom,
                                   height: fitted.height * imageZoom)
                            .overlay {
                                // Only a finished run's boxes belong on the image.
                                if showsOverlays, !item.layoutBlocks.isEmpty {
                                    LayoutBlockOverlay(blocks: item.layoutBlocks, imageSize: item.pixelSize)
                                }
                                if showsOverlays, !item.textLines.isEmpty {
                                    TextBoxOverlay(lines: item.textLines, imageSize: item.pixelSize)
                                }
                            }
                            .padding(Self.previewInset / 2)
                            // Keeps the image centred while it is smaller than
                            // the pane, and lets it overflow once it is larger.
                            .frame(minWidth: geo.size.width, minHeight: geo.size.height)
                    }
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
                    // Trackpad pinch, which is how one actually zooms an image on
                    // a Mac; the toolbar's ± buttons stay for precise steps, and
                    // two-finger scroll now pans because the content is really
                    // that big.
                    .gesture(
                        MagnifyGesture()
                            .onChanged { value in
                                let base = zoomAtGestureStart ?? imageZoom
                                if zoomAtGestureStart == nil { zoomAtGestureStart = imageZoom }
                                imageZoom = min(Self.maxZoom,
                                                max(Self.minZoom, base * value.magnification))
                            }
                            .onEnded { _ in zoomAtGestureStart = nil }
                    )
                    // Double-click toggles between fitting the pane and 2×,
                    // the way every other Mac image viewer behaves.
                    .onTapGesture(count: 2) { zoom(to: imageZoom == 1 ? 2 : 1) }
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "photo.slash")
                        .font(.system(size: 40))
                        .foregroundStyle(.tertiary)
                    Text("无法加载图片")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
            }
        }
        // A different file starts at "fits the pane" rather than inheriting the
        // zoom someone set for the previous one.
        .onChange(of: item.id) { _, _ in imageZoom = 1.0 }
    }

    private static let previewInset: CGFloat = 32

    /// Where `scaledToFit` would have put the image: the largest size with the
    /// original aspect ratio that fits inside the pane, minus its padding.
    static func fittedSize(for image: CGSize, in container: CGSize, inset: CGFloat) -> CGSize {
        let available = CGSize(width: max(1, container.width - inset),
                               height: max(1, container.height - inset))
        guard image.width > 0, image.height > 0 else { return available }
        let scale = min(available.width / image.width, available.height / image.height)
        return CGSize(width: image.width * scale, height: image.height * scale)
    }

    private func zoom(to value: CGFloat) {
        withAnimation(.spring(duration: 0.25)) {
            imageZoom = min(Self.maxZoom, max(Self.minZoom, value))
        }
    }

    /// Steps of 25% up to 2×, then of 50%: the same visual jump takes a bigger
    /// number the further in you are.
    private func zoomStep(above value: CGFloat) -> CGFloat { value >= 2 ? 0.5 : 0.25 }
    private func zoomStep(below value: CGFloat) -> CGFloat { value > 2 ? 0.5 : 0.25 }

    /// Boxes describe the run that produced them, so they are shown only while
    /// that run's result is the one on screen.
    private var showsOverlays: Bool {
        vm.showTextBoxes && item.status == .completed
    }

    // MARK: - Text panel

    private var textPanel: some View {
        VStack(spacing: 0) {
            // Header bar
            HStack {
                Text("识别结果")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                if item.status == .completed, let confidence = item.averageConfidence {
                    Text("\(item.textLines.count) 行 · 置信度 \(Int((confidence * 100).rounded()))%")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
                Spacer()

                if item.isExportable {
                    Button {
                        vm.exportItems(ids: [item.id])
                    } label: {
                        Label("导出此文件…", systemImage: "square.and.arrow.up")
                            .font(.callout)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("只导出「\(item.fileName)」的识别结果")
                }

                if item.status == .completed {
                    Button {
                        if item.hasMarkdown && resultPane != .plain {
                            vm.copyMarkdown(for: item.id)
                        } else {
                            vm.copyText(for: item.id)
                        }
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
                ProgressView()
                    .controlSize(.large)
                Text("正在识别中…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                VStack(spacing: 6) {
                    ProgressView(value: item.processingProgress)
                        .tint(.accentColor)
                    Text("\(Int((item.processingProgress * 100).rounded()))%")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
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
            } else if item.hasMarkdown {
                VStack(spacing: 0) {
                    Picker("", selection: $resultPane) {
                        ForEach(ResultPane.allCases) { pane in Text(pane.rawValue).tag(pane) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)

                    Divider()

                    ScrollView {
                        Group {
                            switch resultPane {
                            case .markdown:
                                // Rendered rather than raw: the point of the VL
                                // pipeline is the structure it recovers, so
                                // headings, tables and figures should look like
                                // headings, tables and figures.
                                MarkdownDocumentView(blocks: renderedBlocks,
                                                     figures: figures,
                                                     showFigures: vm.renderFigures,
                                                     renderTables: vm.renderTables)
                                    .textSelection(.enabled)
                            case .plain:
                                Text(item.ocrText)
                                    .font(.body)
                                    .textSelection(.enabled)
                                    .lineSpacing(4)
                            case .source:
                                Text(item.markdown)
                                    .font(.system(.callout, design: .monospaced))
                                    .textSelection(.enabled)
                                    .lineSpacing(3)
                            }
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .task(id: renderKey) {
                        renderedBlocks = MDParser.parse(item.markdown)
                        figures = DocumentFigures.crops(for: item)
                    }
                }
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

        case .cancelled:
            VStack(spacing: 14) {
                Image(systemName: "stop.circle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.orange)
                Text("已取消")
                    .font(.title3)
                    .fontWeight(.semibold)
                Text("识别在中途停止，这一页只读到了一部分，因此没有保留结果。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                Button("重新识别") { vm.retryItems(ids: [item.id]) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .disabled(vm.isProcessing)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

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
                Button("重试") { vm.retryItems(ids: [item.id]) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    // A retry cannot start while a run is in flight, so the
                    // button says so instead of doing nothing when pressed.
                    .disabled(vm.isProcessing)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Changes whenever the pane has a different document to show — a new
    /// selection, or a result that has just finished.
    private var renderKey: String {
        "\(item.id)#\(item.markdown.count)#\(item.layoutBlocks.count)"
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

// MARK: - Detection overlay

/// Draws PaddleOCR's per-line quadrilaterals on top of the preview.
///
/// The boxes are in image-pixel coordinates, so they first have to be mapped
/// into the letterboxed rectangle that `scaledToFit` actually paints.
struct TextBoxOverlay: View {
    let lines: [PPTextLine]
    let imageSize: CGSize

    var body: some View {
        GeometryReader { geo in
            let fitted = Self.fittedRect(for: imageSize, in: geo.size)
            if fitted.width > 0, imageSize.width > 0, imageSize.height > 0 {
                Canvas { context, _ in
                    let sx = fitted.width / imageSize.width
                    let sy = fitted.height / imageSize.height
                    for line in lines {
                        let points = line.quad.map {
                            CGPoint(x: fitted.minX + $0.x * sx, y: fitted.minY + $0.y * sy)
                        }
                        guard let first = points.first else { continue }
                        var path = Path()
                        path.move(to: first)
                        for p in points.dropFirst() { path.addLine(to: p) }
                        path.closeSubpath()
                        let tint = Self.color(for: line.confidence)
                        context.fill(path, with: .color(tint.opacity(0.14)))
                        context.stroke(path, with: .color(tint.opacity(0.9)), lineWidth: 1)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// Where `scaledToFit` places the image inside its layout frame.
    static func fittedRect(for image: CGSize, in container: CGSize) -> CGRect {
        guard image.width > 0, image.height > 0 else { return .zero }
        let scale = min(container.width / image.width, container.height / image.height)
        let w = image.width * scale, h = image.height * scale
        return CGRect(x: (container.width - w) / 2, y: (container.height - h) / 2, width: w, height: h)
    }

    /// Low-confidence lines are the ones worth looking at, so they stand out.
    static func color(for confidence: Double) -> Color {
        switch confidence {
        case ..<0.75: return .red
        case ..<0.9:  return .orange
        default:      return .accentColor
        }
    }
}

/// Draws the PaddleOCR-VL layout blocks over the preview, numbered in reading
/// order — which is the part worth seeing, since the order is what turns a set
/// of boxes into a document.
struct LayoutBlockOverlay: View {
    let blocks: [PPLayoutBlock]
    let imageSize: CGSize

    var body: some View {
        GeometryReader { geo in
            let fitted = TextBoxOverlay.fittedRect(for: imageSize, in: geo.size)
            if fitted.width > 0, imageSize.width > 0, imageSize.height > 0 {
                Canvas { context, _ in
                    let sx = fitted.width / imageSize.width
                    let sy = fitted.height / imageSize.height
                    for block in blocks {
                        let rect = CGRect(x: fitted.minX + block.rect.minX * sx,
                                          y: fitted.minY + block.rect.minY * sy,
                                          width: block.rect.width * sx,
                                          height: block.rect.height * sy)
                        let tint = Self.color(for: block.label)
                        let path = Path(roundedRect: rect, cornerRadius: 2)
                        context.fill(path, with: .color(tint.opacity(0.10)))
                        context.stroke(path, with: .color(tint.opacity(0.85)), lineWidth: 1.5)

                        var badge = context.resolve(
                            Text("\(block.readingOrder + 1)")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white))
                        badge.shading = .color(.white)
                        let size = badge.measure(in: rect.size)
                        let chip = CGRect(x: rect.minX, y: rect.minY,
                                          width: size.width + 8, height: size.height + 4)
                        context.fill(Path(roundedRect: chip, cornerRadius: 3), with: .color(tint))
                        context.draw(badge, at: CGPoint(x: chip.midX, y: chip.midY), anchor: .center)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// Colour by what the block is, so a page's structure reads at a glance.
    static func color(for label: PPLayoutLabel) -> Color {
        switch label {
        case .docTitle, .paragraphTitle, .figureTitle: return .orange
        case .table:                                    return .purple
        case .chart:                                    return .pink
        case .displayFormula, .inlineFormula, .formulaNumber: return .blue
        case .seal:                                     return .red
        case .image, .headerImage, .footerImage:        return .teal
        case .header, .footer, .number:                 return .gray
        default:                                        return .green
        }
    }
}
