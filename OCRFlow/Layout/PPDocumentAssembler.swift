import Foundation

/// Where a block's text came from, which decides how much markup it may carry.
enum PPTextSource: String, Sendable, Codable {
    /// PaddleOCR-VL, which returns LaTeX for formulas and HTML for tables
    /// because it was asked for exactly that.
    case visionLanguageModel
    /// PP-OCRv6 text lines. A formula region read this way comes back as the
    /// characters the recogniser saw, not as LaTeX, so it must not be dressed
    /// up as maths.
    case plainOCR
}

/// Turns recognised layout blocks back into a document.
///
/// This is the last stage of both pipelines: the blocks arrive in reading order
/// with their text already filled in — by the VLM, or by pouring PP-OCRv6's
/// text lines into the regions — and the only job left is to give each one the
/// markup its label implies.
enum PPDocumentAssembler {

    /// Blocks worth emitting, honouring the auxiliary-content preferences.
    static func contentBlocks(_ blocks: [PPLayoutBlock], dropping: Set<PPLayoutLabel>) -> [PPLayoutBlock] {
        contentIndices(blocks, dropping: dropping).map { blocks[$0] }
    }

    /// Indices of the blocks worth emitting, so a caller that needs to know
    /// where each piece came from can keep the link.
    static func contentIndices(_ blocks: [PPLayoutBlock], dropping: Set<PPLayoutLabel>) -> [Int] {
        let keep = blocks.indices.filter { !dropping.contains(blocks[$0].label) }
        return keep.filter { index in
            !isEchoOfNeighbour(index, in: blocks, among: keep)
        }
    }

    /// True when a block only repeats the start of the one beside it.
    ///
    /// A region that clips a line in half is read as the first few words of
    /// that line, and those words then appear twice in a row — once from the
    /// fragment and once from the paragraph that contains the whole line. The
    /// geometry stage drops most of these; this catches the ones whose boxes
    /// overlap too little to look like duplicates but whose text plainly is.
    private static func isEchoOfNeighbour(_ index: Int, in blocks: [PPLayoutBlock],
                                          among keep: [Int]) -> Bool {
        let text = blocks[index].text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 3, blocks[index].label.vlTask != nil else { return false }

        // Neighbours among the blocks that actually say something: a figure
        // between two paragraphs contributes no text, and letting it break the
        // adjacency would hide the very duplicate this is looking for.
        let speaking = keep.filter {
            !blocks[$0].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard let position = speaking.firstIndex(of: index) else { return false }

        for offset in [-1, 1] {
            let neighbourPosition = position + offset
            guard speaking.indices.contains(neighbourPosition) else { continue }
            let other = blocks[speaking[neighbourPosition]].text
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Only a clearly shorter run counts as an echo; two similar-length
            // blocks are two pieces of content that happen to start alike.
            guard other.count > text.count * 5 / 3 else { continue }
            if other.contains(text) { return true }
        }
        return false
    }

    /// One region's worth of document, and which region it came from.
    ///
    /// Keeping the link is what lets the rendered document point back at the
    /// page: hovering a paragraph can light up the box it was read out of only
    /// if something remembers which box that was.
    struct Fragment: Equatable {
        /// Index into the item's `layoutBlocks`, or nil for a document that has
        /// no regions behind it (Apple Vision, or a whole-page VL pass).
        var source: Int?
        var markdown: String
    }

    /// The document, in pieces that still know where they came from.
    static func fragments(from blocks: [PPLayoutBlock], dropping: Set<PPLayoutLabel> = [],
                          source: PPTextSource = .visionLanguageModel,
                          inferHeadingLevels: Bool = true) -> [Fragment] {
        let levels = inferHeadingLevels ? headingLevels(of: blocks) : [:]
        return contentIndices(blocks, dropping: dropping).compactMap { index in
            guard let text = fragment(for: blocks[index], source: source,
                                      headingLevel: levels[index]) else { return nil }
            return Fragment(source: index, markdown: text)
        }
    }

    /// Assigns each `paragraph_title` a heading level from how big it is set.
    ///
    /// The layout model says "this is a heading", not "this is a level-three
    /// heading" — but a document sets its levels in type, so the sizes carry
    /// the hierarchy. Titles are grouped by height, tallest group first, and
    /// numbered from two, leaving `#` to the document's own title. This is
    /// PaddleOCR's 段落标题级别识别.
    static func headingLevels(of blocks: [PPLayoutBlock]) -> [Int: Int] {
        let titles = blocks.indices.filter { blocks[$0].label == .paragraphTitle }
        guard titles.count > 1 else {
            return Dictionary(uniqueKeysWithValues: titles.map { ($0, 2) })
        }

        // One line of a two-line heading is as tall as half of it, so the
        // height of a single line is what the levels are compared on.
        func unitHeight(_ index: Int) -> CGFloat {
            let block = blocks[index]
            let lines = max(1, block.text.split(separator: "\n").count)
            return block.rect.height / CGFloat(lines)
        }

        var levels: [Int: Int] = [:]
        var level = 2
        var currentHeight: CGFloat?
        for index in titles.sorted(by: { unitHeight($0) > unitHeight($1) }) {
            let height = unitHeight(index)
            if let currentHeight {
                // Within a tenth of each other is the same level; type sizes in
                // a document step by more than that.
                if height < currentHeight * 0.9 { level = min(level + 1, 6) }
            }
            if currentHeight == nil || height < currentHeight! * 0.9 { currentHeight = height }
            levels[index] = level
        }
        return levels
    }

    /// The whole document as one string — the pieces joined, so the text that
    /// is exported and the text that is rendered cannot drift apart.
    static func markdown(from blocks: [PPLayoutBlock], dropping: Set<PPLayoutLabel> = [],
                         source: PPTextSource = .visionLanguageModel,
                         inferHeadingLevels: Bool = true) -> String {
        fragments(from: blocks, dropping: dropping, source: source,
                  inferHeadingLevels: inferHeadingLevels)
            .map(\.markdown)
            .joined(separator: "\n\n")
    }

    /// The same content with the markup stripped, for the plain-text pane and
    /// for the existing text export.
    static func plainText(from blocks: [PPLayoutBlock], dropping: Set<PPLayoutLabel> = []) -> String {
        contentIndices(blocks, dropping: dropping)
            .map { blocks[$0].text }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    /// Points the `![…]()` placeholders `fragment(for:)` writes at real files,
    /// in order. Used by the export, where a placeholder with no target is a
    /// broken image in every other Markdown reader.
    ///
    /// The placeholders are the only empty links the assembler ever writes, so
    /// matching on `]()` is enough to find them.
    static func rewritingFigureLinks(in markdown: String, to links: [String]) -> String {
        var result = ""
        var rest = Substring(markdown)
        var index = 0
        while let range = rest.range(of: "]()") {
            let link = index < links.count ? links[index] : ""
            result += rest[..<range.lowerBound]
            result += "](\(link))"
            rest = rest[range.upperBound...]
            index += 1
        }
        return result + rest
    }

    private static func fragment(for block: PPLayoutBlock, source: PPTextSource,
                                 headingLevel: Int? = nil) -> String? {
        let text = block.text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Plain OCR of a formula or a table is a run of characters, not LaTeX
        // and not HTML. Emitting it as a paragraph is the honest rendering;
        // `$$…$$` around it would only produce a broken formula.
        if source == .plainOCR {
            switch block.label {
            case .image, .headerImage, .footerImage:
                return "![\(block.label.label)]()"
            case .chart:
                let figure = "![\(block.label.label)]()"
                return text.isEmpty ? figure : "\(figure)\n\n\(text)"
            case .docTitle:
                return text.isEmpty ? nil : "# \(text)"
            case .paragraphTitle:
                return text.isEmpty ? nil : "\(String(repeating: "#", count: headingLevel ?? 2)) \(text)"
            case .figureTitle, .visionFootnote:
                return text.isEmpty ? nil : "*\(text)*"
            case .footnote:
                return text.isEmpty ? nil : "> \(text)"
            default:
                return text.isEmpty ? nil : text
            }
        }

        switch block.label {
        case .image, .headerImage, .footerImage:
            // Figures have no text to transcribe. Leaving a marker keeps the
            // reading order honest — a caption that follows still reads as a
            // caption for something.
            return "![\(block.label.label)]()"

        case .docTitle:
            return text.isEmpty ? nil : "# \(text)"

        case .paragraphTitle:
            return text.isEmpty ? nil : "\(String(repeating: "#", count: headingLevel ?? 2)) \(text)"

        case .figureTitle, .visionFootnote:
            return text.isEmpty ? nil : "*\(text)*"

        case .displayFormula:
            guard !text.isEmpty else { return nil }
            return displayMath(text)

        case .inlineFormula:
            guard !text.isEmpty else { return nil }
            // A formula region that survived the containment filter really is
            // standalone, so it is set as display maths rather than squeezed
            // into a line of its own with `$…$`.
            return displayMath(text)

        case .table:
            // Table Recognition emits HTML, which Markdown passes through
            // untouched and the results pane renders as a grid.
            return text.isEmpty ? nil : normalisedTable(text)

        case .chart:
            // Chart Recognition reads a chart out as a table. The numbers are
            // the point, but the chart itself is worth keeping next to them —
            // a bar chart is not reconstructable from its own transcription.
            let figure = "![\(block.label.label)]()"
            return text.isEmpty ? figure : "\(figure)\n\n\(normalisedTable(text))"

        case .footnote:
            return text.isEmpty ? nil : "> \(text)"

        default:
            return text.isEmpty ? nil : normalisingInlineMath(text)
        }
    }

    // MARK: - Formulas

    /// One display formula, in the delimiters everything downstream expects.
    ///
    /// The model answers with `\[ … \]`, which is valid LaTeX and understood by
    /// nothing else: Markdown readers — including this app's own — look for
    /// `$$`. Wrapping the model's answer without unwrapping what it already
    /// carried is how `$\[k \geq 2\]$` ended up in an exported document.
    static func displayMath(_ latex: String) -> String {
        let body = strippingMathDelimiters(latex)
        guard !body.isEmpty else { return "" }
        return "$$\n\(body)\n$$"
    }

    /// Removes whatever delimiters the model put around a formula.
    static func strippingMathDelimiters(_ latex: String) -> String {
        var text = latex.trimmingCharacters(in: .whitespacesAndNewlines)
        // Repeated because the model sometimes doubles them up.
        var changed = true
        while changed {
            changed = false
            for (open, close) in [("$$", "$$"), ("\\[", "\\]"), ("\\(", "\\)"), ("$", "$")]
            where text.hasPrefix(open) && text.hasSuffix(close)
                && text.count > open.count + close.count {
                text = String(text.dropFirst(open.count).dropLast(close.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                changed = true
                break
            }
        }
        return text
    }

    /// Rewrites the LaTeX delimiters inside a run of prose to the Markdown
    /// ones, so a paragraph carrying `\(x\)` renders its maths as maths.
    static func normalisingInlineMath(_ text: String) -> String {
        text.replacingOccurrences(of: "\\(", with: "$")
            .replacingOccurrences(of: "\\)", with: "$")
    }

    // MARK: - Tables

    /// Turns the pipe-separated rows the model writes into a valid GitHub
    /// Markdown table.
    ///
    /// Chart Recognition answers with rows like `汽油能源 | 2.2% | 7.9%` and a
    /// header that is often one cell short, with no `---` rule under it. The
    /// results pane forgave all of that; every other Markdown reader does not,
    /// which is why an exported chart showed up in Typora as a paragraph full
    /// of vertical bars. Anything that is not a pipe table — HTML, prose — is
    /// returned untouched.
    static func normalisedTable(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard lines.count > 1, lines.allSatisfy({ $0.contains("|") }) else { return text }

        var rows: [[String]] = []
        for line in lines {
            var body = Substring(line)
            if body.hasPrefix("|") { body = body.dropFirst() }
            if body.hasSuffix("|") { body = body.dropLast() }
            let cells = body.components(separatedBy: "|")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            // An existing `---` rule is dropped and rewritten below, so a table
            // that was already well formed comes back unchanged.
            let isRule = cells.allSatisfy { cell in
                !cell.isEmpty && cell.allSatisfy { $0 == "-" || $0 == ":" || $0 == " " }
            }
            if !isRule { rows.append(cells) }
        }
        guard let width = rows.map(\.count).max(), width > 1, rows.count > 1 else { return text }

        // A header one cell short of the body is the usual shape of a chart
        // transcription: the row-label column has no title. Pad it at the
        // front, where the missing cell belongs.
        func padded(_ cells: [String], leading: Bool) -> String {
            var cells = cells
            while cells.count < width { leading ? cells.insert("", at: 0) : cells.append("") }
            return "| " + cells.joined(separator: " | ") + " |"
        }

        var out = [padded(rows[0], leading: rows[0].count < width)]
        out.append("|" + String(repeating: " --- |", count: width))
        for row in rows.dropFirst() { out.append(padded(row, leading: false)) }
        return out.joined(separator: "\n")
    }
}
