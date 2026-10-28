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
            vl.dropPageFurniture = true
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
                          onPage: PageHandler? = nil) throws -> [PageResult] {
        if url.pathExtension.lowercased() == "pdf" {
            guard let source = PDFSource(url: url) else { throw OCRError.pdfOpenFailed }
            let count = source.pageCount
            guard count > 0 else { throw OCRError.pdfOpenFailed }
            return try readPages(count: count, done: done, isCancelled: isCancelled,
                                 progress: progress, onPage: onPage) { index, report in
                try recognizePDFPage(index, of: source, settings: settings, engines: engines,
                                     isCancelled: isCancelled, progress: report)
            }
        }
        let count = PageImages.frameCount(of: url)
        guard count > 0 else { throw OCRError.imageLoadFailed }
        progress(ProgressUpdate(fraction: 0.05, pagesDone: done.count, pageCount: count))
        return try readPages(count: count, done: done, isCancelled: isCancelled,
                             progress: progress, onPage: onPage) { index, report in
            try recognizeImagePage(index, at: url, settings: settings, engines: engines,
                                   isCancelled: isCancelled, progress: report)
        }
    }

    /// Reads one page of a file again, on its own — the rest of the document
    /// stays as it is.
    static func recognize(page index: Int, of url: URL, settings: Settings, engines: Engines,
                          isCancelled: @escaping @Sendable () -> Bool,
                          progress: ((Double) -> Void)?) throws -> PageResult {
        if url.pathExtension.lowercased() == "pdf" {
            guard let source = PDFSource(url: url), index < source.pageCount else { throw OCRError.pdfOpenFailed }
            return try recognizePDFPage(index, of: source, settings: settings, engines: engines,
                                        isCancelled: isCancelled, progress: progress)
        }
        return try recognizeImagePage(index, at: url, settings: settings, engines: engines,
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
                                           progress: ((Double) -> Void)?) throws -> PageResult {
        guard let image = PageImages.image(at: url, frame: index) else { throw OCRError.imageLoadFailed }
        return try recognize(page: image, pdf: nil, settings: settings, engines: engines,
                             isCancelled: isCancelled, progress: progress)
    }

    private static func recognizePDFPage(_ index: Int, of source: PDFSource, settings: Settings, engines: Engines,
                                         isCancelled: @escaping @Sendable () -> Bool,
                                         progress: ((Double) -> Void)?) throws -> PageResult {
        guard let rendered = source.render(page: index) else { throw OCRError.imageLoadFailed }
        return try recognize(page: rendered.image, pdf: (source, index, rendered),
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
                                  read: @escaping @Sendable (Int, @escaping (Double) -> Void) throws -> PageResult)
        throws -> [PageResult] {
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
        let toRead = (0..<count).filter { initial.pages[$0] == nil }
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

        let queue = DispatchQueue(label: "OCRFlow.pages", qos: .userInitiated, attributes: .concurrent)
        let slots = DispatchSemaphore(value: count == 1 ? 1 : pagesInFlight)
        let group = DispatchGroup()
        for index in toRead {
            slots.wait()
            if isCancelled() {
                slots.signal()
                break
            }
            group.enter()
            queue.async {
                defer {
                    slots.signal()
                    group.leave()
                }
                do {
                    let page = try read(index) { report(index, $0) }
                    state.withLockUnchecked { $0.pages[index] = page }
                    // The engines answer a stop by returning what they have so
                    // far, so a page that comes back after one is a fragment.
                    if !isCancelled() { onPage?(index, page) }
                } catch {
                    state.withLockUnchecked { $0.errors[index] = error }
                }
                report(index, 1, finishing: true)
            }
        }
        group.wait()

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

    /// Sends one page to whichever engine is selected.
    static func recognize(page source: CGImage,
                          pdf: (source: PDFSource, index: Int, rendered: RenderedPDFPage)?,
                          settings: Settings, engines: Engines,
                          isCancelled: @escaping () -> Bool,
                          progress: ((Double) -> Void)?) throws -> PageResult {
        // 智能分层's first layer: a PDF page whose own text can be trusted is
        // not read from its pixels at all — so it is not flattened either.
        if settings.engine == .auto, let pdf, let layered = engines.layered,
           settings.layered.pdfText.trusts(pdf.source.verdict(page: pdf.index)) {
            if var page = try layered.read(rendered: pdf.rendered, source: pdf.source, page: pdf.index,
                                           progress: progress, isCancelled: isCancelled) {
                page.notes += unavailableNotes(engines, page: page)
                return page
            }
        }

        // Flattening comes first, exactly as it does upstream: everything after
        // it — layout, detection, recognition — assumes text runs in straight
        // lines. A failure here is not fatal; the page is read as photographed.
        var image = source
        var rectified: CGImage?
        if let unwarper = engines.unwarper, let buffer = PPImageBuffer(cgImage: source),
           let flattened = try? unwarper.rectify(buffer), let flat = flattened.cgImage {
            image = flat
            rectified = flat
        }

        var page: PageResult
        switch settings.engine {
        case .visionFast, .visionAccurate:
            page = try performVisionOCR(on: image, settings: settings)
            progress?(1)
        case .paddleVL:
            guard let vlPipeline = engines.vlPipeline else {
                throw VLError.backendFailed(String(localized: "The PaddleOCR-VL model isn't loaded"))
            }
            page = try vlPipeline.parse(image: image, config: settings.vlConfig,
                                        progress: progress, isCancelled: isCancelled)
        case .paddleOCR:
            guard let paddle = engines.paddle else {
                throw PPOCRError.sessionFailed(String(localized: "The PaddleOCR model isn't loaded"))
            }
            let result = try paddle.recognize(image: image, config: settings.paddleConfig,
                                              progress: progress, isCancelled: isCancelled)
            page = PageResult(size: CGSize(width: image.width, height: image.height),
                              lines: result.lines, blocks: result.blocks,
                              blockSource: .plainOCR, rawText: result.lines.plainText)
        case .auto:
            guard let layered = engines.layered else {
                throw PPOCRError.sessionFailed(String(localized: "The PaddleOCR model isn't loaded"))
            }
            page = try layered.read(image: image, progress: progress, isCancelled: isCancelled)
            page.notes += unavailableNotes(engines, page: page)
        }
        page.rectified = rectified.map(ImageItem.page(from:))
        return page
    }

    /// Says so on a page with structure, when 智能分层 had no VLM to read it.
    private static func unavailableNotes(_ engines: Engines, page: PageResult) -> [ReviewNote] {
        guard let reason = engines.vlUnavailable else { return [] }
        let structured = page.blocks.contains { $0.label == .table || $0.label.vlTask == .formula }
        return structured ? [.warning(.structureReadAsPlainText(loadError: reason))] : []
    }

    // MARK: - Apple Vision

    /// `VNImageRequestHandler.perform(_:)` is synchronous — it blocks the
    /// calling thread until every request's completion handler has already
    /// run — so plain local variables are enough here.
    ///
    /// Each line keeps the box Vision found it in, which the app used to throw
    /// away: it is what the preview's overlay and a searchable PDF's text
    /// layer are built from.
    private static func performVisionOCR(on cgImage: CGImage, settings: Settings) throws -> PageResult {
        var observations: [VNRecognizedTextObservation] = []
        var requestError: Error?
        let request = VNRecognizeTextRequest { req, err in
            if let err {
                requestError = err
                return
            }
            observations = req.results as? [VNRecognizedTextObservation] ?? []
        }
        request.recognitionLevel = settings.engine == .visionFast ? .fast : .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = settings.visionLanguages

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])
        if let requestError { throw requestError }

        let width = CGFloat(cgImage.width), height = CGFloat(cgImage.height)
        // Vision's coordinates are normalised with the origin at the bottom
        // left; the app's are pixels from the top left.
        func pixel(_ point: CGPoint) -> CGPoint {
            CGPoint(x: point.x * width, y: (1 - point.y) * height)
        }
        let lines = observations.compactMap { observation -> PPTextLine? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return PPTextLine(quad: [pixel(observation.topLeft), pixel(observation.topRight),
                                     pixel(observation.bottomRight), pixel(observation.bottomLeft)],
                              text: candidate.string,
                              confidence: Double(candidate.confidence),
                              wasRotated: false)
        }
        return PageResult(size: CGSize(width: width, height: height), lines: lines,
                          rawText: lines.map(\.text).joined(separator: "\n"))
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
        return type == "public.tiff" ? count : 1
    }

    /// One frame at full resolution, turned upright.
    ///
    /// A phone photo stores its pixels as the sensor saw them and an EXIF tag
    /// saying which way is up. Reading the pixels without the tag hands the
    /// detectors a sideways page; the thumbnail API applies it, and asked for
    /// a thumbnail as large as the image, returns the whole image.
    static func image(at url: URL, frame: Int = 0) -> CGImage? {
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
