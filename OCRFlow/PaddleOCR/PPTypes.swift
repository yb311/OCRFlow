import Foundation
import CoreGraphics

// MARK: - Results

/// One recognised text line: where it is, what it says, how sure the model is.
struct PPTextLine: Equatable, Codable {
    /// Corners in source-image pixel coordinates, clockwise from top-left.
    var quad: [CGPoint]
    var text: String
    /// Mean per-character CTC probability, 0…1.
    var confidence: Double
    /// True when the textline-orientation model decided the crop was upside down.
    var wasRotated: Bool

    var boundingBox: CGRect {
        let xs = quad.map(\.x), ys = quad.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { return .zero }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

// MARK: - Configuration

/// Which PP-OCRv6 model tier backs detection and the built-in recogniser.
///
/// PP-OCRv6 replaced PP-OCRv5's mobile/server pair with three sizes cut from
/// the same PPLCNetV4 backbone. `tiny` and `small` ship inside the app;
/// `medium` is large enough that it is downloaded on demand instead.
enum PPModelTier: String, CaseIterable, Identifiable, Codable {
    case tiny
    case small
    case medium

    var id: String { rawValue }

    var label: String {
        switch self {
        case .tiny:   return String(localized: "Lightweight (tiny)")
        case .small:  return String(localized: "Balanced (small)")
        case .medium: return String(localized: "High accuracy (medium)")
        }
    }

    var hint: String {
        switch self {
        case .tiny:   return String(localized: "6 MB, fastest. Covers 49 languages (no Japanese)")
        case .small:  return String(localized: "31 MB, balances speed and accuracy, bundled with the app (recommended)")
        case .medium: return String(localized: "139 MB, most accurate. Download it in Model Manager")
        }
    }

    /// True when the tier's files travel inside the app bundle.
    var isBundled: Bool { self != .medium }

    var detFileName: String { "PP-OCRv6_\(rawValue)_det.onnx" }
    var recFileName: String { "PP-OCRv6_\(rawValue)_rec.onnx" }

    /// `tiny` drops the ~4,000 Kanji/Kana entries to keep its output layer
    /// small, so it carries its own charset; the other two share one.
    var dictionaryFileName: String {
        self == .tiny ? "PP-OCRv6_tiny_rec_dict.txt" : "ppocrv6_dict.txt"
    }

    /// `DBPostProcess` defaults from each tier's `inference.yml`. They differ
    /// from PP-OCRv5's, so a config carried over from v5 would under-detect.
    var detectionDefaults: (thresh: Double, boxThresh: Double,
                            unclipRatio: Double, maxCandidates: Int) {
        switch self {
        case .tiny:             return (0.2, 0.40, 1.4, 3000)
        case .small, .medium:   return (0.2, 0.45, 1.4, 3000)
        }
    }
}

/// Which recogniser reads the crops the detector produced.
///
/// PP-OCRv6 covers 50 languages in one model, but PaddlePaddle publishes no v6
/// weights for Korean, Arabic, Cyrillic, Thai, Greek or Devanagari. Those still
/// come from the PP-OCRv5 single-language recognisers — and because DB
/// detection is script-agnostic, they pair with the v6 detector unchanged.
enum PPRecognizerChoice: Hashable, Codable {
    /// The recogniser belonging to the selected tier.
    case builtin
    /// A model file in the user models folder, named as it is on disk.
    case custom(fileName: String)

    var customFileName: String? {
        if case let .custom(name) = self { return name }
        return nil
    }
}

/// How the recognised lines are put in order before they become text.
enum PPTextOrder: String, CaseIterable, Identifiable, Codable {
    /// PP-DocLayoutV3 finds the regions of the page and predicts the order they
    /// are read in; the lines are poured into those regions. This is what
    /// PaddleOCR's own document pipeline does.
    case layout
    /// Recursive XY-cut over the text lines: find the columns from the
    /// whitespace between them, read each one top to bottom. A geometric
    /// estimate, used when the layout model is not installed.
    case columns
    /// PaddleOCR's own `sorted_boxes`: strictly top to bottom, left to right
    /// within a ~10 px band.
    case simple

    var id: String { rawValue }

    var label: String {
        switch self {
        case .layout:  return String(localized: "Layout analysis (official pipeline, recommended)")
        case .columns: return String(localized: "By column (geometric estimate)")
        case .simple:  return String(localized: "Top to bottom (PaddleOCR's raw order)")
        }
    }

    var hint: String {
        switch self {
        case .layout:
            return String(localized: "Uses PP-DocLayoutV3 to find columns, headings, figures and other regions and decide the reading order, then places the recognized lines into their regions. Matches PaddleOCR's official document-parsing pipeline and also yields layout structure and Markdown. Requires the layout model")
        case .columns:
            return String(localized: "Estimates columns from the gaps between lines, without a layout model. Usually right for multi-column print, but bylines and right-aligned numbers may land in the wrong place")
        case .simple:
            return String(localized: "PaddleOCR's raw order: text on the same horizontal line reads left to right. Multi-column layouts get mixed across columns; suits receipts and forms with side-by-side pairs")
        }
    }

    /// True when this mode needs PP-DocLayoutV3 on disk.
    var needsLayoutModel: Bool { self == .layout }
}

/// Execution backend handed to ONNX Runtime.
enum PPComputeUnit: String, CaseIterable, Identifiable, Codable {
    case cpu
    case coreML

    var id: String { rawValue }

    var label: String {
        switch self {
        case .cpu:    return "CPU"
        case .coreML: return String(localized: "Core ML (Neural Engine / GPU)")
        }
    }

    var hint: String {
        switch self {
        case .cpu:    return String(localized: "Multithreaded, with the same results as Core ML (recommended)")
        case .coreML:
            // PP-OCR's det and rec graphs have dynamic input shapes, so Core ML
            // recompiles per shape and ends up several times slower than CPU on
            // typical pages. Kept as an escape hatch, not as an optimisation.
            return String(localized: "Runs on the Neural Engine / GPU. PP-OCR's input sizes vary, so in practice this is usually several times slower than CPU")
        }
    }
}

/// Every knob PaddleOCR exposes on the det → cls → rec chain.
///
/// Defaults mirror the `inference.yml` shipped with the PP-OCRv6 models, so an
/// untouched configuration reproduces the reference pipeline.
struct PPOCRConfig: Equatable, Codable {
    var tier: PPModelTier = .small
    var recognizer: PPRecognizerChoice = .builtin
    var computeUnit: PPComputeUnit = .cpu
    /// 0 lets ONNX Runtime pick, otherwise the intra-op thread count.
    var threadCount: Int = 0

    // Detection
    /// Long side the image is scaled to before detection (rounded to a multiple of 32).
    var detLimitSideLen: Int = 960
    /// Probability above which a pixel counts as text.
    var detThresh: Double = 0.2
    /// Minimum mean probability inside a candidate box.
    var detBoxThresh: Double = 0.45
    /// How far each box is grown; larger values keep more of the glyph edges.
    var detUnclipRatio: Double = 1.4
    var detMaxCandidates: Int = 3000
    /// Boxes whose short side falls below this (in detection-map pixels) are dropped.
    var detMinSize: Int = 3

    // Textline orientation
    var useTextLineOrientation: Bool = true
    /// Minimum probability before a line is flipped. The model separates the
    /// two classes around 0.27 / 0.73, so anything at or above ~0.75 would
    /// never fire; 0.6 sits in the gap.
    var clsThresh: Double = 0.6
    var clsBatchSize: Int = 8

    // Document orientation
    /// Detects a whole page rotated by 90/180/270° and straightens it before
    /// detection. Off by default: PP-OCR's detector only handles upright text,
    /// but the classifier is unreliable on images that are not documents.
    var useDocOrientation: Bool = false

    // Recognition
    var recBatchSize: Int = 6
    var recImageHeight: Int = 48
    var recImageWidth: Int = 320
    /// Lines recognised with less confidence than this are discarded.
    var dropScore: Double = 0.5

    // Assembly
    /// How the recognised lines are ordered before being joined into text.
    var readingOrder: PPTextOrder = .layout

    static let `default` = PPOCRConfig()

    /// Resets the four `DBPostProcess` knobs to the selected tier's reference
    /// values. Called when the tier changes so a threshold tuned for `tiny`
    /// does not silently follow the user over to `medium`.
    mutating func applyDetectionDefaults() {
        let defaults = tier.detectionDefaults
        detThresh = defaults.thresh
        detBoxThresh = defaults.boxThresh
        detUnclipRatio = defaults.unclipRatio
        detMaxCandidates = defaults.maxCandidates
    }
}

extension PPOCRConfig {
    /// Field by field, falling back to the default for anything a settings file
    /// written by an older build does not carry. The synthesised decoder throws
    /// on the first missing key, which would take every tuned value down with
    /// the one field that was added.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = PPOCRConfig()
        func value<T: Decodable>(_ key: CodingKeys, _ default: T) -> T {
            (try? container.decode(T.self, forKey: key)) ?? `default`
        }
        tier = value(.tier, fallback.tier)
        recognizer = value(.recognizer, fallback.recognizer)
        computeUnit = value(.computeUnit, fallback.computeUnit)
        threadCount = value(.threadCount, fallback.threadCount)
        detLimitSideLen = value(.detLimitSideLen, fallback.detLimitSideLen)
        detThresh = value(.detThresh, fallback.detThresh)
        detBoxThresh = value(.detBoxThresh, fallback.detBoxThresh)
        detUnclipRatio = value(.detUnclipRatio, fallback.detUnclipRatio)
        detMaxCandidates = value(.detMaxCandidates, fallback.detMaxCandidates)
        detMinSize = value(.detMinSize, fallback.detMinSize)
        useTextLineOrientation = value(.useTextLineOrientation, fallback.useTextLineOrientation)
        clsThresh = value(.clsThresh, fallback.clsThresh)
        clsBatchSize = value(.clsBatchSize, fallback.clsBatchSize)
        useDocOrientation = value(.useDocOrientation, fallback.useDocOrientation)
        recBatchSize = value(.recBatchSize, fallback.recBatchSize)
        recImageHeight = value(.recImageHeight, fallback.recImageHeight)
        recImageWidth = value(.recImageWidth, fallback.recImageWidth)
        dropScore = value(.dropScore, fallback.dropScore)
        readingOrder = value(.readingOrder, fallback.readingOrder)
    }
}

// MARK: - Errors

enum PPOCRError: LocalizedError {
    case modelsMissing(tier: PPModelTier, missing: [String], searchPath: String)
    case dictionaryMissing
    /// The recogniser's output layer and the loaded charset disagree, which
    /// means the model and the dictionary come from different releases.
    case charsetMismatch(expected: Int, actual: Int)
    case sessionFailed(String)
    case inferenceFailed(String)
    case unexpectedOutputShape(String)
    case imageDecodeFailed

    var errorDescription: String? {
        switch self {
        case let .modelsMissing(tier, missing, path):
            return String(localized: "Missing model files for \(tier.label): \(missing.formatted(.list(type: .and))). Download them in Model Manager, or put the files in \(path) and try again.")
        case .dictionaryMissing:
            return String(localized: "The PaddleOCR dictionary file is missing, so results can't be decoded.")
        case let .charsetMismatch(expected, actual):
            return String(localized: "The recognition model and dictionary don't match: the model outputs \(actual) classes, the dictionary has \(expected). Make sure the dictionary next to the model is from the same release.")
        case let .sessionFailed(msg):
            return String(localized: "Couldn't load the PaddleOCR model: \(msg)")
        case let .inferenceFailed(msg):
            return String(localized: "PaddleOCR inference failed: \(msg)")
        case let .unexpectedOutputShape(msg):
            return String(localized: "Unexpected PaddleOCR model output shape: \(msg)")
        case .imageDecodeFailed:
            return String(localized: "Couldn't decode the image pixels")
        }
    }
}

// MARK: - Cancellation

/// A cancellation flag the OCR worker can poll from outside the main actor.
///
/// The Stop button flips this so a long page is abandoned between batches
/// rather than after it finishes.
final class PPCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    func reset() {
        lock.lock(); cancelled = false; lock.unlock()
    }
}
