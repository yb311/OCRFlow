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
    ///
    /// Each file is pinned to a commit of its repo and to the SHA-256 Hugging
    /// Face publishes for it, the way `huggingface_hub` pins a download: a
    /// later push to `main` cannot change what the app installs, and a file
    /// a mirror or proxy mangled is refused instead of loaded.
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
        /// The commit the file is fetched from.
        var revision: String
        var remoteFile: String
        /// Lowercase hex SHA-256 of the file as served: the LFS object id
        /// for the weights, the hash of the text itself for `inference.yml`.
        var sha256: String
        /// Size in bytes of the file as served.
        var size: Int64
        var localName: String
        var kind: Kind = .model

        func url(from source: Source) -> URL? {
            URL(string: "https://\(source.host)/\(owner)/\(repo)/resolve/\(revision)/\(remoteFile)")
        }
    }

    struct Entry: Identifiable, Hashable {
        var id: String
        var name: String
        /// What it is for, in everyday words, where the model's own name
        /// would mean nothing: the recognition settings.
        var purpose: String
        var detail: String
        var assets: [Asset]

        /// Shown before the download starts: the pinned files' own sizes.
        var approximateBytes: Int64 {
            assets.reduce(0) { $0 + $1.size }
        }

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
        purpose: String(localized: "More accurate text recognition"),
        detail: String(localized: "The most accurate tier, with better detection and recognition than small. Shares the built-in dictionary"),
        assets: [
            Asset(repo: "PP-OCRv6_medium_det_onnx",
                  revision: "61323801669c338b7891481ec7bac61ce31b576a",
                  remoteFile: "inference.onnx",
                  sha256: "eb13b44b25bb36f89528b68720af8a61d9cf381176107f465db1757b65d086e1",
                  size: 62_032_837,
                  localName: PPModelTier.medium.detFileName),
            Asset(repo: "PP-OCRv6_medium_rec_onnx",
                  revision: "50c7eacafc52fa7bcf4194e8cd08e46f8558504b",
                  remoteFile: "inference.onnx",
                  sha256: "9c09abf0957f7968c7586464b7397b84ad2387a0497a351af40e9acc71b673ba",
                  size: 76_554_979,
                  localName: PPModelTier.medium.recFileName),
        ])

    // MARK: - Languages PP-OCRv6 does not cover

    /// PP-OCRv6 reads 50 languages from one model — Simplified and Traditional
    /// Chinese, English, Japanese and 46 Latin-script languages — but
    /// PaddlePaddle published no v6 weights for these scripts. The PP-OCRv5
    /// recognisers still work, and pair with the v6 detector unchanged.
    private struct Language {
        var code: String
        var name: String
        var revision: String
        var model: (sha256: String, size: Int64)
        var dictionary: (sha256: String, size: Int64)
    }

    private static let languages: [Language] = [
        Language(code: "korean", name: String(localized: "Korean"),
                 revision: "5c6f574b8e2230adf4287b33e736d71b9fabd28e",
                 model: ("92f0b7785e64fc9090106a241cf4c1eb97472824558272751b88a2a4476d3a08", 13_418_787),
                 dictionary: ("f757fa1c40e99edcf27e9cce879b93eb2a51fa46f5ef39095689b8c37dd75998", 96_039)),
        Language(code: "cyrillic", name: String(localized: "Cyrillic"),
                 revision: "2cef88145434beb8afa9dd82d77d799eb1ad7b29",
                 model: ("5371ee1ddaa7983cc62d0818d99e982b6804638c85e4f960d59a574094e172e5", 8_048_799),
                 dictionary: ("5c76cc91fa98410178a09f498db10050d0ec1634a660053d3005ab7be581f501", 6_991)),
        Language(code: "eslav", name: String(localized: "East Slavic"),
                 revision: "9a32171fc5718746875e1a261818884517975013",
                 model: ("b3018ef2b09a0250b6e0c8e871c927098363e5fd4df890cc68e8358eb0aaf1bd", 7_887_627),
                 dictionary: ("025039bac23eb4a308efcefa4d58eab3af440767815c6ba6938468bf6353ee5a", 4_538)),
        Language(code: "arabic", name: String(localized: "Arabic"),
                 revision: "14aaedcd75825982689ecf5cd64ab33ee083215a",
                 model: ("799113ebf267fbe742deb99eb36e8d42c9ddc5291ceacf92add41b4d52a59110", 7_998_947),
                 dictionary: ("21368419e6c016c31db55d316d59e11c128e1913e6e6fe10287084710043d3a6", 6_165)),
        Language(code: "devanagari", name: String(localized: "Devanagari"),
                 revision: "251aec19e36739540d35e2cc943f6aa7503b98e5",
                 model: ("cb789212ce96c69d3e74728ae4309d179281d68cb3945d0616b67cafab41c986", 7_912_311),
                 dictionary: ("9bd172dd26440c8ce94d1cde5d5baea6aefdc7cf3c5c8492e0beedef656d4e54", 5_027)),
        Language(code: "el", name: String(localized: "Greek"),
                 revision: "8152b89d2ee0e1d4c92decab75fe75e5e3d836b6",
                 model: ("2acf17fcaea2bc81b878e311e6263b8885f48bb03796f75f9f30ed3242bbaa6d", 7_808_735),
                 dictionary: ("17d85b2fe2d2f24cd4ab07bcbc33e0c126859b956ced36e281dc65e2d0c1f0bf", 3_317)),
        Language(code: "ta", name: String(localized: "Tamil"),
                 revision: "0db89798af0d5218fad9ea7ace0557526e9077f1",
                 model: ("c6d2b682d2a0ea4cb1fccdba295976f93fd439964d16cdc666cadef531accbee", 7_885_691),
                 dictionary: ("88a28f5a1bb30cabe38a0985cb5e6619fa4f0c7c78e57a08274674228c5219a6", 4_579)),
        Language(code: "te", name: String(localized: "Telugu"),
                 revision: "f1197c83430241c58c64b0952b3a80366d04eeba",
                 model: ("8238bfc46d4cffe720ed6706e3842802467343497428693ff2bfb4e6b3caa36b", 7_898_759),
                 dictionary: ("acebbe53f1831bf28ddfed75aedf58225d7aa5d09100c1d5a9140a2a53b137ce", 4_795)),
        Language(code: "th", name: String(localized: "Thai"),
                 revision: "1d4adbbafb1034a2fd6618498575b81ea7b69f69",
                 model: ("27618be66018f8598ac0a526a593f9f1cebf794e7eded93428e8fb016e537f5f", 7_891_015),
                 dictionary: ("f6ba7fefc38ca1ff398ddafa75d67d16e0b3757c4e6c833adffee98a981766c9", 4_667)),
    ]

    static let languageRecognizers: [Entry] = languages.map { language in
        let repo = "\(language.code)_PP-OCRv5_mobile_rec_onnx"
        let model = "\(language.code)_PP-OCRv5_mobile_rec.onnx"
        return Entry(
            id: "lang.\(language.code)",
            name: language.name,
            purpose: language.name,
            detail: String(localized: "PP-OCRv5 single-language recognizer, used with the PP-OCRv6 detector"),
            assets: [
                Asset(repo: repo, revision: language.revision, remoteFile: "inference.onnx",
                      sha256: language.model.sha256, size: language.model.size,
                      localName: model),
                Asset(repo: repo, revision: language.revision, remoteFile: "inference.yml",
                      sha256: language.dictionary.sha256, size: language.dictionary.size,
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
        purpose: String(localized: "Layout analysis"),
        detail: String(localized: "The first stage of PaddleOCR-VL: splits the layout and decides the reading order. Required for the VL engine"),
        assets: [
            Asset(repo: "PP-DocLayoutV3_onnx",
                  revision: "46bbdf188bb0a772c08aed74882ce7e51a8f1ea6",
                  remoteFile: "inference.onnx",
                  sha256: "45bf71750b00739a41fc209f132eb104a4d6b5bb29483c9078164d8b87cf28ba",
                  size: 130_502_049,
                  localName: VLModelStore.layoutModelFileName),
        ])

    static let vlOfficial = Entry(
        id: "vl.official",
        name: String(localized: "PaddleOCR-VL-1.6 (official F16)"),
        purpose: String(localized: "Tables, formulas and charts (full size)"),
        detail: String(localized: "Official PaddlePaddle weights, the accuracy reference. Two files: the text model and the vision encoder"),
        assets: [
            Asset(repo: "PaddleOCR-VL-1.6-GGUF",
                  revision: "511b09642bb324401f15f97cc23bc67e8f0a291d",
                  remoteFile: "PaddleOCR-VL-1.6-GGUF.gguf",
                  sha256: "f3ae46ec885050acf4b3d31944431e1fd90d50664fb09126af4a3c050ba14ee8",
                  size: 935_769_056,
                  localName: VLModelVariant.official.modelFileName),
            Asset(repo: "PaddleOCR-VL-1.6-GGUF",
                  revision: "511b09642bb324401f15f97cc23bc67e8f0a291d",
                  remoteFile: "PaddleOCR-VL-1.6-GGUF-mmproj.gguf",
                  sha256: "204d757d7610d9b3faab10d506d69e5b244e32bf765e2bab2d0167e65e0a058a",
                  size: 881_770_560,
                  localName: VLModelVariant.official.mmprojFileName),
        ])

    static let vlQuantized = Entry(
        id: "vl.quantized",
        name: String(localized: "PaddleOCR-VL-1.6 (Q4 quantized)"),
        purpose: String(localized: "Tables, formulas and charts (compact)"),
        detail: String(localized: "Community quantization, about half the size of the official weights and faster to load. The vision encoder is quantized too, so accuracy may drop slightly"),
        assets: [
            Asset(repo: "PaddleOCR-VL-1.6-GGUF-Q4", owner: "LunarOilRig",
                  revision: "6a772c793f22e0a9e7d8fabd3229431be024569d",
                  remoteFile: "PaddleOCR-VL-1.6-Q4_K_M.gguf",
                  sha256: "d79bfabcb904eaf078f1f8a9a4bfd865f0ad6cda17b6441df7ce4bdf641a2651",
                  size: 300_219_360,
                  localName: VLModelVariant.quantized.modelFileName),
            Asset(repo: "PaddleOCR-VL-1.6-GGUF-Q4", owner: "LunarOilRig",
                  revision: "6a772c793f22e0a9e7d8fabd3229431be024569d",
                  remoteFile: "mmproj-Q8_0.gguf",
                  sha256: "cc4e8e42afe3b45e40168eb4769aad8b491c5fb7aaca937d8e9746f5f0e6f425",
                  size: 597_565_600,
                  localName: VLModelVariant.quantized.mmprojFileName),
        ])

    /// UVDoc, the page-flattening stage. Small enough to install in seconds,
    /// and only useful for photographs of pages rather than scans, so it is
    /// downloaded on demand rather than shipped.
    static let unwarpingModel = Entry(
        id: "pp.unwarp",
        name: String(localized: "UVDoc page unwarping"),
        purpose: String(localized: "Page flattening"),
        detail: String(localized: "Flattens skewed, curled or folded pages before recognition; not needed for scans"),
        assets: [
            Asset(repo: "UVDoc_onnx",
                  revision: "3bcf535371727d11e783101f79a504c68848aae3",
                  remoteFile: "inference.onnx",
                  sha256: "54cab30dc2cf347b4f3d6971c833b1c3d84f5ef17280f1f6d15796bff20e63d6",
                  size: 31_684_150,
                  localName: PPModelStore.unwarpingModelFileName),
        ])

    /// A small file used only to check whether a source answers at all.
    /// `inference.yml` is a few kilobytes, and every mirror carries it.
    static let probeAsset = Asset(repo: "korean_PP-OCRv5_mobile_rec_onnx",
                                  revision: "5c6f574b8e2230adf4287b33e736d71b9fabd28e",
                                  remoteFile: "inference.yml",
                                  sha256: "f757fa1c40e99edcf27e9cce879b93eb2a51fa46f5ef39095689b8c37dd75998",
                                  size: 96_039,
                                  localName: "probe.yml", kind: .dictionary)

    static var vlEntries: [Entry] { [layoutModel, vlQuantized, vlOfficial] }

    static var allEntries: [Entry] {
        [mediumTier, unwarpingModel] + vlEntries + languageRecognizers
    }
}
