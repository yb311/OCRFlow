import Foundation
import AppKit

/// Something about a page that a person should look at.
///
/// Phrased as what was observed — "表格识别输出达到长度上限" — rather than as a
/// score: no engine here reports a calibrated accuracy, and a bare percentage
/// would claim one.
struct ReviewNote: Equatable, Hashable, Codable {
    enum Severity: String, Codable {
        /// Worth checking: the text may be wrong or incomplete.
        case warning
        /// Worth knowing, nothing to fix: "本页取自 PDF 文字层".
        case info
    }

    var severity: Severity
    /// The region the note is about, as an index into the page's blocks; nil
    /// for the page as a whole.
    var block: Int?
    var message: String

    static func warning(_ message: String, block: Int? = nil) -> ReviewNote {
        ReviewNote(severity: .warning, block: block, message: message)
    }

    static func info(_ message: String, block: Int? = nil) -> ReviewNote {
        ReviewNote(severity: .info, block: block, message: message)
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
        case .workspace: return "工作台"
        case .review:    return "复核"
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
    let message: String

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
