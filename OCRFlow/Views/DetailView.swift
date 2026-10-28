import SwiftUI

struct DetailView: View {
    @EnvironmentObject var vm: OCRViewModel
    @State private var translating = false

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
            Text("\(vm.selectedIDs.count) Files Selected")
                .font(.title3)
                .fontWeight(.semibold)
            if exportable > 0 {
                Text("\(exportable) recognized")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button("Export \(exportable) Files…") { vm.exportSelectedItems() }
                        .buttonStyle(.borderedProminent)
                    Button("Copy All Text") { vm.copySelectedText() }
                        .buttonStyle(.bordered)
                    if #available(macOS 15.0, *) {
                        Button("Translate \(exportable) Files…") { translating = true }
                            .buttonStyle(.bordered)
                    }
                }
            }
            if !rerunnable.isEmpty {
                // Carries a document stopped part-way on from where it got
                // to; one that failed has nothing kept and is read in full.
                Button("Recognize \(rerunnable.count) Unfinished Files Again") {
                    vm.resumeItems(ids: Set(rerunnable.map(\.id)))
                }
                .buttonStyle(.bordered)
                .disabled(vm.isProcessing)
            }
            Button("Remove Selected Files", role: .destructive) { vm.removeSelectedItems() }
                .buttonStyle(.bordered)
                .foregroundStyle(.red)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $translating) {
            if #available(macOS 15.0, *) {
                TranslationSheet(items: vm.selectedItems.filter(\.isExportable))
            }
        }
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
    @State private var translating = false
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

    /// The page on show. A multi-page file is looked at, corrected and
    /// reviewed one page at a time, the preview and the text side by side.
    @State private var pageIndex = 0
    /// How many pages the file has, known before it has been read.
    @State private var sourcePageCount = 1
    /// The page as an image, decoded when it is shown rather than kept for
    /// every file in the list.
    @State private var pageImage: NSImage?
    @State private var showingNotes = true
    /// True while a selection made by clicking the result list is being
    /// handled, so the list does not scroll under the pointer that made it.
    @State private var selectedInPane = false
    /// Where the sidebar's search text occurs in this file, and which of
    /// those places is on show.
    @State private var searchMatches: [TextMatch] = []
    @State private var matchIndex = 0
    /// The file and the text the matches were last turned to for. A
    /// correction made while searching changes the matches but should not
    /// pull the page away from the region being corrected.
    @State private var searchedFor = ""

    private var pageCount: Int { max(item.pages.count, sourcePageCount) }

    private var searchNeedle: String { vm.searchQuery.trimmingCharacters(in: .whitespaces) }

    /// Changes whenever the places to find could have.
    private var searchKey: String {
        "\(item.id)#\(searchNeedle)#\(item.status)#\(item.ocrText.count)"
    }

    /// Finds the search text in this file and turns to the first place it
    /// occurs: a file found by what it says opens where it says it.
    private func updateSearchMatches() {
        let matches = item.status == .completed ? item.matches(of: searchNeedle) : []
        let target = "\(item.id)#\(searchNeedle)#\(item.status)"
        guard matches != searchMatches || target != searchedFor else { return }
        searchMatches = matches
        guard target != searchedFor else {
            matchIndex = min(matchIndex, max(matches.count - 1, 0))
            return
        }
        searchedFor = target
        matchIndex = 0
        // Coming back from review to a particular region wins over the search.
        if !matches.isEmpty, vm.documentFocus?.itemID != item.id { showMatch(0) }
    }

    private func showMatch(_ index: Int) {
        guard searchMatches.indices.contains(index) else { return }
        matchIndex = index
        let match = searchMatches[index]
        pageIndex = match.page
        let target: PreviewSelection? = switch match.place {
        case let .block(block): .block(block)
        case let .line(line):   .line(line)
        case .page:             nil
        }
        // Selected once the page change has been handled, which clears the
        // selection of the page being left.
        Task { @MainActor in selection = target }
    }

    /// Turns to the page and region review asked for, if it asked about this
    /// file, and lets the request go.
    private func applyDocumentFocus() {
        guard let focus = vm.documentFocus, focus.itemID == item.id else { return }
        pageIndex = focus.page
        // Selected once the page change has been handled, which clears the
        // selection of the page being left.
        let target = focus.block.map { PreviewSelection.block($0) }
        Task { @MainActor in
            selection = target
            vm.documentFocus = nil
        }
    }

    private var page: PageResult? {
        item.pages.indices.contains(pageIndex) ? item.pages[pageIndex] : nil
    }

    private var blocks: [PPLayoutBlock] { page?.blocks ?? [] }
    private var lines: [PPTextLine] { page?.lines ?? [] }

    /// The size the boxes are expressed in: the page as it was read.
    private var pixelSize: CGSize {
        if let size = page?.size, size.width > 0, size.height > 0 { return size }
        guard let rep = pageImage?.representations.first else { return pageImage?.size ?? .zero }
        return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
    }

    /// This page's text and Markdown, as the document has them.
    private var pageText: (text: String, markdown: String) {
        item.pages.count > 1 ? vm.pageText(for: item, page: pageIndex) : (item.ocrText, item.markdown)
    }

    /// Changes whenever a different picture belongs in the preview.
    private var previewKey: String {
        "\(item.id)#\(pageIndex)#\(page?.rectified.map { ObjectIdentifier($0).hashValue } ?? 0)"
    }

    private static let minZoom: CGFloat = 0.25
    private static let maxZoom: CGFloat = 8.0

    private enum ResultPane: String, CaseIterable, Identifiable {
        /// The document region by region, each with who read it.
        case markdown
        /// The document as a document: the Markdown rendered, nothing else.
        case source
        case plain
        var id: String { rawValue }
        var label: String {
            switch self {
            case .markdown: return String(localized: "Blocks")
            case .source:   return "Markdown"
            case .plain:    return String(localized: "Plain Text")
            }
        }
    }

    /// A box in the preview, and the row in the result list that goes with it.
    enum PreviewSelection: Hashable {
        case line(Int)
        case block(Int)
    }

    /// Panes worth offering for this result.
    private var availablePanes: [ResultPane] {
        let structured = !pageText.markdown.isEmpty
        var panes: [ResultPane] = []
        if structured { panes.append(.markdown) }
        if structured { panes.append(.source) }
        panes.append(.plain)
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
                if pageCount > 1 { pageStepper }
                if item.pages.count > 1 { rereadPageButton }
                if !searchMatches.isEmpty { matchStepper }
                Spacer()
                // Both engines draw boxes now, so both can hide them; the
                // button used to appear only when there were text lines, which
                // left the VL pipeline's blocks stuck on screen.
                if !lines.isEmpty || !blocks.isEmpty {
                    Button {
                        vm.showTextBoxes.toggle()
                    } label: {
                        Image(systemName: vm.showTextBoxes
                              ? "square.grid.3x3.fill" : "square.grid.3x3")
                    }
                    .accessibilityLabel("Text Boxes")
                    .buttonStyle(.borderless)
                    .foregroundStyle(vm.showTextBoxes ? Color.accentColor : Color.secondary)
                    .help(vm.showTextBoxes
                          ? "Show all boxes (turn off to show only the block under the pointer)"
                          : "Show only the block under the pointer (turn on to see all boxes at once)")

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
                        .help("Whether headers, footers, page numbers and other auxiliary content on this page go into the result (dashed boxes are excluded)")
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
                    .help("Zoom Out")

                    Text(imageZoom.percentText)
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
                    .help("Zoom In")

                    Button {
                        zoom(to: 1.0)
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                    }
                    .buttonStyle(.borderless)
                    .disabled(imageZoom == 1.0)
                    .help("Fit to Window")
                }
            }
            .padding(.horizontal, 12)
            .frame(height: Self.paneHeaderHeight)
            .background(.bar)

            Divider()

            if let thumb = pageImage ?? item.thumbnail {
                GeometryReader { geo in
                    // The size the image would take at 1× — what `scaledToFit`
                    // used to work out on its own — scaled by the zoom, so the
                    // frame really grows and the scroll view has somewhere to
                    // scroll to.
                    let fitted = Self.fittedSize(for: pixelSize, in: geo.size,
                                                 inset: Self.previewInset)
                    ScrollView([.horizontal, .vertical]) {
                        Image(nsImage: thumb)
                            .resizable()
                            .interpolation(imageZoom > 2 ? .none : .high)
                            .frame(width: fitted.width * imageZoom,
                                   height: fitted.height * imageZoom)
                            .overlay {
                                // Only a finished run's boxes belong on the
                                // image. With the toggle off they appear one at
                                // a time, under the pointer.
                                if item.status == .completed, !blocks.isEmpty {
                                    LayoutBlockOverlay(blocks: blocks,
                                                       imageSize: pixelSize,
                                                       selected: selectedBlockIndex,
                                                       highlighted: hoveredBlockIndex,
                                                       showsAll: vm.showTextBoxes,
                                                       dropped: vm.droppedLabels)
                                }
                                if item.status == .completed, !lines.isEmpty {
                                    TextBoxOverlay(lines: lines,
                                                   imageSize: pixelSize,
                                                   selected: selectedLineIndex,
                                                   highlighted: hoveredLineIndex,
                                                   showsAll: vm.showTextBoxes)
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
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "photo.slash")
                        .font(.system(size: 40))
                        .foregroundStyle(.tertiary)
                    Text("Couldn't Load Image")
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
            pageIndex = 0
            showingNotes = true
            applyDocumentFocus()
            // Whichever of this and the search's own `onChange` runs second
            // turns the new file to its first match.
            searchedFor = ""
            updateSearchMatches()
        }
        .onChange(of: pageIndex) { _, _ in
            selection = nil
            hovered = nil
        }
        // Coming back from review: open the page in question with its region
        // selected. Runs after `onChange(of: item.id)` has reset the pane.
        .onAppear { applyDocumentFocus() }
        .onChange(of: vm.documentFocus) { _, _ in applyDocumentFocus() }
        // Runs after `onChange(of: item.id)` has turned a new file to its
        // first page, so the search can turn it on to the first match.
        .onAppear { updateSearchMatches() }
        .onChange(of: searchKey) { _, _ in updateSearchMatches() }
        .task(id: previewKey) {
            let index = pageIndex
            pageImage = nil
            async let count = PagePreviews.pageCount(of: item)
            pageImage = await PagePreviews.image(for: item, page: index)
            sourcePageCount = await count
        }
    }

    /// Previous and next page, with the page's number between them — orange
    /// when the page has something flagged for review.
    private var pageStepper: some View {
        HStack(spacing: 2) {
            Button {
                pageIndex = max(0, pageIndex - 1)
            } label: {
                Image(systemName: "chevron.left")
            }
            .keyboardShortcut(.leftArrow, modifiers: .option)
            .disabled(pageIndex == 0)

            Text("\(pageIndex + 1) / \(pageCount)")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(page?.needsReview == true ? Color.orange : .secondary)
                .frame(minWidth: 44)

            Button {
                pageIndex = min(pageCount - 1, pageIndex + 1)
            } label: {
                Image(systemName: "chevron.right")
            }
            .keyboardShortcut(.rightArrow, modifiers: .option)
            .disabled(pageIndex >= pageCount - 1)
        }
        .buttonStyle(.borderless)
        .help("Turn page (⌥← / ⌥→)")
    }

    /// Reads the page on show again, by itself.
    @ViewBuilder
    private var rereadPageButton: some View {
        if vm.rereadingPages.contains(OCRViewModel.PageRef(itemID: item.id, page: pageIndex)) {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.7)
                .frame(width: 16, height: 16)
                .help("Recognizing this page again…")
        } else {
            Button {
                vm.rereadPage(itemID: item.id, page: pageIndex)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(!vm.canRereadPage(item))
            .help(vm.isProcessing ? "Recognition is in progress. You can recognize this page again once it finishes" : "Recognize this page again; other pages stay as they are")
        }
    }

    /// Steps through the places the sidebar's search found in this file.
    private var matchStepper: some View {
        HStack(spacing: 2) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("\(matchIndex + 1)/\(searchMatches.count)")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Button {
                showMatch((matchIndex - 1 + searchMatches.count) % searchMatches.count)
            } label: {
                Image(systemName: "chevron.up")
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            Button {
                showMatch((matchIndex + 1) % searchMatches.count)
            } label: {
                Image(systemName: "chevron.down")
            }
            .keyboardShortcut("g", modifiers: .command)
        }
        .buttonStyle(.borderless)
        .help("“\(searchNeedle)”: match \(matchIndex + 1) of \(searchMatches.count) in this file (⌘G next, ⇧⌘G previous)")
    }

    /// The auxiliary regions this page actually contains, in the order the
    /// settings pane lists them.
    private var presentAuxiliaryLabels: [PPLayoutLabel] {
        let present = Set(blocks.map(\.label))
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
        if case let .line(index) = selection, lines.indices.contains(index) {
            let box = lines[index].boundingBox
            return blocks.indices
                .filter { blocks[$0].rect.intersects(box) }
                .min { a, b in
                    let areaA = blocks[a].rect.width * blocks[a].rect.height
                    let areaB = blocks[b].rect.width * blocks[b].rect.height
                    return areaA < areaB
                }
        }
        return nil
    }

    /// Maps a click on the preview back to the box under it: a text line if
    /// there is one, otherwise the smallest layout region that contains it.
    private func hitTest(_ point: CGPoint, renderedSize: CGSize) -> PreviewSelection? {
        let pixel = pixelSize
        guard renderedSize.width > 0, renderedSize.height > 0,
              pixel.width > 0, pixel.height > 0 else { return nil }
        let inImage = CGPoint(x: point.x / renderedSize.width * pixel.width,
                              y: point.y / renderedSize.height * pixel.height)

        if let index = lines.firstIndex(where: { $0.boundingBox.contains(inImage) }) {
            return .line(index)
        }
        let containing = blocks.indices.filter { blocks[$0].rect.contains(inImage) }
        if let smallest = containing.min(by: { a, b in
            let areaA = blocks[a].rect.width * blocks[a].rect.height
            let areaB = blocks[b].rect.width * blocks[b].rect.height
            return areaA < areaB
        }) {
            return .block(smallest)
        }
        // A click on blank paper clears the selection rather than keeping a
        // highlight the user has moved on from.
        return nil
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
            HStack(spacing: 10) {
                // What to look at is the header: three views of one result.
                let panes = availablePanes
                if item.status == .completed, panes.count > 1,
                   !(pageText.text.isEmpty && pageText.markdown.isEmpty) {
                    Picker("Result view", selection: $resultPane) {
                        ForEach(panes) { pane in Text(pane.label).tag(pane) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                } else {
                    Text("Results")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                if item.status == .processing {
                    Text("Recognizing \(item.processingProgress.percentText)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
                Spacer()

                // Three quiet icons rather than three bordered buttons: they
                // are always in the same place, and the tooltips name them.
                HStack(spacing: 10) {
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
                            Image(systemName: showCopied ? "checkmark" : "doc.on.doc")
                                .foregroundStyle(showCopied ? Color.accentColor : Color.secondary)
                                .frame(width: 18)
                        }
                        .help(showCopied ? "Copied" : "Copy this file's results")
                    }

                    if item.isExportable, #available(macOS 15.0, *) {
                        Button {
                            translating = true
                        } label: {
                            Image(systemName: "character.bubble")
                        }
                        .accessibilityLabel("Translate")
                        .help("Translate the results on this Mac with macOS's built-in translation")
                        .sheet(isPresented: $translating) {
                            TranslationSheet(items: [item])
                        }
                    }

                    if item.isExportable {
                        Button {
                            vm.exportItems(ids: [item.id])
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .help("Export only the results for “\(item.fileName)”")
                    }
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .frame(height: Self.paneHeaderHeight)
            .background(.bar)

            Divider()

            // Only what needs doing gets a banner; what is merely worth
            // knowing goes in the line at the bottom.
            if item.status == .completed, let page, page.needsReview {
                notesBanner(for: page)
                Divider()
            }

            // Content
            textContent

            if item.status == .completed, let footer = footerLine {
                Divider()
                Text(footer)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(footer)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                    .background(.bar)
            }
        }
    }

    /// Both panes' header bars, the same height so they read as one band.
    private static let paneHeaderHeight: CGFloat = 40

    /// Who read the page, how long it took, and anything worth knowing that
    /// is not a problem: "正文取自 PDF 原生文字层".
    private var footerLine: String? {
        let info = page?.allNotes.filter { $0.severity == .info }.map(\.message) ?? []
        let parts = [resultSummary].compactMap { $0 } + info
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var textContent: some View {
        switch item.status {
        case .pending:
            statusPlaceholder(
                icon: "circle.dashed",
                title: String(localized: "Waiting for Recognition"),
                subtitle: item.resume.map {
                    String(localized: "\($0.read) of \($0.total) pages read last time. Click Start Recognition to read only the remaining pages")
                } ?? String(localized: "Click Start Recognition in the toolbar to process this file"),
                color: .secondary
            )

        case .processing:
            VStack(spacing: 20) {
                ProgressView()
                    .controlSize(.large)
                Text("Recognizing…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                VStack(spacing: 6) {
                    ProgressView(value: item.processingProgress)
                        .tint(.accentColor)
                    Text(item.pageCount > 1
                         ? String(localized: "\(item.processingProgress.percentText) · \(item.pagesDone)/\(item.pageCount) pages read")
                         : item.processingProgress.percentText)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 40)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .completed:
            if pageText.text.isEmpty && pageText.markdown.isEmpty {
                statusPlaceholder(
                    icon: "text.slash",
                    title: String(localized: "No Text Found"),
                    subtitle: pageCount > 1 ? String(localized: "This page may not contain any recognizable text")
                                            : String(localized: "This image may not contain any recognizable text"),
                    color: .orange
                )
            } else {
                VStack(spacing: 0) {
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
                                    labelForSource: regionTag(for:),
                                    readerForSource: reader(for:),
                                    kindForSource: { index in
                                        guard blocks.indices.contains(index), let page else { return .text }
                                        return .of(blocks[index].text, label: blocks[index].label,
                                                   source: blocks[index].source ?? page.blockSource)
                                    },
                                    onHover: { source in
                                        // Only the page scrolls this pane; the
                                        // pane moving under its own pointer
                                        // would fight the user.
                                        hoveringPage = false
                                        hovered = source.map { .block($0) }
                                    },
                                    onTap: { source in
                                        selectedInPane = true
                                        selection = .block(source)
                                    },
                                    textForSource: { index in
                                        blocks.indices.contains(index)
                                            ? blocks[index].text : nil
                                    },
                                    onCorrect: page?.derivesFromBlocks == true
                                        ? { [pageIndex] index, text in
                                            vm.correctBlock(itemID: item.id, page: pageIndex,
                                                            blockIndex: index, text: text)
                                        }
                                        : nil,
                                    noteForSource: { index in
                                        blocks.indices.contains(index) ? blocks[index].review : nil
                                    },
                                    onReview: { [pageIndex] index in
                                        vm.startReview(itemID: item.id, page: pageIndex, block: index)
                                    },
                                    onReread: vm.canReread(item)
                                        ? { [pageIndex] index in
                                            vm.rereadBlock(itemID: item.id, page: pageIndex,
                                                           blockIndex: index)
                                        }
                                        : nil)
                                    // Each region is one thing to click, select
                                    // and double-click to edit; selecting words
                                    // inside it took the click instead, behind
                                    // an I-beam. Text is copied with the copy
                                    // icon, or selected in the 纯文本 pane.
                                    .textSelection(.disabled)
                                    .padding(.vertical, 4)
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
                            // A region picked on the page, or turned to from
                            // review, is brought into view; one clicked here
                            // already is.
                            .onChange(of: selectedBlockIndex) { _, source in
                                defer { selectedInPane = false }
                                guard !selectedInPane, let source,
                                      let target = renderedBlocks.first(where: { $0.sourceBlock == source })
                                else { return }
                                withAnimation(.easeOut(duration: 0.2)) {
                                    proxy.scrollTo(target.id, anchor: .center)
                                }
                            }
                        }
                    case .source:
                        MarkdownWebView(
                            fragments: vm.documentFragments(for: item, page: pageIndex).map { fragment in
                                let region = fragment.source.flatMap { blocks.indices.contains($0) ? blocks[$0] : nil }
                                let editable = region != nil && page?.derivesFromBlocks == true
                                return MarkdownWebView.Fragment(
                                    block: fragment.source, markdown: fragment.markdown,
                                    flagged: region?.review != nil,
                                    text: editable ? region?.text : nil,
                                    kind: editable ? fragment.source.map(webKind(for:)) : nil)
                            },
                            figures: vm.renderFigures ? figures : [],
                            selected: selectedBlockIndex,
                            onSelect: { source in
                                selectedInPane = true
                                selection = .block(source)
                            },
                            onSave: { [pageIndex] source, text in
                                vm.correctBlock(itemID: item.id, page: pageIndex,
                                                blockIndex: source, text: text)
                            })
                    case .plain:
                        ScrollView {
                            Text(pageText.text)
                                .font(.body)
                                .textSelection(.enabled)
                                .lineSpacing(4)
                                .padding(16)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .task(id: renderKey) { await refreshDocument() }
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
                Text("Cancelled")
                    .font(.title3)
                    .fontWeight(.semibold)
                if let resume = item.resume {
                    // The pages read before the stop are kept; reading on
                    // reads only the rest.
                    Text("Recognition stopped partway, with \(resume.read) of \(resume.total) pages read. Resuming reads only the remaining pages.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                    HStack(spacing: 10) {
                        Button("Resume") { vm.resumeItems(ids: [item.id]) }
                            .buttonStyle(.borderedProminent)
                        Button("Start Over") { vm.retryItems(ids: [item.id]) }
                            .buttonStyle(.bordered)
                    }
                    .controlSize(.regular)
                    .disabled(vm.isProcessing)
                } else {
                    Text("Recognition stopped partway through. Only part of this page was read, so no result was kept.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                    Button("Recognize Again") { vm.retryItems(ids: [item.id]) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                        .disabled(vm.isProcessing)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .failed:
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.red)
                Text("Recognition Failed")
                    .font(.title3)
                    .fontWeight(.semibold)
                if let msg = item.errorMessage {
                    Text(msg)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                Button("Retry") { vm.retryItems(ids: [item.id]) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    // A retry cannot start while a run is in flight, so the
                    // button says so instead of doing nothing when pressed.
                    .disabled(vm.isProcessing)
                Button("Copy Diagnostic Info") { vm.copyDiagnostics(for: [item.id]) }
                    .buttonStyle(.link)
                    .help("Copies a report on this file for a bug report: its type, size and the error, but not its name or contents")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// What the header says about the page: who read it, and how sure they
    /// were — the layered routing, at a glance.
    private var resultSummary: String? {
        var parts: [String] = []
        if let page {
            let readers = page.readers
            if readers.count > 1 || item.engine == .auto {
                parts += readers.map { String(localized: "\($0.source.label) \($0.count) blocks") }
            } else if !page.blocks.isEmpty {
                parts.append(String(localized: "\(page.blocks.count) regions"))
            }
            // Vision's confidences are coarse steps, not a measure worth
            // averaging; PP-OCRv6's are per-character probabilities.
            if !page.lines.isEmpty, item.engine == .paddleOCR || item.engine == .auto {
                let mean = page.lines.reduce(0) { $0 + $1.confidence } / Double(page.lines.count)
                parts.append(String(localized: "\(page.lines.count) lines · Confidence \(mean.percentText)"))
            } else if !page.lines.isEmpty, page.blocks.isEmpty {
                parts.append(String(localized: "\(page.lines.count) lines"))
            }
        }
        if item.reusedCachedResult {
            parts.append(String(localized: "Reused earlier result"))
        } else if let elapsed = item.elapsed {
            parts.append(Duration.seconds(elapsed).formatted(
                .units(allowed: [.minutes, .seconds], width: .abbreviated,
                       fractionalPart: elapsed < 60 ? .show(length: 1) : .hide)))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// What the quality check found on this page, said as what was observed.
    private func notesBanner(for page: PageResult) -> some View {
        let warnings = page.allNotes.filter { $0.severity == .warning }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("\(warnings.count) items on this page need review")
                    .fontWeight(.semibold)
                Spacer()
                if let next = nextPageNeedingReview {
                    Button("Next Page →") { pageIndex = next }
                        .help("Go to page \(next + 1)")
                }
                Button("Review") { vm.startReview(itemID: item.id, page: pageIndex) }
                    .fontWeight(.semibold)
                    .help("Go through them one by one in Review (⌘2)")
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { showingNotes.toggle() }
                } label: {
                    Image(systemName: showingNotes ? "chevron.up" : "chevron.down")
                }
                .help(showingNotes ? "Collapse" : "Expand")
            }
            .buttonStyle(.borderless)
            if showingNotes {
                ForEach(Array(warnings.enumerated()), id: \.offset) { _, note in
                    noteRow(note, in: page)
                }
            }
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.10))
    }

    private func noteRow(_ note: ReviewNote, in page: PageResult) -> some View {
        let region = note.block.flatMap { index in
            page.blocks.indices.contains(index) ? page.blocks[index] : nil
        }
        return Button {
            if let index = note.block { selection = .block(index) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(region.map { "\($0.readingOrder + 1) · \($0.label.label)" } ?? "Whole page")
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 56, alignment: .leading)
                Text(note.message)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(note.block == nil)
        .help(note.block == nil ? "" : "Locate this region in the preview")
    }

    /// The next page after this one with something flagged, wrapping round.
    private var nextPageNeedingReview: Int? {
        let count = item.pages.count
        guard count > 1 else { return nil }
        return (1..<count).map { (pageIndex + $0) % count }
            .first { item.pages[$0].needsReview }
    }

    /// Keeps `resultPane` on something this result actually has.
    private func normalisePane() {
        let panes = availablePanes
        guard !panes.contains(resultPane) else { return }
        resultPane = panes.first ?? .plain
    }

    /// How the rendered Markdown edits a region in place.
    private func webKind(for index: Int) -> String {
        guard blocks.indices.contains(index), let page else { return "text" }
        switch RegionContentKind.of(blocks[index].text, label: blocks[index].label,
                                    source: blocks[index].source ?? page.blockSource) {
        case .table:   return "table"
        case .formula: return "formula"
        case .text:    return "text"
        }
    }

    /// What a region is: its place in the reading order and its kind.
    private func regionTag(for index: Int) -> String? {
        guard blocks.indices.contains(index) else { return nil }
        let block = blocks[index]
        var tag = "\(block.readingOrder + 1) · \(block.label.label)"
        if block.isCorrected { tag += String(localized: " · Edited") }
        return tag
    }

    /// Who read a region, with PP-OCRv6's confidence when it was PP-OCRv6 —
    /// the layered routing, on the region itself.
    private func reader(for index: Int) -> String? {
        guard blocks.indices.contains(index), let page else { return nil }
        let source = blocks[index].source ?? page.blockSource
        if let confidence = page.ocrConfidence(ofBlock: index) {
            return "\(source.label) · \(confidence.percentText)"
        }
        return source.label
    }

    private func refreshDocument() async {
        renderedBlocks = MDParser.parse(fragments: vm.documentFragments(for: item, page: pageIndex))
        let image = pageImage?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        figures = page.map { DocumentFigures.crops(for: $0, image: image, dropping: vm.droppedLabels) } ?? []
    }

    /// Changes whenever the pane has a different document to show — a new
    /// selection, a result that has just finished, or the page-furniture switch
    /// having added or removed regions.
    private var renderKey: String {
        "\(item.id)#\(pageIndex)#\(pageText.markdown.count)#\(blocks.count)#\(vm.keptAuxiliary.count)#\(pageImage != nil)"
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
    /// Draw every line, or only the one being pointed at.
    var showsAll = true

    var body: some View {
        GeometryReader { geo in
            let fitted = Self.fittedRect(for: imageSize, in: geo.size)
            if fitted.width > 0, imageSize.width > 0, imageSize.height > 0 {
                Canvas { context, _ in
                    let sx = fitted.width / imageSize.width
                    let sy = fitted.height / imageSize.height
                    for (index, line) in lines.enumerated()
                    where showsAll || index == highlighted || index == selected {
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
                        let tint = Self.color(for: line.confidence)
                        context.fill(path, with: .color(tint.opacity(isSelected ? 0.28
                                                                    : isHovered ? 0.18 : 0.10)))
                        context.stroke(path, with: .color(tint.opacity(lit ? 0.95 : 0.75)),
                                       lineWidth: isSelected ? 1.5 : isHovered ? 1.2 : 0.75)
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
    /// Draw every region, or only the one being pointed at. Off, the page is
    /// the page and a box appears where you look; on, the whole analysis is
    /// visible at once.
    var showsAll = true
    /// Regions being left out of the document, drawn dashed.
    var dropped: Set<PPLayoutLabel> = []

    var body: some View {
        GeometryReader { geo in
            let fitted = TextBoxOverlay.fittedRect(for: imageSize, in: geo.size)
            if fitted.width > 0, imageSize.width > 0, imageSize.height > 0 {
                Canvas { context, _ in
                    let sx = fitted.width / imageSize.width
                    let sy = fitted.height / imageSize.height
                    // Chips are placed after the boxes so a label is never
                    // hidden under the next region's outline, and each one is
                    // put where it does not sit on top of another.
                    var placed: [CGRect] = []

                    for index in visibleIndices {
                        let block = blocks[index]
                        let rect = CGRect(x: fitted.minX + block.rect.minX * sx,
                                          y: fitted.minY + block.rect.minY * sy,
                                          width: block.rect.width * sx,
                                          height: block.rect.height * sy)
                        let isSelected = index == selected
                        let isHovered = index == highlighted
                        let lit = isSelected || isHovered
                        let isDropped = dropped.contains(block.label)
                        // One colour for every region, orange for one that
                        // needs a look, grey for one left out of the document;
                        // being pointed at makes it heavier, not a different
                        // colour. The chip already says what the region is.
                        let tint = isDropped ? Color.secondary : Self.color(for: block)
                        let path = Path(roundedRect: rect, cornerRadius: 2)

                        // A region waiting for review has to be found at a
                        // glance on a busy page: heavier, tinted, and labelled
                        // with what it is waiting for.
                        let isFlagged = block.review != nil && !isDropped
                        context.fill(path, with: .color(tint.opacity(lit ? 0.18
                                                                    : isFlagged ? 0.14
                                                                    : isDropped ? 0.04 : 0.08)))
                        context.stroke(path, with: .color(tint.opacity(isDropped && !lit ? 0.55 : isFlagged ? 1 : 0.8)),
                                       style: StrokeStyle(lineWidth: isSelected ? 2.25
                                                              : isFlagged ? 2
                                                              : isHovered ? 1.4 : 0.75,
                                                          dash: isDropped ? [3, 2.5] : []))

                        let caption = isFlagged
                            ? String(localized: "\(block.readingOrder + 1) · Needs review")
                            : lit || !showsAll
                                ? "\(block.readingOrder + 1) \(block.label.label)"
                                : "\(block.readingOrder + 1)"
                        // Dark on orange: white on it is too faint at this size.
                        let ink: Color = isFlagged ? Color.black.opacity(0.82) : .white
                        var badge = context.resolve(
                            Text(caption)
                                .font(.system(size: isFlagged ? 10 : 9, weight: .bold))
                                .foregroundStyle(ink))
                        badge.shading = .color(ink)
                        let size = badge.measure(in: CGSize(width: 240, height: rect.height))
                        let chip = Self.chipPlacement(for: rect, size: CGSize(width: size.width + 8,
                                                                             height: size.height + 4),
                                                      avoiding: placed, within: fitted,
                                                      outsideFirst: isFlagged)
                        placed.append(chip)
                        context.fill(Path(roundedRect: chip, cornerRadius: 3),
                                     with: .color(tint.opacity(isDropped && !lit ? 0.5 : 1)))
                        context.draw(badge, at: CGPoint(x: chip.midX, y: chip.midY), anchor: .center)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// Which regions to draw: all of them, or just the one being pointed at.
    private var visibleIndices: [Int] {
        guard !showsAll else { return Array(blocks.indices) }
        // What needs review stays marked even with the other boxes hidden.
        let flagged = blocks.indices.filter { blocks[$0].review != nil }
        return Array(Set([highlighted, selected].compactMap { $0 } + flagged))
            .filter(blocks.indices.contains).sorted()
    }

    /// Somewhere for the label that is not on top of another label.
    ///
    /// A page with regions packed against each other stacks its numbers into an
    /// unreadable pile otherwise. The corners are tried in turn and the first
    /// free one wins; if the region is boxed in on all four, the label goes
    /// where it belongs and overlaps, which is at least predictable.
    ///
    /// `outsideFirst` tries above and below the region before its corners: on
    /// a region flagged for review the label must not cover what needs
    /// checking.
    static func chipPlacement(for rect: CGRect, size: CGSize,
                              avoiding placed: [CGRect], within bounds: CGRect,
                              outsideFirst: Bool = false) -> CGRect {
        var candidates = [
            CGPoint(x: rect.minX, y: rect.minY),                                  // inside top left
            CGPoint(x: rect.maxX - size.width, y: rect.minY),                     // inside top right
            CGPoint(x: rect.minX, y: rect.maxY - size.height),                    // inside bottom left
            CGPoint(x: rect.maxX - size.width, y: rect.maxY - size.height),       // inside bottom right
            CGPoint(x: rect.minX, y: rect.minY - size.height - 1),                // just above
            CGPoint(x: rect.minX, y: rect.maxY + 1),                              // just below
            CGPoint(x: rect.minX - size.width - 1, y: rect.minY),                 // just left
        ]
        if outsideFirst {
            candidates = Array(candidates[4...]) + Array(candidates[..<4])
        }
        for origin in candidates {
            let chip = CGRect(origin: origin, size: size)
            guard bounds.contains(chip) else { continue }
            if !placed.contains(where: { $0.intersects(chip) }) { return chip }
        }
        return CGRect(origin: candidates[0], size: size)
    }

    /// The app's accent, and orange for a region flagged for review — the one
    /// distinction worth a colour. Telling a table from a formula by hue was
    /// eight colours to learn for something the region's label already says.
    static func color(for block: PPLayoutBlock) -> Color {
        block.review != nil ? .orange : .accentColor
    }
}

// MARK: - Page previews

/// Decodes the page shown in the preview, on demand.
///
/// The list used to keep every file's full image in memory as its thumbnail.
/// Now only the pages actually looked at are decoded, rendered the same way
/// the recogniser rendered them — so the boxes fit — and a handful are kept.
enum PagePreviews {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 24
        return cache
    }()

    static func image(for item: ImageItem, page: Int) async -> NSImage? {
        if item.pages.indices.contains(page), let rectified = item.pages[page].rectified {
            return rectified
        }
        let key = "\(item.url.path)#\(page)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let url = item.url, isPDF = item.isPDF
        let image = await Task.detached(priority: .userInitiated) { () -> NSImage? in
            let decoded = isPDF ? PDFSource(url: url)?.render(page: page)?.image
                                : PageImages.image(at: url, frame: page)
            return decoded.map(ImageItem.page(from:))
        }.value
        if let image { cache.setObject(image, forKey: key) }
        return image
    }

    static func pageCount(of item: ImageItem) async -> Int {
        let url = item.url, isPDF = item.isPDF
        return await Task.detached(priority: .utility) {
            isPDF ? (PDFSource(url: url)?.pageCount ?? 1) : max(1, PageImages.frameCount(of: url))
        }.value
    }
}
