import Foundation
import CoreGraphics
import ImageIO
import Vision
import os

/// Reads one file — every page of it — with the engine the settings name.
///
/// Everything here runs off the main actor, on whatever thread calls it; the
/// view model hands it a snapshot of the settings and the engines it has
/// loaded, and gets the pages back.
enum DocumentRecognizer {

    /// The state that affects recognition, read on the main actor before the
    /// work leaves it.
    struct Settings: Sendable {
        var engine: OCREngine
        var visionLanguages: [String]
        var paddleConfig: PPOCRConfig
        var vlConfig: VLConfig
        var layered: LayeredConfig

        /// The model each reader uses under these settings.
        var models: [PPTextSource: String] {
            let ocr = paddleConfig.modelName, vl = vlConfig.variant.modelName
            switch engine {
            case .visionFast, .visionAccurate: return [:]
            case .paddleOCR:                   return [.plainOCR: ocr]
            case .paddleVL:                    return [.visionLanguageModel: vl]
            case .auto:                        return [.plainOCR: ocr, .visionLanguageModel: vl]
            }
        }

        /// Everything about these settings that changes what a file reads as,
        /// for the recognition cache. Knobs that only change *how fast* — the
        /// batch width, thread counts — are left out, so turning them does not
        /// throw the cache away.
        func fingerprint(vlAvailable: Bool, layoutAvailable: Bool, unwarping: Bool) -> String {
            struct Key: Encodable {
                var engine: OCREngine
                var languages: [String]?
                var paddle: PPOCRConfig?
                var vl: VLConfig?
                var layered: LayeredConfig?
                var vlAvailable: Bool
                var layoutAvailable: Bool
                var unwarping: Bool
            }
            var paddle = paddleConfig
            paddle.threadCount = 0
            var vl = vlConfig
            vl.parallelSequences = 0
            vl.threadCount = 0
            // Document settings, applied when the pages are assembled.
            vl.inferHeadingLevels = true
            let usesPaddle = engine == .paddleOCR || engine == .auto
            let usesVL = engine == .paddleVL || (engine == .auto && vlAvailable)
            let key = Key(engine: engine,
                          languages: engine.usesVisionLanguages ? visionLanguages : nil,
                          paddle: usesPaddle ? paddle : nil,
                          vl: usesVL ? vl : nil,
                          layered: engine == .auto ? layered : nil,
                          vlAvailable: vlAvailable, layoutAvailable: layoutAvailable,
                          unwarping: unwarping)
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            return (try? encoder.encode(key)).map { String(decoding: $0, as: UTF8.self) } ?? "\(engine)"
        }
    }

    /// The loaded models a run may use. Which ones are set depends on the
    /// engine.
    struct Engines: @unchecked Sendable {
        var paddle: PPOCREngine?
        var vlPipeline: VLDocumentPipeline?
        var layered: LayeredPipeline?
        var unwarper: PPDocUnwarper?
        /// Turns sideways pages upright before PaddleOCR-VL or 智能分层 cut
        /// regions out of them. PP-OCR on its own straightens pages itself.
        var orienter: PPDocOrientationClassifier?
        /// The error that kept PaddleOCR-VL from loading, when 智能分层 is
        /// running without it although it is installed. Noted on every page
        /// it affects.
        var vlUnavailable: String?
    }

    /// How far one file has got: the share of the work done, and how many of
    /// its pages are finished — which, for a file of five hundred pages, says
    /// more than a percentage does.
    struct ProgressUpdate: Sendable {
        var fraction: Double
        var pagesDone: Int
        var pageCount: Int
    }

    typealias Progress = @Sendable (ProgressUpdate) -> Void

    /// Hands over each page the moment it has been read in full, so it can be
    /// kept before the rest of the file is done.
    typealias PageHandler = @Sendable (Int, PageResult) -> Void

    /// Pages of one file read at once. Two is enough to keep the GPU fed —
    /// one page's layout and PP-OCR run while the other's regions are with
    /// the VLM — without holding a stack of rendered pages in memory.
    static let pagesInFlight = 2

    /// Reads a file, skipping the pages in `done` — what an earlier, stopped
    /// run of the same file with the same settings already read.
    static func recognize(url: URL, settings: Settings, engines: Engines,
                          done: [Int: PageResult] = [:],
                          isCancelled: @escaping @Sendable () -> Bool,
                          progress: @escaping Progress,
                          onPage: PageHandler? = nil) async throws -> [PageResult] {
        if url.pathExtension.lowercased() == "pdf" {
            guard let source = PDFSource(url: url) else { throw OCRError.pdfOpenFailed }
            let count = source.pageCount
            guard count > 0 else { throw OCRError.pdfOpenFailed }
            return try await readPages(count: count, done: done, isCancelled: isCancelled,
                                       progress: progress, onPage: onPage) { index, report in
                try await recognizePDFPage(index, of: source, settings: settings, engines: engines,
                                           isCancelled: isCancelled, progress: report)
            }
        }
        let count = PageImages.frameCount(of: url)
        guard count > 0 else { throw OCRError.imageLoadFailed }
        progress(ProgressUpdate(fraction: 0.05, pagesDone: done.count, pageCount: count))
        return try await readPages(count: count, done: done, isCancelled: isCancelled,
                                   progress: progress, onPage: onPage) { index, report in
            try await recognizeImagePage(index, at: url, settings: settings, engines: engines,
                                         isCancelled: isCancelled, progress: report)
        }
    }

    /// Reads one page of a file again, on its own — the rest of the document
    /// stays as it is.
    static func recognize(page index: Int, of url: URL, settings: Settings, engines: Engines,
                          isCancelled: @escaping @Sendable () -> Bool,
                          progress: (@Sendable (Double) -> Void)?) async throws -> PageResult {
        if url.pathExtension.lowercased() == "pdf" {
            guard let source = PDFSource(url: url), index < source.pageCount else { throw OCRError.pdfOpenFailed }
            return try await recognizePDFPage(index, of: source, settings: settings, engines: engines,
                                              isCancelled: isCancelled, progress: progress)
        }
        return try await recognizeImagePage(index, at: url, settings: settings, engines: engines,
                                            isCancelled: isCancelled, progress: progress)
    }

    /// How many pages a file has, without reading any of them.
    static func pageCount(of url: URL) -> Int {
        if url.pathExtension.lowercased() == "pdf" { return PDFSource(url: url)?.pageCount ?? 0 }
        return PageImages.frameCount(of: url)
    }

    // MARK: - Files

    private static func recognizeImagePage(_ index: Int, at url: URL, settings: Settings, engines: Engines,
                                           isCancelled: @escaping @Sendable () -> Bool,
                                           progress: (@Sendable (Double) -> Void)?) async throws -> PageResult {
        let image = try await BlockingWork.run {
            guard let image = PageImages.image(at: url, frame: index) else { throw OCRError.imageLoadFailed }
            return image
        }
        return try await recognize(page: image, pdf: nil, settings: settings, engines: engines,
                                   isCancelled: isCancelled, progress: progress)
    }

    private static func recognizePDFPage(_ index: Int, of source: PDFSource, settings: Settings, engines: Engines,
                                         isCancelled: @escaping @Sendable () -> Bool,
                                         progress: (@Sendable (Double) -> Void)?) async throws -> PageResult {
        let rendered = try await BlockingWork.run {
            guard let rendered = source.render(page: index) else { throw OCRError.imageLoadFailed }
            return rendered
        }
        return try await recognize(page: rendered.image, pdf: PDFPage(source: source, index: index, rendered: rendered),
                                   settings: settings, engines: engines,
                                   isCancelled: isCancelled, progress: progress)
    }

    /// Reads `count` pages, a couple at a time, and returns them in order.
    ///
    /// A page that fails is kept as an empty page that says why, so one
    /// unreadable page in a hundred does not throw the other ninety-nine
    /// away. Only a file none of whose pages could be read fails as a whole.
    ///
    /// Pages already in `done` are not read again. Each page read here goes
    /// to `onPage` once it is complete — never one a stop cut short, and never
    /// one that failed, which is worth trying again next time.
    private static func readPages(count: Int, done: [Int: PageResult],
                                  isCancelled: @escaping @Sendable () -> Bool,
                                  progress: @escaping Progress,
                                  onPage: PageHandler?,
                                  read: @escaping @Sendable (Int, @escaping @Sendable (Double) -> Void) async throws -> PageResult)
        async throws -> [PageResult] {
        struct State {
            var pages: [PageResult?]
            var errors: [Error?]
            var fractions: [Double]
            var finished = 0
        }
        var initial = State(pages: Array(repeating: nil, count: count),
                            errors: Array(repeating: nil, count: count),
                            fractions: Array(repeating: 0, count: count))
        for (index, page) in done where initial.pages.indices.contains(index) {
            initial.pages[index] = page
            initial.fractions[index] = 1
            initial.finished += 1
        }
        var toRead = (0..<count).filter { initial.pages[$0] == nil }.makeIterator()
        // Pages hold images, which are not Sendable; every access to them
        // goes through the lock.
        let state = OSAllocatedUnfairLock(uncheckedState: initial)

        @Sendable func report(_ index: Int, _ fraction: Double, finishing: Bool = false) {
            let update = state.withLockUnchecked { state in
                state.fractions[index] = min(max(fraction, 0), 1)
                if finishing { state.finished += 1 }
                return ProgressUpdate(fraction: state.fractions.reduce(0, +) / Double(count),
                                      pagesDone: state.finished, pageCount: count)
            }
            progress(update)
        }
        progress(ProgressUpdate(fraction: Double(initial.finished) / Double(count),
                                pagesDone: initial.finished, pageCount: count))

        await withTaskGroup(of: Void.self) { group in
            func readNext() {
                guard !isCancelled(), let index = toRead.next() else { return }
                group.addTask {
                    do {
                        let page = try await read(index) { report(index, $0) }
                        // The engines answer a stop by returning what they have
                        // so far, so a page that comes back after one is a
                        // fragment.
                        if !isCancelled() { onPage?(index, page) }
                        state.withLockUnchecked { $0.pages[index] = page }
                    } catch {
                        state.withLockUnchecked { $0.errors[index] = error }
                    }
                    report(index, 1, finishing: true)
                }
            }
            for _ in 0..<(count == 1 ? 1 : pagesInFlight) { readNext() }
            while await group.next() != nil { readNext() }
        }

        let (pages, errors) = state.withLockUnchecked { ($0.pages, $0.errors) }
        if isCancelled() { return pages.compactMap { $0 } }
        if pages.allSatisfy({ $0 == nil }), let first = errors.compactMap({ $0 }).first { throw first }
        return (0..<count).map { index in
            pages[index] ?? PageResult(size: .zero, notes: [
                .warning(.pageFailed(page: index, error: errors[index]?.localizedDescription)),
            ])
        }
    }

    // MARK: - One page

    /// A page of a PDF, as it was rendered for reading.
    struct PDFPage: Sendable {
        let source: PDFSource
        let index: Int
        let rendered: RenderedPDFPage
    }

    /// Sends one page to whichever engine is selected.
    static func recognize(page source: CGImage, pdf: PDFPage?,
                          settings: Settings, engines: Engines,
                          isCancelled: @escaping @Sendable () -> Bool,
                          progress: (@Sendable (Double) -> Void)?) async throws -> PageResult {
        // 智能分层's first layer: a PDF page whose own text can be trusted is
        // not read from its pixels at all — so it is not flattened either.
        if settings.engine == .auto, let pdf, let layered = engines.layered,
           settings.layered.pdfText.trusts(pdf.source.verdict(page: pdf.index)) {
            let read = try await BlockingWork.run {
                try layered.read(rendered: pdf.rendered, source: pdf.source, page: pdf.index,
                                 progress: progress, isCancelled: isCancelled)
            }
            if var page = read {
                page.notes += unavailableNotes(engines, page: page)
                page.models = settings.models
                return page
            }
        }

        let drawnByPDF = pdf.map { $0.source.verdict(page: $0.index) == .digital } ?? false
        let (image, rectified) = await BlockingWork.run {
            prepared(source, drawnByPDF: drawnByPDF, engines: engines)
        }

        var page: PageResult
        if settings.engine.usesVisionLanguages {
            page = try await performVisionOCR(on: image, settings: settings)
            progress?(1)
        } else {
            page = try await BlockingWork.run {
                try readWithModels(image, drawnByPDF: drawnByPDF, settings: settings, engines: engines,
                                   isCancelled: isCancelled, progress: progress)
            }
        }
        page.rectified = rectified.map(ImageItem.page(from:))
        page.models = settings.models
        return page
    }

    /// The page as the readers should see it, and the picture of it when that
    /// differs from the source.
    ///
    /// Flattening comes first, exactly as it does upstream: everything after
    /// it — layout, detection, recognition — assumes text runs in straight
    /// lines. A failure here is not fatal; the page is read as photographed.
    ///
    /// PaddleOCR-VL reads regions cut out of the page, so a page lying on its
    /// side is turned upright next; its boxes then belong to the turned page,
    /// kept the same way a flattened one is. Not a page a PDF drew itself: its
    /// rotation is the PDF's own, already applied when it was rendered, and
    /// the classifier only gets such a page wrong — a figure full of sideways
    /// labels reads to it as a page on its side.
    private static func prepared(_ source: CGImage, drawnByPDF: Bool,
                                 engines: Engines) -> (image: CGImage, rectified: CGImage?) {
        var image = source
        var rectified: CGImage?
        if let unwarper = engines.unwarper, let buffer = PPImageBuffer(cgImage: source),
           let flattened = try? unwarper.rectify(buffer), let flat = flattened.cgImage {
            image = flat
            rectified = flat
        }
        if !drawnByPDF, let orienter = engines.orienter, let upright = try? orienter.straightened(image) {
            image = upright
            rectified = upright
        }
        return (image, rectified)
    }

    /// Reads a page with the PaddleOCR engines. They block the calling thread
    /// until they are done.
    private static func readWithModels(_ image: CGImage, drawnByPDF: Bool, settings: Settings, engines: Engines,
                                       isCancelled: @escaping @Sendable () -> Bool,
                                       progress: (@Sendable (Double) -> Void)?) throws -> PageResult {
        switch settings.engine {
        case .visionFast, .visionAccurate:
            preconditionFailure("Apple Vision is not one of the PaddleOCR engines")
        case .paddleVL:
            guard let vlPipeline = engines.vlPipeline else {
                throw VLError.backendFailed(String(localized: "The model isn't loaded"))
            }
            return try vlPipeline.parse(image: image, config: settings.vlConfig,
                                        progress: progress, isCancelled: isCancelled)
        case .paddleOCR:
            guard let paddle = engines.paddle else {
                throw PPOCRError.sessionFailed(String(localized: "The model isn't loaded"))
            }
            var config = settings.paddleConfig
            if drawnByPDF { config.useDocOrientation = false }
            // Every line comes back, however unsure, so the unsure ones can
            // say which regions are worth checking; the drop threshold is
            // applied after, as 智能分层 does.
            config.dropScore = 0
            let result = try paddle.recognize(image: image, config: config,
                                              progress: progress, isCancelled: isCancelled)
            return plainOCRPage(result, size: CGSize(width: image.width, height: image.height),
                                dropScore: settings.paddleConfig.dropScore,
                                doubtBelow: settings.layered.escalationConfidence)
        case .auto:
            guard let layered = engines.layered else {
                throw PPOCRError.sessionFailed(String(localized: "The model isn't loaded"))
            }
            var page = try layered.read(image: image, progress: progress, isCancelled: isCancelled)
            page.notes += unavailableNotes(engines, page: page)
            return page
        }
    }

    /// A page PP-OCRv6 read on its own, with the lines below `dropScore`
    /// left out and the regions it is unsure of flagged for review — by the
    /// rule 智能分层 uses, which has a second reader to send them to; here
    /// the person reading is the only one.
    static func plainOCRPage(_ result: PPOCREngine.Page, size: CGSize,
                             dropScore: Double, doubtBelow: Double) -> PageResult {
        var blocks = result.blocks
        for index in blocks.indices {
            let members = result.members.indices.contains(index)
                ? result.members[index].map { result.lines[$0] } : []
            guard !members.isEmpty else { continue }
            blocks[index].text = members.filter { $0.confidence >= dropScore }.map(\.text)
                .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            let label = blocks[index].label
            guard label.vlTask == .ocr, !label.isPageFurniture, !label.producesFigure else { continue }
            blocks[index].review = LowConfidence.finding(in: members, dropScore: dropScore,
                                                         averageBelow: doubtBelow).map { .lowConfidence($0) }
        }
        let kept = result.lines.filter { $0.confidence >= dropScore }
        var page = PageResult(size: size, lines: kept, blocks: blocks,
                              blockSource: .plainOCR, rawText: kept.plainText)
        if blocks.isEmpty, let finding = LowConfidence.finding(in: result.lines, dropScore: dropScore,
                                                               averageBelow: doubtBelow) {
            page.notes.append(.warning(.lowConfidence(finding)))
        }
        return page
    }

    /// Says so on a page with structure, when 智能分层 had no VLM to read it.
    private static func unavailableNotes(_ engines: Engines, page: PageResult) -> [ReviewNote] {
        guard let reason = engines.vlUnavailable else { return [] }
        let structured = page.blocks.contains { $0.label == .table || $0.label.vlTask == .formula }
        return structured ? [.warning(.structureReadAsPlainText(loadError: reason))] : []
    }

    // MARK: - Apple Vision

    /// Each line keeps the box Vision found it in: it is what the preview's
    /// overlay and a searchable PDF's text layer are built from.
    private static func performVisionOCR(on cgImage: CGImage, settings: Settings) async throws -> PageResult {
        var request = RecognizeTextRequest()
        request.recognitionLevel = settings.engine == .visionFast ? .fast : .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = settings.visionLanguages.map(Locale.Language.init(identifier:))
        let observations = try await request.perform(on: cgImage)

        // Vision's coordinates are normalised with the origin at the bottom
        // left; the app's are pixels from the top left.
        let size = CGSize(width: cgImage.width, height: cgImage.height)
        func pixel(_ point: NormalizedPoint) -> CGPoint {
            point.toImageCoordinates(size, origin: .upperLeft)
        }
        let lines = observations.compactMap { observation -> PPTextLine? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return PPTextLine(quad: [pixel(observation.topLeft), pixel(observation.topRight),
                                     pixel(observation.bottomRight), pixel(observation.bottomLeft)],
                              text: candidate.string,
                              confidence: Double(candidate.confidence),
                              wasRotated: false)
        }
        return PageResult(size: size, lines: lines, rawText: lines.map(\.text).joined(separator: "\n"))
    }
}

/// Runs synchronous work that blocks — the inference engines wait on their
/// own thread pools and on the GPU, files are decoded and rendered — on a
/// dispatch queue rather than on Swift's cooperative thread pool, whose few
/// threads must never be held up waiting.
enum BlockingWork {
    private static let queue = DispatchQueue(label: "OCRFlow.blocking", qos: .userInitiated,
                                             attributes: .concurrent)

    static func run<T>(_ work: @escaping @Sendable () throws -> sending T) async throws -> sending T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func run<T>(_ work: @escaping @Sendable () -> sending T) async -> sending T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }
}

/// Decoding page images from files, the same way for recognition, previews
/// and exports.
enum PageImages {
    /// How many pages an image file holds: a multi-page TIFF is a document,
    /// every other format one picture.
    static func frameCount(of url: URL) -> Int {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return 0 }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return 0 }
        let type = (CGImageSourceGetType(source) as String?) ?? ""
        if type == "public.tiff", count > 1 { return count }
        return LongImagePages.pages(of: url)?.count ?? 1
    }

    /// One page at full resolution, turned upright: a frame of a multi-page
    /// TIFF, a page of a long screenshot, or the whole picture.
    ///
    /// A phone photo stores its pixels as the sensor saw them and an EXIF tag
    /// saying which way is up. Reading the pixels without the tag hands the
    /// detectors a sideways page; the thumbnail API applies it, and asked for
    /// a thumbnail as large as the image, returns the whole image.
    static func image(at url: URL, frame: Int = 0) -> CGImage? {
        if frame > 0 || LongImagePages.mayBeLong(url), let pages = LongImagePages.pages(of: url) {
            return LongImagePages.page(frame, of: url, cutAt: pages)
        }
        return wholeImage(at: url, frame: frame)
    }

    /// One frame, all of it, however long.
    static func wholeImage(at url: URL, frame: Int = 0) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, frame, nil) as? [CFString: Any]
        else { return nil }
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height, 1),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, frame, options as CFDictionary)
    }

    /// A small upright preview for the file list.
    static func thumbnail(of url: URL, maxPixels: Int = 96) -> CGImage? {
        if url.pathExtension.lowercased() == "pdf" {
            guard let source = PDFSource(url: url), source.pageCount > 0,
                  let rendered = source.render(page: 0, scale: 0.25) else { return nil }
            return rendered.image
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
