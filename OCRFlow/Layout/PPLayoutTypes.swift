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
        case .abstract:         return "摘要"
        case .algorithm:        return "算法"
        case .asideText:        return "旁注"
        case .chart:            return "图表"
        case .content:          return "目录"
        case .displayFormula:   return "行间公式"
        case .docTitle:         return "文档标题"
        case .figureTitle:      return "图题"
        case .footer:           return "页脚"
        case .footerImage:      return "页脚图"
        case .footnote:         return "脚注"
        case .formulaNumber:    return "公式编号"
        case .header:           return "页眉"
        case .headerImage:      return "页眉图"
        case .image:            return "图片"
        case .inlineFormula:    return "行内公式"
        case .number:           return "页码"
        case .paragraphTitle:   return "段落标题"
        case .reference:        return "参考文献"
        case .referenceContent: return "参考文献内容"
        case .seal:             return "印章"
        case .table:            return "表格"
        case .text:             return "正文"
        case .verticalText:     return "竖排文字"
        case .visionFootnote:   return "图注"
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
struct PPLayoutBlock: Equatable {
    var rect: CGRect
    var label: PPLayoutLabel
    var score: Double
    /// Position in the page's reading order, filled in by `PPReadingOrder`.
    var readingOrder: Int = 0
    /// What the VLM read out of this block. Empty until recognition runs.
    var text: String = ""
}
