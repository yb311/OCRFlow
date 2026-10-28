import SwiftUI

// MARK: - Queue

/// The sidebar in review mode: everything flagged, grouped by file.
///
/// The 待复核 filter used to narrow the file list to files with a flag
/// somewhere in them, which still left the flag itself to be found page by
/// page. Here each flag is its own row.
struct ReviewQueueView: View {
    @EnvironmentObject var vm: OCRViewModel

    private struct FileGroup: Identifiable {
        let id: UUID
        let fileName: String
        let entries: [ReviewEntry]
    }

    private func groups(of entries: [ReviewEntry]) -> [FileGroup] {
        var order: [UUID] = []
        var byFile: [UUID: [ReviewEntry]] = [:]
        for entry in entries {
            if byFile[entry.itemID] == nil { order.append(entry.itemID) }
            byFile[entry.itemID, default: []].append(entry)
        }
        return order.map { id in
            FileGroup(id: id, fileName: byFile[id]?.first?.fileName ?? "", entries: byFile[id] ?? [])
        }
    }

    // Deferred for the same reason as the file list's selection: the list
    // writes it back while it is being drawn.
    private var selection: Binding<ReviewEntry.Key?> {
        Binding(
            get: { vm.reviewFocus },
            set: { key in Task { @MainActor in vm.reviewFocus = key } }
        )
    }

    var body: some View {
        let entries = vm.reviewEntries
        if entries.isEmpty {
            // The pane beside it already says so in full; the list only has
            // to not look broken.
            Text("Nothing to Review")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(selection: selection) {
                ForEach(groups(of: entries)) { group in
                    Section {
                        ForEach(group.entries) { entry in
                            ReviewQueueRow(entry: entry).tag(entry.id)
                        }
                    } header: {
                        HStack {
                            Text(group.fileName).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text("\(group.entries.count)").monospacedDigit()
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }
}

private struct ReviewQueueRow: View {
    @EnvironmentObject var vm: OCRViewModel
    let entry: ReviewEntry

    private var region: PPLayoutBlock? {
        guard let block = entry.block,
              let item = vm.items.first(where: { $0.id == entry.itemID }),
              item.pages.indices.contains(entry.page),
              item.pages[entry.page].blocks.indices.contains(block) else { return nil }
        return item.pages[entry.page].blocks[block]
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if entry.reason == .rereading {
                ProgressView().controlSize(.mini)
            } else {
                Circle().fill(.orange).frame(width: 7, height: 7)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.message)
                    .lineLimit(2)
                Text("Page \(entry.page + 1) · \(region?.label.label ?? String(localized: "Whole page"))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Detail

/// One flagged item at a time: the page as it is, and the result as it will
/// read — which is also where it is corrected.
struct ReviewDetailView: View {
    @EnvironmentObject var vm: OCRViewModel

    fileprivate enum Choice: Hashable { case current, alternative }

    /// Where in the queue the pane was, so that when the item on screen is
    /// settled and leaves the queue, the next one takes its place.
    @State private var position = 0
    @State private var draft = ""
    @State private var choice: Choice = .current
    @State private var pageImage: NSImage?
    @State private var crop: NSImage?

    var body: some View {
        let entries = vm.reviewEntries
        Group {
            if entries.isEmpty {
                ContentUnavailableView {
                    Label("All Reviewed", systemImage: "checkmark.circle")
                } description: {
                    Text("Your corrections are saved in the results and will be included in exports.")
                } actions: {
                    Button("Back to Workspace") { vm.mode = .workspace }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                let index = currentIndex(in: entries)
                pane(for: entries[index], at: index, of: entries)
            }
        }
        .onAppear { settleFocus(entries) }
        .onChange(of: entries.map(\.id)) { _, _ in settleFocus(vm.reviewEntries) }
    }

    private func currentIndex(in entries: [ReviewEntry]) -> Int {
        if let focus = vm.reviewFocus, let index = entries.firstIndex(where: { $0.id == focus }) {
            return index
        }
        return min(position, entries.count - 1)
    }

    /// Keeps the focus on something still in the queue — the item that moved
    /// into the settled one's place.
    private func settleFocus(_ entries: [ReviewEntry]) {
        guard !entries.isEmpty else { return }
        let index = currentIndex(in: entries)
        position = index
        if vm.reviewFocus != entries[index].id {
            let key = entries[index].id
            Task { @MainActor in vm.reviewFocus = key }
        }
    }

    private func move(by step: Int, in entries: [ReviewEntry]) {
        guard !entries.isEmpty else { return }
        let index = (currentIndex(in: entries) + step + entries.count) % entries.count
        position = index
        vm.reviewFocus = entries[index].id
    }

    // MARK: Pane

    /// Everything the pane needs to know about the region on screen.
    private struct Context {
        let page: PageResult
        let index: Int
        let block: PPLayoutBlock
        var source: PPTextSource { block.source ?? page.blockSource }
    }

    private func context(for entry: ReviewEntry) -> Context? {
        guard case let .region(index) = entry.origin,
              let item = vm.items.first(where: { $0.id == entry.itemID }),
              item.pages.indices.contains(entry.page),
              item.pages[entry.page].blocks.indices.contains(index) else { return nil }
        let page = item.pages[entry.page]
        return Context(page: page, index: index, block: page.blocks[index])
    }

    @ViewBuilder
    private func pane(for entry: ReviewEntry, at index: Int, of entries: [ReviewEntry]) -> some View {
        let item = vm.items.first { $0.id == entry.itemID }
        let region = context(for: entry)
        let rereading = entry.reason == .rereading

        VStack(spacing: 0) {
            header(entry: entry, region: region?.block, index: index, count: entries.count, entries: entries)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    reason(entry.message, rereading: rereading)

                    section(region == nil ? String(localized: "This page") : String(localized: "Original")) {
                        HStack(alignment: .center, spacing: 16) {
                            Group {
                                if let crop {
                                    Image(nsImage: crop)
                                        .resizable()
                                        .interpolation(.high)
                                        .scaledToFit()
                                        .frame(maxHeight: region == nil ? 320 : 200)
                                } else {
                                    ProgressView().frame(height: 80)
                                }
                            }
                            .frame(maxWidth: .infinity)

                            if let pageImage, let item, item.pages.indices.contains(entry.page), region != nil {
                                pageLocator(image: pageImage, page: item.pages[entry.page],
                                            block: entry.block, entry: entry)
                            }
                        }
                    }

                    if let region {
                        result(for: region, rereading: rereading)
                    } else {
                        Text("This note is about the whole page, with no single region to edit. Confirming changes no text.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 22)
                .frame(maxWidth: 780)
                .frame(maxWidth: .infinity)
            }

            Divider()
            actions(entry: entry, item: item, region: region, rereading: rereading, entries: entries)
        }
        // A new item, or the same one after the model has read it again.
        .task(id: "\(entry.id.hashValue)#\(region?.block.text ?? "")#\(region?.block.alternative?.text ?? "")") {
            draft = region?.block.text ?? ""
            choice = .current
        }
        .task(id: entry.id) {
            await loadImages(item: item, pageIndex: entry.page, block: entry.block)
        }
    }

    private func reason(_ message: String, rereading: Bool) -> some View {
        HStack(spacing: 8) {
            if rereading {
                ProgressView().controlSize(.small)
                Text(message).foregroundStyle(.secondary)
            } else {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    .accessibilityLabel("Warning")
                Text(message)
            }
        }
        .font(.callout)
    }

    /// A caption over a quiet panel — the one shape every part of the pane
    /// takes, so the page and the result read as a pair.
    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        section(title, accessory: { EmptyView() }, content: content)
    }

    private func section<Accessory: View, Content: View>(_ title: String,
                                                         @ViewBuilder accessory: () -> Accessory,
                                                         @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                accessory()
            }
            content()
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
        }
    }

    /// The result: one rendering, edited where it stands. With two readings,
    /// a small switch picks between them and what differs is marked.
    private func result(for region: Context, rereading: Bool) -> some View {
        let alternative = region.block.alternative
        let other = choice == .alternative ? region.block.text : alternative?.text
        let shownSource = choice == .alternative ? (alternative?.source ?? region.source) : region.source
        let kind = RegionContentKind.of(draft, label: region.block.label, source: shownSource)
        let edited = draft != region.block.text && draft != alternative?.text
        // Marks only appear between two readings of the same kind: a table
        // and PP-OCR's lines of the same table share no cells to compare.
        let otherSource = choice == .alternative ? region.source : (alternative?.source ?? region.source)
        let comparable = other.map { RegionContentKind.of($0, label: region.block.label, source: otherSource) == kind }
            ?? false

        let currentTitle = title(source: region.source, detail: detail(forCurrentOf: region))
        let alternativeTitle = alternative.map { title(source: $0.source, detail: detail(for: $0, in: region)) }
        // The title says what will be saved — a choice, not a view.
        let heading: String = {
            if edited { return String(localized: "Result · Edited by hand") }
            guard let alternativeTitle else { return region.block.isCorrected ? String(localized: "Result · Edited") : String(localized: "Results") }
            return String(localized: "Result · Using \(choice == .alternative ? alternativeTitle : currentTitle)")
        }()

        return VStack(alignment: .leading, spacing: 6) {
            section(heading) {
                if let alternative, let alternativeTitle {
                    // Both readings in view at once, one row each: the chosen
                    // one is the editor, the other stays as it was read, and
                    // what differs is marked in both.
                    VStack(alignment: .leading, spacing: 0) {
                        readingRow(title: currentTitle, isChosen: choice == .current,
                                   text: region.block.text, label: region.block.label, source: region.source,
                                   other: alternative.text, edited: edited, rereading: rereading) {
                            choose(.current, region: region)
                        }
                        Divider().padding(.vertical, 2)
                        readingRow(title: alternativeTitle, isChosen: choice == .alternative,
                                   text: alternative.text, label: region.block.label, source: alternative.source,
                                   other: region.block.text, edited: edited, rereading: rereading) {
                            choose(.alternative, region: region)
                        }
                    }
                } else {
                    InlineRegionEditor(kind: kind, text: $draft, comparedTo: other)
                        .disabled(rereading)
                }
            }
            Text(hint(for: kind, alternatives: alternative != nil, marked: comparable && kind != .formula))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private func choose(_ newChoice: Choice, region: Context) {
        guard choice != newChoice else { return }
        choice = newChoice
        draft = newChoice == .alternative ? (region.block.alternative?.text ?? region.block.text) : region.block.text
    }

    /// One reading as a choice: a radio mark, who read it, and what they read.
    /// The chosen row is edited where it stands; the other is a button that
    /// chooses it.
    @ViewBuilder
    private func readingRow(title: String, isChosen: Bool, text: String, label: PPLayoutLabel,
                            source: PPTextSource, other: String, edited: Bool, rereading: Bool,
                            choose: @escaping () -> Void) -> some View {
        let kind = RegionContentKind.of(isChosen ? draft : text, label: label, source: source)
        let header = HStack(spacing: 8) {
            Image(systemName: isChosen ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(isChosen ? Color.accentColor : Color.secondary)
                .accessibilityHidden(true)
            Text(title)
                .fontWeight(isChosen ? .semibold : .regular)
                .foregroundStyle(isChosen ? Color.primary : Color.secondary)
            if isChosen && edited {
                Text("Edited").foregroundStyle(Color.accentColor)
            }
            Spacer(minLength: 0)
        }
        .font(.caption)

        Group {
            if isChosen {
                VStack(alignment: .leading, spacing: 6) {
                    header
                    InlineRegionEditor(kind: kind, text: $draft, comparedTo: other)
                        .disabled(rereading)
                        .padding(.leading, 22)
                }
            } else {
                Button(action: choose) {
                    VStack(alignment: .leading, spacing: 6) {
                        header
                        RegionContentView(text: text, kind: kind, comparedTo: draft)
                            .font(.body)
                            .padding(.leading, 22)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .opacity(0.8)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Use this reading instead")
                .accessibilityLabel("Use \(title)")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isChosen ? Color.accentColor.opacity(0.08) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .accessibilityAddTraits(isChosen ? .isSelected : [])
    }

    private func hint(for kind: RegionContentKind, alternatives: Bool, marked: Bool) -> String {
        let edit: String
        switch kind {
        case .table:   edit = String(localized: "Click a cell to edit it")
        case .formula: edit = String(localized: "Click the formula to edit it")
        case .text:    edit = String(localized: "Click the text to edit it")
        }
        if marked { return String(localized: "Yellow marks where the two readings differ · Click the other reading to use it instead · \(edit)") }
        return alternatives ? String(localized: "Click the other reading to use it instead · \(edit)") : edit
    }

    private func title(source: PPTextSource, detail: String?) -> String {
        [source.label, detail].compactMap { $0 }.joined(separator: " · ")
    }

    /// How the reading on screen came about, in a few words.
    private func detail(forCurrentOf region: Context) -> String? {
        if let confidence = region.page.ocrConfidence(ofBlock: region.index) {
            return confidence.percentText
        }
        return region.block.alternative?.note == .beforeReread ? String(localized: "After reread") : nil
    }

    private func detail(for alternative: AlternativeReading, in region: Context) -> String? {
        if alternative.source == .plainOCR,
           let confidence = region.page.ocrConfidence(ofBlock: region.index, evenIfReplaced: true) {
            return [alternative.note?.label, confidence.percentText]
                .compactMap { $0 }.joined(separator: " · ")
        }
        return alternative.note?.label
    }

    private func header(entry: ReviewEntry, region: PPLayoutBlock?, index: Int, count: Int,
                        entries: [ReviewEntry]) -> some View {
        HStack(spacing: 6) {
            Text(entry.fileName).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text("Page \(entry.page + 1) · \(region.map { "\($0.readingOrder + 1) \($0.label.label)" } ?? String(localized: "Whole page"))")
                .fontWeight(.medium)
            Spacer()
            Text("\(index + 1) / \(count)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Button { move(by: -1, in: entries) } label: {
                Label("Previous", systemImage: "chevron.left").labelStyle(.iconOnly)
            }
                .keyboardShortcut("[", modifiers: .command)
                .help("Previous (⌘[)")
            Button { move(by: 1, in: entries) } label: {
                Label("Next", systemImage: "chevron.right").labelStyle(.iconOnly)
            }
                .keyboardShortcut("]", modifiers: .command)
                .help("Next (⌘])")
        }
        .buttonStyle(.borderless)
        .font(.callout)
        .padding(.horizontal, 16)
        .frame(height: 40)
        .background(.bar)
    }

    private func actions(entry: ReviewEntry, item: ImageItem?, region: Context?, rereading: Bool,
                         entries: [ReviewEntry]) -> some View {
        let canReread = item.map(vm.canReread) ?? false
        let truncated = entry.reason.isOutputLimit
        return HStack(spacing: 8) {
            Button {
                confirm(entry, region: region)
            } label: {
                Text("Confirm").frame(minWidth: 56)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(rereading)
            .help("Keep the current result and go to the next one (⌘↩)")

            Button("Skip") { move(by: 1, in: entries) }
                .help("Leave it for now and go to the next one (⌘])")

            if let block = entry.block, region != nil {
                Button {
                    vm.rereadBlock(itemID: entry.itemID, page: entry.page, blockIndex: block)
                } label: {
                    Label(truncated ? "Reread with Higher Limit" : "Reread", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(rereading || !canReread)
                .help(canReread
                      ? "Read again with PaddleOCR-VL using a higher output limit; if the result differs you can pick one (⌥⌘R)"
                      : "Download the PaddleOCR-VL model in Settings first")
            }

            Spacer()

            Button("Show in Document") { vm.showInDocument(entry) }
                .buttonStyle(.borderless)
                .foregroundStyle(Color.accentColor)
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
        .background(.bar)
    }

    /// The whole page, small, with the region outlined — where on the page
    /// the crop came from.
    private func pageLocator(image: NSImage, page: PageResult, block: Int?, entry: ReviewEntry) -> some View {
        let size = page.size.width > 0 ? page.size : image.size
        let blocks = block.flatMap { page.blocks.indices.contains($0) ? [page.blocks[$0]] : nil } ?? []
        return Button { vm.showInDocument(entry) } label: {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .overlay { LayoutBlockOverlay(blocks: blocks, imageSize: size, selected: 0) }
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
        }
        .buttonStyle(.plain)
        .frame(width: 84)
        .help("Show this in the document")
    }

    // MARK: Actions

    private func confirm(_ entry: ReviewEntry, region: Context?) {
        let entries = vm.reviewEntries
        position = entries.firstIndex(where: { $0.id == entry.id }) ?? position
        if let region {
            // Taken as it stands, the chosen reading keeps its reader's name;
            // anything typed over it is a correction.
            let chosen = choice == .alternative ? region.block.alternative : nil
            let chosenText = chosen?.text ?? region.block.text
            let chosenSource = chosen?.source ?? region.source
            vm.settleRegion(itemID: entry.itemID, page: entry.page, blockIndex: region.index,
                            text: draft, chosenSource: draft == chosenText ? chosenSource : nil)
        } else {
            vm.resolveReview(entry)
        }
        // The settled item leaves the queue; whatever moves into its place is next.
        vm.reviewFocus = nil
    }

    private func loadImages(item: ImageItem?, pageIndex: Int, block: Int?) async {
        crop = nil
        pageImage = nil
        guard let item, item.pages.indices.contains(pageIndex) else { return }
        let page = item.pages[pageIndex]
        guard let image = await PagePreviews.image(for: item, page: pageIndex) else { return }
        pageImage = image
        guard let block, page.blocks.indices.contains(block),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            crop = image
            return
        }
        // The boxes are in the page as it was read; the preview may have been
        // rendered at another size.
        let sx = CGFloat(cgImage.width) / max(page.size.width, 1)
        let sy = CGFloat(cgImage.height) / max(page.size.height, 1)
        let rect = page.blocks[block].rect.applying(CGAffineTransform(scaleX: sx, y: sy))
        // A little of the surroundings, so a cut-off character at the edge
        // reads as cut off rather than as a different character.
        let margin = max(12, min(rect.width, rect.height) * 0.08)
        let bounds = CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
        let area = rect.insetBy(dx: -margin, dy: -margin).intersection(bounds).integral
        crop = cgImage.cropping(to: area).map(ImageItem.page(from:)) ?? image
    }
}

// MARK: - Region content

/// What a region holds, which decides how it is shown and how it is edited.
enum RegionContentKind {
    case text, table, formula

    static func of(_ text: String, label: PPLayoutLabel, source: PPTextSource) -> RegionContentKind {
        if text.range(of: "<tr", options: .caseInsensitive) != nil, MDParser.parseHTMLTable(text) != nil {
            return .table
        }
        // PP-OCR's reading of a formula is the characters it saw, not LaTeX.
        if label.vlTask == .formula, source.carriesMarkup { return .formula }
        return .text
    }
}

/// A region's text as it will look in the document: a table as a table, a
/// formula set as maths. Given a second reading, what differs from it is
/// marked.
struct RegionContentView: View {
    let text: String
    let kind: RegionContentKind
    var comparedTo: String?

    var body: some View {
        switch kind {
        case .table:
            if let table = MDParser.parseHTMLTable(text) {
                let other = comparedTo.flatMap(MDParser.parseHTMLTable)
                MDTableView(table: table, flagged: other.map(table.cells(differingFrom:)) ?? [])
            } else {
                Text(text)
            }
        case .formula:
            MathBlockView(latex: text)
        case .text:
            if MathInlineText.hasInlineMath(text) {
                MathInlineText(source: text, size: 13)
                    .lineSpacing(3)
            } else {
                Text(TextDiff.marked(text, against: comparedTo))
                    .lineSpacing(3)
            }
        }
    }
}

/// A region edited where it is read.
///
/// The rendering is the editor: prose turns into a field in place when it is
/// clicked, in the same type, with nothing around it; a table is changed a
/// cell at a time; a formula shows its LaTeX only while it is being changed,
/// with the result set live above it.
struct InlineRegionEditor: View {
    let kind: RegionContentKind
    @Binding var text: String
    var comparedTo: String?
    /// Opens straight into editing — for 纠正, which was asked for.
    var startsEditing = false

    @State private var editing = false
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            switch kind {
            case .table:
                EditableTableView(html: $text, comparedTo: comparedTo)
            case .formula:
                formula
            case .text:
                prose
            }
        }
        .onAppear { if startsEditing, kind != .table { begin() } }
        .onChange(of: focused) { _, isFocused in
            if !isFocused { editing = false }
        }
    }

    private func begin() {
        editing = true
        // The field exists once this pass has been drawn.
        Task { @MainActor in focused = true }
    }

    @ViewBuilder
    private var prose: some View {
        if editing {
            TextField("", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.body)
                .lineSpacing(3)
                .focused($focused)
        } else {
            Button(action: begin) {
                Group {
                    if text.isEmpty {
                        Text("(empty)").foregroundStyle(.tertiary)
                    } else {
                        RegionContentView(text: text, kind: .text, comparedTo: comparedTo)
                    }
                }
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Click to edit")
        }
    }

    @ViewBuilder
    private var formula: some View {
        if editing {
            VStack(alignment: .leading, spacing: 10) {
                MathBlockView(latex: text)
                TextField("LaTeX", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .focused($focused)
                    .onSubmit { editing = false }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
            }
        } else {
            Button(action: begin) {
                MathBlockView(latex: text)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Click to edit the formula")
        }
    }
}

// MARK: - Editable table

/// An HTML table as rows of cells that can be changed one at a time and
/// written back.
struct EditableTable: Equatable {
    struct Cell: Equatable {
        var text: String
        var columnSpan = 1
        var rowSpan = 1
        var isHeader = false
    }

    /// Where a cell lands once the row spans above it have pushed it along.
    enum Slot: Hashable {
        case cell(row: Int, index: Int)
        /// Under the `rowspan` of a cell above, or padding at the end of a short row.
        case covered(top: Bool)
    }

    var rows: [[Cell]]

    init?(html: String) {
        let options: NSRegularExpression.Options = [.caseInsensitive, .dotMatchesLineSeparators]
        guard let rowPattern = try? NSRegularExpression(pattern: "<tr[^>]*>(.*?)</tr>", options: options),
              let cellPattern = try? NSRegularExpression(pattern: "<(td|th)([^>]*)>(.*?)</(?:td|th)>",
                                                         options: options) else { return nil }
        func string(_ match: NSTextCheckingResult, _ group: Int, in text: NSString) -> String {
            match.range(at: group).location == NSNotFound ? "" : text.substring(with: match.range(at: group))
        }
        func span(_ name: String, in attributes: String) -> Int {
            guard let range = attributes.range(of: "\(name)\\s*=\\s*\"?'?(\\d+)", options: .regularExpression),
                  let digits = attributes[range].split(whereSeparator: { !$0.isNumber }).last,
                  let value = Int(digits) else { return 1 }
            return max(1, value)
        }

        let source = html as NSString
        rows = rowPattern.matches(in: html, range: NSRange(location: 0, length: source.length)).map { row in
            let body = string(row, 1, in: source)
            let rowSource = body as NSString
            return cellPattern.matches(in: body, range: NSRange(location: 0, length: rowSource.length)).map { cell in
                let attributes = string(cell, 2, in: rowSource)
                return Cell(text: MDParser.plainText(fromHTML: string(cell, 3, in: rowSource)),
                            columnSpan: span("colspan", in: attributes),
                            rowSpan: span("rowspan", in: attributes),
                            isHeader: string(cell, 1, in: rowSource).lowercased() == "th")
            }
        }
        guard !rows.isEmpty else { return nil }
    }

    var html: String {
        func escaped(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\n", with: "<br>")
        }
        return "<table>" + rows.map { row in
            "<tr>" + row.map { cell in
                let tag = cell.isHeader ? "th" : "td"
                var attributes = ""
                if cell.columnSpan > 1 { attributes += " colspan=\"\(cell.columnSpan)\"" }
                if cell.rowSpan > 1 { attributes += " rowspan=\"\(cell.rowSpan)\"" }
                return "<\(tag)\(attributes)>\(escaped(cell.text))</\(tag)>"
            }.joined() + "</tr>"
        }.joined() + "</table>"
    }

    /// The grid as drawn: each row's cells pushed along by the row spans above
    /// them, every row padded to the full width.
    var layout: [[Slot]] {
        var carry: [Int: (remaining: Int, width: Int)] = [:]
        var grid: [[(slot: Slot, width: Int)]] = []
        for (r, row) in rows.enumerated() {
            var slots: [(slot: Slot, width: Int)] = []
            var column = 0
            func fillCarried() {
                while let pending = carry[column] {
                    for _ in 0..<pending.width { slots.append((.covered(top: false), 1)) }
                    carry[column] = pending.remaining > 1 ? (pending.remaining - 1, pending.width) : nil
                    column += pending.width
                }
            }
            fillCarried()
            for (i, cell) in row.enumerated() {
                slots.append((.cell(row: r, index: i), cell.columnSpan))
                if cell.rowSpan > 1 { carry[column] = (cell.rowSpan - 1, cell.columnSpan) }
                column += cell.columnSpan
                fillCarried()
            }
            grid.append(slots)
        }
        let width = grid.map { $0.reduce(0) { $0 + $1.width } }.max() ?? 0
        return grid.map { row in
            var padded = row.map(\.slot)
            var used = row.reduce(0) { $0 + $1.width }
            while used < width { padded.append(.covered(top: true)); used += 1 }
            return padded
        }
    }

    /// True when no cell says it is a header, in which case the first row is
    /// taken to be one — the model writes every cell as `<td>`.
    var hasExplicitHeader: Bool { rows.contains { $0.contains(where: \.isHeader) } }

    /// The cells whose text is not what the other table has in the same place.
    func cells(differingFrom other: EditableTable) -> Set<Slot> {
        var differing = Set<Slot>()
        for (r, row) in rows.enumerated() {
            for (i, cell) in row.enumerated() {
                let theirs = other.rows.indices.contains(r) && other.rows[r].indices.contains(i)
                    ? other.rows[r][i].text.trimmingCharacters(in: .whitespacesAndNewlines) : nil
                if theirs != cell.text.trimmingCharacters(in: .whitespacesAndNewlines) {
                    differing.insert(.cell(row: r, index: i))
                }
            }
        }
        return differing
    }
}

/// A table edited where it is read: each cell shows its rendered text and
/// turns into a field when clicked.
struct EditableTableView: View {
    @Binding var html: String
    /// Another reading of the same table, whose differing cells are marked.
    var comparedTo: String?

    @State private var table: EditableTable?
    @State private var editing: EditableTable.Slot?
    @FocusState private var fieldFocused: Bool

    private let borderColor = Color.secondary.opacity(0.35)

    var body: some View {
        Group {
            if let table {
                ScrollView(.horizontal, showsIndicators: true) {
                    grid(table)
                }
                .fixedSize(horizontal: false, vertical: true)
            } else {
                // Not a table this editor can take apart; its text is still
                // better than nothing.
                TextField("", text: $html, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(.callout, design: .monospaced))
            }
        }
        .onAppear { table = EditableTable(html: html) }
        .onChange(of: html) { _, new in
            // Another reading was picked: start over from it. An edit made
            // here writes the same text back and is left alone.
            if table?.html != new {
                table = EditableTable(html: new)
                editing = nil
            }
        }
        .onChange(of: fieldFocused) { _, focused in
            if !focused { editing = nil }
        }
    }

    private func grid(_ table: EditableTable) -> some View {
        let implicitHeader = !table.hasExplicitHeader && table.rows.count > 1
        let flagged = comparedTo.flatMap(EditableTable.init(html:)).map(table.cells(differingFrom:)) ?? []
        return Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
            ForEach(Array(table.layout.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, slot in
                        switch slot {
                        case let .cell(r, i):
                            let cell = table.rows[r][i]
                            cellView(slot: slot, cell: cell,
                                     isHeader: cell.isHeader || (implicitHeader && r == 0),
                                     isFlagged: flagged.contains(slot))
                                .gridCellColumns(cell.columnSpan)
                        case let .covered(top):
                            Color.clear
                                .frame(minWidth: 52, maxHeight: .infinity)
                                .overlay(MDCellBorder(skipTop: !top).stroke(borderColor, lineWidth: 0.5))
                        }
                    }
                }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(borderColor, lineWidth: 1))
        .padding(1)
    }

    @ViewBuilder
    private func cellView(slot: EditableTable.Slot, cell: EditableTable.Cell,
                          isHeader: Bool, isFlagged: Bool) -> some View {
        let isEditing = editing == slot
        Group {
            if isEditing, case let .cell(r, i) = slot {
                TextField("", text: Binding(
                    get: { table?.rows[r][i].text ?? "" },
                    set: { value in
                        table?.rows[r][i].text = value
                        if let table { html = table.html }
                    }), axis: .vertical)
                    .textFieldStyle(.plain)
                    .focused($fieldFocused)
                    .onSubmit { editing = nil }
            } else {
                // A button rather than a tap gesture, so a cell can be reached
                // from the keyboard and by VoiceOver, not only by pointing.
                Button {
                    editing = slot
                    Task { @MainActor in fieldFocused = true }
                } label: {
                    MDCellText(text: cell.text, isHeader: isHeader)
                        .frame(maxWidth: .infinity, minHeight: 16, alignment: .topLeading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(cell.text.isEmpty ? String(localized: "Empty cell") : cell.text)
                .accessibilityHint("Edit this cell")
            }
        }
        .font(isHeader ? .callout.weight(.semibold) : .callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(minWidth: 52 * CGFloat(cell.columnSpan), maxWidth: 260 * CGFloat(cell.columnSpan),
               alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(isEditing ? Color.accentColor.opacity(0.12)
                    : isFlagged ? Color.orange.opacity(0.25)
                    : isHeader ? Color.secondary.opacity(0.12) : Color.clear)
        .overlay(MDCellBorder(skipTop: false).stroke(isEditing ? Color.accentColor : borderColor,
                                                     lineWidth: isEditing ? 1.5 : 0.5))
        .help("Click to edit this cell")
    }
}

// MARK: - Differences

/// Marks where one reading parts ways with the other, which is where to look.
///
/// Runs of whitespace compare as a single space, so one reader breaking lines
/// where the page does and the other not is no difference at all. A space
/// that one has and the other lacks — "Table3rows" against "Table 3 rows" —
/// is a difference, marked on the characters either side of it, since a
/// highlighted space is too thin to see. Text missing here that the other
/// reading has is marked the same way, where it would go.
enum TextDiff {
    static func marked(_ text: String, against other: String?) -> AttributedString {
        var result = AttributedString(text)
        guard let other, text != other else { return result }
        let characters = Array(text)
        let mine = tokens(of: characters)
        let a = mine.map(\.character)
        let b = tokens(of: Array(other)).map(\.character)
        // A longest common subsequence costs a×b; past this a long region is
        // shown unmarked rather than stalling the pane.
        guard !a.isEmpty, !b.isEmpty, a.count * b.count <= 1_500_000 else { return result }

        var lengths = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                lengths[i][j] = a[i] == b[j] ? lengths[i + 1][j + 1] + 1 : max(lengths[i + 1][j], lengths[i][j + 1])
            }
        }

        var marked = Set<Int>()
        /// Marks a token, or — for a space — what stands either side of it.
        func mark(token index: Int) {
            let token = mine[index]
            if token.character != " " {
                marked.insert(token.offset)
                return
            }
            if index > 0 { marked.insert(mine[index - 1].offset) }
            if index + 1 < mine.count { marked.insert(mine[index + 1].offset) }
        }
        /// Marks the place before token `index`, where the other reading has
        /// something this one does not.
        func markGap(before index: Int) {
            if index > 0, mine[index - 1].character != " " { marked.insert(mine[index - 1].offset) }
            if index < mine.count, mine[index].character != " " { marked.insert(mine[index].offset) }
        }

        var i = 0, j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] {
                i += 1
                j += 1
            } else if lengths[i + 1][j] >= lengths[i][j + 1] {
                mark(token: i)
                i += 1
            } else {
                markGap(before: i)
                j += 1
            }
        }
        while i < a.count { mark(token: i); i += 1 }
        if j < b.count { markGap(before: a.count) }

        var index = result.startIndex
        var offset = 0
        while index < result.endIndex {
            let next = result.characters.index(after: index)
            if marked.contains(offset), !characters[offset].isWhitespace {
                result[index..<next].backgroundColor = Color.orange.opacity(0.35)
            }
            index = next
            offset += 1
        }
        return result
    }

    /// The text as compared: one token per character, a run of whitespace
    /// folded into one space; each token remembers where it starts.
    private static func tokens(of characters: [Character]) -> [(character: Character, offset: Int)] {
        var tokens: [(character: Character, offset: Int)] = []
        for (offset, character) in characters.enumerated() {
            if character.isWhitespace {
                if tokens.last?.character != " " { tokens.append((" ", offset)) }
            } else {
                tokens.append((character, offset))
            }
        }
        return tokens
    }
}
