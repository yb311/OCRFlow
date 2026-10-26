#if DEBUG
import Foundation
import PDFKit
import OnnxRuntimeBindings

/// Runs the engines over a set of files from the command line and reports
/// what each one read and how long it took — the same machine, the same files,
/// the same export, as the design document's evaluation section asks.
///
///     OCRFlow.app/Contents/MacOS/OCRFlow --benchmark <output-dir> <modes> <file>…
///
/// `modes` is a comma-separated list of `vision`, `ppocr`, `vl`, `vl1` (the
/// VLM one region at a time, as before batching), `auto`, and `auto-ocr`
/// (智能分层 with the PDF text layer ignored, so its routing is what is
/// measured). `OCRFLOW_MODELS_DIR` points it at models kept outside the
/// app's folder.
///
/// For a born-digital PDF the page's own text layer is the ground truth, and
/// each reading is scored against it: the share of its letters and digits
/// that each side has in common, counted without regard to order so that a
/// layout read in a different order is not punished for it.
///
/// Debug builds only.
enum PipelineBenchmark {

    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--benchmark"), args.count > flag + 3 else { return }
        let output = URL(fileURLWithPath: args[flag + 1], isDirectory: true)
        let modes = args[flag + 2].split(separator: ",").map(String.init)
        let files = args[(flag + 3)...].map { URL(fileURLWithPath: $0) }
        do {
            try run(modes: modes, files: files, output: output)
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("benchmark failed: \(error)\n".utf8))
            exit(1)
        }
    }

    private struct Row: Encodable {
        var mode: String
        var file: String
        var pages: Int
        var seconds: Double
        var characters: Int
        /// Letters and digits shared with the PDF's own text, as F1.
        var agreement: Double?
        var regions: [String: Int]
        var reviewNotes: Int
    }

    private static func run(modes: [String], files: [URL], output: URL) throws {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var rows: [Row] = []
        var markdownByMode: [String: [String: String]] = [:]

        for mode in modes {
            let settings = try settings(for: mode)
            let engines = try loadEngines(for: settings)
            let folder = output.appendingPathComponent(mode, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

            for file in files {
                let start = Date()
                let pages = try DocumentRecognizer.recognize(url: file, settings: settings, engines: engines,
                                                             isCancelled: { false }, progress: { _ in })
                let seconds = Date().timeIntervalSince(start)
                let document = OCRViewModel.assemble(pages, dropping: [], inferHeadingLevels: true)

                let stem = file.deletingPathExtension().lastPathComponent
                try document.markdown.write(to: folder.appendingPathComponent("\(stem).md"),
                                            atomically: true, encoding: .utf8)
                try document.text.write(to: folder.appendingPathComponent("\(stem).txt"),
                                        atomically: true, encoding: .utf8)
                let encoded = try JSONEncoder().encode(pages)
                try encoded.write(to: folder.appendingPathComponent("\(stem).json"))
                // What the queue saves must come back exactly as it went in.
                if try JSONDecoder().decode([PageResult].self, from: encoded) != pages {
                    print("  ✗ \(file.lastPathComponent): results do not survive saving")
                }
                try checkSearchablePDF(file: file, pages: pages, text: document.text,
                                       to: folder.appendingPathComponent("\(stem).searchable.pdf"))
                markdownByMode[mode, default: [:]][file.lastPathComponent] = document.text

                var regions: [String: Int] = [:]
                for page in pages {
                    for reader in page.readers { regions[reader.source.label, default: 0] += reader.count }
                }
                let row = Row(mode: mode, file: file.lastPathComponent, pages: pages.count,
                              seconds: seconds, characters: document.text.count,
                              agreement: groundTruth(for: file).map { agreement(document.text, $0) },
                              regions: regions,
                              reviewNotes: pages.flatMap(\.allNotes).filter { $0.severity == .warning }.count)
                rows.append(row)
                print(String(format: "%-9@ %-28@ %3d页 %7.2fs  %6d字  一致度 %@  %@  待复核 %d",
                             mode as NSString, String(file.lastPathComponent.prefix(28)) as NSString,
                             row.pages, row.seconds, row.characters,
                             row.agreement.map { String(format: "%.3f", $0) } ?? "—",
                             regions.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }
                                 .joined(separator: " / "),
                             row.reviewNotes))
            }
        }

        // Batching must not change what is read: every file, side by side.
        if let batched = markdownByMode["vl"], let serial = markdownByMode["vl1"] {
            for (file, text) in batched.sorted(by: { $0.key < $1.key }) {
                print("vl vs vl1  \(file): \(text == serial[file] ? "identical" : "DIFFERENT")")
            }
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(rows).write(to: output.appendingPathComponent("summary.json"))
    }

    /// Writes the searchable PDF and checks a reader can find the text in
    /// it: a sample of the recognised words, searched for in the written file.
    private static func checkSearchablePDF(file: URL, pages: [PageResult], text: String, to url: URL) throws {
        var item = ImageItem(url: file)
        item.pages = pages
        item.status = .completed
        try SearchablePDFWriter.write([item], to: url)
        guard let written = PDFDocument(url: url) else {
            print("  ✗ \(url.lastPathComponent): unreadable")
            return
        }
        let words = text.components(separatedBy: .whitespacesAndNewlines)
            .filter { $0.count >= 6 && $0.allSatisfy { $0.isLetter } }
        let sample = stride(from: 0, to: words.count, by: max(1, words.count / 20)).map { words[$0] }
        let found = sample.filter { !written.findString($0, withOptions: .caseInsensitive).isEmpty }
        print("  searchable PDF: \(written.pageCount) 页, \(found.count)/\(sample.count) 个抽样词可搜索到")
        let sheets = TableWorkbook.sheets(from: [item])
        if !sheets.isEmpty {
            try TableWorkbook.write(sheets, to: url.deletingPathExtension().appendingPathExtension("xlsx"))
            print("  Excel: \(sheets.count) 个表格")
        }
    }

    private static func settings(for mode: String) throws -> DocumentRecognizer.Settings {
        var paddle = PPOCRConfig.default
        if let tier = ProcessInfo.processInfo.environment["PADDLE_TIER"].flatMap(PPModelTier.init(rawValue:)) {
            paddle.tier = tier
            paddle.applyDetectionDefaults()
        }
        var vl = VLConfig.default
        if let width = ProcessInfo.processInfo.environment["VL_PARALLEL"].flatMap(Int.init) {
            vl.parallelSequences = width
        }
        var layered = LayeredConfig.default
        let engine: OCREngine
        switch mode {
        case "vision": engine = .visionAccurate
        case "ppocr":  engine = .paddleOCR
        case "vl":     engine = .paddleVL
        case "vl1":    engine = .paddleVL; vl.parallelSequences = 1
        case "auto":   engine = .auto
        case "auto-ocr": engine = .auto; layered.pdfText = .never
        default: throw NSError(domain: "benchmark", code: 1,
                               userInfo: [NSLocalizedDescriptionKey: "unknown mode \(mode)"])
        }
        if !VLModelStore.isLayoutModelInstalled { paddle.readingOrder = .columns }
        return .init(engine: engine, visionLanguages: OCRSettings().recognitionLanguages,
                     paddleConfig: paddle, vlConfig: vl, layered: layered)
    }

    private static func loadEngines(for settings: DocumentRecognizer.Settings) throws -> DocumentRecognizer.Engines {
        var engines = DocumentRecognizer.Engines()
        switch settings.engine {
        case .visionFast, .visionAccurate:
            break
        case .paddleOCR:
            engines.paddle = try PPOCREngine(config: settings.paddleConfig)
        case .paddleVL:
            let layout = try PPSession(modelPath: VLModelStore.resolveLayoutModel(),
                                       env: ORTEnv(loggingLevel: .error), config: .default)
            engines.vlPipeline = VLDocumentPipeline(layout: PPLayoutDetector(session: layout),
                                                    vl: try VLEngine(config: settings.vlConfig))
        case .auto:
            var paddle = settings.paddleConfig
            if VLModelStore.isLayoutModelInstalled { paddle.readingOrder = .layout }
            let engine = try PPOCREngine(config: paddle)
            let vl = VLModelStore.isInstalled(settings.vlConfig.variant)
                ? try VLEngine(config: settings.vlConfig) : nil
            engines.paddle = engine
            engines.layered = LayeredPipeline(paddle: engine, vl: vl, paddleConfig: paddle,
                                              vlConfig: settings.vlConfig, config: settings.layered)
        }
        return engines
    }

    /// The PDF's own text, when it has trustworthy text of its own — or, for
    /// an image, a `<name>.truth.txt` beside it.
    private static func groundTruth(for file: URL) -> String? {
        let truth = file.deletingPathExtension().appendingPathExtension("truth.txt")
        if let text = try? String(contentsOf: truth, encoding: .utf8) { return text }
        guard file.pathExtension.lowercased() == "pdf", let document = PDFDocument(url: file) else { return nil }
        var text = ""
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index), PDFTextLayer.verdict(for: page) == .digital else {
                return nil
            }
            text += (page.string ?? "") + "\n"
        }
        return text
    }

    /// F1 over the multiset of letters and digits, case-folded.
    private static func agreement(_ reading: String, _ truth: String) -> Double {
        func counts(_ text: String) -> [Character: Int] {
            // Markup is not content: a table read as HTML, or a formula read as
            // LaTeX, must not score its tags and commands as extra letters.
            let stripped = text
                .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                .replacingOccurrences(of: "\\\\[a-zA-Z]+", with: " ", options: .regularExpression)
            var counts: [Character: Int] = [:]
            for character in stripped.lowercased() where character.isLetter || character.isNumber {
                counts[character, default: 0] += 1
            }
            return counts
        }
        let a = counts(reading), b = counts(truth)
        let shared = a.reduce(0) { $0 + min($1.value, b[$1.key] ?? 0) }
        let total = a.values.reduce(0, +) + b.values.reduce(0, +)
        return total == 0 ? 1 : Double(2 * shared) / Double(total)
    }
}
#endif
