import Foundation
import CoreGraphics
import ImageIO
import Vision

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
        /// Why 智能分层 is running without PaddleOCR-VL although it is
        /// installed, when that is the case. Noted on every page it affects.
        var vlUnavailable: String?
    }

    typealias Progress = @Sendable (Double) -> Void

    /// Pages of one file read at once. Two is enough to keep the GPU fed —
    /// one page's layout and PP-OCR run while the other's regions are with
    /// the VLM — without holding a stack of rendered pages in memory.
    static let pagesInFlight = 2

    static func recognize(url: URL, settings: Settings, engines: Engines,
                          isCancelled: @escaping @Sendable () -> Bool,
                          progress: @escaping Progress) throws -> [PageResult] {
        if url.pathExtension.lowercased() == "pdf" {
            return try recognizePDF(at: url, settings: settings, engines: engines,
                                    isCancelled: isCancelled, progress: progress)
        }
        return try recognizeImageFile(at: url, settings: settings, engines: engines,
                                      isCancelled: isCancelled, progress: progress)
    }

    // MARK: - Files

    private static func recognizeImageFile(at url: URL, settings: Settings, engines: Engines,
                                           isCancelled: @escaping @Sendable () -> Bool,
                                           progress: @escaping Progress) throws -> [PageResult] {
        let count = PageImages.frameCount(of: url)
        guard count > 0 else { throw OCRError.imageLoadFailed }
        progress(0.05)
        return try readPages(count: count, isCancelled: isCancelled, progress: progress) { index, report in
            guard let image = PageImages.image(at: url, frame: index) else { throw OCRError.imageLoadFailed }
            return try recognize(page: image, pdf: nil, settings: settings, engines: engines,
                                 isCancelled: isCancelled, progress: report)
        }
    }

    private static func recognizePDF(at url: URL, settings: Settings, engines: Engines,
                                     isCancelled: @escaping @Sendable () -> Bool,
                                     progress: @escaping Progress) throws -> [PageResult] {
        guard let source = PDFSource(url: url) else { throw OCRError.pdfOpenFailed }
        let count = source.pageCount
        guard count > 0 else { throw OCRError.pdfOpenFailed }
        return try readPages(count: count, isCancelled: isCancelled, progress: progress) { index, report in
            guard let rendered = source.render(page: index) else { throw OCRError.imageLoadFailed }
            return try recognize(page: rendered.image, pdf: (source, index, rendered),
                                 settings: settings, engines: engines,
                                 isCancelled: isCancelled, progress: report)
        }
    }

    /// Reads `count` pages, a couple at a time, and returns them in order.
    ///
    /// A page that fails is kept as an empty page that says why, so one
    /// unreadable page in a hundred does not throw the other ninety-nine
    /// away. Only a file none of whose pages could be read fails as a whole.
    private static func readPages(count: Int, isCancelled: @escaping @Sendable () -> Bool,
                                  progress: @escaping Progress,
                                  read: @escaping @Sendable (Int, @escaping (Double) -> Void) throws -> PageResult)
        throws -> [PageResult] {
        let lock = NSLock()
        var pages = [PageResult?](repeating: nil, count: count)
        var errors = [Error?](repeating: nil, count: count)
        var fractions = [Double](repeating: 0, count: count)

        func report(_ index: Int, _ fraction: Double) {
            lock.lock()
            fractions[index] = min(max(fraction, 0), 1)
            let total = fractions.reduce(0, +) / Double(count)
            lock.unlock()
            progress(total)
        }

        let queue = DispatchQueue(label: "OCRFlow.pages", qos: .userInitiated, attributes: .concurrent)
        let slots = DispatchSemaphore(value: count == 1 ? 1 : pagesInFlight)
        let group = DispatchGroup()
        for index in 0..<count {
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
                    lock.lock(); pages[index] = page; lock.unlock()
                } catch {
                    lock.lock(); errors[index] = error; lock.unlock()
                }
                report(index, 1)
            }
        }
        group.wait()

        if isCancelled() { return pages.compactMap { $0 } }
        if pages.allSatisfy({ $0 == nil }), let first = errors.compactMap({ $0 }).first { throw first }
        return (0..<count).map { index in
            pages[index] ?? PageResult(size: .zero, notes: [
                .warning("第 \(index + 1) 页识别失败：\(errors[index]?.localizedDescription ?? "未知错误")"),
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
                throw VLError.backendFailed("PaddleOCR-VL 模型未加载")
            }
            page = try vlPipeline.parse(image: image, config: settings.vlConfig,
                                        progress: progress, isCancelled: isCancelled)
        case .paddleOCR:
            guard let paddle = engines.paddle else {
                throw PPOCRError.sessionFailed("PaddleOCR 模型未加载")
            }
            let result = try paddle.recognize(image: image, config: settings.paddleConfig,
                                              progress: progress, isCancelled: isCancelled)
            page = PageResult(size: CGSize(width: image.width, height: image.height),
                              lines: result.lines, blocks: result.blocks,
                              blockSource: .plainOCR, rawText: result.lines.plainText)
        case .auto:
            guard let layered = engines.layered else {
                throw PPOCRError.sessionFailed("PaddleOCR 模型未加载")
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
        return structured ? [.warning("本页含表格或公式，但 \(reason)，按普通文字识别")] : []
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
