import Foundation

/// The models the app can install for itself, and where they come from.
///
/// Everything here lands in `PPModelStore.userModelsDirectory`; nothing
/// overwrites a bundled file. Two kinds of entry exist: the `medium` PP-OCRv6
/// tier, which is too large to ship, and the PP-OCRv5 single-language
/// recognisers for the scripts PP-OCRv6 does not cover.
enum PPModelCatalog {

    /// Where the files are fetched from. Hugging Face is frequently
    /// unreachable from mainland China, so the mirror is a first-class choice
    /// rather than a fallback.
    enum Source: String, CaseIterable, Identifiable, Codable {
        case huggingFace
        case mirror

        var id: String { rawValue }

        var host: String {
            switch self {
            case .huggingFace: return "huggingface.co"
            case .mirror:      return "hf-mirror.com"
            }
        }

        var label: String {
            switch self {
            case .huggingFace: return "Hugging Face"
            case .mirror:      return "HF 镜像（国内）"
            }
        }
    }

    /// One remote file and what it becomes on disk.
    struct Asset: Hashable {
        enum Kind: Hashable {
            /// Saved verbatim.
            case model
            /// Parsed as `inference.yml` and written out as a charset file.
            case dictionary
        }

        /// Hugging Face repo id. Defaults to the PaddlePaddle organisation;
        /// the quantised PaddleOCR-VL weights are community uploads and carry
        /// their own owner.
        var repo: String
        var owner: String = "PaddlePaddle"
        var remoteFile: String
        var localName: String
        var kind: Kind = .model

        func url(from source: Source) -> URL? {
            URL(string: "https://\(source.host)/\(owner)/\(repo)/resolve/main/\(remoteFile)")
        }
    }

    struct Entry: Identifiable, Hashable {
        var id: String
        var name: String
        var detail: String
        /// Shown before the download starts; the real size comes from the
        /// server's `Content-Length`.
        var approximateBytes: Int64
        var assets: [Asset]

        /// Every file present in the user models folder.
        var isInstalled: Bool {
            assets.allSatisfy { PPModelStore.isDownloaded($0.localName) }
        }

        /// The recogniser this entry installs, if it installs one. Lets the
        /// settings list a language the app can read *and* one it cannot read
        /// yet in the same place, instead of leaving the missing ones to be
        /// discovered by way of a page of nonsense.
        var recognizerFileName: String? {
            assets.first { $0.localName.hasSuffix("_rec.onnx") }?.localName
        }
    }

    // MARK: - Tiers

    static let mediumTier = Entry(
        id: "tier.medium",
        name: "PP-OCRv6 medium",
        detail: "精度最高的一档，检测与识别均优于 small；共享内置字典",
        approximateBytes: 62_032_837 + 76_554_979,
        assets: [
            Asset(repo: "PP-OCRv6_medium_det_onnx", remoteFile: "inference.onnx",
                  localName: PPModelTier.medium.detFileName),
            Asset(repo: "PP-OCRv6_medium_rec_onnx", remoteFile: "inference.onnx",
                  localName: PPModelTier.medium.recFileName),
        ])

    // MARK: - Languages PP-OCRv6 does not cover

    /// PP-OCRv6 reads 50 languages from one model — Simplified and Traditional
    /// Chinese, English, Japanese and 46 Latin-script languages — but
    /// PaddlePaddle published no v6 weights for these scripts. The PP-OCRv5
    /// recognisers still work, and pair with the v6 detector unchanged.
    private static let languages: [(code: String, name: String)] = [
        ("korean",     "韩语"),
        ("cyrillic",   "西里尔字母"),
        ("eslav",      "东斯拉夫语"),
        ("arabic",     "阿拉伯语"),
        ("devanagari", "天城文"),
        ("el",         "希腊语"),
        ("ta",         "泰米尔语"),
        ("te",         "泰卢固语"),
        ("th",         "泰语"),
    ]

    static let languageRecognizers: [Entry] = languages.map { language in
        let repo = "\(language.code)_PP-OCRv5_mobile_rec_onnx"
        let model = "\(language.code)_PP-OCRv5_mobile_rec.onnx"
        return Entry(
            id: "lang.\(language.code)",
            name: language.name,
            detail: "PP-OCRv5 单语种识别器，搭配 PP-OCRv6 检测器使用",
            approximateBytes: 16_500_000,
            assets: [
                Asset(repo: repo, remoteFile: "inference.onnx", localName: model),
                Asset(repo: repo, remoteFile: "inference.yml",
                      localName: "\(language.code)_PP-OCRv5_mobile_rec_dict.txt",
                      kind: .dictionary),
            ])
    }

    // MARK: - PaddleOCR-VL

    /// Layout analysis. Without it the VLM only ever sees a whole page at once,
    /// which the official docs warn against and which measurably drops content.
    static let layoutModel = Entry(
        id: "vl.layout",
        name: "PP-DocLayoutV3 版面分析",
        detail: "PaddleOCR-VL 的第一阶段：切分版面并判定阅读顺序。使用 VL 引擎必装",
        approximateBytes: 130_500_000,
        assets: [
            Asset(repo: "PP-DocLayoutV3_onnx", remoteFile: "inference.onnx",
                  localName: VLModelStore.layoutModelFileName),
        ])

    static let vlOfficial = Entry(
        id: "vl.official",
        name: "PaddleOCR-VL-1.6（官方 F16）",
        detail: "PaddlePaddle 官方权重，精度基准。含文本模型与视觉编码器两个文件",
        approximateBytes: 935_769_056 + 881_770_560,
        assets: [
            Asset(repo: "PaddleOCR-VL-1.6-GGUF", remoteFile: "PaddleOCR-VL-1.6-GGUF.gguf",
                  localName: VLModelVariant.official.modelFileName),
            Asset(repo: "PaddleOCR-VL-1.6-GGUF", remoteFile: "PaddleOCR-VL-1.6-GGUF-mmproj.gguf",
                  localName: VLModelVariant.official.mmprojFileName),
        ])

    static let vlQuantized = Entry(
        id: "vl.quantized",
        name: "PaddleOCR-VL-1.6（Q4 量化）",
        detail: "社区量化版，体积约为官方的一半、加载更快；视觉编码器也被量化，精度可能略有损失",
        approximateBytes: 300_000_000 + 598_000_000,
        assets: [
            Asset(repo: "PaddleOCR-VL-1.6-GGUF-Q4", owner: "LunarOilRig",
                  remoteFile: "PaddleOCR-VL-1.6-Q4_K_M.gguf",
                  localName: VLModelVariant.quantized.modelFileName),
            Asset(repo: "PaddleOCR-VL-1.6-GGUF-Q4", owner: "LunarOilRig",
                  remoteFile: "mmproj-Q8_0.gguf",
                  localName: VLModelVariant.quantized.mmprojFileName),
        ])

    static var vlEntries: [Entry] { [layoutModel, vlQuantized, vlOfficial] }

    static var allEntries: [Entry] { [mediumTier] + vlEntries + languageRecognizers }
}
