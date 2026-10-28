import Foundation
import AppKit

/// Something about a page that a person should look at.
///
/// Phrased as what was observed — "Output hit the token limit" — rather than
/// as a score: no engine here reports a calibrated accuracy, and a bare
/// percentage would claim one.
struct ReviewNote: Equatable, Hashable, Codable {
    enum Severity: String, Codable {
        /// Worth checking: the text may be wrong or incomplete.
        case warning
        /// Worth knowing, nothing to fix: "Body text comes from the PDF's text layer".
        case info
    }

    var severity: Severity
    /// The region the note is about, as an index into the page's blocks; nil
    /// for the page as a whole.
    var block: Int?
    var reason: ReviewReason

    var message: String { reason.message }

    static func warning(_ reason: ReviewReason, block: Int? = nil) -> ReviewNote {
        ReviewNote(severity: .warning, block: block, reason: reason)
    }

    static func info(_ reason: ReviewReason, block: Int? = nil) -> ReviewNote {
        ReviewNote(severity: .info, block: block, reason: reason)
    }
}

/// What was observed about a region or a page, kept as what happened and put
/// into words only when shown — so a result read in one language reads right
/// in another, and code can ask what kind of problem it is without matching
/// on text.
enum ReviewReason: Hashable, Codable {
    // A region PP-OCRv6 read on its own.
    /// A table or formula read as plain text, with no VLM to restore it.
    case structureNotRestored(PPLayoutLabel)
    case layoutTextUnread
    case lowConfidence(LowConfidence)

    // A region PaddleOCR-VL read.
    /// It failed; `kept` is whose reading stands instead, nil when there was
    /// none and `error` says why.
    case vlFailed(error: String, kept: PPTextSource?, hadFallback: Bool)
    case vlReadNothing(kept: PPTextSource?, hadFallback: Bool)
    case outputLimit(tokens: Int)
    case repetition
    case interrupted
    case noTableStructure
    case readLessThanHalf
    case disagrees(with: PPTextSource?, overlap: Int)
    case tableCellsMisordered(pairs: Int)
    case tableTextMissing(count: Int, examples: [String])

    // A region read again on request.
    case rereading
    case rereadReadNothing
    case rereadDiffers
    case rereadFailed(error: String)

    // A page.
    case layoutModelMissing
    case pdfTextLayer(PDFTextLayer.Verdict)
    case pdfNativeBody
    case pageFailed(page: Int, error: String?)
    /// Tables or formulas read as plain text because PaddleOCR-VL failed to load.
    case structureReadAsPlainText(loadError: String)
    case pageOutputLimit(tokens: Int)

    var message: String {
        switch self {
        case let .structureNotRestored(label):
            return String(localized: "PaddleOCR-VL isn't installed, so this region (\(label.label)) was read as plain text and its structure wasn't restored")
        case .layoutTextUnread:
            return String(localized: "Layout analysis found text here, but PP-OCRv6 read nothing")
        case let .lowConfidence(finding):
            return String(localized: "\(finding.description); worth checking")
        case let .vlFailed(error, kept, hadFallback):
            return hadFallback
                ? String(localized: "PaddleOCR-VL couldn't read this region; kept the \(Self.name(of: kept)) result")
                : String(localized: "PaddleOCR-VL couldn't read this region: \(error)")
        case let .vlReadNothing(kept, hadFallback):
            return hadFallback
                ? String(localized: "PaddleOCR-VL read nothing; kept the \(Self.name(of: kept)) result")
                : String(localized: "PaddleOCR-VL read nothing")
        case let .outputLimit(tokens):
            return String(localized: "Output hit the \(tokens) token limit; content may be incomplete")
        case .repetition:
            return String(localized: "The model repeated itself and was cut off; something may be missing")
        case .interrupted:
            return String(localized: "PaddleOCR-VL inference was interrupted; content may be incomplete")
        case .noTableStructure:
            return String(localized: "No table structure was recognized; only the text was read")
        case .readLessThanHalf:
            return String(localized: "PaddleOCR-VL read less than half as much text as PP-OCRv6; something may be missing")
        case let .disagrees(other, overlap):
            return String(localized: "Differs a lot from the \(Self.name(of: other)) result (\((Double(overlap) / 100).percentText) character overlap); please check")
        case let .tableCellsMisordered(pairs):
            return String(localized: "\(pairs) pairs of cells in the table are ordered differently from the layout PP-OCRv6 saw; content may be in the wrong rows or columns. Please check")
        case let .tableTextMissing(count, examples):
            let quoted = examples.map { "“\($0)”" }.joined(separator: String(localized: ", "))
            return String(localized: "\(count) pieces of text PP-OCRv6 read inside the table (\(quoted)\(count > examples.count ? String(localized: " etc.") : "")) are missing from it. Cells may have been skipped or misplaced; please check")
        case .rereading:
            return String(localized: "Rereading with PaddleOCR-VL…")
        case .rereadReadNothing:
            return String(localized: "PaddleOCR-VL read nothing; kept the original result")
        case .rereadDiffers:
            return String(localized: "The reread differs from the original. Choose which one to keep")
        case let .rereadFailed(error):
            return String(localized: "PaddleOCR-VL reread failed: \(error)")
        case .layoutModelMissing:
            return String(localized: "The layout model isn't installed, so this page was read with PP-OCRv6 only, without per-region routing")
        case let .pdfTextLayer(verdict):
            return String(localized: "This page's text comes from the PDF text layer (\(verdict.description))")
        case .pdfNativeBody:
            return String(localized: "Body text comes from the PDF's native text layer, without OCR")
        case let .pageFailed(page, error):
            return String(localized: "Page \(page + 1) failed: \(error ?? String(localized: "Unknown error"))")
        case let .structureReadAsPlainText(loadError):
            return String(localized: "This page has tables or formulas, but it was read as plain text: \(String(localized: "Couldn't load PaddleOCR-VL (\(loadError))"))")
        case let .pageOutputLimit(tokens):
            return String(localized: "Page output hit the \(tokens) token limit; content may be incomplete")
        }
    }

    /// True when the reader stopped at its output budget, which a larger one
    /// may get past.
    var isOutputLimit: Bool {
        switch self {
        case .outputLimit, .pageOutputLimit: return true
        default:                             return false
        }
    }

    private static func name(of source: PPTextSource?) -> String {
        source?.label ?? String(localized: "the other engine")
    }
}

/// Why PP-OCRv6's reading of a region is in doubt.
enum LowConfidence: Hashable, Codable {
    case lines(unsure: Int, of: Int)
    case average(percent: Int)

    var description: String {
        switch self {
        case let .lines(unsure, total):
            return String(localized: "\(unsure) of \(total) PP-OCRv6 lines have low confidence")
        case let .average(percent):
            return String(localized: "PP-OCRv6 average confidence \((Double(percent) / 100).percentText)")
        }
    }
}

extension BinaryFloatingPoint {
    /// A fraction written as a whole percentage, the way the user's locale
    /// writes one.
    var percentText: String { Double(self).formatted(.percent.precision(.fractionLength(0))) }
}

/// Why a region went to the reader it did, when that was a decision rather
/// than the default.
enum RoutingReason: Hashable, Codable {
    case verticalText
    case inlineFormulas(Int)
    case ppFoundNothing
    case lowConfidence(LowConfidence)
    case pdfInlineFormulas(Int)
    case pdfNoText
    case rereadOnRequest

    var message: String {
        switch self {
        case .verticalText:
            return String(localized: "Vertical text goes to PaddleOCR-VL")
        case let .inlineFormulas(count):
            return String(localized: "The paragraph has \(count) inline formulas, so PaddleOCR-VL reads it as LaTeX")
        case .ppFoundNothing:
            return String(localized: "PP-OCRv6 found no text here; reading it with PaddleOCR-VL instead")
        case let .lowConfidence(finding):
            return String(localized: "\(finding.description); reread with PaddleOCR-VL")
        case let .pdfInlineFormulas(count):
            return String(localized: "The paragraph has \(count) inline formulas, which the PDF text layer can't represent, so PaddleOCR-VL reads it")
        case .pdfNoText:
            return String(localized: "The PDF text layer has no text here; reading the image with PP-OCRv6 instead")
        case .rereadOnRequest:
            return String(localized: "Reread with PaddleOCR-VL on request")
        }
    }
}

/// What the window is for at the moment.
enum WorkspaceMode: String, CaseIterable, Identifiable {
    /// Browsing the files and reading their results.
    case workspace
    /// Working through what was flagged, one item at a time.
    case review

    var id: String { rawValue }

    var label: String {
        switch self {
        case .workspace: return String(localized: "Workspace")
        case .review:    return String(localized: "Review")
        }
    }
}

/// One thing flagged for review: a region's note, or a note about a page.
struct ReviewEntry: Identifiable, Hashable {
    enum Origin: Hashable {
        /// `PPLayoutBlock.review` on the region at this index.
        case region(Int)
        /// A warning in `PageResult.notes`.
        case note(ReviewNote)
    }

    /// Stays the same while the message changes — a region being re-read is
    /// still the same item in the queue.
    struct Key: Hashable {
        let itemID: UUID
        let page: Int
        let origin: Origin
    }

    let itemID: UUID
    let fileName: String
    let page: Int
    let origin: Origin
    let reason: ReviewReason

    var message: String { reason.message }

    var id: Key { Key(itemID: itemID, page: page, origin: origin) }

    /// The region the entry is about, if it is about one.
    var block: Int? {
        switch origin {
        case let .region(index): return index
        case let .note(note):    return note.block
        }
    }
}

/// Where the document pane should turn to.
struct DocumentFocus: Equatable {
    let itemID: UUID
    let page: Int
    let block: Int?
    /// Asking for the same place twice still moves the pane.
    let token = UUID()
}

/// What one page yielded.
///
/// A multi-page file used to keep page one's boxes and the whole file's text,
/// which left every later page impossible to correct, review or overlay. Each
/// page now carries its own regions, lines and text, and the document is
/// assembled from all of them.
struct PageResult: Equatable {
    /// The size, in pixels, of the image `lines` and `blocks` are expressed in.
    var size: CGSize
    var lines: [PPTextLine] = []
    var blocks: [PPLayoutBlock] = []
    /// Who read the blocks, unless a block says otherwise.
    var blockSource: PPTextSource = .plainOCR
    /// Used when there are no blocks: Apple Vision, PaddleOCR-VL's whole-page
    /// pass, or a PDF's text layer without a layout model to split it.
    var rawText = ""
    var rawMarkdown = ""
    var notes: [ReviewNote] = []
    /// The page after 图片扭曲矫正 flattened it.
    ///
    /// Kept because the boxes belong to *this* image, not to the original: the
    /// rectification is a per-pixel warp, so there is no way to map a box back
    /// onto the photograph.
    var rectified: NSImage?

    /// True when the text and the Markdown can be rebuilt from `blocks`, which
    /// is what lets a document setting — or a correction — apply after the
    /// fact.
    var derivesFromBlocks: Bool { !blocks.isEmpty }

    /// Every note on the page: its own, and each region's.
    var allNotes: [ReviewNote] {
        notes + blocks.indices.compactMap { index in
            blocks[index].review.map { ReviewNote.warning($0, block: index) }
        }
    }

    var needsReview: Bool { allNotes.contains { $0.severity == .warning } }

    /// How many regions each reader handled, for the line under the result.
    var readers: [(source: PPTextSource, count: Int)] {
        guard !blocks.isEmpty else { return [] }
        var counts: [PPTextSource: Int] = [:]
        for block in blocks where block.label.vlTask != nil || !block.text.isEmpty {
            counts[block.source ?? blockSource, default: 0] += 1
        }
        return [PPTextSource.pdfTextLayer, .plainOCR, .visionLanguageModel]
            .compactMap { source in counts[source].map { (source, $0) } }
    }

    static func == (lhs: PageResult, rhs: PageResult) -> Bool {
        lhs.size == rhs.size && lhs.lines == rhs.lines && lhs.blocks == rhs.blocks
            && lhs.blockSource == rhs.blockSource && lhs.rawText == rhs.rawText
            && lhs.rawMarkdown == rhs.rawMarkdown && lhs.notes == rhs.notes
            && lhs.rectified === rhs.rectified
    }
}

extension PageResult: Codable {
    private enum CodingKeys: String, CodingKey {
        case size, lines, blocks, blockSource, rawText, rawMarkdown, notes, rectified
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        size = try container.decode(CGSize.self, forKey: .size)
        lines = try container.decodeIfPresent([PPTextLine].self, forKey: .lines) ?? []
        blocks = try container.decodeIfPresent([PPLayoutBlock].self, forKey: .blocks) ?? []
        blockSource = try container.decodeIfPresent(PPTextSource.self, forKey: .blockSource) ?? .plainOCR
        rawText = try container.decodeIfPresent(String.self, forKey: .rawText) ?? ""
        rawMarkdown = try container.decodeIfPresent(String.self, forKey: .rawMarkdown) ?? ""
        notes = try container.decodeIfPresent([ReviewNote].self, forKey: .notes) ?? []
        rectified = try container.decodeIfPresent(Data.self, forKey: .rectified)
            .flatMap(NSBitmapImageRep.init(data:))
            .map { rep in
                let image = NSImage(size: NSSize(width: rep.pixelsWide, height: rep.pixelsHigh))
                image.addRepresentation(rep)
                return image
            }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(size, forKey: .size)
        try container.encode(lines, forKey: .lines)
        try container.encode(blocks, forKey: .blocks)
        try container.encode(blockSource, forKey: .blockSource)
        try container.encode(rawText, forKey: .rawText)
        try container.encode(rawMarkdown, forKey: .rawMarkdown)
        try container.encode(notes, forKey: .notes)
        try container.encodeIfPresent(rectified?.pngData, forKey: .rectified)
    }
}

extension PageResult {
    /// Text and Markdown for this page, honouring the auxiliary-content
    /// preferences.
    func assembled(dropping: Set<PPLayoutLabel>,
                   inferHeadingLevels: Bool) -> (text: String, markdown: String) {
        guard derivesFromBlocks else { return (rawText, rawMarkdown) }
        return (PPDocumentAssembler.plainText(from: blocks, dropping: dropping),
                PPDocumentAssembler.markdown(from: blocks, dropping: dropping,
                                             source: blockSource,
                                             inferHeadingLevels: inferHeadingLevels))
    }

    /// How sure PP-OCRv6 was about the lines inside a region, or nil when it
    /// did not read them.
    ///
    /// The region's own `score` is how sure the layout model was that there is
    /// a region there at all — not a word about the text in it.
    /// `evenIfReplaced` asks about PP-OCRv6's lines even when another reader's
    /// text has since taken the region over — the confidence of the reading
    /// that is now the alternative.
    func ocrConfidence(ofBlock index: Int, evenIfReplaced: Bool = false) -> Double? {
        guard blocks.indices.contains(index),
              evenIfReplaced || (blocks[index].source ?? blockSource) == .plainOCR else { return nil }
        let rect = blocks[index].rect
        let inside = lines.filter { rect.contains(CGPoint(x: $0.boundingBox.midX, y: $0.boundingBox.midY)) }
        guard !inside.isEmpty else { return nil }
        return inside.reduce(0) { $0 + $1.confidence } / Double(inside.count)
    }

    /// The same boxes on an image `factor` times the size.
    func scaled(by factor: CGFloat) -> PageResult {
        guard factor != 1 else { return self }
        var page = self
        let transform = CGAffineTransform(scaleX: factor, y: factor)
        page.size = CGSize(width: size.width * factor, height: size.height * factor)
        page.blocks = blocks.map { block in
            var block = block
            block.rect = block.rect.applying(transform)
            return block
        }
        page.lines = lines.map { line in
            var line = line
            line.quad = line.quad.map { $0.applying(transform) }
            return line
        }
        return page
    }
}
