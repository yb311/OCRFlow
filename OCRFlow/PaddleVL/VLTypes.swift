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
        case .ocr:      return "文字识别"
        case .table:    return "表格识别"
        case .formula:  return "公式识别"
        case .chart:    return "图表识别"
        case .seal:     return "印章识别"
        case .spotting: return "文字定位"
        }
    }

    var hint: String {
        switch self {
        case .ocr:      return "读出图中文字"
        case .table:    return "输出 HTML 表格结构"
        case .formula:  return "输出 LaTeX 公式"
        case .chart:    return "把图表内容还原成表格"
        case .seal:     return "读出印章上的弧形文字"
        case .spotting: return "同时给出文字与位置"
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
        case .official:  return "官方 F16"
        case .quantized: return "Q4 量化"
        }
    }

    var hint: String {
        switch self {
        case .official:  return "1.8 GB，PaddlePaddle 官方权重，精度基准"
        case .quantized: return "0.9 GB，社区量化，加载快、占用小（推荐先试）"
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
    /// Prompt used when layout analysis is off and the whole image goes to the
    /// model in one shot.
    var wholeImageTask: VLTask = .ocr
    /// Run PP-DocLayoutV3 first and recognise block by block. This is the
    /// official pipeline; turning it off matches `use_layout_detection=False`.
    var useLayoutDetection: Bool = true
    /// Where the preference used to live. It is a document setting rather than
    /// an engine one — both engines produce layout blocks now — so it moved to
    /// the view model; this field is only read once, to carry the user's old
    /// choice forward.
    var dropPageFurniture: Bool = true

    static let `default` = VLConfig()
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
            return "缺少\(variant.label)模型文件：\(missing.joined(separator: "、"))。"
                 + "请在「模型管理」中下载，或将文件放入 \(path) 后重试。"
        case let .backendFailed(msg):
            return "PaddleOCR-VL 模型加载失败：\(msg)"
        case let .contextFailed(msg):
            return "PaddleOCR-VL 上下文创建失败：\(msg)"
        case let .multimodalFailed(msg):
            return "PaddleOCR-VL 视觉编码器加载失败：\(msg)"
        case let .tokenizeFailed(code):
            return "PaddleOCR-VL 无法处理这张图片（错误码 \(code)）"
        case let .evalFailed(code):
            return "PaddleOCR-VL 推理失败（错误码 \(code)）"
        case .imageDecodeFailed:
            return "无法解码图片像素数据"
        case let .layoutModelMissing(path):
            return "缺少版面分析模型 PP-DocLayoutV3.onnx。"
                 + "请在「模型管理」中下载，或将文件放入 \(path) 后重试。"
        }
    }
}
