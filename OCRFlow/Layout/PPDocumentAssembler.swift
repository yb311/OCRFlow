import Foundation

/// Turns recognised layout blocks back into a document.
///
/// This is the last stage of the PaddleOCR-VL pipeline: the blocks arrive in
/// reading order with their text already filled in, and the only job left is to
/// give each one the markup its label implies.
enum PPDocumentAssembler {

    /// Blocks worth emitting, honouring the page-furniture preference.
    static func contentBlocks(_ blocks: [PPLayoutBlock], dropPageFurniture: Bool) -> [PPLayoutBlock] {
        blocks.filter { block in
            if dropPageFurniture && block.label.isPageFurniture { return false }
            return true
        }
    }

    static func markdown(from blocks: [PPLayoutBlock], dropPageFurniture: Bool = true) -> String {
        contentBlocks(blocks, dropPageFurniture: dropPageFurniture)
            .compactMap(fragment)
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

    private static func fragment(for block: PPLayoutBlock) -> String? {
        let text = block.text.trimmingCharacters(in: .whitespacesAndNewlines)

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
            return text.isEmpty ? nil : text

        case .chart:
            // Chart Recognition reads a chart out as a table. The numbers are
            // the point, but the chart itself is worth keeping next to them —
            // a bar chart is not reconstructable from its own transcription.
            let figure = "![\(block.label.label)]()"
            return text.isEmpty ? figure : "\(figure)\n\n\(text)"

        case .footnote:
            return text.isEmpty ? nil : "> \(text)"

        default:
            return text.isEmpty ? nil : text
        }
    }
}
