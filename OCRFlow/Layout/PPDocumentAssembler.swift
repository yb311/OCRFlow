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
    /// The text a born-digital PDF already carries, taken as it is. Exact
    /// characters, but no more markup than OCR: a formula in a PDF's text
    /// layer is a run of glyphs, not LaTeX.
    case pdfTextLayer

    /// True when the text may carry LaTeX and HTML the model was asked for.
    var carriesMarkup: Bool { self == .visionLanguageModel }

    /// Who read it, as the result pane names them.
    var label: String {
        switch self {
        case .visionLanguageModel: return "PaddleOCR-VL"
        case .plainOCR:            return "PP-OCRv6"
        case .pdfTextLayer:        return "PDF 文字层"
        }
    }
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
            // A block read by a different reader than the page's own carries
            // its own source: a table the VLM read on a page PP-OCR read is
            // still HTML, and a paragraph PP-OCR read beside it is still not.
            guard let text = fragment(for: blocks[index], source: blocks[index].source ?? source,
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
            .map { index in
                let block = blocks[index]
                // A table is rows of cells, not HTML: tab-separated, it pastes
                // straight into a spreadsheet and reads as a table anywhere.
                guard block.label == .table || block.label == .chart,
                      let cells = TableWorkbook.cells(from: block.text) else { return block.text }
                return tabSeparated(cells)
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    private static func tabSeparated(_ cells: [TableWorkbook.Cell]) -> String {
        Dictionary(grouping: cells, by: \.row).sorted { $0.key < $1.key }.map { _, row in
            var line: [String] = []
            for cell in row.sorted(by: { $0.column < $1.column }) {
                while line.count < cell.column { line.append("") }
                line.append(cell.text.replacingOccurrences(of: "\n", with: " "))
            }
            return line.joined(separator: "\t")
        }.joined(separator: "\n")
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
        let trimmed = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Lines of OCR or of a PDF's text layer end where the page's lines
        // ended; the VLM writes a paragraph as a paragraph. Rejoined, a page
        // read by both reads as one document.
        let text = source.carriesMarkup || block.label == .table ? trimmed : reflowed(trimmed)

        // Plain OCR of a formula or a table is a run of characters, not LaTeX
        // and not HTML — and so is a PDF's own text layer. Emitting it as a
        // paragraph is the honest rendering; `$$…$$` around it would only
        // produce a broken formula.
        if !source.carriesMarkup {
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
            // Table Recognition emits OTSL, turned into HTML here; Markdown
            // passes HTML through untouched and the results pane renders it as
            // a grid.
            return text.isEmpty ? nil : normalisedTable(htmlTable(fromOTSL: text) ?? text)

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

    // MARK: - Paragraphs

    /// Joins the lines of a paragraph the way the page set them: Chinese and
    /// Japanese run on without a space, other scripts take one, and a word
    /// hyphenated across a line break is put back together. A line that
    /// starts a list item stays a line of its own.
    static func reflowed(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard var result = lines.first else { return text }
        for line in lines.dropFirst() {
            if startsListItem(line) {
                result += "\n" + line
                continue
            }
            let last = result.last, first = line.first
            if last == "-", let before = result.dropLast().last, before.isLetter, before.isASCII,
               let first, first.isLowercase {
                result.removeLast()
                result += line
            } else if let last, let first, isWideScript(last) || isWideScript(first) {
                result += line
            } else {
                result += " " + line
            }
        }
        return result
    }

    private static func startsListItem(_ line: String) -> Bool {
        if let first = line.first, "•·●▪◦-–—*".contains(first) { return true }
        return line.range(of: #"^(\(?\d{1,3}[.)、）]|[（(]\d{1,3}[)）]|[一二三四五六七八九十]+、)"#,
                          options: .regularExpression) != nil
    }

    /// Scripts written without spaces between words, plus their punctuation.
    private static func isWideScript(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x3000...0x303F, 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
             0xF900...0xFAFF, 0xFF00...0xFFEF, 0x20000...0x2FA1F:
            return true
        default:
            return false
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

    /// The OTSL cell tokens PaddleOCR-VL writes a table in.
    static let otslTokens = ["<fcel>", "<ecel>", "<lcel>", "<ucel>", "<xcel>", "<nl>"]

    /// One cell of an OTSL table, with the merges folded into its spans.
    struct OTSLCell: Equatable {
        var row: Int
        var column: Int
        var rowSpan = 1
        var columnSpan = 1
        var text: String
    }

    /// Turns PaddleOCR-VL's OTSL table into HTML.
    ///
    /// PaddleOCR-VL-1.6 does not answer Table Recognition with HTML: it writes
    /// OTSL, a grid of one token per cell — `<fcel>` a cell with text after
    /// it, `<ecel>` an empty one, `<lcel>` merged into the cell on its left,
    /// `<ucel>` into the one above, `<xcel>` into both — with `<nl>` ending
    /// each row. PaddleOCR converts it before the table reaches a document;
    /// the raw tokens are unreadable anywhere else. Merged cells become
    /// `colspan` and `rowspan`.
    ///
    /// Nil when the text is not OTSL, so HTML or a pipe table passes through.
    static func htmlTable(fromOTSL text: String) -> String? {
        guard let table = otslCells(text) else { return nil }
        var html = "<table>"
        var cells = table.cells[...]
        for r in 0..<table.rows {
            html += "<tr>"
            while let cell = cells.first, cell.row == r {
                html += "<td"
                if cell.columnSpan > 1 { html += " colspan=\"\(cell.columnSpan)\"" }
                if cell.rowSpan > 1 { html += " rowspan=\"\(cell.rowSpan)\"" }
                html += ">\(cell.text)</td>"
                cells = cells.dropFirst()
            }
            html += "</tr>"
        }
        return html + "</table>"
    }

    /// The cells of an OTSL table in reading order, empty ones included, and
    /// how many rows it has. Nil when the text is not OTSL.
    static func otslCells(_ text: String) -> (rows: Int, cells: [OTSLCell])? {
        guard text.contains("<fcel>") || text.contains("<ecel>") else { return nil }

        // Split into (tag, text) cells, row by row.
        var rows: [[(tag: String, text: String)]] = []
        var row: [(tag: String, text: String)] = []
        var rest = Substring(text)
        while !rest.isEmpty {
            guard let start = rest.firstIndex(of: "<"),
                  let tag = otslTokens.first(where: { rest[start...].hasPrefix($0) }) else {
                // Text belongs to the cell before it.
                let end = rest.dropFirst().firstIndex(of: "<") ?? rest.endIndex
                if row.isEmpty { row.append(("<fcel>", "")) }
                row[row.count - 1].text += rest[rest.startIndex..<end]
                rest = rest[end...]
                continue
            }
            if start > rest.startIndex {
                if row.isEmpty { row.append(("<fcel>", "")) }
                row[row.count - 1].text += rest[rest.startIndex..<start]
            }
            rest = rest[rest.index(start, offsetBy: tag.count)...]
            if tag == "<nl>" {
                rows.append(row)
                row = []
            } else {
                row.append((tag, ""))
            }
        }
        if !row.isEmpty { rows.append(row) }
        rows.removeAll { $0.isEmpty }
        guard let width = rows.map(\.count).max(), width > 0 else { return nil }
        // A short row is padded with empty cells, as PaddleOCR does.
        rows = rows.map { $0 + Array(repeating: ("<ecel>", ""), count: width - $0.count) }

        // A merge marker that carries text of its own is a cell after all:
        // spanning over it would lose what it says.
        func blank(_ r: Int, _ c: Int) -> Bool {
            rows[r][c].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        func merged(_ r: Int, _ c: Int, into direction: String) -> Bool {
            let tag = rows[r][c].tag
            return (tag == direction || tag == "<xcel>") && blank(r, c)
        }

        var cells: [OTSLCell] = []
        for r in rows.indices {
            for c in 0..<width {
                // A merge marker with nothing to merge into — the first row or
                // column — is a cell of its own rather than a lost one.
                let tag = rows[r][c].tag
                let covered = blank(r, c) && ((tag == "<lcel>" && c > 0) || (tag == "<ucel>" && r > 0)
                    || (tag == "<xcel>" && r > 0 && c > 0))
                if covered { continue }
                var columns = 1
                while c + columns < width, merged(r, c + columns, into: "<lcel>") { columns += 1 }
                var spannedRows = 1
                while r + spannedRows < rows.count, merged(r + spannedRows, c, into: "<ucel>") { spannedRows += 1 }
                cells.append(OTSLCell(row: r, column: c, rowSpan: spannedRows, columnSpan: columns,
                                      text: rows[r][c].text.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
        return (rows.count, cells)
    }

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
