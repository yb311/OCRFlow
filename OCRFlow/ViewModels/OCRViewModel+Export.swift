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
            panel.nameFieldStringValue = "\(String(localized: "OCRFlow Results")).\(format.fileExtension)"
            panel.message = String(localized: "Export results for \(targets.count) files (combined into one file)")
        }
        panel.prompt = String(localized: "Export")
        Task {
            guard let url = await FilePanel.run(panel) else { return }
            writeCombined(targets, format: format, to: url)
        }
    }

    private func writeCombined(_ targets: [ImageItem], format: ExportFormat, to url: URL) {
        switch format {
        case .json:
            let files = targets.map(exportPayload(for:))
            enqueueExport {
                let failures = await BlockingWork.run { [Self.write(Self.jsonData(files), to: url)].compactMap { $0 } }
                self.reportExportFailures(failures)
            }
        case .searchablePDF:
            writeSearchablePDFs([(targets, url)], reveal: url)
        case .excel:
            writeWorkbooks([(targets, url)], reveal: url)
        case .markdown, .plainText:
            let options = exportOptions
            enqueueExport {
                let failures = await BlockingWork.run {
                    let text = Self.combinedText(of: targets, format: format, to: url, options: options)
                    return [Self.write(Data(text.utf8), to: url)].compactMap { $0 }
                }
                self.reportExportFailures(failures)
            }
        }
    }

    /// Every file's result in one text, in the order given.
    private nonisolated static func combinedText(of targets: [ImageItem], format: ExportFormat,
                                                 to url: URL, options: ExportOptions) -> String {
        // Every file's figures go into the one folder beside the export,
        // so two files of the same name — from different folders, or
        // `scan.png` beside `scan.pdf` — must not write over each other's.
        var used = Set<String>()
        let prefixes = targets.map { item -> String in
            let base = figurePrefix(for: item)
            var prefix = base, count = 1
            while !used.insert(prefix).inserted {
                count += 1
                prefix = "\(base)-\(count)"
            }
            return prefix
        }
        return zip(targets, prefixes)
            .map { item, prefix -> String in
                let body = body(of: item, format: format, alongside: url, figurePrefix: prefix, options: options)
                guard options.includeFilename else { return body }
                return format == .markdown ? "# \(item.fileName)\n\n\(body)"
                                           : "=== \(item.fileName) ===\n\(body)"
            }
            .joined(separator: options.separator)
    }

    /// What an export takes from the settings, read on the main actor so the
    /// writing can run off it.
    struct ExportOptions: Sendable {
        var includeFilename: Bool
        var separator: String
        var figures: Bool
        var dropped: Set<PPLayoutLabel>
    }

    private var exportOptions: ExportOptions {
        ExportOptions(includeFilename: exportIncludeFilename, separator: exportSeparator.separator,
                      figures: exportFigures, dropped: droppedLabels)
    }

    /// Runs an export once any export before it has finished writing. The
    /// work itself decodes, renders and writes off the main actor, so the
    /// window stays live through a large export, and two exports never write
    /// the same files at once.
    private func enqueueExport(_ work: @escaping @MainActor () async -> Void) {
        let previous = exportInFlight
        exportInFlight = Task {
            await previous?.value
            await work()
        }
    }

    /// Makes the folder a result goes into.
    private nonisolated static func makeFolder(for file: URL) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
    }

    // MARK: - Originals

    /// The files themselves, as they were added — screenshots, scans, PDFs —
    /// whether or not they have been read. A capture of several pages comes
    /// out as a picture a page, in a folder of its own.
    func exportOriginals(ids: Set<UUID>) {
        let targets = items.filter { ids.contains($0.id) }
        guard !targets.isEmpty else { return }
        if targets.count == 1, Self.pagesInside(targets[0].url) == 1 {
            let item = targets[0]
            let panel = NSSavePanel()
            panel.nameFieldStringValue = item.url.lastPathComponent
            panel.message = String(localized: "Export the original of “\(item.fileName)”")
            panel.prompt = String(localized: "Export")
            Task {
                guard let url = await FilePanel.run(panel) else { return }
                let source = item.url
                enqueueExport {
                    let failure = await BlockingWork.run { () -> String? in
                        try? FileManager.default.removeItem(at: url)
                        do {
                            try FileManager.default.copyItem(at: source, to: url)
                            return nil
                        } catch {
                            return String(localized: "\(url.lastPathComponent): \(error.localizedDescription)")
                        }
                    }
                    if let failure {
                        self.reportExportFailures([failure])
                    } else {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
            }
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Choose where to export the originals of \(targets.count) files")
        panel.prompt = String(localized: "Export Here")
        Task {
            guard let folder = await FilePanel.run(panel) else { return }
            enqueueExport {
                let (written, failures) = await BlockingWork.run { Self.writeOriginals(of: targets, into: folder) }
                self.reportExportFailures(failures)
                if !written.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(written) }
            }
        }
    }

    /// Each item's original into `folder`: what was written, and what could
    /// not be, said for the user.
    nonisolated static func writeOriginals(of targets: [ImageItem], into folder: URL) -> (written: [URL], failures: [String]) {
        var written: [URL] = []
        var failures: [String] = []
        for item in targets {
            do {
                written.append(try exportOriginal(item.url, into: folder))
            } catch {
                failures.append(String(localized: "\(item.fileName): \(error.localizedDescription)"))
            }
        }
        return (written, failures)
    }

    /// Pages held in one image file: more than one only in a multi-page TIFF.
    /// A long screenshot is one picture here, however it is read.
    private nonisolated static func pagesInside(_ url: URL) -> Int {
        guard url.pathExtension.lowercased() != "pdf",
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              (CGImageSourceGetType(source) as String?) == UTType.tiff.identifier else { return 1 }
        return max(1, CGImageSourceGetCount(source))
    }

    /// Copies a file into `folder` under a name not taken there — or, for a
    /// file of several pages, writes a folder of PNGs. Returns what it wrote.
    nonisolated static func exportOriginal(_ source: URL, into folder: URL) throws -> URL {
        func free(_ name: String, _ pathExtension: String?) -> URL {
            func url(_ name: String) -> URL {
                let url = folder.appending(path: name)
                return pathExtension.map { url.appendingPathExtension($0) } ?? url
            }
            var candidate = url(name), count = 1
            while FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) {
                count += 1
                candidate = url("\(name) \(count)")
            }
            return candidate
        }
        let stem = source.deletingPathExtension().lastPathComponent
        let pages = pagesInside(source)
        guard pages > 1 else {
            let target = free(stem, source.pathExtension)
            try FileManager.default.copyItem(at: source, to: target)
            return target
        }
        let pagesFolder = free(stem, nil)
        try FileManager.default.createDirectory(at: pagesFolder, withIntermediateDirectories: true)
        let digits = String(pages).count
        for page in 0..<pages {
            guard let image = PageImages.wholeImage(at: source, frame: page),
                  let destination = CGImageDestinationCreateWithURL(
                      pagesFolder.appending(path: "\(stem) \(String(format: "%0\(digits)d", page + 1)).png") as CFURL,
                      UTType.png.identifier as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(destination, image, nil)
            CGImageDestinationFinalize(destination)
        }
        return pagesFolder
    }

    /// Writes one exported file; says what went wrong when it could not.
    private nonisolated static func write(_ data: Data, to url: URL) -> String? {
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
        prompt = UserPrompt(title: String(localized: "\(failures.count) files couldn't be exported"),
                            message: failures.prefix(8).joined(separator: "\n"))
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
        Task {
            guard let folder = await FilePanel.run(panel) else { return }
            writeSeparately(targets, format: format, into: folder, reveal: folder)
        }
    }

    /// One result file per item, laid out under `folder` as the sources were.
    /// `reveal` is shown in Finder when the writing is done; nil writes
    /// silently, which is how a watched folder's results are exported.
    func writeSeparately(_ targets: [ImageItem], format: ExportFormat, into folder: URL, reveal: URL?) {
        let urls = Self.separateExportURLs(for: targets, format: format, in: folder)
        switch format {
        case .searchablePDF where !targets.isEmpty:
            writeSearchablePDFs(zip(targets, urls).map { ([$0], $1) }, reveal: reveal)
        case .excel where !targets.isEmpty:
            writeWorkbooks(zip(targets, urls).map { ([$0], $1) }, reveal: reveal)
        default:
            let payloads = format == .json ? targets.map(exportPayload(for:)) : []
            let options = exportOptions
            enqueueExport {
                let failures = await BlockingWork.run {
                    zip(targets, urls).enumerated().compactMap { index, job -> String? in
                        let (item, url) = job
                        Self.makeFolder(for: url)
                        switch format {
                        case .json:
                            return Self.write(Self.jsonData([payloads[index]]), to: url)
                        case .markdown, .plainText, .searchablePDF, .excel:
                            let body = Self.body(of: item, format: format, alongside: url, options: options)
                            let text = options.includeFilename && format == .markdown
                                ? "# \(item.fileName)\n\n\(body)"
                                : body
                            return Self.write(Data(text.utf8), to: url)
                        }
                    }
                }
                self.reportExportFailures(failures, interactive: reveal != nil)
                if let reveal { NSWorkspace.shared.open(reveal) }
            }
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
            while !used.insert(directory.appending(component: name).path(percentEncoded: false)).inserted {
                name = "\(exportStem(for: item))-\(suffix)"
                suffix += 1
            }
            return directory.appending(component: "\(name).\(format.fileExtension)")
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
        enqueueExport {
            let (written, failures) = await BlockingWork.run { () -> (Int, [String]) in
                var written = 0
                var failures: [String] = []
                for (items, url) in jobs {
                    let sheets = TableWorkbook.sheets(from: items)
                    guard !sheets.isEmpty else { continue }
                    Self.makeFolder(for: url)
                    do {
                        try TableWorkbook.write(sheets, to: url)
                        written += 1
                    } catch {
                        // Said, rather than passed off as there being no tables.
                        failures.append(String(localized: "\(url.lastPathComponent): \(error.localizedDescription)"))
                    }
                }
                return (written, failures)
            }
            self.reportExportFailures(failures, interactive: reveal != nil)
            guard let reveal, failures.isEmpty else { return }
            if written == 0 {
                self.prompt = UserPrompt(title: String(localized: "No Tables to Export"),
                                         message: String(localized: "Only tables whose structure was recognized by close reading can be exported to Excel. Tables quick reading read as plain text have no cell information."))
            } else {
                NSWorkspace.shared.activateFileViewerSelecting([reveal])
            }
        }
    }

    /// Where a file's result goes: under the folder it came in through, at
    /// the same place it sat in that folder.
    nonisolated static func exportDirectory(for item: ImageItem, in folder: URL) -> URL {
        guard let root = item.root else { return folder }
        let relative = (item.relativePath as NSString).deletingLastPathComponent
        let base = folder.appending(path: root.lastPathComponent, directoryHint: .isDirectory)
        return relative.isEmpty ? base : base.appending(path: relative, directoryHint: .isDirectory)
    }

    /// Writes PDFs off the main thread — redrawing a few hundred pages takes a
    /// while — and says so if any could not be written.
    private func writeSearchablePDFs(_ jobs: [([ImageItem], URL)], reveal: URL?) {
        enqueueExport {
            let failures = await BlockingWork.run {
                jobs.compactMap { items, url -> String? in
                    Self.makeFolder(for: url)
                    do {
                        try SearchablePDFWriter.write(items, to: url)
                        return nil
                    } catch {
                        return String(localized: "\(url.lastPathComponent): \(error.localizedDescription)")
                    }
                }
            }
            guard let reveal else { return }
            if failures.isEmpty {
                NSWorkspace.shared.activateFileViewerSelecting([reveal])
            } else {
                self.prompt = UserPrompt(title: String(localized: "\(failures.count) PDFs couldn't be written"),
                                         message: failures.prefix(8).joined(separator: "\n"))
            }
        }
    }

    private nonisolated static func body(of item: ImageItem, format: ExportFormat, alongside file: URL,
                                         figurePrefix: String? = nil, options: ExportOptions) -> String {
        switch format {
        case .plainText, .json, .searchablePDF, .excel:
            return item.ocrText
        case .markdown:
            guard item.hasMarkdown else { return item.ocrText }
            guard options.figures else { return item.markdown }
            return writingFigures(of: item, from: item.markdown, alongside: file,
                                  prefix: figurePrefix ?? Self.figurePrefix(for: item),
                                  dropping: options.dropped)
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
        return ExportedFile(file: item.fileName, path: item.url.path(percentEncoded: false), engine: item.engine?.rawValue,
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

    private nonisolated static func jsonData(_ files: [ExportedFile]) -> Data {
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
    private nonisolated static func writingFigures(of item: ImageItem, from markdown: String,
                                                   alongside file: URL, prefix: String,
                                                   dropping droppedLabels: Set<PPLayoutLabel>) -> String {
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
        let folder = file.deletingLastPathComponent().appending(component: folderName)
        guard (try? FileManager.default.createDirectory(at: folder,
                                                        withIntermediateDirectories: true)) != nil
        else { return markdown }

        var links: [String] = []
        for (index, crop) in crops.enumerated() {
            guard let data = crop?.pngData else {
                links.append("")
                continue
            }
            let name = "\(prefix)-\(index + 1).png"
            do {
                try data.write(to: folder.appending(component: name))
                let path = "\(folderName)/\(name)"
                links.append(path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path)
            } catch {
                links.append("")
            }
        }
        return PPDocumentAssembler.rewritingFigureLinks(in: markdown, to: links)
    }

    /// What a file's figures are named after: its name, kept usable as part
    /// of a file name.
    private nonisolated static func figurePrefix(for item: ImageItem) -> String {
        sanitizedFileStem((item.fileName as NSString).deletingPathExtension)
    }

    /// Keeps a source file's name usable as part of a figure's file name.
    private nonisolated static func sanitizedFileStem(_ stem: String) -> String {
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
            .appending(component: "\(result.deletingPathExtension().lastPathComponent)_\(translation.target).md")
        let text = translation.document(of: item.ocrText, bilingual: false)
        enqueueExport {
            let failure = await BlockingWork.run { Self.write(Data(text.utf8), to: file) }
            if let failure { self.reportExportFailures([failure], interactive: false) }
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

/// An open or save panel, as a sheet on the window the user is working in —
/// where it belongs, and where the window gets the keys back as it closes —
/// or, with no such window, on its own.
@MainActor
enum FilePanel {
    /// What was chosen; nil when cancelled.
    static func run(_ panel: NSSavePanel, for window: NSWindow? = NSApp.keyWindow ?? NSApp.mainWindow) async -> URL? {
        let response: NSApplication.ModalResponse
        if let window, window.isVisible, window.styleMask.contains(.titled) {
            response = await panel.beginSheetModal(for: window)
        } else {
            NSApp.activate()
            response = await withCheckedContinuation { continuation in
                panel.begin { continuation.resume(returning: $0) }
            }
        }
        return response == .OK ? panel.url : nil
    }

    /// A folder, chosen in a sheet on `window`.
    static func chooseFolder(message: String, prompt: String,
                             for window: NSWindow? = NSApp.keyWindow ?? NSApp.mainWindow) async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = message
        panel.prompt = prompt
        return await run(panel, for: window)
    }
}
