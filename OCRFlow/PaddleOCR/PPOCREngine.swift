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
    private let lock = NSLock()

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
    }

    /// True when `other` would produce an engine equivalent to this one, so the
    /// loaded sessions can be reused instead of rebuilt.
    func matchesModelConfiguration(_ other: PPOCRConfig) -> Bool {
        config.tier == other.tier
            && config.recognizer == other.recognizer
            && config.computeUnit == other.computeUnit
            && config.threadCount == other.threadCount
    }

    /// Runs detection → orientation → recognition on one image.
    ///
    /// `progress` is reported in the 0…1 range; `isCancelled` is polled between
    /// recognition batches so a long page can be abandoned promptly.
    func recognize(image: CGImage,
                   config runtimeConfig: PPOCRConfig? = nil,
                   progress: ((Double) -> Void)? = nil,
                   isCancelled: (() -> Bool)? = nil) throws -> [PPTextLine] {
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

        let quads = try detector.detect(page, config: cfg)
        progress?(0.35)
        guard !quads.isEmpty else { return [] }
        if isCancelled?() == true { return [] }

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
        guard !crops.isEmpty else { return [] }
        progress?(0.45)
        if isCancelled?() == true { return [] }

        var rotated = [Bool](repeating: false, count: crops.count)
        if cfg.useTextLineOrientation {
            let corrected = try classifier.correctOrientation(crops, config: cfg)
            crops = corrected.crops
            rotated = corrected.rotated
        }
        progress?(0.55)
        if isCancelled?() == true { return [] }

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
        return Self.inReadingOrder(lines, mode: cfg.readingOrder)
    }

    /// Detection hands its boxes back in PaddleOCR's `sorted_boxes` order,
    /// which is purely top-to-bottom: on a two-column page that reads one line
    /// from the left column, then one from the right, all the way down. The
    /// XY-cut pass finds the columns first and reads each one whole.
    static func inReadingOrder(_ lines: [PPTextLine], mode: PPTextOrder) -> [PPTextLine] {
        guard mode == .columns, lines.count > 1 else { return lines }
        return PPXYCut.order(lines.map(\.boundingBox)).map { lines[$0] }
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
