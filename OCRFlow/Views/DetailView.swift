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
    /// Which pane the result is shown in.
    @State private var resultPane: ResultPane = .markdown
    /// What the user clicked in the preview, echoed in the result list — and
    /// the other way round. Clicking a box to find out what was read out of it
    /// is the first thing anyone tries.
    @State private var selection: PreviewSelection?
    /// What the pointer is over right now — the transient counterpart to
    /// `selection`. Pointing at a paragraph on the page lights up its text, and
    /// pointing at the text lights up the paragraph.
    @State private var hovered: PreviewSelection?
    /// True while the pointer is on the page rather than in the document, which
    /// is when it is worth scrolling the document to keep up.
    @State private var hoveringPage = false

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

    /// A box in the preview, and the row in the result list that goes with it.
    enum PreviewSelection: Hashable {
        case line(Int)
        case block(Int)
    }

    /// What the pointer is over, in words: the region's kind, how sure the
    /// model was, and what it read there.
    ///
    /// This is what the 逐块 pane used to be for. A list of every line was a
    /// poor way to answer "what did it make of *this*" — you had to find the
    /// row — so the answer now appears where the question is asked.
    struct HoverReading: Equatable {
        var label: PPLayoutLabel?
        var confidence: Double
        var text: String
        var isDropped = false
    }

    private var hoverReading: HoverReading? {
        switch hovered {
        case let .line(index):
            guard item.textLines.indices.contains(index) else { return nil }
            let line = item.textLines[index]
            return HoverReading(label: blockLabel(containing: line.boundingBox),
                                confidence: line.confidence, text: line.text)
        case let .block(index):
            guard item.layoutBlocks.indices.contains(index) else { return nil }
            let block = item.layoutBlocks[index]
            return HoverReading(label: block.label, confidence: block.score, text: block.text,
                                isDropped: vm.droppedLabels.contains(block.label))
        case nil:
            return nil
        }
    }

    private func blockLabel(containing rect: CGRect) -> PPLayoutLabel? {
        item.layoutBlocks
            .filter { $0.rect.intersects(rect) }
            .min { $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height }?
            .label
    }

    /// Panes worth offering for this result.
    private var availablePanes: [ResultPane] {
        var panes: [ResultPane] = []
        if item.hasMarkdown { panes.append(.markdown) }
        panes.append(.plain)
        if item.hasMarkdown { panes.append(.source) }
        return panes
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
                // Both engines draw boxes now, so both can hide them; the
                // button used to appear only when there were text lines, which
                // left the VL pipeline's blocks stuck on screen.
                if !item.textLines.isEmpty || !item.layoutBlocks.isEmpty {
                    Button {
                        vm.showTextBoxes.toggle()
                    } label: {
                        Image(systemName: vm.showTextBoxes
                              ? "viewfinder.circle.fill" : "viewfinder.circle")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(vm.showTextBoxes ? Color.accentColor : Color.secondary)
                    .help(vm.showTextBoxes ? "隐藏识别框" : "显示识别框（文本行与版面区域）")

                    // The auxiliary regions this page actually has, each one
                    // switchable from here: the decision is about what is on
                    // the page in front of you, so it belongs next to it.
                    let auxiliary = presentAuxiliaryLabels
                    if !auxiliary.isEmpty {
                        Menu {
                            ForEach(auxiliary, id: \.rawValue) { label in
                                Toggle(label.label, isOn: Binding(
                                    get: { vm.keptAuxiliary.contains(label) },
                                    set: { vm.setAuxiliary(label, kept: $0) }))
                            }
                        } label: {
                            Image(systemName: vm.droppedLabels.isDisjoint(with: auxiliary)
                                  ? "text.badge.checkmark" : "text.badge.minus")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help("这一页上的页眉/页脚/页码等辅助内容要不要写进结果（虚线框表示已排除）")
                    }
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
                                    LayoutBlockOverlay(blocks: item.layoutBlocks,
                                                       imageSize: item.pixelSize,
                                                       selected: selectedBlockIndex,
                                                       highlighted: hoveredBlockIndex,
                                                       dropped: vm.droppedLabels)
                                }
                                if showsOverlays, !item.textLines.isEmpty {
                                    TextBoxOverlay(lines: item.textLines,
                                                   imageSize: item.pixelSize,
                                                   selected: selectedLineIndex,
                                                   highlighted: hoveredLineIndex)
                                }
                            }
                            // Declared before the single tap so a double click
                            // zooms instead of selecting twice.
                            .onTapGesture(count: 2) { zoom(to: imageZoom == 1 ? 2 : 1) }
                            .onTapGesture(count: 1, coordinateSpace: .local) { point in
                                let size = CGSize(width: fitted.width * imageZoom,
                                                  height: fitted.height * imageZoom)
                                withAnimation(.easeOut(duration: 0.15)) {
                                    selection = hitTest(point, renderedSize: size)
                                }
                            }
                            // Hovering is the fast way to ask "what did it read
                            // here?" — no click, no second pane, the answer
                            // lights up where it already is.
                            .onContinuousHover(coordinateSpace: .local) { phase in
                                switch phase {
                                case let .active(point):
                                    let size = CGSize(width: fitted.width * imageZoom,
                                                      height: fitted.height * imageZoom)
                                    hoveringPage = true
                                    let hit = hitTest(point, renderedSize: size)
                                    if hit != hovered { hovered = hit }
                                case .ended:
                                    hoveringPage = false
                                    hovered = nil
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
                }
                .overlay(alignment: .bottom) {
                    if let reading = hoverReading {
                        hoverReadout(reading)
                            .padding(10)
                            .transition(.opacity)
                    }
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
        .onChange(of: item.id) { _, _ in
            imageZoom = 1.0
            selection = nil
        }
    }

    /// The auxiliary regions this page actually contains, in the order the
    /// settings pane lists them.
    private var presentAuxiliaryLabels: [PPLayoutLabel] {
        let present = Set(item.layoutBlocks.map(\.label))
        return PPLayoutLabel.auxiliary.filter(present.contains)
    }

    private var selectedLineIndex: Int? {
        if case let .line(index) = selection { return index }
        return nil
    }

    private var hoveredLineIndex: Int? {
        if case let .line(index) = hovered { return index }
        return nil
    }

    private var hoveredBlockIndex: Int? {
        blockIndex(for: hovered)
    }

    private var selectedBlockIndex: Int? {
        blockIndex(for: selection)
    }

    /// The region a selection points into: the region itself, or the one the
    /// selected text line sits in.
    private func blockIndex(for selection: PreviewSelection?) -> Int? {
        if case let .block(index) = selection { return index }
        // A selected line lights up the region it belongs to as well, which is
        // what makes "this line is part of the footer" visible at a glance.
        if case let .line(index) = selection, item.textLines.indices.contains(index) {
            let box = item.textLines[index].boundingBox
            return item.layoutBlocks.indices
                .filter { item.layoutBlocks[$0].rect.intersects(box) }
                .min { a, b in
                    let areaA = item.layoutBlocks[a].rect.width * item.layoutBlocks[a].rect.height
                    let areaB = item.layoutBlocks[b].rect.width * item.layoutBlocks[b].rect.height
                    return areaA < areaB
                }
        }
        return nil
    }

    /// Maps a click on the preview back to the box under it: a text line if
    /// there is one, otherwise the smallest layout region that contains it.
    private func hitTest(_ point: CGPoint, renderedSize: CGSize) -> PreviewSelection? {
        let pixel = item.pixelSize
        guard renderedSize.width > 0, renderedSize.height > 0,
              pixel.width > 0, pixel.height > 0 else { return nil }
        let inImage = CGPoint(x: point.x / renderedSize.width * pixel.width,
                              y: point.y / renderedSize.height * pixel.height)

        if let index = item.textLines.firstIndex(where: { $0.boundingBox.contains(inImage) }) {
            return .line(index)
        }
        let containing = item.layoutBlocks.indices.filter { item.layoutBlocks[$0].rect.contains(inImage) }
        if let smallest = containing.min(by: { a, b in
            let areaA = item.layoutBlocks[a].rect.width * item.layoutBlocks[a].rect.height
            let areaB = item.layoutBlocks[b].rect.width * item.layoutBlocks[b].rect.height
            return areaA < areaB
        }) {
            return .block(smallest)
        }
        // A click on blank paper clears the selection rather than keeping a
        // highlight the user has moved on from.
        return nil
    }

    /// A strip along the bottom of the preview saying what is under the
    /// pointer. Fixed in place rather than following the cursor: it has to be
    /// readable, and a card that moves while you read it is not.
    private func hoverReadout(_ reading: HoverReading) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if let label = reading.label {
                Text(label.label)
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(LayoutBlockOverlay.color(for: label).opacity(0.18), in: Capsule())
                    .foregroundStyle(LayoutBlockOverlay.color(for: label))
                    .fixedSize()
            }
            Text(reading.text.isEmpty ? "（无文字）" : reading.text)
                .font(.caption)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            if reading.isDropped {
                Text("已排除")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize()
            }
            Text("\(Int((reading.confidence * 100).rounded()))%")
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(TextBoxOverlay.color(for: reading.confidence))
                .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        .allowsHitTesting(false)
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
            } else {
                VStack(spacing: 0) {
                    let panes = availablePanes
                    if panes.count > 1 {
                        Picker("", selection: $resultPane) {
                            ForEach(panes) { pane in Text(pane.rawValue).tag(pane) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)

                        Divider()
                    }

                    switch resultPane {
                    case .markdown:
                        ScrollViewReader { proxy in
                            ScrollView {
                                // Rendered rather than raw: the point of layout
                                // analysis is the structure it recovers, so
                                // headings, tables and figures should look like
                                // headings, tables and figures — and each of
                                // them still knows which part of the page it
                                // was read from.
                                MarkdownDocumentView(
                                    blocks: renderedBlocks,
                                    figures: figures,
                                    showFigures: vm.renderFigures,
                                    renderTables: vm.renderTables,
                                    highlighted: hoveredBlockIndex,
                                    selected: selectedBlockIndex,
                                    labelForSource: { index in
                                        item.layoutBlocks.indices.contains(index)
                                            ? item.layoutBlocks[index].label.label : nil
                                    },
                                    onHover: { source in
                                        // Only the page scrolls this pane; the
                                        // pane moving under its own pointer
                                        // would fight the user.
                                        hoveringPage = false
                                        hovered = source.map { .block($0) }
                                    },
                                    onTap: { source in selection = .block(source) },
                                    textForSource: { index in
                                        item.layoutBlocks.indices.contains(index)
                                            ? item.layoutBlocks[index].text : nil
                                    },
                                    onCorrect: item.derivesFromBlocks
                                        ? { index, text in
                                            vm.correctBlock(itemID: item.id, blockIndex: index,
                                                            text: text)
                                        }
                                        : nil)
                                    .textSelection(.enabled)
                                    .padding(16)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .onChange(of: hoveredBlockIndex) { _, source in
                                guard hoveringPage, let source,
                                      let target = renderedBlocks.first(where: { $0.sourceBlock == source })
                                else { return }
                                withAnimation(.easeOut(duration: 0.2)) {
                                    proxy.scrollTo(target.id, anchor: .center)
                                }
                            }
                        }
                        .task(id: renderKey) { await refreshDocument() }
                    default:
                        ScrollView {
                            Group {
                                if resultPane == .source {
                                    Text(item.markdown)
                                        .font(.system(.callout, design: .monospaced))
                                        .textSelection(.enabled)
                                        .lineSpacing(3)
                                } else {
                                    Text(item.ocrText)
                                        .font(.body)
                                        .textSelection(.enabled)
                                        .lineSpacing(4)
                                }
                            }
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                // A pane that no longer applies to this file would otherwise
                // show as an empty result.
                .onAppear { normalisePane() }
                .onChange(of: renderKey) { _, _ in normalisePane() }
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

    /// Keeps `resultPane` on something this result actually has.
    private func normalisePane() {
        let panes = availablePanes
        guard !panes.contains(resultPane) else { return }
        resultPane = panes.first ?? .plain
    }

    private func refreshDocument() async {
        renderedBlocks = MDParser.parse(fragments: vm.documentFragments(for: item))
        figures = DocumentFigures.crops(for: item)
    }

    /// Changes whenever the pane has a different document to show — a new
    /// selection, a result that has just finished, or the page-furniture switch
    /// having added or removed regions.
    private var renderKey: String {
        "\(item.id)#\(item.markdown.count)#\(item.layoutBlocks.count)#\(vm.keptAuxiliary.count)"
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
    /// The line the result list is pointing at, drawn to stand out from the
    /// rest the way a selection should.
    var selected: Int?
    /// The line under the pointer, lit more softly than a selection.
    var highlighted: Int?

    var body: some View {
        GeometryReader { geo in
            let fitted = Self.fittedRect(for: imageSize, in: geo.size)
            if fitted.width > 0, imageSize.width > 0, imageSize.height > 0 {
                Canvas { context, _ in
                    let sx = fitted.width / imageSize.width
                    let sy = fitted.height / imageSize.height
                    for (index, line) in lines.enumerated() {
                        let points = line.quad.map {
                            CGPoint(x: fitted.minX + $0.x * sx, y: fitted.minY + $0.y * sy)
                        }
                        guard let first = points.first else { continue }
                        var path = Path()
                        path.move(to: first)
                        for p in points.dropFirst() { path.addLine(to: p) }
                        path.closeSubpath()
                        let isSelected = index == selected
                        let isHovered = index == highlighted
                        let lit = isSelected || isHovered
                        let tint = lit ? Color.accentColor : Self.color(for: line.confidence)
                        context.fill(path, with: .color(tint.opacity(isSelected ? 0.34
                                                                    : isHovered ? 0.22 : 0.14)))
                        context.stroke(path, with: .color(tint.opacity(lit ? 1 : 0.9)),
                                       lineWidth: isSelected ? 2.5 : isHovered ? 2 : 1)
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
    var selected: Int?
    /// The region under the pointer, wherever the pointer is: on the page, or
    /// on the text that came out of it.
    var highlighted: Int?
    /// Draw the regions that are being left out of the document as dashed
    /// outlines, so "these three boxes are the ones being dropped" is something
    /// the page itself shows rather than something the settings claim.
    var dropped: Set<PPLayoutLabel> = []

    var body: some View {
        GeometryReader { geo in
            let fitted = TextBoxOverlay.fittedRect(for: imageSize, in: geo.size)
            if fitted.width > 0, imageSize.width > 0, imageSize.height > 0 {
                Canvas { context, _ in
                    let sx = fitted.width / imageSize.width
                    let sy = fitted.height / imageSize.height
                    for (index, block) in blocks.enumerated() {
                        let rect = CGRect(x: fitted.minX + block.rect.minX * sx,
                                          y: fitted.minY + block.rect.minY * sy,
                                          width: block.rect.width * sx,
                                          height: block.rect.height * sy)
                        let isSelected = index == selected
                        let isHovered = index == highlighted
                        let lit = isSelected || isHovered
                        let isDropped = dropped.contains(block.label)
                        let tint = lit ? Color.accentColor : Self.color(for: block.label)
                        let path = Path(roundedRect: rect, cornerRadius: 2)

                        context.fill(path, with: .color(tint.opacity(isSelected ? 0.22
                                                                    : isHovered ? 0.16
                                                                    : isDropped ? 0.04 : 0.10)))
                        context.stroke(path, with: .color(tint.opacity(isDropped ? 0.6 : 0.85)),
                                       style: StrokeStyle(lineWidth: isSelected ? 3 : isHovered ? 2.5 : 1.5,
                                                          dash: isDropped ? [4, 3] : []))

                        // The reading-order number normally; the region's name
                        // once it is under the pointer, which is the thing
                        // worth knowing at that moment.
                        let caption = lit ? "\(block.readingOrder + 1) \(block.label.label)"
                                          : "\(block.readingOrder + 1)"
                        var badge = context.resolve(
                            Text(caption)
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white))
                        badge.shading = .color(.white)
                        let size = badge.measure(in: CGSize(width: 200, height: rect.height))
                        let chip = CGRect(x: rect.minX, y: rect.minY,
                                          width: size.width + 8, height: size.height + 4)
                        context.fill(Path(roundedRect: chip, cornerRadius: 3),
                                     with: .color(tint.opacity(isDropped ? 0.5 : 1)))
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
