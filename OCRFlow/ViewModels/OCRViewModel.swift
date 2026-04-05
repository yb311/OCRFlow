import Foundation
import AppKit
import Vision
import Combine
import UniformTypeIdentifiers

// MARK: - OCR Engine

enum OCREngine: String, CaseIterable, Identifiable {
    case visionFast     = "vision_fast"
    case visionAccurate = "vision_accurate"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .visionFast:     return "快速模式"
        case .visionAccurate: return "精准模式"
        }
    }

    var hint: String {
        switch self {
        case .visionFast:     return "速度快，适合批量快速处理"
        case .visionAccurate: return "识别效果好，速度稍慢（推荐）"
        }
    }
}

@MainActor
final class OCRViewModel: ObservableObject {

    // MARK: - Published state

    @Published var items: [ImageItem] = []
    @Published var selectedIDs: Set<UUID> = []
    @Published var isProcessing = false
    @Published var totalProgress: Double = 0        // 0.0 – 1.0
    @Published var recognitionLanguages: [String] = ["zh-Hans", "zh-Hant", "en-US"]
    @Published var ocrEngine: OCREngine = .visionAccurate

    // MARK: - Text post-processing settings
    /// 合并换行为空格（"不换行"模式）
    @Published var mergeLineBreaks = false
    /// 去除连续空行，只保留单个空行
    @Published var removeEmptyLines = false
    /// 去除每行首尾多余空格
    @Published var trimWhitespace = true
    /// 自动去除行内连字符换行（如 "exam-\nple" → "example"）
    @Published var removeHyphenBreaks = false

    // MARK: - Behavior settings
    /// 添加文件后自动开始识别
    @Published var autoStartOnAdd = false
    /// 重新处理时跳过已完成的文件
    @Published var skipCompleted = true

    // MARK: - Export settings
    enum ExportSeparator: String, CaseIterable, Identifiable {
        case emptyLine  = "空行"
        case divider    = "分割线"
        case pageBreak  = "换页符"
        case none       = "无"
        var id: String { rawValue }
        var separator: String {
            switch self {
            case .emptyLine:  return "\n\n"
            case .divider:    return "\n\n---\n\n"
            case .pageBreak:  return "\n\u{0C}\n"
            case .none:       return "\n"
            }
        }
    }
    @Published var exportSeparator: ExportSeparator = .emptyLine
    /// 导出时包含文件名标题
    @Published var exportIncludeFilename = true

    // MARK: - Computed helpers

    /// The single item to show in detail panel (last selected, or nil)
    var selectedItem: ImageItem? {
        guard let id = selectedIDs.first else { return nil }
        return items.first { $0.id == id }
    }

    var selectedItems: [ImageItem] {
        items.filter { selectedIDs.contains($0.id) }
    }

    var completedCount: Int { items.filter { $0.status == .completed }.count }
    var failedCount:    Int { items.filter { $0.status == .failed }.count }

    // MARK: - File import

    func addImages(urls: [URL]) {
        let supported: Set<String> = ["png", "jpg", "jpeg", "tiff", "tif", "bmp", "gif", "heic", "webp", "pdf"]
        let newURLs = urls.filter { supported.contains($0.pathExtension.lowercased()) }
        let existingURLs = Set(items.map(\.url))
        let uniqueNew = newURLs.filter { !existingURLs.contains($0) }.map { ImageItem(url: $0) }
        items.append(contentsOf: uniqueNew)
        if selectedIDs.isEmpty, let first = uniqueNew.first { selectedIDs = [first.id] }
        recalcProgress()
        if autoStartOnAdd && !uniqueNew.isEmpty {
            Task { @MainActor in self.startProcessing() }
        }
    }

    func openFilePicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .bmp, .gif, .heif, .webP, .pdf,
                                     UTType(filenameExtension: "heic") ?? .heif]
        panel.message = "选择图片文件或文件夹"
        panel.prompt = "添加"
        if panel.runModal() == .OK {
            let urls = panel.urls.flatMap { url -> [URL] in
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
                if isDir.boolValue {
                    return (try? FileManager.default.contentsOfDirectory(
                        at: url, includingPropertiesForKeys: nil)) ?? []
                }
                return [url]
            }
            addImages(urls: urls)
        }
    }

    func removeItem(id: UUID) {
        removeItems(ids: [id])
    }

    func removeSelectedItems() {
        removeItems(ids: selectedIDs)
    }

    func removeItems(ids: Set<UUID>) {
        // Determine next selection after removal
        if !selectedIDs.isDisjoint(with: ids) {
            let remaining = items.filter { !ids.contains($0.id) }
            // Pick the item that came right after the last removed one
            if let lastRemovedIdx = items.lastIndex(where: { ids.contains($0.id) }) {
                let candidate = remaining.first(where: { items.firstIndex(of: $0).map { $0 > lastRemovedIdx } ?? false })
                selectedIDs = candidate.map { [$0.id] } ?? (remaining.first.map { [$0.id] } ?? [])
            } else {
                selectedIDs = []
            }
        }
        items.removeAll { ids.contains($0.id) }
        recalcProgress()
    }

    func clearAll() {
        items.removeAll()
        selectedIDs = []
        totalProgress = 0
        isProcessing = false
    }

    // MARK: - OCR processing

    func startProcessing() {
        guard !isProcessing else { return }
        let pendingIDs = items.filter {
            $0.status == .pending || $0.status == .failed || (!skipCompleted && $0.status == .completed)
        }.map(\.id)
        guard !pendingIDs.isEmpty else { return }
        isProcessing = true

        Task {
            for id in pendingIDs {
                guard isProcessing else { break }
                await processItem(id: id)
                recalcProgress()
            }
            isProcessing = false
        }
    }

    func stopProcessing() {
        isProcessing = false
    }

    func retryItem(id: UUID) {
        if let idx = items.firstIndex(where: { $0.id == id }) {
            items[idx].status = .pending
            items[idx].ocrText = ""
            items[idx].errorMessage = nil
        }
    }

    // MARK: - Export

    /// Export a specific set of items (defaults to all completed if ids is empty)
    func exportItems(ids: Set<UUID>? = nil) {
        let targets: [ImageItem]
        if let ids, !ids.isEmpty {
            targets = items.filter { ids.contains($0.id) && $0.status == .completed && !$0.ocrText.isEmpty }
        } else {
            targets = items.filter { $0.status == .completed && !$0.ocrText.isEmpty }
        }
        guard !targets.isEmpty else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        if targets.count == 1 {
            let stem = (targets[0].fileName as NSString).deletingPathExtension
            panel.nameFieldStringValue = "\(stem)_OCR.txt"
            panel.message = "导出「\(targets[0].fileName)」的识别结果"
        } else {
            panel.nameFieldStringValue = "OCRFlow_Results.txt"
            panel.message = "导出 \(targets.count) 个文件的识别结果"
        }
        panel.prompt = "导出"
        if panel.runModal() == .OK, let url = panel.url {
            let sep = exportSeparator.separator
            let text = targets
                .map { exportIncludeFilename ? "=== \($0.fileName) ===\n\($0.ocrText)" : $0.ocrText }
                .joined(separator: sep)
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    func exportSelectedItems() {
        exportItems(ids: selectedIDs)
    }

    func exportResults() {
        exportItems(ids: nil)
    }

    func copyText(for id: UUID) {
        guard let item = items.first(where: { $0.id == id }), !item.ocrText.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.ocrText, forType: .string)
    }

    func copySelectedText() {
        let text = selectedItems
            .filter { $0.status == .completed }
            .map(\.ocrText)
            .joined(separator: "\n\n")
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Private

    private func processItem(id: UUID) async {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].status = .processing
        items[idx].processingProgress = 0

        let url = items[idx].url
        do {
            let text = try await recognizeText(at: url) { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard let self, let i = self.items.firstIndex(where: { $0.id == id }) else { return }
                    self.items[i].processingProgress = progress
                }
            }
            if let i = items.firstIndex(where: { $0.id == id }) {
                var updated = items[i]
                updated.status = .completed
                updated.ocrText = postProcess(text)
                updated.processingProgress = 1.0
                items[i] = updated          // single assignment → one objectWillChange
            }
        } catch {
            if let i = items.firstIndex(where: { $0.id == id }) {
                var updated = items[i]
                updated.status = .failed
                updated.errorMessage = error.localizedDescription
                items[i] = updated
            }
        }
    }

    private func recognizeText(at url: URL, progressCallback: @escaping (Double) -> Void) async throws -> String {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" {
            return try await recognizePDF(at: url, progressCallback: progressCallback)
        } else {
            return try await recognizeImage(at: url, progressCallback: progressCallback)
        }
    }

    private func recognizeImage(at url: URL, progressCallback: @escaping (Double) -> Void) async throws -> String {
        guard let image = NSImage(contentsOf: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw OCRError.imageLoadFailed
        }
        progressCallback(0.2)
        let result = try await performVisionOCR(on: cgImage)
        progressCallback(1.0)
        return result
    }

    private func recognizePDF(at url: URL, progressCallback: @escaping (Double) -> Void) async throws -> String {
        // Use PDFKit to render pages then OCR each
        guard let provider = CGDataProvider(url: url as CFURL),
              let pdfDoc = CGPDFDocument(provider) else {
            throw OCRError.imageLoadFailed
        }
        let pageCount = pdfDoc.numberOfPages
        var allText: [String] = []
        for pageNum in 1...max(1, pageCount) {
            guard let page = pdfDoc.page(at: pageNum) else { continue }
            let mediaBox = page.getBoxRect(.mediaBox)
            let scale: CGFloat = 2.0
            let size = CGSize(width: mediaBox.width * scale, height: mediaBox.height * scale)
            guard let context = CGContext(
                data: nil,
                width: Int(size.width), height: Int(size.height),
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { continue }
            context.setFillColor(CGColor.white)
            context.fill(CGRect(origin: .zero, size: size))
            context.scaleBy(x: scale, y: scale)
            context.drawPDFPage(page)
            guard let cgImage = context.makeImage() else { continue }
            let text = try await performVisionOCR(on: cgImage)
            allText.append(text)
            progressCallback(Double(pageNum) / Double(pageCount))
        }
        return allText.joined(separator: "\n\n")
    }

    private func performVisionOCR(on cgImage: CGImage) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { req, err in
                if let err {
                    continuation.resume(throwing: err)
                    return
                }
                let observations = req.results as? [VNRecognizedTextObservation] ?? []
                let text = observations
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")
                continuation.resume(returning: text)
            }
            request.recognitionLevel = ocrEngine == .visionFast ? .fast : .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = recognitionLanguages

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - Text post-processing

    private func postProcess(_ raw: String) -> String {
        var text = raw

        // 1. 去除连字符换行："exam-\nple" → "example"
        if removeHyphenBreaks {
            text = text.replacingOccurrences(of: "-\n", with: "")
        }

        // 2. 每行首尾去空格
        if trimWhitespace {
            text = text.split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .joined(separator: "\n")
        }

        // 3. 合并连续空行为单个空行
        if removeEmptyLines {
            let multipleNewlines = try? NSRegularExpression(pattern: "\n{3,}", options: [])
            text = multipleNewlines?.stringByReplacingMatches(
                in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "\n\n"
            ) ?? text
        }

        // 4. 合并所有换行为空格（不换行模式）—— 放最后执行
        if mergeLineBreaks {
            text = text
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }

        return text
    }

    private func recalcProgress() {
        guard !items.isEmpty else { totalProgress = 0; return }
        let done = items.filter { $0.status == .completed || $0.status == .failed }.count
        totalProgress = Double(done) / Double(items.count)
    }
}

enum OCRError: LocalizedError {
    case imageLoadFailed

    var errorDescription: String? {
        switch self {
        case .imageLoadFailed: return "无法加载图片文件"
        }
    }
}
