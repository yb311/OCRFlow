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
            case .mirror:      return String(localized: "HF mirror (mainland China)")
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
        detail: String(localized: "The most accurate tier, with better detection and recognition than small. Shares the built-in dictionary"),
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
        ("korean",     String(localized: "Korean")),
        ("cyrillic",   String(localized: "Cyrillic")),
        ("eslav",      String(localized: "East Slavic")),
        ("arabic",     String(localized: "Arabic")),
        ("devanagari", String(localized: "Devanagari")),
        ("el",         String(localized: "Greek")),
        ("ta",         String(localized: "Tamil")),
        ("te",         String(localized: "Telugu")),
        ("th",         String(localized: "Thai")),
    ]

    static let languageRecognizers: [Entry] = languages.map { language in
        let repo = "\(language.code)_PP-OCRv5_mobile_rec_onnx"
        let model = "\(language.code)_PP-OCRv5_mobile_rec.onnx"
        return Entry(
            id: "lang.\(language.code)",
            name: language.name,
            detail: String(localized: "PP-OCRv5 single-language recognizer, used with the PP-OCRv6 detector"),
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
        name: String(localized: "PP-DocLayoutV3 layout analysis"),
        detail: String(localized: "The first stage of PaddleOCR-VL: splits the layout and decides the reading order. Required for the VL engine"),
        approximateBytes: 130_500_000,
        assets: [
            Asset(repo: "PP-DocLayoutV3_onnx", remoteFile: "inference.onnx",
                  localName: VLModelStore.layoutModelFileName),
        ])

    static let vlOfficial = Entry(
        id: "vl.official",
        name: String(localized: "PaddleOCR-VL-1.6 (official F16)"),
        detail: String(localized: "Official PaddlePaddle weights, the accuracy reference. Two files: the text model and the vision encoder"),
        approximateBytes: 935_769_056 + 881_770_560,
        assets: [
            Asset(repo: "PaddleOCR-VL-1.6-GGUF", remoteFile: "PaddleOCR-VL-1.6-GGUF.gguf",
                  localName: VLModelVariant.official.modelFileName),
            Asset(repo: "PaddleOCR-VL-1.6-GGUF", remoteFile: "PaddleOCR-VL-1.6-GGUF-mmproj.gguf",
                  localName: VLModelVariant.official.mmprojFileName),
        ])

    static let vlQuantized = Entry(
        id: "vl.quantized",
        name: String(localized: "PaddleOCR-VL-1.6 (Q4 quantized)"),
        detail: String(localized: "Community quantization, about half the size of the official weights and faster to load. The vision encoder is quantized too, so accuracy may drop slightly"),
        approximateBytes: 300_000_000 + 598_000_000,
        assets: [
            Asset(repo: "PaddleOCR-VL-1.6-GGUF-Q4", owner: "LunarOilRig",
                  remoteFile: "PaddleOCR-VL-1.6-Q4_K_M.gguf",
                  localName: VLModelVariant.quantized.modelFileName),
            Asset(repo: "PaddleOCR-VL-1.6-GGUF-Q4", owner: "LunarOilRig",
                  remoteFile: "mmproj-Q8_0.gguf",
                  localName: VLModelVariant.quantized.mmprojFileName),
        ])

    /// UVDoc, the page-flattening stage. Small enough to install in seconds,
    /// and only useful for photographs of pages rather than scans, so it is
    /// downloaded on demand rather than shipped.
    static let unwarpingModel = Entry(
        id: "pp.unwarp",
        name: String(localized: "UVDoc page unwarping"),
        detail: String(localized: "Flattens skewed, curled or folded pages before recognition; not needed for scans"),
        approximateBytes: 31_000_000,
        assets: [
            Asset(repo: "UVDoc_onnx", remoteFile: "inference.onnx",
                  localName: PPModelStore.unwarpingModelFileName),
        ])

    /// A small file used only to check whether a source answers at all.
    /// `inference.yml` is a few kilobytes, and every mirror carries it.
    static let probeAsset = Asset(repo: "korean_PP-OCRv5_mobile_rec_onnx",
                                  remoteFile: "inference.yml",
                                  localName: "probe.yml", kind: .dictionary)

    static var vlEntries: [Entry] { [layoutModel, vlQuantized, vlOfficial] }

    static var allEntries: [Entry] {
        [mediumTier, unwarpingModel] + vlEntries + languageRecognizers
    }
}
