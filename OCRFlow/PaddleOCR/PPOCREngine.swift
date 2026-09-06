import Foundation
import CoreGraphics
import OnnxRuntimeBindings

/// The full PP-OCRv6 pipeline: detect text regions, straighten each crop,
/// then read it.
///
/// Sessions are expensive to build (the recogniser alone is a 21 MB graph), so
/// an engine is created once per configuration and reused across images. All
/// entry points are serialised internally, which lets the view model hold a
/// single engine and hand it work from a background task.
final class PPOCREngine: @unchecked Sendable {

    let config: PPOCRConfig

    private let env: ORTEnv
    private let detector: PPDetector
    private let classifier: PPTextLineClassifier
    private let docOrienter: PPDocOrientationClassifier
    private let recognizer: PPRecognizer
    /// PP-DocLayoutV3, loaded only when the reading order is taken from the
    /// layout model. It is the same file the PaddleOCR-VL pipeline uses.
    private let layout: PPLayoutDetector?
    private let lock = NSLock()

    /// What one page yielded: the lines, and — when layout analysis ran — the
    /// regions they were poured into.
    struct Page {
        var lines: [PPTextLine] = []
        var blocks: [PPLayoutBlock] = []
    }

    convenience init(config: PPOCRConfig) throws {
        try self.init(config: config,
                      paths: PPModelStore.resolve(tier: config.tier,
                                                  recognizer: config.recognizer))
    }

    /// Builds an engine from explicit file paths, bypassing `PPModelStore`.
    init(config: PPOCRConfig, paths: PPModelStore.Paths) throws {
        self.config = config
        do {
            env = try ORTEnv(loggingLevel: .error)
        } catch {
            throw PPOCRError.sessionFailed(error.localizedDescription)
        }
        detector = PPDetector(session: try PPSession(modelPath: paths.detModel, env: env, config: config))
        classifier = PPTextLineClassifier(session: try PPSession(modelPath: paths.clsModel, env: env, config: config))
        docOrienter = PPDocOrientationClassifier(
            session: try PPSession(modelPath: paths.docOriModel, env: env, config: config))
        recognizer = try PPRecognizer(
            session: try PPSession(modelPath: paths.recModel, env: env, config: config),
            dictionaryURL: paths.dictionary)

        if config.readingOrder.needsLayoutModel, let modelURL = try? VLModelStore.resolveLayoutModel() {
            layout = PPLayoutDetector(
                session: try PPSession(modelPath: modelURL, env: env, config: config))
        } else {
            // Missing model is not a failure: the engine still reads the page,
            // it just falls back to ordering the lines geometrically. The
            // settings pane is where a missing model gets reported.
            layout = nil
        }
    }

    /// True when layout analysis is actually available on this engine.
    var hasLayoutAnalysis: Bool { layout != nil }

    /// True when `other` would produce an engine equivalent to this one, so the
    /// loaded sessions can be reused instead of rebuilt.
    func matchesModelConfiguration(_ other: PPOCRConfig) -> Bool {
        config.tier == other.tier
            && config.recognizer == other.recognizer
            && config.computeUnit == other.computeUnit
            && config.threadCount == other.threadCount
            // Turning layout analysis on or off adds or drops a session, so the
            // engine has to be rebuilt rather than reused.
            && config.readingOrder.needsLayoutModel == other.readingOrder.needsLayoutModel
    }

    /// Runs detection → orientation → recognition on one image.
    ///
    /// `progress` is reported in the 0…1 range; `isCancelled` is polled between
    /// recognition batches so a long page can be abandoned promptly.
    func recognize(image: CGImage,
                   config runtimeConfig: PPOCRConfig? = nil,
                   progress: ((Double) -> Void)? = nil,
                   isCancelled: (() -> Bool)? = nil) throws -> Page {
        lock.lock()
        defer { lock.unlock() }

        let cfg = runtimeConfig ?? config
        guard let buffer = PPImageBuffer(cgImage: image) else {
            throw PPOCRError.imageDecodeFailed
        }

        progress?(0.05)
        // Straighten the page first: the detector only understands upright text,
        // so a rotated scan has to be corrected before it is run, not after.
        let orientation: PPDocOrientationClassifier.Orientation =
            cfg.useDocOrientation ? try docOrienter.classify(buffer) : .upright
        let page = PPDocOrientationClassifier.straighten(buffer, from: orientation)
        progress?(0.1)

        // Layout first, on the straightened page: the regions are what the
        // lines will be sorted into, and they are cheap next to recognition.
        var regions: [PPLayoutBlock] = []
        if cfg.readingOrder.needsLayoutModel, let layout {
            regions = (try? layout.detect(page)) ?? []
            regions = Self.mappedBack(regions, orientation: orientation,
                                      originalWidth: buffer.width, originalHeight: buffer.height)
        }
        progress?(0.2)

        let quads = try detector.detect(page, config: cfg)
        progress?(0.35)
        guard !quads.isEmpty else { return Page(lines: [], blocks: regions) }
        if isCancelled?() == true { return Page() }

        var crops: [PPImageBuffer] = []
        var keptQuads: [[CGPoint]] = []
        crops.reserveCapacity(quads.count)
        for quad in quads {
            guard let crop = page.perspectiveCrop(quad: quad) else { continue }
            crops.append(crop)
            // Report boxes in the coordinates of the image the caller passed in.
            keptQuads.append(quad.map {
                PPDocOrientationClassifier.mapBack($0, orientation: orientation,
                                                   originalWidth: buffer.width,
                                                   originalHeight: buffer.height)
            })
        }
        guard !crops.isEmpty else { return Page(lines: [], blocks: regions) }
        progress?(0.45)
        if isCancelled?() == true { return Page() }

        var rotated = [Bool](repeating: false, count: crops.count)
        if cfg.useTextLineOrientation {
            let corrected = try classifier.correctOrientation(crops, config: cfg)
            crops = corrected.crops
            rotated = corrected.rotated
        }
        progress?(0.55)
        if isCancelled?() == true { return Page() }

        let recognised = try recognizer.recognize(crops, config: cfg)
        progress?(0.95)

        var lines: [PPTextLine] = []
        lines.reserveCapacity(recognised.count)
        for (i, result) in recognised.enumerated() {
            guard result.confidence >= cfg.dropScore else { continue }
            guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            lines.append(PPTextLine(quad: keptQuads[i], text: result.text,
                                    confidence: result.confidence, wasRotated: rotated[i]))
        }
        progress?(1.0)

        // Regions decide the order when the layout model ran; otherwise fall
        // back to reading the geometry of the lines themselves.
        if !regions.isEmpty {
            let page = PPStructureAssembler.assemble(lines: lines, blocks: regions)
            return Page(lines: page.lines, blocks: page.blocks)
        }
        return Page(lines: Self.inReadingOrder(lines, mode: cfg.readingOrder), blocks: [])
    }

    /// Detection hands its boxes back in PaddleOCR's `sorted_boxes` order,
    /// which is purely top-to-bottom: on a two-column page that reads one line
    /// from the left column, then one from the right, all the way down. Without
    /// a layout model to say where the columns are, the XY-cut pass estimates
    /// them from the whitespace instead.
    static func inReadingOrder(_ lines: [PPTextLine], mode: PPTextOrder) -> [PPTextLine] {
        guard mode != .simple, lines.count > 1 else { return lines }
        return PPXYCut.order(lines.map(\.boundingBox)).map { lines[$0] }
    }

    /// Layout runs on the straightened page, so its boxes come back in that
    /// page's coordinates; the caller works in the coordinates of the image it
    /// passed in, which is what the text-line quads are already mapped to.
    private static func mappedBack(_ blocks: [PPLayoutBlock],
                                   orientation: PPDocOrientationClassifier.Orientation,
                                   originalWidth: Int, originalHeight: Int) -> [PPLayoutBlock] {
        guard orientation != .upright else { return blocks }
        return blocks.map { block in
            var block = block
            let corners = [CGPoint(x: block.rect.minX, y: block.rect.minY),
                           CGPoint(x: block.rect.maxX, y: block.rect.maxY)]
                .map { PPDocOrientationClassifier.mapBack($0, orientation: orientation,
                                                          originalWidth: originalWidth,
                                                          originalHeight: originalHeight) }
            block.rect = CGRect(x: min(corners[0].x, corners[1].x),
                                y: min(corners[0].y, corners[1].y),
                                width: abs(corners[1].x - corners[0].x),
                                height: abs(corners[1].y - corners[0].y))
            return block
        }
    }
}

// MARK: - Text assembly

extension Array where Element == PPTextLine {
    /// The lines arrive in reading order — `PPOCREngine.inReadingOrder` put
    /// them there — so joining is enough; the view model's post-processing
    /// handles paragraph reflow from here.
    var plainText: String {
        map(\.text).joined(separator: "\n")
    }
}
