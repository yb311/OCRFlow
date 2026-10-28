import Foundation
import CoreGraphics

/// The 25 layout classes PP-DocLayoutV3 predicts.
///
/// The order is load-bearing: a class id from the model is an index into this
/// list, and it must stay identical to `label_list` in the model's
/// `inference.yml`. Never reorder these cases.
enum PPLayoutLabel: Int, CaseIterable {
    case abstract = 0
    case algorithm
    case asideText
    case chart
    case content
    case displayFormula
    case docTitle
    case figureTitle
    case footer
    case footerImage
    case footnote
    case formulaNumber
    case header
    case headerImage
    case image
    case inlineFormula
    case number
    case paragraphTitle
    case reference
    case referenceContent
    case seal
    case table
    case text
    case verticalText
    case visionFootnote

    /// The identifier PaddleOCR uses, for logs and for the JSON export.
    var rawName: String {
        switch self {
        case .abstract:         return "abstract"
        case .algorithm:        return "algorithm"
        case .asideText:        return "aside_text"
        case .chart:            return "chart"
        case .content:          return "content"
        case .displayFormula:   return "display_formula"
        case .docTitle:         return "doc_title"
        case .figureTitle:      return "figure_title"
        case .footer:           return "footer"
        case .footerImage:      return "footer_image"
        case .footnote:         return "footnote"
        case .formulaNumber:    return "formula_number"
        case .header:           return "header"
        case .headerImage:      return "header_image"
        case .image:            return "image"
        case .inlineFormula:    return "inline_formula"
        case .number:           return "number"
        case .paragraphTitle:   return "paragraph_title"
        case .reference:        return "reference"
        case .referenceContent: return "reference_content"
        case .seal:             return "seal"
        case .table:            return "table"
        case .text:             return "text"
        case .verticalText:     return "vertical_text"
        case .visionFootnote:   return "vision_footnote"
        }
    }

    var label: String {
        switch self {
        case .abstract:         return String(localized: "Abstract")
        case .algorithm:        return String(localized: "Algorithm")
        case .asideText:        return String(localized: "Side note")
        case .chart:            return String(localized: "Chart")
        case .content:          return String(localized: "Table of contents")
        case .displayFormula:   return String(localized: "Display formula")
        case .docTitle:         return String(localized: "Document title")
        case .figureTitle:      return String(localized: "Figure title")
        case .footer:           return String(localized: "Footer")
        case .footerImage:      return String(localized: "Footer image")
        case .footnote:         return String(localized: "Footnote")
        case .formulaNumber:    return String(localized: "Formula number")
        case .header:           return String(localized: "Header")
        case .headerImage:      return String(localized: "Header image")
        case .image:            return String(localized: "Image")
        case .inlineFormula:    return String(localized: "Inline formula")
        case .number:           return String(localized: "Page number")
        case .paragraphTitle:   return String(localized: "Paragraph title")
        case .reference:        return String(localized: "References")
        case .referenceContent: return String(localized: "Reference content")
        case .seal:             return String(localized: "Seal")
        case .table:            return String(localized: "Table")
        case .text:             return String(localized: "Body text")
        case .verticalText:     return String(localized: "Vertical text")
        case .visionFootnote:   return String(localized: "Figure note")
        }
    }

    /// Which PaddleOCR-VL prompt reads this kind of block.
    ///
    /// Mirrors the routing the official two-stage pipeline performs after
    /// layout analysis: every block goes to the VLM, but with the prompt that
    /// matches what the block contains.
    var vlTask: VLTask? {
        switch self {
        case .table:
            return .table
        case .displayFormula, .inlineFormula, .formulaNumber:
            return .formula
        case .chart:
            return .chart
        case .seal:
            return .seal
        case .image, .headerImage, .footerImage:
            // Figures carry no text to transcribe; the assembler emits a
            // placeholder so the reading order stays intact.
            return nil
        default:
            return .ocr
        }
    }

    /// Blocks the assembler represents with a figure placeholder, in document
    /// order. `DocumentFigures` crops these out of the page to fill the
    /// placeholders in, so the two must agree on the set.
    var producesFigure: Bool {
        switch self {
        case .image, .headerImage, .footerImage, .chart: return true
        default:                                         return false
        }
    }

    /// Running headers, footers and page numbers repeat on every page and only
    /// add noise to an extracted document.
    var isPageFurniture: Bool {
        self == .header || self == .footer || self == .number
    }

    /// Looks a label back up from the identifier PaddleOCR uses for it, which
    /// is what the settings file stores.
    init?(rawName: String) {
        guard let match = PPLayoutLabel.allCases.first(where: { $0.rawName == rawName }) else {
            return nil
        }
        self = match
    }

    /// The regions PaddleOCR calls 辅助内容 — everything that frames a page
    /// rather than being part of what it says. The reference pipeline filters
    /// all of them by default and offers one switch each.
    static let auxiliary: [PPLayoutLabel] = [
        .header, .footer, .number, .footnote, .asideText, .headerImage, .footerImage,
    ]

    var isAuxiliary: Bool { Self.auxiliary.contains(self) }
}

extension Array where Element == PPLayoutBlock {
    /// Re-labels header/footer/page-number blocks that are not in a margin as
    /// plain text.
    ///
    /// The classifier applies those labels by appearance as much as by
    /// position, so a title line or a stray paragraph in the middle of a page
    /// can come back as `header`. With 丢弃页眉、页脚与页码 on — the default —
    /// that block then vanishes from the document without a trace. Only a
    /// short block actually sitting in the top or bottom margin is treated as
    /// furniture; everything else keeps its content.
    func reclassifyingFalsePageFurniture(pageHeight: CGFloat) -> [PPLayoutBlock] {
        guard pageHeight > 0 else { return self }
        let topMargin = pageHeight * 0.12
        let bottomMargin = pageHeight * 0.88

        return map { block in
            guard block.label.isPageFurniture else { return block }
            let inMargin = block.rect.midY <= topMargin || block.rect.midY >= bottomMargin
            let short = block.rect.height <= pageHeight * 0.10
            // A footer that reaches the top of the page, or a header halfway
            // down it, is a misread label, not a margin.
            let placed: Bool
            switch block.label {
            case .header: placed = block.rect.midY <= topMargin
            case .footer: placed = block.rect.midY >= bottomMargin
            default:      placed = inMargin
            }
            guard placed, short else {
                var promoted = block
                promoted.label = .text
                return promoted
            }
            return block
        }
    }
}

/// One block of the page, in source-image pixel coordinates.
struct PPLayoutBlock: Equatable, Codable {
    var rect: CGRect
    var label: PPLayoutLabel
    var score: Double
    /// Position in the page's reading order, filled in by `PPReadingOrder`.
    var readingOrder: Int = 0
    /// What was read out of this block. Empty until recognition runs.
    var text: String = ""
    /// Who read `text`, when it differs from the page as a whole — the layered
    /// pipeline hands each region to whichever reader suits it, so one page can
    /// mix all three.
    var source: PPTextSource?
    /// Why this region went to the reader it did, when that was a decision
    /// rather than the default: "PP-OCRv6 average confidence 62%; reread with
    /// PaddleOCR-VL".
    var routing: RoutingReason?
    /// What about this region is worth a person's attention, if anything.
    var review: ReviewReason?
    /// How many inline formulas the layout model found inside this region —
    /// regions it then folded into this one rather than reading twice.
    var inlineFormulas: Int?
    /// The text as recognised, before anyone corrected it. Nil until a
    /// correction is made, so re-recognising never silently replaces an edit.
    var recognisedText: String?
    /// Another reading of this region that disagrees with `text` — the other
    /// engine's, or the one before a re-read — kept while the region is under
    /// review so a person can pick between the two instead of retyping.
    var alternative: AlternativeReading?

    var isCorrected: Bool { recognisedText != nil }
}

/// A second reading of a region, and who made it.
struct AlternativeReading: Equatable, Codable {
    var source: PPTextSource
    var text: String
    /// What sets it apart, when "who read it" is not enough.
    var note: Note?

    enum Note: String, Codable {
        /// The reading a reread replaced.
        case beforeReread

        var label: String {
            switch self {
            case .beforeReread: return String(localized: "Before reread")
            }
        }
    }

    /// True when two readings say the same thing and differ only in how it is
    /// laid out — where the lines break, full- or half-width punctuation, a
    /// word hyphenated at a line end, a table's markup. Asking a person to
    /// choose between those is a false alarm.
    ///
    /// Spaces are folded, not dropped: "Table3rows" against "Table 3 rows" is
    /// a real difference. A minus sign is never dropped either.
    static func isEquivalent(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        if let left = MDParser.parseHTMLTable(a), let right = MDParser.parseHTMLTable(b),
           a.range(of: "<tr", options: .caseInsensitive) != nil,
           b.range(of: "<tr", options: .caseInsensitive) != nil {
            let cells = { (table: MDTable) in
                table.rows.map { $0.cells.filter { !$0.isContinuation }.map { normalized($0.text, joiningHyphens: false) } }
            }
            return cells(left) == cells(right)
        }
        return normalized(a, joiningHyphens: false) == normalized(b, joiningHyphens: false)
            || normalized(a, joiningHyphens: true) == normalized(b, joiningHyphens: true)
    }

    private static func normalized(_ text: String, joiningHyphens: Bool) -> String {
        // NFKC: full-width letters, digits and punctuation become their
        // ordinary forms.
        var text = text.precomposedStringWithCompatibilityMapping
        text = joiningHyphens
            // "archi-⏎tecture" was one word broken at the margin.
            ? text.replacingOccurrences(of: "(?<=\\p{L})-[ \\t]*\\n\\s*(?=\\p{L})", with: "",
                                        options: .regularExpression)
            // "point-⏎wise" is "point-wise" with a line break in it.
            : text.replacingOccurrences(of: "-[ \\t]*\\n\\s*", with: "-", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespaces)
    }
}

extension PPLayoutLabel: Codable {
    /// Stored by PaddleOCR's own name rather than the class index, so a model
    /// that renumbers its classes cannot turn a saved table into a footer.
    init(from decoder: Decoder) throws {
        let name = try decoder.singleValueContainer().decode(String.self)
        guard let label = PPLayoutLabel(rawName: name) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "unknown layout label \(name)"))
        }
        self = label
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawName)
    }
}
