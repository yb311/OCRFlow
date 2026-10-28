import Foundation

/// The tables found in results, written out as an Excel workbook — one sheet
/// per table, merged cells kept merged.
///
/// Only tables whose structure was actually recognised are written: HTML from
/// PaddleOCR-VL (its OTSL converted on the way in), or the pipe tables chart
/// recognition produces. A table PP-OCR read as lines of text has no cells to
/// put anywhere, and guessing them would be making a table up.
///
/// An `.xlsx` is a zip of a few XML files. Writing the zip by hand — stored,
/// not compressed — keeps the app free of a dependency for something this
/// small.
enum TableWorkbook {

    struct Cell {
        var row: Int
        var column: Int
        var rowSpan = 1
        var columnSpan = 1
        var text: String
    }

    struct Sheet {
        var name: String
        var cells: [Cell]
    }

    /// Every recognised table in the items, named after where it was found.
    static func sheets(from items: [ImageItem]) -> [Sheet] {
        var sheets: [Sheet] = []
        for item in items {
            let stem = (item.fileName as NSString).deletingPathExtension
            var count = 0
            for (pageIndex, page) in item.pages.enumerated() {
                for block in page.blocks where block.label == .table || block.label == .chart {
                    guard (block.source ?? page.blockSource) == .visionLanguageModel,
                          let cells = cells(from: block.text), !cells.isEmpty else { continue }
                    count += 1
                    let page = item.pages.count > 1 ? String(localized: "-p\(pageIndex + 1)") : ""
                    sheets.append(Sheet(name: String(localized: "\(stem)\(page)-Table \(count)"), cells: cells))
                }
            }
        }
        return sheets
    }

    /// The cells of an HTML, OTSL or pipe table, placed on a grid.
    static func cells(from text: String) -> [Cell]? {
        let html = PPDocumentAssembler.htmlTable(fromOTSL: text) ?? text
        if html.range(of: "<tr", options: .caseInsensitive) != nil { return cells(fromHTML: html) }
        return cells(fromPipes: text)
    }

    private static func cells(fromHTML html: String) -> [Cell]? {
        guard let rowPattern = try? NSRegularExpression(pattern: "<tr[^>]*>(.*?)</tr>",
                                                        options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let cellPattern = try? NSRegularExpression(pattern: "<t[dh]([^>]*)>(.*?)</t[dh]>",
                                                         options: [.caseInsensitive, .dotMatchesLineSeparators])
        else { return nil }
        func group(_ match: NSTextCheckingResult, _ index: Int, in text: String) -> String {
            Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
        func span(_ name: String, in attributes: String) -> Int {
            guard let range = attributes.range(of: "\(name)\\s*=\\s*[\"']?(\\d+)", options: .regularExpression)
            else { return 1 }
            return max(1, Int(attributes[range].filter(\.isNumber)) ?? 1)
        }

        var occupied = Set<[Int]>()
        var cells: [Cell] = []
        let rows = rowPattern.matches(in: html, range: NSRange(html.startIndex..., in: html))
        for (rowIndex, rowMatch) in rows.enumerated() {
            let rowHTML = group(rowMatch, 1, in: html)
            var column = 0
            for cellMatch in cellPattern.matches(in: rowHTML, range: NSRange(rowHTML.startIndex..., in: rowHTML)) {
                // Skip the columns a cell above still reaches down into.
                while occupied.contains([rowIndex, column]) { column += 1 }
                let attributes = group(cellMatch, 1, in: rowHTML)
                let cell = Cell(row: rowIndex, column: column,
                                rowSpan: span("rowspan", in: attributes),
                                columnSpan: span("colspan", in: attributes),
                                text: plainText(group(cellMatch, 2, in: rowHTML)))
                for r in 0..<cell.rowSpan {
                    for c in 0..<cell.columnSpan { occupied.insert([rowIndex + r, column + c]) }
                }
                cells.append(cell)
                column += cell.columnSpan
            }
        }
        return cells.isEmpty ? nil : cells
    }

    private static func cells(fromPipes text: String) -> [Cell]? {
        let lines = text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.contains("|") }
            // The `---` rule under a header is not a row.
            .filter { !$0.allSatisfy { "|-: ".contains($0) } }
        guard lines.count > 1 else { return nil }
        var cells: [Cell] = []
        for (row, line) in lines.enumerated() {
            var body = Substring(line)
            if body.hasPrefix("|") { body = body.dropFirst() }
            if body.hasSuffix("|") { body = body.dropLast() }
            for (column, value) in body.components(separatedBy: "|").enumerated() {
                cells.append(Cell(row: row, column: column,
                                  text: value.trimmingCharacters(in: .whitespaces)))
            }
        }
        return cells
    }

    /// Cell text as a spreadsheet wants it: line breaks for `<br>`, no tags,
    /// entities decoded.
    private static func plainText(_ html: String) -> String {
        html.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Writing

    static func write(_ sheets: [Sheet], to url: URL) throws {
        var names = Set<String>()
        let named = sheets.map { sheet -> Sheet in
            var sheet = sheet
            sheet.name = uniqueName(sheet.name, among: &names)
            return sheet
        }

        var files: [(String, Data)] = [
            ("[Content_Types].xml", Data(contentTypes(sheetCount: named.count).utf8)),
            ("_rels/.rels", Data("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>\
            </Relationships>
            """.utf8)),
            ("xl/workbook.xml", Data(workbook(named).utf8)),
            ("xl/_rels/workbook.xml.rels", Data(workbookRelationships(sheetCount: named.count).utf8)),
            // Not strictly required, but readers other than Excel fall back to
            // odd defaults — rows a page tall — without a base style.
            ("xl/styles.xml", Data("""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\
            <fonts count="1"><font><sz val="11"/><name val="Calibri"/></font></fonts>\
            <fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>\
            <borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>\
            <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>\
            <cellXfs count="2"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>\
            <xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0" applyAlignment="1"><alignment vertical="top" wrapText="1"/></xf></cellXfs>\
            <cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>\
            </styleSheet>
            """.utf8)),
        ]
        for (index, sheet) in named.enumerated() {
            files.append(("xl/worksheets/sheet\(index + 1).xml", Data(worksheet(sheet).utf8)))
        }
        try StoredZip.archive(files).write(to: url, options: .atomic)
    }

    /// Excel's rules for a sheet name: at most 31 characters, none of
    /// `[]:*?/\`, and unique in the workbook.
    private static func uniqueName(_ name: String, among used: inout Set<String>) -> String {
        let cleaned = String(name.map { "[]:*?/\\".contains($0) ? "_" : $0 })
        var candidate = String(cleaned.prefix(31))
        var suffix = 2
        while used.contains(candidate.lowercased()) {
            let tail = "(\(suffix))"
            candidate = String(cleaned.prefix(31 - tail.count)) + tail
            suffix += 1
        }
        used.insert(candidate.lowercased())
        return candidate
    }

    private static func contentTypes(sheetCount: Int) -> String {
        let sheets = (1...max(sheetCount, 1)).prefix(sheetCount).map {
            "<Override PartName=\"/xl/worksheets/sheet\($0).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
        }.joined()
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/>\
        <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>\
        <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>\
        \(sheets)</Types>
        """
    }

    private static func workbook(_ sheets: [Sheet]) -> String {
        let entries = sheets.enumerated().map { index, sheet in
            "<sheet name=\"\(escaped(sheet.name))\" sheetId=\"\(index + 1)\" r:id=\"rId\(index + 1)\"/>"
        }.joined()
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" \
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">\
        <sheets>\(entries)</sheets></workbook>
        """
    }

    private static func workbookRelationships(sheetCount: Int) -> String {
        let entries = (0..<sheetCount).map {
            "<Relationship Id=\"rId\($0 + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\($0 + 1).xml\"/>"
        }.joined() + "<Relationship Id=\"rId\(sheetCount + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/>"
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\(entries)</Relationships>
        """
    }

    private static func worksheet(_ sheet: Sheet) -> String {
        // The positions a merge covers get empty cells of their own, as Excel
        // writes them: readers that lay a sheet out cell by cell otherwise
        // shift the rest of the row into the gap.
        var placed = sheet.cells
        for cell in sheet.cells where cell.rowSpan > 1 || cell.columnSpan > 1 {
            for r in 0..<cell.rowSpan {
                for c in 0..<cell.columnSpan where r > 0 || c > 0 {
                    placed.append(Cell(row: cell.row + r, column: cell.column + c, text: ""))
                }
            }
        }
        let byRow = Dictionary(grouping: placed, by: \.row)
        let columns = max(1, sheet.cells.map { $0.column + $0.columnSpan }.max() ?? 1)
        var rows = ""
        for row in byRow.keys.sorted() {
            let cells = byRow[row]!.sorted { $0.column < $1.column }.map { cell -> String in
                let ref = reference(row: cell.row, column: cell.column)
                if cell.text.isEmpty { return "<c r=\"\(ref)\" s=\"1\"/>" }
                // A plain number stays a number, so the sheet can sum it. "1,200"
                // and "08" stay text: reading them as numbers would change them.
                if cell.text.range(of: "^-?(0|[1-9][0-9]*)(\\.[0-9]+)?$", options: .regularExpression) != nil {
                    return "<c r=\"\(ref)\" s=\"1\"><v>\(cell.text)</v></c>"
                }
                return "<c r=\"\(ref)\" s=\"1\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(escaped(cell.text))</t></is></c>"
            }.joined()
            rows += "<row r=\"\(row + 1)\">\(cells)</row>"
        }
        let merges = sheet.cells.filter { $0.rowSpan > 1 || $0.columnSpan > 1 }.map { cell in
            "<mergeCell ref=\"\(reference(row: cell.row, column: cell.column)):"
                + "\(reference(row: cell.row + cell.rowSpan - 1, column: cell.column + cell.columnSpan - 1))\"/>"
        }
        let mergeXML = merges.isEmpty ? "" : "<mergeCells count=\"\(merges.count)\">\(merges.joined())</mergeCells>"
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\
        <sheetFormatPr defaultRowHeight="15"/><cols><col min="1" max="\(columns)" width="16" customWidth="1"/></cols>\
        <sheetData>\(rows)</sheetData>\(mergeXML)</worksheet>
        """
    }

    /// `A1`-style reference, zero-based in.
    private static func reference(row: Int, column: Int) -> String {
        var letters = ""
        var value = column + 1
        while value > 0 {
            let remainder = (value - 1) % 26
            letters = String(UnicodeScalar(65 + remainder)!) + letters
            value = (value - 1) / 26
        }
        return "\(letters)\(row + 1)"
    }

    private static func escaped(_ text: String) -> String {
        // Characters XML 1.0 cannot carry at all are dropped rather than
        // producing a file Excel refuses to open.
        let allowed = text.unicodeScalars.filter {
            $0 == "\t" || $0 == "\n" || $0 == "\r" || $0.value >= 0x20
        }
        return String(String.UnicodeScalarView(allowed))
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// A zip archive whose entries are stored, not compressed: everything an
/// `.xlsx` needs, and nothing a reader can trip over.
enum StoredZip {
    static func archive(_ files: [(path: String, data: Data)]) -> Data {
        var archive = Data()
        var directory = Data()
        for (path, data) in files {
            let name = Data(path.utf8)
            let crc = crc32(data)
            let offset = UInt32(archive.count)
            // Local file header.
            archive.append(le32(0x04034b50))
            archive.append(le16(20)); archive.append(le16(0x0800)); archive.append(le16(0))   // version, UTF-8 names, stored
            archive.append(le16(0)); archive.append(le16(0x21))                                  // time, date (1980-01-01)
            archive.append(le32(crc)); archive.append(le32(UInt32(data.count))); archive.append(le32(UInt32(data.count)))
            archive.append(le16(UInt16(name.count))); archive.append(le16(0))
            archive.append(name); archive.append(data)
            // Central directory entry.
            directory.append(le32(0x02014b50))
            directory.append(le16(20)); directory.append(le16(20)); directory.append(le16(0x0800)); directory.append(le16(0))
            directory.append(le16(0)); directory.append(le16(0x21))
            directory.append(le32(crc)); directory.append(le32(UInt32(data.count))); directory.append(le32(UInt32(data.count)))
            directory.append(le16(UInt16(name.count))); directory.append(le16(0)); directory.append(le16(0))
            directory.append(le16(0)); directory.append(le16(0)); directory.append(le32(0))
            directory.append(le32(offset)); directory.append(name)
        }
        let directoryOffset = UInt32(archive.count)
        archive.append(directory)
        archive.append(le32(0x06054b50))
        archive.append(le16(0)); archive.append(le16(0))
        archive.append(le16(UInt16(files.count))); archive.append(le16(UInt16(files.count)))
        archive.append(le32(UInt32(directory.count))); archive.append(le32(directoryOffset))
        archive.append(le16(0))
        return archive
    }

    private static func le16(_ value: UInt16) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
    private static func le32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }

    private static let table: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFFFFFF
    }
}
