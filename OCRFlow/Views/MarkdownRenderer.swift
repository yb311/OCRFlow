import SwiftUI
import AppKit

// MARK: - Parsed document

/// One renderable piece of an assembled document.
///
/// `AttributedString`'s Markdown parser is inline-only — it styles emphasis and
/// links but ignores every block construct — so a table used to arrive in the
/// results pane as a run of pipes and a figure as the literal word "图片".
/// Recovering the block structure here is what lets a table become a grid and a
/// figure become the part of the page it stands for.
struct MDBlock: Identifiable {
    enum Kind {
        case heading(level: Int, text: String)
        case paragraph(String)
        case quote(String)
        case list([MDListItem])
        case code(String)
        /// Display maths, still as LaTeX: there is no typesetter here, but a
        /// formula deserves to be set apart from the prose around it.
        case formula(String)
        case table(MDTable)
        /// A figure placeholder. `ordinal` counts placeholders from the top of
        /// the document, which is how the crop for it is found.
        case figure(ordinal: Int, caption: String)
        case rule
    }

    let id: Int
    let kind: Kind
}

struct MDListItem: Identifiable {
    let id: Int
    var marker: String
    var text: String
}

struct MDCell: Identifiable {
    let id: Int
    var text: String
    var columnSpan: Int = 1
    var isHeader: Bool = false
    /// Covered by the `rowspan` of a cell above it: drawn as an empty cell so
    /// the columns below still line up.
    var isContinuation: Bool = false
}

struct MDRow: Identifiable {
    let id: Int
    var cells: [MDCell]
}

struct MDTable {
    var rows: [MDRow] = []
    var columnCount: Int = 0

    var isEmpty: Bool { rows.isEmpty || columnCount == 0 }
}

// MARK: - Parsing

enum MDParser {

    static func parse(_ source: String) -> [MDBlock] {
        var blocks: [MDBlock] = []
        var figureOrdinal = 0
        let lines = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        var i = 0

        func append(_ kind: MDBlock.Kind) {
            blocks.append(MDBlock(id: blocks.count, kind: kind))
        }

        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            if line.isEmpty { i += 1; continue }

            // Fenced code
            if line.hasPrefix("```") {
                i += 1
                var body: [String] = []
                while i < lines.count,
                      !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    body.append(lines[i]); i += 1
                }
                if i < lines.count { i += 1 }
                append(.code(body.joined(separator: "\n")))
                continue
            }

            // Display formula, either "$$…$$" on one line or fenced over several
            if line.hasPrefix("$$") {
                let inner = String(line.dropFirst(2))
                if inner.hasSuffix("$$") {
                    append(.formula(String(inner.dropLast(2))
                        .trimmingCharacters(in: .whitespaces)))
                    i += 1
                    continue
                }
                var body: [String] = inner.isEmpty ? [] : [inner]
                i += 1
                while i < lines.count,
                      !lines[i].trimmingCharacters(in: .whitespaces).hasSuffix("$$") {
                    body.append(lines[i]); i += 1
                }
                if i < lines.count {
                    let closing = String(lines[i].trimmingCharacters(in: .whitespaces).dropLast(2))
                    if !closing.trimmingCharacters(in: .whitespaces).isEmpty { body.append(closing) }
                    i += 1
                }
                append(.formula(body.joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)))
                continue
            }

            // A line that is nothing but one inline formula — which is how a
            // standalone `inline_formula` region arrives — is a display
            // formula as far as this pane is concerned.
            if let body = Self.soleInlineFormula(in: line) {
                append(.formula(body))
                i += 1
                continue
            }

            // HTML table — what Table Recognition and Chart Recognition emit
            if line.lowercased().contains("<table") {
                var body: [String] = []
                while i < lines.count {
                    body.append(lines[i])
                    let lower = lines[i].lowercased()
                    i += 1
                    if lower.contains("</table>") { break }
                }
                let html = body.joined(separator: "\n")
                if let table = parseHTMLTable(html), !table.isEmpty {
                    append(.table(table))
                } else {
                    // An unparsable table is still worth seeing as it came.
                    append(.code(html))
                }
                continue
            }

            // Pipe table
            if isPipeRow(line) {
                var rows: [String] = []
                var j = i
                while j < lines.count {
                    let candidate = lines[j].trimmingCharacters(in: .whitespaces)
                    guard isPipeRow(candidate) else { break }
                    rows.append(candidate)
                    j += 1
                }
                if let table = parsePipeTable(rows), !table.isEmpty {
                    append(.table(table))
                    i = j
                    continue
                }
                // One stray pipe is prose, not a table: fall through.
            }

            // Heading
            if line.hasPrefix("#") {
                var level = 0
                var body = Substring(line)
                while body.hasPrefix("#"), level < 6 {
                    level += 1
                    body = body.dropFirst()
                }
                let text = body.trimmingCharacters(in: .whitespaces)
                if !text.isEmpty {
                    append(.heading(level: level, text: text))
                    i += 1
                    continue
                }
            }

            // Thematic break
            if isRule(line) {
                append(.rule)
                i += 1
                continue
            }

            // Figure placeholder
            if let caption = imageAlt(in: line) {
                append(.figure(ordinal: figureOrdinal, caption: caption))
                figureOrdinal += 1
                i += 1
                continue
            }

            // Block quote
            if line.hasPrefix(">") {
                var body: [String] = []
                while i < lines.count {
                    let candidate = lines[i].trimmingCharacters(in: .whitespaces)
                    guard candidate.hasPrefix(">") else { break }
                    body.append(String(candidate.dropFirst()).trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                append(.quote(body.joined(separator: "\n")))
                continue
            }

            // List
            if let first = listItem(in: line) {
                var items = [MDListItem(id: 0, marker: first.marker, text: first.text)]
                i += 1
                while i < lines.count,
                      let next = listItem(in: lines[i].trimmingCharacters(in: .whitespaces)) {
                    items.append(MDListItem(id: items.count, marker: next.marker, text: next.text))
                    i += 1
                }
                append(.list(items))
                continue
            }

            // Paragraph: everything up to a blank line or the next block start.
            var paragraph: [String] = [line]
            i += 1
            while i < lines.count {
                let next = lines[i].trimmingCharacters(in: .whitespaces)
                if next.isEmpty || startsBlock(next) { break }
                paragraph.append(next)
                i += 1
            }
            append(.paragraph(paragraph.joined(separator: "\n")))
        }

        return blocks
    }

    /// Inline Markdown only — emphasis, code spans, links — with the line
    /// breaks left alone, which matters for CJK text where joining wrapped
    /// lines with a space inserts gaps that were never in the page.
    /// The body of `$…$` or `\(…\)` when the whole line is exactly that.
    static func soleInlineFormula(in line: String) -> String? {
        for (open, close) in [("\\(", "\\)"), ("$", "$")] {
            guard line.hasPrefix(open), line.hasSuffix(close),
                  line.count > open.count + close.count else { continue }
            let body = String(line.dropFirst(open.count).dropLast(close.count))
            // A second delimiter inside means this is prose with maths in it,
            // not one formula.
            guard !body.contains("$"), MathParser.looksLikeMath(body) else { continue }
            return body
        }
        return nil
    }

    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible)
        return (try? AttributedString(markdown: text, options: options))
            ?? AttributedString(text)
    }

    // MARK: Line classification

    private static func startsBlock(_ line: String) -> Bool {
        if line.hasPrefix("#") || line.hasPrefix("```") || line.hasPrefix("$$") { return true }
        if line.hasPrefix(">") { return true }
        if line.lowercased().contains("<table") { return true }
        if isPipeRow(line) || isRule(line) { return true }
        if imageAlt(in: line) != nil { return true }
        if listItem(in: line) != nil { return true }
        return false
    }

    private static func isRule(_ line: String) -> Bool {
        let stripped = line.replacingOccurrences(of: " ", with: "")
        guard stripped.count >= 3 else { return false }
        return stripped.allSatisfy { $0 == "-" } || stripped.allSatisfy { $0 == "*" }
            || stripped.allSatisfy { $0 == "_" }
    }

    /// A pipe-table row: at least two separators, so a sentence that happens to
    /// contain one vertical bar is not mistaken for a table.
    private static func isPipeRow(_ line: String) -> Bool {
        line.filter { $0 == "|" }.count >= 2
    }

    private static func isPipeSeparator(_ cells: [String]) -> Bool {
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            let stripped = cell.replacingOccurrences(of: " ", with: "")
            guard stripped.contains("-") else { return false }
            return stripped.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }

    /// The alt text of a line that is nothing but an image.
    private static func imageAlt(in line: String) -> String? {
        guard line.hasPrefix("!["), line.hasSuffix(")"),
              let close = line.firstIndex(of: "]"),
              line.index(after: close) < line.endIndex,
              line[line.index(after: close)] == "(" else { return nil }
        return String(line[line.index(line.startIndex, offsetBy: 2)..<close])
    }

    private static func listItem(in line: String) -> (marker: String, text: String)? {
        for bullet in ["- ", "* ", "+ ", "• "] where line.hasPrefix(bullet) {
            return ("•", String(line.dropFirst(bullet.count)))
        }
        // "1. " and the CJK "1、"
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let rest = line.dropFirst(digits.count)
        for separator in [". ", ".", "、", ") "] where rest.hasPrefix(separator) {
            let text = String(rest.dropFirst(separator.count)).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            // `3.1独立运动` is a date, not the third item of a list. A bare dot
            // only starts a list when what follows is not another digit —
            // `1.内容` still counts, because CJK lists are written that way.
            if separator == ".", let first = text.first, first.isNumber { return nil }
            return ("\(digits).", text)
        }
        return nil
    }

    // MARK: Tables

    static func parsePipeTable(_ rows: [String]) -> MDTable? {
        var parsed: [[String]] = []
        var headerRows = 0

        for (index, row) in rows.enumerated() {
            var body = Substring(row)
            if body.hasPrefix("|") { body = body.dropFirst() }
            if body.hasSuffix("|") { body = body.dropLast() }
            let cells = body
                .components(separatedBy: "|")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if isPipeSeparator(cells) {
                // The dashed rule under a header, not a row of its own.
                if index == 1 { headerRows = 1 }
                continue
            }
            parsed.append(cells)
        }

        // A single row with no header rule is a sentence with pipes in it.
        guard parsed.count > 1 || headerRows == 1, !parsed.isEmpty else { return nil }

        let columnCount = parsed.map(\.count).max() ?? 0
        guard columnCount > 1 else { return nil }

        var table = MDTable(rows: [], columnCount: columnCount)
        for (index, cells) in parsed.enumerated() {
            var padded = cells
            while padded.count < columnCount { padded.append("") }
            let isHeader = headerRows > 0 && index == 0
            table.rows.append(MDRow(id: index, cells: padded.enumerated().map { column, text in
                MDCell(id: column, text: text, isHeader: isHeader)
            }))
        }
        return table
    }

    /// Parses the subset of HTML the recognition prompts produce: `<tr>` rows of
    /// `<td>`/`<th>` cells, with `colspan`/`rowspan` and `<br>` inside them.
    static func parseHTMLTable(_ html: String) -> MDTable? {
        let rowMatches = matches(of: "<tr[^>]*>(.*?)</tr>", in: html)
        guard !rowMatches.isEmpty else { return nil }

        struct Pending { var remaining: Int; var columnSpan: Int }
        var carry: [Int: Pending] = [:]      // column → rows still covered
        var grid: [[MDCell]] = []

        for rowHTML in rowMatches {
            let cellMatches = matchesWithTags(of: "<(td|th)([^>]*)>(.*?)</(?:td|th)>", in: rowHTML)
            var row: [MDCell] = []
            var column = 0

            func fillCarried() {
                while let pending = carry[column] {
                    for _ in 0..<pending.columnSpan {
                        row.append(MDCell(id: row.count, text: "",
                                          columnSpan: 1, isContinuation: true))
                    }
                    carry[column] = pending.remaining > 1
                        ? Pending(remaining: pending.remaining - 1, columnSpan: pending.columnSpan)
                        : nil
                    column += pending.columnSpan
                }
            }

            fillCarried()
            for cell in cellMatches {
                let columnSpan = max(1, attribute("colspan", in: cell.attributes) ?? 1)
                let rowSpan = max(1, attribute("rowspan", in: cell.attributes) ?? 1)
                row.append(MDCell(id: row.count, text: plainText(fromHTML: cell.body),
                                  columnSpan: columnSpan, isHeader: cell.tag == "th"))
                if rowSpan > 1 {
                    carry[column] = Pending(remaining: rowSpan - 1, columnSpan: columnSpan)
                }
                column += columnSpan
                fillCarried()
            }
            // Rows carried down from above with no cells of their own still
            // have to be emitted, or the table loses a line.
            if !row.isEmpty { grid.append(row) }
        }

        guard !grid.isEmpty else { return nil }
        let columnCount = grid.map { $0.reduce(0) { $0 + $1.columnSpan } }.max() ?? 0
        guard columnCount > 0 else { return nil }

        var table = MDTable(rows: [], columnCount: columnCount)
        for (index, cells) in grid.enumerated() {
            var padded = cells
            var width = cells.reduce(0) { $0 + $1.columnSpan }
            while width < columnCount {
                padded.append(MDCell(id: padded.count, text: "", isContinuation: true))
                width += 1
            }
            table.rows.append(MDRow(id: index, cells: padded))
        }
        return table
    }

    private static func attribute(_ name: String, in attributes: String) -> Int? {
        guard let value = matches(of: "\(name)\\s*=\\s*\"?'?(\\d+)", in: attributes).first else {
            return nil
        }
        return Int(value)
    }

    /// Cell text: `<br>` becomes a line break, every other tag is dropped and
    /// the entities the model escapes are put back.
    static func plainText(fromHTML html: String) -> String {
        var text = html.replacingOccurrences(of: "(?i)<br\\s*/?>", with: "\n",
                                             options: .regularExpression)
        text = text.replacingOccurrences(of: "(?s)<[^>]+>", with: "",
                                         options: .regularExpression)
        for (entity, replacement) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
                                      ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " "),
                                      ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: replacement,
                                             options: .caseInsensitive)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Regex helpers

    private static func matches(of pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let group = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[group])
        }
    }

    private static func matchesWithTags(of pattern: String, in text: String)
        -> [(tag: String, attributes: String, body: String)] {
        guard let regex = try? NSRegularExpression(
            pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 3,
                  let tag = Range(match.range(at: 1), in: text),
                  let attributes = Range(match.range(at: 2), in: text),
                  let body = Range(match.range(at: 3), in: text) else { return nil }
            return (String(text[tag]).lowercased(), String(text[attributes]), String(text[body]))
        }
    }
}

// MARK: - Figure crops

enum DocumentFigures {

    /// The page regions the assembler left placeholders for, in the same order
    /// the placeholders appear in — which is how a figure in the results pane
    /// finds the pixels it stands for.
    ///
    /// Empty when the document came from a whole-page pass, which has no layout
    /// blocks to crop from, and short of the placeholder count for a PDF, where
    /// only page one's blocks are kept.
    static func crops(for item: ImageItem) -> [NSImage?] {
        guard !item.layoutBlocks.isEmpty,
              let page = item.thumbnail?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return [] }

        let pixel = item.pixelSize
        let sx = pixel.width > 0 ? CGFloat(page.width) / pixel.width : 1
        let sy = pixel.height > 0 ? CGFloat(page.height) / pixel.height : 1
        let bounds = CGRect(x: 0, y: 0, width: page.width, height: page.height)

        return item.layoutBlocks
            .filter { $0.label.producesFigure }
            .map { block -> NSImage? in
                let scaled = CGRect(x: block.rect.minX * sx, y: block.rect.minY * sy,
                                    width: block.rect.width * sx, height: block.rect.height * sy)
                let rect = scaled.integral.intersection(bounds)
                guard rect.width >= 8, rect.height >= 8,
                      let cropped = page.cropping(to: rect) else { return nil }
                return NSImage(cgImage: cropped,
                               size: NSSize(width: cropped.width, height: cropped.height))
            }
    }
}

extension NSImage {
    /// PNG bytes at the image's own pixel size, for the figure export.
    var pngData: Data? {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        rep.size = NSSize(width: cg.width, height: cg.height)
        return rep.representation(using: .png, properties: [:])
    }
}

// MARK: - Rendering

struct MarkdownDocumentView: View {
    let blocks: [MDBlock]
    /// Crops for the figure placeholders, indexed by ordinal.
    var figures: [NSImage?] = []
    var showFigures = true
    var renderTables = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(blocks) { block in
                view(for: block)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func view(for block: MDBlock) -> some View {
        switch block.kind {
        case let .heading(level, text):
            Text(MDParser.inline(text))
                .font(headingFont(level))
                .padding(.top, level <= 2 ? 6 : 2)

        case let .paragraph(text):
            if MathInlineText.hasInlineMath(text) {
                MathInlineText(source: text, size: 13)
                    .lineSpacing(4)
            } else {
                Text(MDParser.inline(text))
                    .font(.body)
                    .lineSpacing(4)
            }

        case let .quote(text):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 3)
                Text(MDParser.inline(text))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
            }
            .fixedSize(horizontal: false, vertical: true)

        case let .list(items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(items) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.marker)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Text(MDParser.inline(item.text))
                            .font(.body)
                            .lineSpacing(3)
                    }
                }
            }

        case let .code(text):
            Text(text)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))

        case let .formula(latex):
            MathBlockView(latex: latex)

        case let .table(table):
            if renderTables {
                MDTableView(table: table)
            } else {
                Text(rawSource(of: table))
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }

        case let .figure(ordinal, caption):
            MDFigureView(image: showFigures ? figure(at: ordinal) : nil, caption: caption)

        case .rule:
            Divider().padding(.vertical, 4)
        }
    }

    private func figure(at ordinal: Int) -> NSImage? {
        guard figures.indices.contains(ordinal) else { return nil }
        return figures[ordinal]
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1:  return .system(.title, weight: .bold)
        case 2:  return .system(.title2, weight: .semibold)
        case 3:  return .system(.title3, weight: .semibold)
        default: return .system(.headline)
        }
    }

    /// The pipe form of a parsed table, for the "don't render tables" setting.
    private func rawSource(of table: MDTable) -> String {
        table.rows
            .map { "| " + $0.cells.map(\.text).joined(separator: " | ") + " |" }
            .joined(separator: "\n")
    }
}

/// A recognised table, drawn as a real grid.
///
/// Wide tables scroll sideways rather than squeezing every column: the results
/// pane is narrow, and a financial table with a dozen columns is unreadable
/// once each one is 20 points wide.
struct MDTableView: View {
    let table: MDTable

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            MDTableGrid(table: table)
        }
        // The pane is itself a vertical ScrollView, which offers its content
        // unbounded height; without this the table would take all of it.
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct MDTableGrid: View {
    let table: MDTable

    private let borderColor = Color.secondary.opacity(0.35)

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
            ForEach(table.rows) { row in
                GridRow {
                    ForEach(row.cells) { cell in
                        Text(cell.text)
                            .font(cell.isHeader ? .callout.weight(.semibold) : .callout)
                            .textSelection(.enabled)
                            .lineSpacing(2)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            // The cap is per column, so a cell that spans two
                            // of them may be twice as wide before it wraps.
                            .frame(minWidth: 52 * CGFloat(cell.columnSpan),
                                   maxWidth: 260 * CGFloat(cell.columnSpan),
                                   alignment: cell.isHeader ? .center : .leading)
                            // Keeps a wrapped cell at its full height instead
                            // of letting the row's proposal truncate it.
                            .fixedSize(horizontal: false, vertical: true)
                            // Fills the row, so a one-line cell next to a
                            // wrapped one still has its rules drawn around it.
                            .frame(maxHeight: .infinity, alignment: .top)
                            .background(cell.isHeader ? Color.secondary.opacity(0.12) : .clear)
                            .overlay(MDCellBorder(skipTop: cell.isContinuation)
                                .stroke(borderColor, lineWidth: 0.5))
                            .gridCellColumns(cell.columnSpan)
                    }
                }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(borderColor, lineWidth: 1))
        .padding(1)
    }
}

/// The rules around one cell. A cell continuing the `rowspan` of the one above
/// drops its top edge, so the pair reads as the single merged cell it was.
private struct MDCellBorder: Shape {
    let skipTop: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        if !skipTop {
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        }
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        return path
    }
}

/// A figure: the crop from the page it was detected in, or — when there is no
/// crop, as with a whole-page pass — a marker that keeps the reading order
/// honest, so the caption that follows still reads as a caption for something.
struct MDFigureView: View {
    let image: NSImage?
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: min(image.size.width, 560), maxHeight: 460)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.25), lineWidth: 1))
                // No label under the picture: the placeholder's alt text only
                // ever names the kind of block, which the crop already shows.
                // The page's own 图题 block is a caption of its own.
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "photo")
                        .foregroundStyle(.tertiary)
                    Text(caption.isEmpty ? "图片" : caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .foregroundStyle(Color.secondary.opacity(0.35)))
            }
        }
    }
}
