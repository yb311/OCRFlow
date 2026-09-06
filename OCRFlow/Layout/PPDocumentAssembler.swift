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

    /// Blocks worth emitting, honouring the page-furniture preference.
    static func contentBlocks(_ blocks: [PPLayoutBlock], dropPageFurniture: Bool) -> [PPLayoutBlock] {
        blocks.filter { block in
            if dropPageFurniture && block.label.isPageFurniture { return false }
            return true
        }
    }

    static func markdown(from blocks: [PPLayoutBlock], dropPageFurniture: Bool = true,
                         source: PPTextSource = .visionLanguageModel) -> String {
        contentBlocks(blocks, dropPageFurniture: dropPageFurniture)
            .compactMap { fragment(for: $0, source: source) }
            .joined(separator: "\n\n")
    }

    /// The same content with the markup stripped, for the plain-text pane and
    /// for the existing text export.
    static func plainText(from blocks: [PPLayoutBlock], dropPageFurniture: Bool = true) -> String {
        contentBlocks(blocks, dropPageFurniture: dropPageFurniture)
            .filter { !$0.text.isEmpty }
            .map(\.text)
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

    private static func fragment(for block: PPLayoutBlock, source: PPTextSource) -> String? {
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
                return text.isEmpty ? nil : "## \(text)"
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
            return text.isEmpty ? nil : "## \(text)"

        case .figureTitle, .visionFootnote:
            return text.isEmpty ? nil : "*\(text)*"

        case .displayFormula:
            guard !text.isEmpty else { return nil }
            // The model returns bare LaTeX; wrap it unless it already carries
            // its own delimiters.
            if text.hasPrefix("$$") || text.hasPrefix("\\[") { return text }
            return "$$\n\(text)\n$$"

        case .inlineFormula:
            guard !text.isEmpty else { return nil }
            return text.hasPrefix("$") ? text : "$\(text)$"

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
            return text.isEmpty ? nil : text
        }
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
