import Foundation

/// What we are asking PaddleOCR-VL to read out of an image.
///
/// The raw values are the prompts verbatim from PaddlePaddle's model card; the
/// model was trained on these exact strings, so they are not paraphrasable.
enum VLTask: String, CaseIterable, Identifiable, Codable {
    case ocr     = "OCR:"
    case table   = "Table Recognition:"
    case formula = "Formula Recognition:"
    case chart   = "Chart Recognition:"
    case seal    = "Seal Recognition:"
    case spotting = "Spotting:"

    var id: String { rawValue }

    var prompt: String { rawValue }

    var label: String {
        switch self {
        case .ocr:      return String(localized: "Text recognition")
        case .table:    return String(localized: "Table recognition")
        case .formula:  return String(localized: "Formula recognition")
        case .chart:    return String(localized: "Chart recognition")
        case .seal:     return String(localized: "Seal recognition")
        case .spotting: return String(localized: "Text spotting")
        }
    }

    var hint: String {
        switch self {
        case .ocr:      return String(localized: "Reads the text in the image")
        case .table:    return String(localized: "Outputs an HTML table")
        case .formula:  return String(localized: "Outputs LaTeX")
        case .chart:    return String(localized: "Turns a chart back into a table")
        case .seal:     return String(localized: "Reads the curved text on seals")
        case .spotting: return String(localized: "Returns text along with its position")
        }
    }
}

/// Which PaddleOCR-VL weights to load.
enum VLModelVariant: String, CaseIterable, Identifiable, Codable {
    /// PaddlePaddle's own F16 export.
    case official
    /// Community Q4_K_M weights with a Q8_0 vision encoder.
    case quantized

    var id: String { rawValue }

    var label: String {
        switch self {
        case .official:  return String(localized: "Official F16")
        case .quantized: return String(localized: "Q4 Quantized")
        }
    }

    var hint: String {
        switch self {
        case .official:  return String(localized: "1.8 GB, official PaddlePaddle weights, the accuracy reference")
        case .quantized: return String(localized: "0.9 GB, community quantization. Loads faster and uses less memory (try this first)")
        }
    }

    /// File names in the user models folder.
    var modelFileName: String {
        switch self {
        case .official:  return "PaddleOCR-VL-1.6-F16.gguf"
        case .quantized: return "PaddleOCR-VL-1.6-Q4_K_M.gguf"
        }
    }

    var mmprojFileName: String {
        switch self {
        case .official:  return "PaddleOCR-VL-1.6-mmproj-F16.gguf"
        case .quantized: return "PaddleOCR-VL-1.6-mmproj-Q8_0.gguf"
        }
    }
}

/// Everything tunable about a PaddleOCR-VL run.
struct VLConfig: Equatable, Codable {
    var variant: VLModelVariant = .quantized
    /// Context window. A dense page's image tokens plus its output have to fit.
    var contextTokens: Int = 8192
    /// Cap on generation per block, so one confused block cannot stall a page.
    var maxOutputTokens: Int = 1024
    /// 0 = as many as the system offers; PaddleOCR-VL runs on Metal by default.
    var threadCount: Int = 0
    var useGPU: Bool = true
    /// How many regions are decoded side by side. 0 picks from the machine's
    /// memory. Changes how fast a page is read, never what is read out of it.
    var parallelSequences: Int = 0
    /// Prompt used when layout analysis is off and the whole image goes to the
    /// model in one shot.
    var wholeImageTask: VLTask = .ocr
    /// Run PP-DocLayoutV3 first and recognise block by block. This is the
    /// official pipeline; turning it off matches `use_layout_detection=False`.
    var useLayoutDetection: Bool = true
    // Sampling. PaddleOCR passes these straight through to the VLM, and its
    // defaults are a plain greedy decode — temperature 0, no penalty, top-p 1.
    /// 0 keeps the decode greedy, which is what a transcription model wants.
    var temperature: Double = 0
    /// Nucleus sampling cut-off. Only consulted when the temperature is above 0.
    var topP: Double = 1
    /// Above 1, tokens already produced are made less likely — the knob the
    /// reference UI calls 重复抑制强度.
    var repetitionPenalty: Double = 1

    // Which of the specialised prompts the pipeline is allowed to use.
    /// Read charts as data tables. Off in the reference pipeline: a chart read
    /// as a table is a guess at numbers that are only drawn.
    var useChartRecognition: Bool = false
    /// Read the curved text on stamps and seals.
    var useSealRecognition: Bool = true
    /// Also read any text inside a figure, rather than treating it as a picture.
    var useImageTextRecognition: Bool = false
    /// Work out a heading's level from how large it is set, rather than making
    /// every heading the same level.
    var inferHeadingLevels: Bool = true

    /// How much wider than the detected region each crop is taken. PaddleOCR
    /// exposes the same knob on its layout stage as `unclip_ratio`.
    var cropUnclipRatio: Double = 1.05
    /// Where the preference used to live. It is a document setting rather than
    /// an engine one — both engines produce layout blocks now — so it moved to
    /// the view model; this field is only read once, to carry the user's old
    /// choice forward.
    var dropPageFurniture: Bool = true

    static let `default` = VLConfig()

    /// The choices offered for `parallelSequences`, besides automatic.
    static let parallelismChoices = [1, 2, 4, 6, 8, 12, 16]

    /// The number of sequences the engine actually runs.
    ///
    /// Each one holds its own share of the KV cache while it runs — about
    /// 18 KB per token, so sixteen sequences cost roughly 600 MB more than one
    /// — and the automatic choice follows the machine's memory. Sixteen is
    /// worth reaching for: llama.cpp's Metal backend reads the weights once
    /// per row for up to eight rows, and only past that switches to the
    /// matrix kernels that make a wide step nearly as cheap as a narrow one.
    var resolvedParallelism: Int {
        if parallelSequences > 0 { return min(16, parallelSequences) }
        let gigabytes = ProcessInfo.processInfo.physicalMemory >> 30
        switch gigabytes {
        case 24...: return 16
        case 14...: return 8
        default:    return 4
        }
    }

    /// KV cells for the whole batch.
    ///
    /// A typical region — a paragraph, a table, a formula — needs a few hundred
    /// to a couple of thousand cells for its image plus room for its answer, so
    /// about 2.5 K per sequence keeps the batch full without reserving a whole
    /// page's worth for every one of them. Never less than one request's own
    /// context, so a single full-page read still fits.
    static func contextBudget(perRequest: Int, parallelism: Int) -> Int {
        guard parallelism > 1 else { return perRequest }
        return min(65_536, max(perRequest, parallelism * 2_560))
    }
}

extension VLConfig {
    /// Field by field, so a settings file from an older build keeps everything
    /// it still knows about instead of resetting the lot.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = VLConfig()
        func value<T: Decodable>(_ key: CodingKeys, _ default: T) -> T {
            (try? container.decode(T.self, forKey: key)) ?? `default`
        }
        variant = value(.variant, fallback.variant)
        contextTokens = value(.contextTokens, fallback.contextTokens)
        maxOutputTokens = value(.maxOutputTokens, fallback.maxOutputTokens)
        threadCount = value(.threadCount, fallback.threadCount)
        useGPU = value(.useGPU, fallback.useGPU)
        parallelSequences = value(.parallelSequences, fallback.parallelSequences)
        wholeImageTask = value(.wholeImageTask, fallback.wholeImageTask)
        useLayoutDetection = value(.useLayoutDetection, fallback.useLayoutDetection)
        temperature = value(.temperature, fallback.temperature)
        topP = value(.topP, fallback.topP)
        repetitionPenalty = value(.repetitionPenalty, fallback.repetitionPenalty)
        useChartRecognition = value(.useChartRecognition, fallback.useChartRecognition)
        useSealRecognition = value(.useSealRecognition, fallback.useSealRecognition)
        useImageTextRecognition = value(.useImageTextRecognition, fallback.useImageTextRecognition)
        inferHeadingLevels = value(.inferHeadingLevels, fallback.inferHeadingLevels)
        cropUnclipRatio = value(.cropUnclipRatio, fallback.cropUnclipRatio)
        dropPageFurniture = value(.dropPageFurniture, fallback.dropPageFurniture)
    }
}

enum VLError: LocalizedError {
    case modelsMissing(variant: VLModelVariant, missing: [String], searchPath: String)
    case backendFailed(String)
    case contextFailed(String)
    case multimodalFailed(String)
    case tokenizeFailed(Int32)
    case evalFailed(Int32)
    case imageDecodeFailed
    case layoutModelMissing(searchPath: String)

    var errorDescription: String? {
        switch self {
        case let .modelsMissing(variant, missing, path):
            return String(localized: "Missing \(variant.label) model files: \(missing.formatted(.list(type: .and))). Download them in Model Manager, or put the files in \(path) and try again.")
        case let .backendFailed(msg):
            return String(localized: "Couldn't load the PaddleOCR-VL model: \(msg)")
        case let .contextFailed(msg):
            return String(localized: "Couldn't create the PaddleOCR-VL context: \(msg)")
        case let .multimodalFailed(msg):
            return String(localized: "Couldn't load the PaddleOCR-VL vision encoder: \(msg)")
        case let .tokenizeFailed(code):
            return String(localized: "PaddleOCR-VL can't process this image (error \(code))")
        case let .evalFailed(code):
            return String(localized: "PaddleOCR-VL inference failed (error \(code))")
        case .imageDecodeFailed:
            return String(localized: "Couldn't decode the image pixels")
        case let .layoutModelMissing(path):
            return String(localized: "The layout model PP-DocLayoutV3.onnx is missing. Download it in Model Manager, or put the file in \(path) and try again.")
        }
    }
}
