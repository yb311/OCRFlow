import Foundation
import CoreGraphics

/// Settings for 智能分层, the engine that reads each region of a page with
/// whichever reader suits it.
struct LayeredConfig: Equatable, Codable {
    /// A text region whose PP-OCRv6 lines average below this confidence is
    /// read again by PaddleOCR-VL.
    var escalationConfidence: Double = 0.85
    /// Read low-confidence text regions again with PaddleOCR-VL. Off, they
    /// are only flagged for review.
    var escalateLowConfidence = true
    /// When a PDF's own text stands in for OCR.
    var pdfText: PDFTextPolicy = .digitalOnly

    static let `default` = LayeredConfig()
}

extension LayeredConfig {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = LayeredConfig()
        func value<T: Decodable>(_ key: CodingKeys, _ default: T) -> T {
            (try? container.decode(T.self, forKey: key)) ?? `default`
        }
        escalationConfidence = value(.escalationConfidence, fallback.escalationConfidence)
        escalateLowConfidence = value(.escalateLowConfidence, fallback.escalateLowConfidence)
        pdfText = value(.pdfText, fallback.pdfText)
    }
}

/// 智能分层: one page, read in layers.
///
/// 1. **The PDF's own text.** A born-digital page already says exactly what
///    it says; reading its pixels again can only add mistakes. Its regions
///    take their text from the text layer, and a scan's OCR layer — which is
///    only as good as whatever produced it — is not trusted.
/// 2. **Layout.** PP-DocLayoutV3 splits the page into regions and orders them.
///    Every later decision is made per region, not per page: a page with one
///    table does not need its thirty paragraphs read by a 0.9B model.
/// 3. **PP-OCRv6** reads the prose — fast, and with a box and a confidence for
///    every line.
/// 4. **PaddleOCR-VL** reads what PP-OCR cannot represent — tables,
///    formulas, charts, seals — and any text region PP-OCR was unsure of. All
///    of a page's VL regions go to the engine at once, and are decoded side by
///    side.
/// 5. **Quality check.** What each reader's output looks like — a confidence,
///    an answer that ran out of budget, two readers that disagree — decides
///    which regions are flagged for a person to look at.
///
/// Every routing decision is recorded on the region it was made for, so the
/// result can say why a paragraph was read the way it was.
struct LayeredPipeline {
    let paddle: PPOCREngine
    /// Nil when PaddleOCR-VL is not installed: structure-bearing regions are
    /// then read as plain text, and doubtful ones are only flagged.
    let vl: VLEngine?
    let paddleConfig: PPOCRConfig
    let vlConfig: VLConfig
    let config: LayeredConfig

    typealias Progress = (Double) -> Void

    /// Reads a scanned page or a photograph.
    func read(image: CGImage, progress: Progress?, isCancelled: @escaping () -> Bool) throws -> PageResult {
        var runtime = paddleConfig
        runtime.readingOrder = paddle.hasLayoutAnalysis ? .layout : paddleConfig.readingOrder
        // Every line comes back, however unsure; the drop threshold is applied
        // below, after the unsure lines have had their say in routing.
        runtime.dropScore = 0
        let ocr = try paddle.recognize(image: image, config: runtime,
                                       progress: { progress?($0 * 0.35) },
                                       isCancelled: isCancelled)
        let size = CGSize(width: image.width, height: image.height)
        let kept = ocr.lines.filter { $0.confidence >= paddleConfig.dropScore }

        guard !ocr.blocks.isEmpty else {
            var page = PageResult(size: size, lines: kept, rawText: kept.plainText)
            if !paddle.hasLayoutAnalysis {
                page.notes.append(.info("未安装版面分析模型，本页只用 PP-OCRv6 识别，未做分区路由"))
            }
            return page
        }

        var blocks = ocr.blocks
        var regions: [RegionReader.Region] = []
        for index in blocks.indices {
            let members = ocr.members.indices.contains(index)
                ? ocr.members[index].map { ocr.lines[$0] } : []
            let confident = members.filter { $0.confidence >= paddleConfig.dropScore }
            blocks[index].text = confident.map(\.text).joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            blocks[index].source = .plainOCR
            // A figure is a picture unless 图片文字识别 says to read it — the
            // same rule the VL pipeline follows. Its lines stay on the page,
            // for the overlay and for a searchable PDF's text layer.
            if blocks[index].label.producesFigure, blocks[index].label != .chart,
               !vlConfig.useImageTextRecognition {
                blocks[index].text = ""
            }

            switch route(blocks[index], lines: members) {
            case let .vl(task, reason):
                blocks[index].routing = reason
                regions.append(.init(block: index, task: task, fallback: blocks[index].text,
                                     isEscalation: reason != nil, lines: members))
            case let .keep(review):
                blocks[index].review = review
            }
        }

        var page = PageResult(size: size, lines: kept, blocks: blocks, blockSource: .plainOCR)
        try readRegions(regions, of: image, into: &page, progress: progress, isCancelled: isCancelled)
        return page
    }

    /// Reads a PDF page whose text layer can be trusted: layout from the
    /// pixels, text from the PDF, and the VLM only where structure matters.
    func read(rendered: RenderedPDFPage, source pdf: PDFSource, page pageIndex: Int,
              progress: Progress?, isCancelled: @escaping () -> Bool) throws -> PageResult? {
        let image = rendered.image
        let size = CGSize(width: image.width, height: image.height)
        guard let layout = try paddle.layout(image: image) else {
            // No layout model to split the page: the text layer as it stands.
            let native = pdf.nativeText(page: pageIndex, rendering: rendered, regions: nil,
                                        policy: config.pdfText)
            guard let text = native.texts.first, !text.isEmpty else { return nil }
            return PageResult(size: size, blockSource: .pdfTextLayer, rawText: text,
                              rawMarkdown: text,
                              notes: [.info("本页文字取自 PDF 文字层（\(native.verdict.description)）")])
        }
        progress?(0.1)
        if layout.isEmpty { return nil }

        let native = pdf.nativeText(page: pageIndex, rendering: rendered,
                                    regions: layout.map(\.rect), policy: config.pdfText)
        guard native.texts.count == layout.count else { return nil }

        var blocks = layout
        var regions: [RegionReader.Region] = []
        var unread: [Int] = []
        for index in blocks.indices {
            // Figures are pictures here too, unless 图片文字识别 says otherwise:
            // the labels inside a diagram are not part of the text.
            if blocks[index].label.producesFigure, blocks[index].label != .chart,
               !vlConfig.useImageTextRecognition {
                continue
            }
            blocks[index].text = native.texts[index]
            blocks[index].source = .pdfTextLayer
            if let task = structuralTask(for: blocks[index].label), vl != nil {
                regions.append(.init(block: index, task: task, fallback: native.texts[index],
                                     isEscalation: false))
            } else if let formulas = blocks[index].inlineFormulas, formulas > 0, vl != nil {
                // A text layer has the glyphs of a formula, not its structure —
                // `d_k` comes out as "dk", and a font's radical can come out as
                // an arrow. The VLM writes it as LaTeX; the PDF's text stays as
                // the fallback and the yardstick.
                blocks[index].routing = "段落含 \(formulas) 处行内公式，PDF 文字层表达不了公式结构，交由 PaddleOCR-VL 识别"
                regions.append(.init(block: index, task: .ocr, fallback: native.texts[index],
                                     isEscalation: true))
            } else if blocks[index].label.vlTask != nil, native.texts[index].isEmpty,
                      !blocks[index].label.isPageFurniture {
                // A text region the text layer has nothing for: text set as a
                // picture, most likely. It is read from the pixels instead.
                unread.append(index)
            }
        }

        // The regions the text layer missed get PP-OCRv6, one crop each, and
        // the usual escalation if PP-OCR is unsure of them too.
        var crop = paddleConfig
        crop.readingOrder = .columns
        crop.dropScore = 0
        for index in unread {
            if isCancelled() { break }
            let rect = blocks[index].rect.integral.intersection(CGRect(origin: .zero, size: size))
            guard rect.width >= 4, rect.height >= 4, let piece = image.cropping(to: rect) else { continue }
            let lines = try paddle.recognize(image: piece, config: crop, isCancelled: isCancelled).lines
            blocks[index].text = lines.filter { $0.confidence >= paddleConfig.dropScore }
                .map(\.text).joined(separator: "\n")
            blocks[index].source = .plainOCR
            blocks[index].routing = "PDF 文字层在此区域没有文字，改用 PP-OCRv6 识别图像"
            switch route(blocks[index], lines: lines) {
            case let .vl(task, reason):
                if let reason { blocks[index].routing = reason }
                regions.append(.init(block: index, task: task, fallback: blocks[index].text,
                                     isEscalation: true))
            case let .keep(review):
                blocks[index].review = review
            }
        }
        progress?(0.3)

        var page = PageResult(size: size, blocks: blocks, blockSource: .pdfTextLayer,
                              notes: [.info("正文取自 PDF 原生文字层，未经 OCR")])
        try readRegions(regions, of: image, into: &page, progress: progress, isCancelled: isCancelled)
        return page
    }

    // MARK: - Routing

    private enum Route {
        /// Read with PaddleOCR-VL; the reason is set when it is an escalation
        /// rather than the region's kind.
        case vl(VLTask, reason: String?)
        /// Keep what PP-OCR read, optionally flagged.
        case keep(review: String?)
    }

    /// The prompt for a region whose content PP-OCR cannot represent, or nil
    /// for one that is prose.
    ///
    /// Mirrors the module switches of the VL pipeline: a chart is only
    /// transcribed when chart recognition is on — otherwise it is a picture —
    /// and the same for seals and text inside figures.
    private func structuralTask(for label: PPLayoutLabel) -> VLTask? {
        switch label {
        case .table:                          return .table
        case .displayFormula, .inlineFormula: return .formula
        case .chart:                          return vlConfig.useChartRecognition ? .chart : nil
        case .seal:                           return vlConfig.useSealRecognition ? .seal : nil
        case .image, .headerImage, .footerImage:
            return vlConfig.useImageTextRecognition ? .ocr : nil
        default:                              return nil
        }
    }

    private func route(_ block: PPLayoutBlock, lines: [PPTextLine]) -> Route {
        if let task = structuralTask(for: block.label) {
            guard vl != nil else {
                return .keep(review: block.label == .table || block.label.vlTask == .formula
                             ? "未安装 PaddleOCR-VL，\(block.label.label)按普通文字识别，结构未还原" : nil)
            }
            return .vl(task, reason: nil)
        }
        // Figures without text, and the running heads and page numbers that are
        // dropped from most documents anyway, are not worth a second reader.
        guard block.label.vlTask != nil, !block.label.isPageFurniture else { return .keep(review: nil) }

        let canEscalate = vl != nil && config.escalateLowConfidence
        if block.label == .verticalText, vl != nil {
            return .vl(.ocr, reason: "竖排文字交由 PaddleOCR-VL 识别")
        }
        // Prose with maths in it: PP-OCR reads `d_k` as "dk" and has no way to
        // write a square root at all. The VLM writes the formulas as LaTeX.
        if let formulas = block.inlineFormulas, formulas > 0, vl != nil {
            return .vl(.ocr, reason: "段落含 \(formulas) 处行内公式，交由 PaddleOCR-VL 识别为 LaTeX")
        }
        guard !lines.isEmpty else {
            return canEscalate
                ? .vl(.ocr, reason: "PP-OCRv6 在此区域没有检测到文字，改由 PaddleOCR-VL 读取")
                : .keep(review: "版面分析认为这里有文字，但 PP-OCRv6 没有读出内容")
        }

        let mean = lines.reduce(0) { $0 + $1.confidence } / Double(lines.count)
        let unsure = lines.filter { $0.confidence < paddleConfig.dropScore }.count
        // One stray mark read at 0.3 among ten good lines is noise, and the
        // drop threshold already removes it. A quarter of the lines below it
        // means the region itself is hard to read.
        guard mean < config.escalationConfidence || unsure * 4 >= lines.count else {
            return .keep(review: nil)
        }
        let finding = unsure * 4 >= lines.count
            ? "PP-OCRv6 有 \(unsure)/\(lines.count) 行置信度过低"
            : "PP-OCRv6 平均置信度 \(Int((mean * 100).rounded()))%"
        return canEscalate
            ? .vl(.ocr, reason: "\(finding)，改由 PaddleOCR-VL 重读")
            : .keep(review: "\(finding)，建议核对")
    }

    private func readRegions(_ regions: [RegionReader.Region], of image: CGImage,
                             into page: inout PageResult, progress: Progress?,
                             isCancelled: @escaping () -> Bool) throws {
        guard let vl, !regions.isEmpty else {
            progress?(1)
            return
        }
        RegionReader.read(regions, of: image, blocks: &page.blocks, vl: vl, config: vlConfig,
                          progress: { progress?(0.35 + 0.65 * $0) }, isCancelled: isCancelled)
        progress?(1)
    }
}

/// Reads regions of a page with PaddleOCR-VL — all of them at once — and
/// folds the answers, and what they reveal about their own quality, back into
/// the blocks.
enum RegionReader {
    struct Region {
        var block: Int
        var task: VLTask
        /// What another reader made of the region, kept if the VLM fails and
        /// used to cross-check it when it does not. Nil when the VLM is the
        /// only reader.
        var fallback: String?
        /// True when the VLM is a second opinion on a region PP-OCR doubted,
        /// rather than the region's natural reader.
        var isEscalation: Bool
        /// PP-OCRv6's lines inside the region, in page coordinates, when it
        /// read the region too. A table's layout is checked against them.
        var lines: [PPTextLine] = []
    }

    static func read(_ regions: [Region], of image: CGImage, blocks: inout [PPLayoutBlock],
                     vl: VLEngine, config: VLConfig, progress: ((Double) -> Void)?,
                     isCancelled: @escaping () -> Bool) {
        guard !regions.isEmpty else { return }
        let size = CGSize(width: image.width, height: image.height)
        let requests = regions.map { region in
            // Crop a little wider than the box. A region that hugs the glyphs
            // clips their edges, and a model shown a clipped word drops it;
            // PaddleOCR grows the box the same way, as `unclip_ratio`.
            VLRequest(image: image,
                      crop: PPLayoutPostProcess.expanded(blocks[region.block].rect,
                                                         ratio: config.cropUnclipRatio, within: size),
                      task: region.task)
        }

        let lock = NSLock()
        var done = 0
        let results = vl.recognize(requests, isCancelled: isCancelled) { _, _ in
            lock.lock()
            done += 1
            let fraction = Double(done) / Double(requests.count)
            lock.unlock()
            progress?(fraction)
        }

        for (region, result) in zip(regions, results) {
            apply(result, for: region, to: &blocks[region.block], limit: config.maxOutputTokens)
        }
    }

    private static func apply(_ result: Result<VLOutput, Error>, for region: Region,
                              to block: inout PPLayoutBlock, limit: Int) {
        let fallback = region.fallback?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let otherReader = block.source
        let output: VLOutput
        switch result {
        case let .failure(error):
            block.review = fallback.isEmpty
                ? "PaddleOCR-VL 无法读取此区域：\(error.localizedDescription)"
                : "PaddleOCR-VL 无法读取此区域，保留了 \(block.source?.label ?? "另一引擎") 的结果"
            return
        case let .success(value):
            output = value
        }
        guard output.ending != .cancelled else { return }

        let text = output.text
        guard !text.isEmpty else {
            // An empty answer keeps whatever the other reader had.
            if block.label.vlTask == .table || block.label.vlTask == .formula || region.isEscalation
                || !fallback.isEmpty {
                block.review = fallback.isEmpty
                    ? "PaddleOCR-VL 没有读出内容"
                    : "PaddleOCR-VL 没有读出内容，保留了 \(block.source?.label ?? "另一引擎") 的结果"
            }
            return
        }

        // Tables are stored as HTML rather than the OTSL the model writes: it
        // is what every later reader — the editor, an export, a person — can
        // make sense of.
        block.text = region.task == .table ? (PPDocumentAssembler.htmlTable(fromOTSL: text) ?? text) : text
        block.source = .visionLanguageModel

        switch output.ending {
        case .lengthLimit:
            block.review = "输出达到 \(limit) token 上限，内容可能不完整"
        case .repetition:
            block.review = "模型出现重复输出，已截断，可能漏读"
        case .decodeFailed:
            block.review = "PaddleOCR-VL 推理中断，内容可能不完整"
        case .finished, .cancelled:
            if let finding = crossCheck(block.text, against: fallback, readBy: otherReader,
                                        task: region.task, isEscalation: region.isEscalation)
                ?? (region.task == .table ? layoutCheck(table: text, against: region.lines) : nil) {
                block.review = finding
            }
        }
    }

    /// What a comparison with the other reader says, if anything worth saying.
    ///
    /// Two independent readers that agree are the best evidence available; two
    /// that do not are worth a look. The comparison counts characters and
    /// ignores their order — a table read as HTML and the same table read as
    /// lines of text share their characters, not their layout.
    static func crossCheck(_ text: String, against other: String, readBy otherReader: PPTextSource?,
                           task: VLTask, isEscalation: Bool) -> String? {
        if task == .table, !looksLikeTable(text) {
            return "没有识别出表格结构，只读出了文字"
        }
        // Only prose and tables are comparable: PP-OCR's reading of a formula
        // or a seal is not a second opinion worth weighing against LaTeX.
        guard task == .table || isEscalation else { return nil }
        let mine = characterCounts(text), theirs = characterCounts(other)
        let theirTotal = theirs.values.reduce(0, +)
        guard theirTotal >= 20 else { return nil }
        let myTotal = mine.values.reduce(0, +)

        if isEscalation {
            // PP-OCR was unsure, so disagreeing with it is expected. Reading
            // far less than it did is not: the VLM may have skipped lines.
            return myTotal * 2 < theirTotal
                ? "PaddleOCR-VL 读出的文字比 PP-OCRv6 少一半以上，可能漏读"
                : nil
        }
        let shared = mine.reduce(0) { $0 + min($1.value, theirs[$1.key] ?? 0) }
        let agreement = Double(2 * shared) / Double(myTotal + theirTotal)
        return agreement < 0.6
            ? "与\(otherReader?.label ?? "另一引擎")的结果差异较大（字符重合 \(Int((agreement * 100).rounded()))%），请核对"
            : nil
    }

    /// What PP-OCRv6's view of a table says about where PaddleOCR-VL put
    /// its cells.
    ///
    /// The character comparison cannot see a value written into the wrong
    /// row: the characters are all there. On a sparse table — a grid of
    /// ablations where most cells are blank — the VLM does exactly that, and
    /// does it erratically: the same table read from a crop a few pixels
    /// wider can come out right, or with a whole block of values pulled up a
    /// row and two rows swapped. Full-precision weights do no better, and no
    /// crop size reads it right every time, so the result is checked instead.
    ///
    /// PP-OCRv6 read the same region line by line, and in a table a line is
    /// almost always one cell, with a box that says where on the page it is.
    /// A text that appears exactly once in both readings pins a cell to a
    /// place. Two such cells whose rows or columns are in one order in the
    /// table and the other order on the page — or that share a row in the
    /// table but not on the page — cannot both be right. Lines PP-OCRv6 read
    /// with confidence that the table has fewer of, or lacks, were dropped or
    /// overwritten.
    static func layoutCheck(table otsl: String, against lines: [PPTextLine]) -> String? {
        guard let table = PPDocumentAssembler.otslCells(otsl) else { return nil }
        let readable = lines.filter { $0.confidence >= 0.8 && !layoutKey($0.text).isEmpty }
        guard readable.count >= 6 else { return nil }
        let heights = readable.map(\.boundingBox.height).sorted()
        let lineHeight = heights[heights.count / 2]
        // A box over several stacked cells — PP-OCR joins a column of single
        // digits into one line — places none of them.
        let placed = readable.filter { $0.boundingBox.height <= lineHeight * 1.6 }

        let cells = table.cells.filter { !layoutKey($0.text).isEmpty }
        let cellsByKey = Dictionary(grouping: cells) { layoutKey($0.text) }
        let linesByKey = Dictionary(grouping: placed) { layoutKey($0.text) }

        let anchors: [(cell: PPDocumentAssembler.OTSLCell, at: CGPoint)] = cellsByKey.compactMap { key, cells in
            guard cells.count == 1, let lines = linesByKey[key], lines.count == 1 else { return nil }
            let box = lines[0].boundingBox
            return (cells[0], CGPoint(x: box.midX, y: box.midY))
        }
        // Cells in different rows must be that far apart, in that order; cells
        // in the same row no further apart than this.
        let rowGap = lineHeight * 0.25, sameRow = lineHeight * 0.6
        var contradictions = 0
        for i in anchors.indices {
            for j in anchors.indices where j > i {
                let (a, p) = anchors[i], (b, q) = anchors[j]
                var wrong = false
                if a.row + a.rowSpan <= b.row {
                    wrong = p.y > q.y - rowGap
                } else if b.row + b.rowSpan <= a.row {
                    wrong = q.y > p.y - rowGap
                } else if a.rowSpan == 1, b.rowSpan == 1 {
                    wrong = abs(p.y - q.y) > sameRow
                }
                if a.column + a.columnSpan <= b.column {
                    wrong = wrong || p.x > q.x
                } else if b.column + b.columnSpan <= a.column {
                    wrong = wrong || q.x > p.x
                }
                if wrong { contradictions += 1 }
            }
        }
        if contradictions >= 3 {
            return "表格中 \(contradictions) 组单元格的行列顺序与 PP-OCRv6 看到的版面不符，可能有内容错行错列，请核对"
        }

        // A cell PP-OCRv6 split over two lines is still there; so is a long
        // one the two readers spell a letter apart — the paper that says
        // "el al." comes back from the VLM as "et al.". A short value must
        // match exactly: "0.3" and "0.2" are different cells.
        let everything = cells.map { layoutKey($0.text) }.joined()
        func isInTable(_ key: String) -> Bool {
            everything.contains(key)
                || key.count >= 6 && cellsByKey.keys.contains { editDistance(key, $0) <= key.count / 5 }
        }
        var missing: [String] = []
        for (key, lines) in linesByKey where lines.contains(where: { $0.confidence >= 0.9 }) {
            let shortfall = cellsByKey[key].map { lines.count - $0.count }
                ?? (isInTable(key) ? 0 : lines.count)
            missing += Array(repeating: lines[0].text, count: max(0, shortfall))
        }
        guard missing.count >= 2 else { return nil }
        let examples = missing.sorted().prefix(3).map { "“\($0)”" }.joined(separator: "、")
        return "PP-OCRv6 在表格中读到的 \(missing.count) 处内容（\(examples)\(missing.count > 3 ? " 等" : "")）不在表格里，可能有单元格漏读或错位，请核对"
    }

    /// Letters and digits, case-folded, with LaTeX commands left out — what a
    /// cell and PP-OCRv6's reading of it have in common: `d_{model}` and
    /// "dmodel" are the same cell, and so are `10^{6}` and "10⁶".
    private static func layoutKey(_ text: String) -> String {
        let stripped = text.replacingOccurrences(of: "\\\\[a-zA-Z]+", with: " ", options: .regularExpression)
        var key = ""
        for character in stripped.lowercased() where character.isLetter || character.isNumber {
            if let digit = character.wholeNumberValue, (0...9).contains(digit) {
                key += String(digit)
            } else {
                key.append(character)
            }
        }
        return key
    }

    private static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var previous = Array(0...b.count)
        for i in a.indices {
            var current = [i + 1]
            for j in b.indices {
                current.append(min(previous[j + 1] + 1, current[j] + 1,
                                   previous[j] + (a[i] == b[j] ? 0 : 1)))
            }
            previous = current
        }
        return previous[b.count]
    }

    private static func looksLikeTable(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("<td") || lower.contains("<th")
            || text.components(separatedBy: "\n").filter { $0.contains("|") }.count >= 2
    }

    /// Letters and digits, case-folded, with markup and whitespace left out —
    /// the part two readers of the same region should agree on.
    private static func characterCounts(_ text: String) -> [Character: Int] {
        var stripped = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        stripped = stripped.replacingOccurrences(of: "\\\\[a-zA-Z]+", with: " ", options: .regularExpression)
        var counts: [Character: Int] = [:]
        for character in stripped.lowercased() where character.isLetter || character.isNumber {
            counts[character, default: 0] += 1
        }
        return counts
    }
}
