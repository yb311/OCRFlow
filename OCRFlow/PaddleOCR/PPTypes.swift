import Foundation
import CoreGraphics

// MARK: - Results

/// One recognised text line: where it is, what it says, how sure the model is.
struct PPTextLine: Equatable {
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
        case .tiny:   return "轻量版 tiny"
        case .small:  return "均衡版 small"
        case .medium: return "高精度版 medium"
        }
    }

    var hint: String {
        switch self {
        case .tiny:   return "6 MB，最快。覆盖 49 种语言（不含日文）"
        case .small:  return "31 MB，速度与精度平衡，随应用内置（推荐）"
        case .medium: return "139 MB，精度最高，需在模型管理中下载"
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
    /// Recursive XY-cut: find the columns first, read each one top to bottom.
    case columns
    /// PaddleOCR's own `sorted_boxes`: strictly top to bottom, left to right
    /// within a ~10 px band.
    case simple

    var id: String { rawValue }

    var label: String {
        switch self {
        case .columns: return "按栏排序（推荐）"
        case .simple:  return "自上而下"
        }
    }

    var hint: String {
        switch self {
        case .columns:
            return "先切分栏目再逐栏阅读，报刊、论文等多栏版面不会串行"
        case .simple:
            return "PaddleOCR 原始顺序，同一水平线上的文字按从左到右排列；"
                 + "适合票据、表单等左右成对的内容"
        }
    }
}

/// Execution backend handed to ONNX Runtime.
enum PPComputeUnit: String, CaseIterable, Identifiable, Codable {
    case cpu
    case coreML

    var id: String { rawValue }

    var label: String {
        switch self {
        case .cpu:    return "CPU"
        case .coreML: return "Core ML（神经引擎 / GPU）"
        }
    }

    var hint: String {
        switch self {
        case .cpu:    return "多线程并行，识别结果与 Core ML 一致（推荐）"
        case .coreML:
            // PP-OCR's det and rec graphs have dynamic input shapes, so Core ML
            // recompiles per shape and ends up several times slower than CPU on
            // typical pages. Kept as an escape hatch, not as an optimisation.
            return "交由神经引擎/GPU 执行。PP-OCR 输入尺寸可变，实测通常比 CPU 慢数倍"
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
    var readingOrder: PPTextOrder = .columns

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
            return "缺少\(tier.label)的模型文件：\(missing.joined(separator: "、"))。"
                 + "请在「模型管理」中下载，或将文件放入 \(path) 后重试。"
        case .dictionaryMissing:
            return "缺少 PaddleOCR 字典文件，无法解码识别结果。"
        case let .charsetMismatch(expected, actual):
            return "识别模型与字典不匹配：模型输出 \(actual) 类，字典对应 \(expected) 类。"
                 + "请确认模型旁的字典文件来自同一个版本。"
        case let .sessionFailed(msg):
            return "PaddleOCR 模型加载失败：\(msg)"
        case let .inferenceFailed(msg):
            return "PaddleOCR 推理失败：\(msg)"
        case let .unexpectedOutputShape(msg):
            return "PaddleOCR 模型输出形状异常：\(msg)"
        case .imageDecodeFailed:
            return "无法解码图片像素数据"
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
