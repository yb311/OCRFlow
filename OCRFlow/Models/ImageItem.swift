import Foundation
import AppKit

enum ProcessingStatus: String, Equatable, Codable {
    case pending = "pending"
    case processing = "processing"
    case completed = "completed"
    case failed = "failed"
    /// Stopped part-way through. Distinct from `pending` so the list says what
    /// happened, and distinct from `completed` because whatever the engine had
    /// produced by then is a fragment of the page, not a result.
    case cancelled = "cancelled"

    var label: String {
        switch self {
        case .pending:    return String(localized: "Pending")
        case .processing: return String(localized: "Recognizing")
        case .completed:  return String(localized: "Completed")
        case .failed:     return String(localized: "Failed")
        case .cancelled:  return String(localized: "Cancelled")
        }
    }
}

/// How far a stopped document got, and where its pages are kept.
struct ResumePoint: Equatable {
    /// The recognition cache key the pages are stored under: the file's
    /// bytes and the settings. Either changing gives a different key, and the
    /// pages kept under this one are not used.
    var key: String
    var total: Int
    var read: Int
}

struct ImageItem: Identifiable, Equatable {
    let id: UUID
    let url: URL
    /// The folder this file was added through, when it came in as part of
    /// one. A separate export recreates the tree below it.
    var root: URL?
    /// A small picture for the file list, made in the background.
    var thumbnail: NSImage?
    var status: ProcessingStatus
    /// The whole document, assembled from the pages and post-processed.
    var ocrText: String
    /// The whole document as Markdown. Empty for a result with no structure.
    var markdown: String
    var pages: [PageResult]
    var errorMessage: String?
    var processingProgress: Double   // 0.0 – 1.0, used when status == .processing
    /// Pages finished and pages in all, while a multi-page file is being read.
    var pagesDone = 0
    var pageCount = 0
    /// Set while a multi-page document is part-way read: it was stopped, the
    /// app quit, or it is being read right now.
    var resume: ResumePoint?
    /// Which engine produced the result currently attached, so an export can
    /// say where the text came from.
    var engine: OCREngine?
    /// How long the last run took.
    var elapsed: TimeInterval?
    /// True when the last run found this file, read the same way, in the
    /// recognition cache instead of reading it again.
    var reusedCachedResult = false
    /// The result translated, when it has been.
    var translation: DocumentTranslation?

    var fileName: String { url.lastPathComponent }
    var fileExtension: String { url.pathExtension.uppercased() }
    var isPDF: Bool { url.pathExtension.lowercased() == "pdf" }

    /// The path below the folder it was added through, for an export that
    /// keeps the source's structure: `2024/合同/扫描001.pdf`.
    var relativePath: String {
        guard let root else { return fileName }
        let base = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(base + "/") else { return fileName }
        return String(path.dropFirst(base.count + 1))
    }

    var fileSizeString: String {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64 else { return "—" }
        return size.formatted(.byteCount(style: .file))
    }

    /// Wraps a decoded page so its pixel dimensions survive.
    ///
    /// `NSImage(cgImage:size:)` wraps the image in a snapshot representation
    /// that reports its size scaled by the screen's backing factor — on a
    /// Retina display, twice the pixels the image actually has. Every box
    /// drawn over it then lands at half the right place. A bitmap
    /// representation reports what is really there.
    static func page(from image: CGImage) -> NSImage {
        let rep = NSBitmapImageRep(cgImage: image)
        let page = NSImage(size: NSSize(width: rep.pixelsWide, height: rep.pixelsHigh))
        page.addRepresentation(rep)
        return page
    }

    /// Drops everything a previous run produced.
    ///
    /// A retry or a failed re-run must not leave the last result attached: the
    /// preview overlay draws whatever the item currently holds, so stale boxes
    /// would be painted over an image that has not been recognised — or has
    /// just failed.
    mutating func clearResults() {
        ocrText = ""
        markdown = ""
        pages = []
        engine = nil
        errorMessage = nil
        processingProgress = 0
        pagesDone = 0
        pageCount = 0
        elapsed = nil
        translation = nil
    }

    /// True when the result has structure worth rendering as Markdown.
    var hasMarkdown: Bool { !markdown.isEmpty }

    /// Anything worth copying or exporting.
    var hasContent: Bool { !ocrText.isEmpty || hasMarkdown }

    /// A finished run with something in it. The single test behind every
    /// export control, so what a button offers and what the export writes can
    /// not drift apart.
    var isExportable: Bool { status == .completed && hasContent }

    /// Every note on every page, with the page it belongs to.
    var reviewNotes: [(page: Int, note: ReviewNote)] {
        pages.enumerated().flatMap { index, page in page.allNotes.map { (index, $0) } }
    }

    /// A finished result something in which is worth checking.
    var needsReview: Bool {
        status == .completed && pages.contains(where: \.needsReview)
    }

    /// True once any region has been corrected by hand.
    var isCorrected: Bool {
        pages.contains { $0.blocks.contains(where: \.isCorrected) }
    }

    /// Mean confidence across recognised lines, or nil when there are none.
    var averageConfidence: Double? {
        let lines = pages.flatMap(\.lines)
        guard !lines.isEmpty else { return nil }
        return lines.reduce(0) { $0 + $1.confidence } / Double(lines.count)
    }

    static func == (lhs: ImageItem, rhs: ImageItem) -> Bool {
        lhs.id == rhs.id && lhs.status == rhs.status &&
        lhs.ocrText == rhs.ocrText && lhs.markdown == rhs.markdown &&
        lhs.processingProgress == rhs.processingProgress &&
        lhs.pagesDone == rhs.pagesDone && lhs.resume == rhs.resume &&
        lhs.pages == rhs.pages && lhs.thumbnail === rhs.thumbnail &&
        lhs.errorMessage == rhs.errorMessage && lhs.translation == rhs.translation
    }

    init(url: URL, root: URL? = nil, id: UUID = UUID()) {
        self.id = id
        self.url = url
        self.root = root
        self.status = .pending
        self.ocrText = ""
        self.markdown = ""
        self.pages = []
        self.processingProgress = 0
        self.engine = nil
    }
}

/// One place a search found its text in a result: a page, and the region or
/// line on it the text was read from, when there is one.
struct TextMatch: Equatable {
    enum Place: Equatable {
        case block(Int)
        case line(Int)
        /// Text with no box behind it: a page read as a whole.
        case page
    }

    let page: Int
    let place: Place
}

extension ImageItem {
    /// Every place `needle` occurs, page by page and in reading order on each
    /// page, so stepping through them reads the document front to back.
    func matches(of needle: String) -> [TextMatch] {
        guard !needle.isEmpty else { return [] }
        return pages.enumerated().flatMap { index, page -> [TextMatch] in
            if !page.blocks.isEmpty {
                return page.blocks.indices
                    .filter { page.blocks[$0].text.localizedCaseInsensitiveContains(needle) }
                    .sorted { page.blocks[$0].readingOrder < page.blocks[$1].readingOrder }
                    .map { TextMatch(page: index, place: .block($0)) }
            }
            let lines = page.lines.indices.filter { page.lines[$0].text.localizedCaseInsensitiveContains(needle) }
            if !lines.isEmpty { return lines.map { TextMatch(page: index, place: .line($0)) } }
            let whole = page.rawMarkdown.isEmpty ? page.rawText : page.rawMarkdown
            return whole.localizedCaseInsensitiveContains(needle) ? [TextMatch(page: index, place: .page)] : []
        }
    }
}
