import Foundation
import AppKit
import UniformTypeIdentifiers
import os

extension OCRViewModel {

    // MARK: - Export

    /// Export a specific set of items (defaults to all completed if ids is empty)
    func exportItems(ids: Set<UUID>? = nil) {
        let targets: [ImageItem]
        if let ids, !ids.isEmpty {
            targets = items.filter { ids.contains($0.id) && $0.isExportable }
        } else {
            targets = items.filter(\.isExportable)
        }
        guard !targets.isEmpty else { return }

        let format = resolvedFormat(for: targets)
        switch exportLayout {
        case .combined: exportCombined(targets, format: format)
        case .separate: exportSeparately(targets, format: format)
        }
    }

    /// Markdown is only offered when something in the batch actually has any;
    /// asking for it from a plain Apple Vision run would write a `.md` holding
    /// nothing but the text that a `.txt` would have held.
    func resolvedFormat(for targets: [ImageItem]) -> ExportFormat {
        guard exportFormat == .markdown, !targets.contains(where: \.hasMarkdown) else {
            return exportFormat
        }
        return .plainText
    }

    private func exportCombined(_ targets: [ImageItem], format: ExportFormat) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.contentType(for: format)]
        if targets.count == 1 {
            panel.nameFieldStringValue = "\(Self.exportStem(for: targets[0])).\(format.fileExtension)"
            panel.message = String(localized: "Export the results for “\(targets[0].fileName)”")
        } else {
            panel.nameFieldStringValue = "OCRFlow_Results.\(format.fileExtension)"
            panel.message = String(localized: "Export results for \(targets.count) files (combined into one file)")
        }
        panel.prompt = String(localized: "Export")
        guard panel.runModal() == .OK, let url = panel.url else { return }

        switch format {
        case .json:
            reportExportFailures([write(Self.jsonData(targets.map(exportPayload(for:))), to: url)].compactMap { $0 })
        case .searchablePDF:
            writeSearchablePDFs([(targets, url)], reveal: url)
        case .excel:
            writeWorkbooks([(targets, url)], reveal: url)
        case .markdown, .plainText:
            let text = targets
                .map { item -> String in
                    let body = self.body(of: item, format: format, alongside: url)
                    guard exportIncludeFilename else { return body }
                    return format == .markdown ? "# \(item.fileName)\n\n\(body)"
                                               : "=== \(item.fileName) ===\n\(body)"
                }
                .joined(separator: exportSeparator.separator)
            reportExportFailures([write(Data(text.utf8), to: url)].compactMap { $0 })
        }
    }

    /// Writes one exported file; says what went wrong when it could not.
    private func write(_ data: Data, to url: URL) -> String? {
        do {
            try data.write(to: url, options: .atomic)
            return nil
        } catch {
            return String(localized: "\(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// Tells the user which files could not be written. A watched folder's
    /// exports run with nobody looking, so theirs go to the log instead.
    private func reportExportFailures(_ failures: [String], interactive: Bool = true) {
        guard !failures.isEmpty else { return }
        guard interactive else {
            for failure in failures { Self.log.error("Watched-folder export failed: \(failure, privacy: .private)") }
            return
        }
        let alert = NSAlert()
        alert.messageText = String(localized: "\(failures.count) files couldn't be exported")
        alert.informativeText = failures.prefix(8).joined(separator: "\n")
        alert.runModal()
    }

    private static let log = Logger(subsystem: "com.ocrflow.app", category: "export")

    /// One file per source, into a folder the user picks. A batch of scans is
    /// usually wanted as a batch of documents, not as one long one.
    ///
    /// Files that came in through a folder are laid out the way that folder
    /// was — `合同/2024/扫描001.pdf_OCR.md` — so a thousand results do not land
    /// in one flat heap with their organisation thrown away.
    private func exportSeparately(_ targets: [ImageItem], format: ExportFormat) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Choose where to export. \(targets.count) files will each be saved as .\(format.fileExtension), keeping the original folder structure")
        panel.prompt = String(localized: "Export Here")
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        writeSeparately(targets, format: format, into: folder, reveal: folder)
    }

    /// One result file per item, laid out under `folder` as the sources were.
    /// `reveal` is shown in Finder when the writing is done; nil writes
    /// silently, which is how a watched folder's results are exported.
    func writeSeparately(_ targets: [ImageItem], format: ExportFormat, into folder: URL, reveal: URL?) {
        var pdfJobs: [([ImageItem], URL)] = []
        var workbookJobs: [([ImageItem], URL)] = []
        var failures: [String] = []
        for (item, url) in zip(targets, Self.separateExportURLs(for: targets, format: format, in: folder)) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            switch format {
            case .json:
                if let failure = write(Self.jsonData([exportPayload(for: item)]), to: url) { failures.append(failure) }
            case .searchablePDF:
                pdfJobs.append(([item], url))
            case .excel:
                workbookJobs.append(([item], url))
            case .markdown, .plainText:
                let body = self.body(of: item, format: format, alongside: url)
                let text = exportIncludeFilename && format == .markdown
                    ? "# \(item.fileName)\n\n\(body)"
                    : body
                if let failure = write(Data(text.utf8), to: url) { failures.append(failure) }
            }
        }
        reportExportFailures(failures, interactive: reveal != nil)
        if !pdfJobs.isEmpty {
            writeSearchablePDFs(pdfJobs, reveal: reveal)
        } else if !workbookJobs.isEmpty {
            writeWorkbooks(workbookJobs, reveal: reveal)
        } else if let reveal {
            NSWorkspace.shared.open(reveal)
        }
    }

    /// Where each item's result goes in a separate export, in the order given.
    /// Two items only compete for a name when both were added as loose files
    /// with the same name from different folders; the later one is numbered.
    nonisolated static func separateExportURLs(for items: [ImageItem], format: ExportFormat, in folder: URL) -> [URL] {
        var used = Set<String>()
        return items.map { item in
            let directory = exportDirectory(for: item, in: folder)
            var name = exportStem(for: item)
            var suffix = 2
            while !used.insert(directory.appendingPathComponent(name).path).inserted {
                name = "\(exportStem(for: item))-\(suffix)"
                suffix += 1
            }
            return directory.appendingPathComponent("\(name).\(format.fileExtension)")
        }
    }

    /// A result's name keeps the source's whole name, extension included, so
    /// `scan.png` and `scan.pdf` in one folder can never claim the same file
    /// — not in one export, and not across a watched folder's one-at-a-time
    /// exports either.
    nonisolated static func exportStem(for item: ImageItem) -> String {
        "\(item.fileName)_OCR"
    }

    /// Writes each group's tables to a workbook. A group with no recognised
    /// table writes nothing — an empty workbook would only look like a loss.
    private func writeWorkbooks(_ jobs: [([ImageItem], URL)], reveal: URL?) {
        var written = 0
        for (items, url) in jobs {
            let sheets = TableWorkbook.sheets(from: items)
            guard !sheets.isEmpty else { continue }
            do {
                try TableWorkbook.write(sheets, to: url)
                written += 1
            } catch {
                continue
            }
        }
        guard let reveal else { return }
        if written == 0 {
            let alert = NSAlert()
            alert.messageText = String(localized: "No Tables to Export")
            alert.informativeText = String(localized: "Only tables whose structure was recognized by PaddleOCR-VL (or the VL layer in Smart Layering) can be exported to Excel. Tables PP-OCRv6 read as plain text have no cell information.")
            alert.runModal()
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([reveal])
        }
    }

    /// Where a file's result goes: under the folder it came in through, at
    /// the same place it sat in that folder.
    nonisolated static func exportDirectory(for item: ImageItem, in folder: URL) -> URL {
        guard let root = item.root else { return folder }
        let relative = (item.relativePath as NSString).deletingLastPathComponent
        let base = folder.appendingPathComponent(root.lastPathComponent, isDirectory: true)
        return relative.isEmpty ? base : base.appendingPathComponent(relative, isDirectory: true)
    }

    /// Writes PDFs off the main thread — redrawing a few hundred pages takes a
    /// while — and says so if any could not be written.
    private func writeSearchablePDFs(_ jobs: [([ImageItem], URL)], reveal: URL?) {
        Task.detached(priority: .userInitiated) {
            let failures = jobs.compactMap { items, url -> String? in
                do {
                    try SearchablePDFWriter.write(items, to: url)
                    return nil
                } catch {
                    return String(localized: "\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            await MainActor.run {
                guard let reveal else { return }
                if failures.isEmpty {
                    NSWorkspace.shared.activateFileViewerSelecting([reveal])
                } else {
                    let alert = NSAlert()
                    alert.messageText = String(localized: "\(failures.count) PDFs couldn't be written")
                    alert.informativeText = failures.prefix(8).joined(separator: "\n")
                    alert.runModal()
                }
            }
        }
    }

    private func body(of item: ImageItem, format: ExportFormat, alongside file: URL) -> String {
        switch format {
        case .plainText, .json, .searchablePDF, .excel:
            return item.ocrText
        case .markdown:
            guard item.hasMarkdown else { return item.ocrText }
            guard exportFigures else { return item.markdown }
            return writingFigures(of: item, from: item.markdown, alongside: file)
        }
    }

    private static func contentType(for format: ExportFormat) -> UTType {
        switch format {
        case .markdown:      return UTType(filenameExtension: "md") ?? .plainText
        case .plainText:     return .plainText
        case .json:          return .json
        case .searchablePDF: return .pdf
        case .excel:         return UTType(filenameExtension: "xlsx") ?? .data
        }
    }

    // MARK: - JSON export

    /// The structured result, in the shape the rest of the world can read:
    /// every page, every line with its box and confidence, every region with
    /// its label, its place in the reading order, who read it and why.
    private struct ExportedFile: Encodable {
        struct Page: Encodable {
            struct Line: Encodable {
                var text: String
                var confidence: Double
                /// Four corner points, clockwise from the top left, in image pixels.
                var quad: [[Double]]
            }
            struct Region: Encodable {
                var label: String
                var readingOrder: Int
                var score: Double
                /// `[x, y, width, height]` in image pixels.
                var box: [Double]
                var text: String
                var isPageFurniture: Bool
                /// `vlm`, `ppocr` or `pdf_text`.
                var source: String
                var routing: String?
                var review: String?
                /// What the engine read, when the text has been corrected since.
                var recognisedText: String?
            }
            var index: Int
            var width: Double
            var height: Double
            var text: String
            var markdown: String?
            var lines: [Line]
            var regions: [Region]
            var notes: [String]
        }
        var schemaVersion = 2
        var file: String
        var path: String
        var engine: String?
        var text: String
        var markdown: String?
        var pages: [Page]
    }

    private func exportPayload(for item: ImageItem) -> ExportedFile {
        let pages = item.pages.enumerated().map { index, page -> ExportedFile.Page in
            let assembled = pageText(for: item, page: index)
            return ExportedFile.Page(
                index: index + 1,
                width: page.size.width, height: page.size.height,
                text: assembled.text,
                markdown: assembled.markdown.isEmpty ? nil : assembled.markdown,
                lines: page.lines.map { line in
                    .init(text: line.text, confidence: line.confidence,
                          quad: line.quad.map { [Double($0.x), Double($0.y)] })
                },
                regions: page.blocks.map { block in
                    .init(label: block.label.rawName, readingOrder: block.readingOrder,
                          score: block.score,
                          box: [Double(block.rect.minX), Double(block.rect.minY),
                                Double(block.rect.width), Double(block.rect.height)],
                          text: block.text, isPageFurniture: block.label.isPageFurniture,
                          source: Self.exportName(for: block.source ?? page.blockSource),
                          routing: block.routing?.message, review: block.review?.message,
                          recognisedText: block.recognisedText)
                },
                notes: page.notes.map(\.message))
        }
        return ExportedFile(file: item.fileName, path: item.url.path, engine: item.engine?.rawValue,
                            text: item.ocrText, markdown: item.hasMarkdown ? item.markdown : nil,
                            pages: pages)
    }

    private static func exportName(for source: PPTextSource) -> String {
        switch source {
        case .visionLanguageModel: return "vlm"
        case .plainOCR:            return "ppocr"
        case .pdfTextLayer:        return "pdf_text"
        }
    }

    private static func jsonData(_ files: [ExportedFile]) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(files)) ?? Data()
    }

    /// Saves the figures a document points at into a folder beside the exported
    /// file and rewrites the placeholders to reference them.
    ///
    /// Without this the `![图片]()` placeholders leave the export with broken
    /// images: the pictures only exist inside the source page. Every page's
    /// figures are written — each page is decoded again for it — and a
    /// figure that cannot be cropped keeps its empty placeholder.
    private func writingFigures(of item: ImageItem, from markdown: String,
                                alongside file: URL) -> String {
        var crops: [NSImage?] = []
        let pdf = item.isPDF ? PDFSource(url: item.url) : nil
        for (index, page) in item.pages.enumerated() {
            let figureCount = PPDocumentAssembler.contentIndices(page.blocks, dropping: droppedLabels)
                .filter { page.blocks[$0].label.producesFigure }.count
            guard figureCount > 0 else { continue }
            let image = page.rectified?.cgImage(forProposedRect: nil, context: nil, hints: nil)
                ?? (pdf.flatMap { $0.render(page: index)?.image } ?? PageImages.image(at: item.url, frame: index))
            crops += DocumentFigures.crops(for: page, image: image, dropping: droppedLabels)
        }
        guard crops.contains(where: { $0 != nil }) else { return markdown }

        let stem = file.deletingPathExtension().lastPathComponent
        let folderName = "\(stem).assets"
        let folder = file.deletingLastPathComponent().appendingPathComponent(folderName)
        guard (try? FileManager.default.createDirectory(at: folder,
                                                        withIntermediateDirectories: true)) != nil
        else { return markdown }

        let prefix = Self.sanitizedFileStem((item.fileName as NSString).deletingPathExtension)
        var links: [String] = []
        for (index, crop) in crops.enumerated() {
            guard let data = crop?.pngData else {
                links.append("")
                continue
            }
            let name = "\(prefix)-\(index + 1).png"
            do {
                try data.write(to: folder.appendingPathComponent(name))
                let path = "\(folderName)/\(name)"
                links.append(path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path)
            } catch {
                links.append("")
            }
        }
        return PPDocumentAssembler.rewritingFigureLinks(in: markdown, to: links)
    }

    /// Keeps a source file's name usable as part of a figure's file name.
    private static func sanitizedFileStem(_ stem: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = String(stem.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
        return cleaned.isEmpty ? "figure" : cleaned
    }

    /// Writes a watched file's translation beside its result, named for the
    /// language: `scan.pdf_OCR_zh-Hans.md`.
    func exportWatchedTranslation(_ item: ImageItem) {
        guard let output = watchOutputFolder, let translation = item.translation else { return }
        let result = Self.separateExportURLs(for: [item], format: .markdown, in: output)[0]
        let file = result.deletingLastPathComponent()
            .appendingPathComponent("\(result.deletingPathExtension().lastPathComponent)_\(translation.target).md")
        let text = translation.document(of: item.ocrText, bilingual: false)
        if let failure = write(Data(text.utf8), to: file) { reportExportFailures([failure], interactive: false) }
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

    /// Copies the structured document rather than the flattened text, which is
    /// what the Markdown and source panes are showing.
    func copyMarkdown(for id: UUID) {
        guard let item = items.first(where: { $0.id == id }), item.hasMarkdown else {
            copyText(for: id)
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.markdown, forType: .string)
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
}
