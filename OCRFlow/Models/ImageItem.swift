import Foundation
import AppKit

enum ProcessingStatus: String, Equatable {
    case pending = "pending"
    case processing = "processing"
    case completed = "completed"
    case failed = "failed"

    var label: String {
        switch self {
        case .pending:    return "待处理"
        case .processing: return "识别中"
        case .completed:  return "已完成"
        case .failed:     return "失败"
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

    var fileName: String { url.lastPathComponent }
    var fileExtension: String { url.pathExtension.uppercased() }

    var fileSizeString: String {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64 else { return "—" }
        let kb = Double(size) / 1024
        if kb < 1024 { return String(format: "%.1f KB", kb) }
        return String(format: "%.1f MB", kb / 1024)
    }

    static func == (lhs: ImageItem, rhs: ImageItem) -> Bool {
        lhs.id == rhs.id && lhs.status == rhs.status &&
        lhs.ocrText == rhs.ocrText && lhs.processingProgress == rhs.processingProgress
    }

    init(url: URL) {
        self.id = UUID()
        self.url = url
        self.status = .pending
        self.ocrText = ""
        self.processingProgress = 0
        self.thumbnail = NSImage(contentsOf: url)
    }
}
