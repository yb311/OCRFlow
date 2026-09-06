import Foundation
import AppKit

enum ProcessingStatus: String, Equatable {
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
        case .pending:    return "待处理"
        case .processing: return "识别中"
        case .completed:  return "已完成"
        case .failed:     return "失败"
        case .cancelled:  return "已取消"
        }
    }
}

struct ImageItem: Identifiable, Equatable {
    let id: UUID
    let url: URL
    var thumbnail: NSImage?
    var status: ProcessingStatus
    var ocrText: String
    var errorMessage: String?
    var processingProgress: Double   // 0.0 – 1.0, used when status == .processing
    /// Per-line boxes from PaddleOCR, used to draw the detection overlay.
    /// Empty for Vision, which this app only asks for plain text.
    var textLines: [PPTextLine]
    /// Structured output from the PaddleOCR-VL pipeline. Empty for the other
    /// engines, which produce plain text and per-line boxes instead.
    var markdown: String
    var layoutBlocks: [PPLayoutBlock]

    /// Pixel dimensions of the loaded image, which is the coordinate space
    /// `textLines` are expressed in. `NSImage.size` is in points and can differ.
    var pixelSize: CGSize {
        guard let rep = thumbnail?.representations.first else { return thumbnail?.size ?? .zero }
        return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
    }

    /// Mean confidence across recognised lines, or nil when there are none.
    var averageConfidence: Double? {
        guard !textLines.isEmpty else { return nil }
        return textLines.reduce(0) { $0 + $1.confidence } / Double(textLines.count)
    }

    var fileName: String { url.lastPathComponent }
    var fileExtension: String { url.pathExtension.uppercased() }

    var fileSizeString: String {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64 else { return "—" }
        let kb = Double(size) / 1024
        if kb < 1024 { return String(format: "%.1f KB", kb) }
        return String(format: "%.1f MB", kb / 1024)
    }

    /// Drops everything a previous run produced.
    ///
    /// A retry or a failed re-run must not leave the last result attached: the
    /// preview overlay draws `textLines` and `layoutBlocks` from whatever the
    /// item currently holds, so stale boxes would be painted over an image that
    /// has not been recognised — or has just failed.
    mutating func clearResults() {
        ocrText = ""
        textLines = []
        markdown = ""
        layoutBlocks = []
        errorMessage = nil
        processingProgress = 0
    }

    /// True when the VL pipeline produced a structured document for this item.
    var hasMarkdown: Bool { !markdown.isEmpty }

    /// Anything worth copying or exporting.
    var hasContent: Bool { !ocrText.isEmpty || hasMarkdown }

    /// A finished run with something in it. The single test behind every
    /// export control, so what a button offers and what the export writes can
    /// not drift apart.
    var isExportable: Bool { status == .completed && hasContent }

    static func == (lhs: ImageItem, rhs: ImageItem) -> Bool {
        lhs.id == rhs.id && lhs.status == rhs.status &&
        lhs.ocrText == rhs.ocrText && lhs.markdown == rhs.markdown &&
        lhs.processingProgress == rhs.processingProgress
    }

    init(url: URL) {
        self.id = UUID()
        self.url = url
        self.status = .pending
        self.ocrText = ""
        self.processingProgress = 0
        self.textLines = []
        self.markdown = ""
        self.layoutBlocks = []
        self.thumbnail = NSImage(contentsOf: url)
    }
}
