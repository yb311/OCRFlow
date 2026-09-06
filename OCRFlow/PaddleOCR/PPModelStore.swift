import Foundation

/// Locates the ONNX files and character dictionary backing the pipeline.
///
/// The `tiny` and `small` PP-OCRv6 models ship inside the app so a fresh
/// install works offline. Anything placed in the user models folder wins over
/// the bundled copy, which is how `medium` — and the PP-OCRv5 single-language
/// recognisers for the scripts v6 does not cover — get installed.
enum PPModelStore {

    struct Paths {
        var detModel: URL
        var recModel: URL
        var clsModel: URL
        var docOriModel: URL
        var dictionary: URL
    }

    /// `~/Library/Application Support/OCRFlow/Models`
    static var userModelsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("OCRFlow/Models", isDirectory: true)
    }

    static func ensureUserModelsDirectory() {
        try? FileManager.default.createDirectory(at: userModelsDirectory,
                                                 withIntermediateDirectories: true)
    }

    /// Bundled resources live in a `PaddleOCR` folder reference.
    private static func bundled(_ fileName: String) -> URL? {
        let name = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        return Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "PaddleOCR")
            ?? Bundle.main.url(forResource: name, withExtension: ext)
    }

    static func existingUserFile(_ name: String) -> URL? {
        let url = userModelsDirectory.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// User folder first, then the app bundle. `medium` has no bundled copy.
    private static func locate(_ fileName: String, bundledFallback: Bool) -> URL? {
        existingUserFile(fileName) ?? (bundledFallback ? bundled(fileName) : nil)
    }

    static func resolve(tier: PPModelTier, recognizer: PPRecognizerChoice) throws -> Paths {
        var missing: [String] = []

        let det = locate(tier.detFileName, bundledFallback: tier.isBundled)
        if det == nil { missing.append(tier.detFileName) }

        // A custom recogniser lives only in the user folder and brings its own
        // charset; the built-in one follows the tier.
        let recName = recognizer.customFileName ?? tier.recFileName
        let rec = recognizer.customFileName == nil
            ? locate(tier.recFileName, bundledFallback: tier.isBundled)
            : existingUserFile(recName)
        if rec == nil { missing.append(recName) }

        // The orientation classifiers are shared by every tier.
        let cls = locate("PP-LCNet_x0_25_textline_ori.onnx", bundledFallback: true)
        if cls == nil { missing.append("PP-LCNet_x0_25_textline_ori.onnx") }

        let docOri = locate("PP-LCNet_x1_0_doc_ori.onnx", bundledFallback: true)
        if docOri == nil { missing.append("PP-LCNet_x1_0_doc_ori.onnx") }

        guard missing.isEmpty, let det, let rec, let cls, let docOri else {
            throw PPOCRError.modelsMissing(tier: tier, missing: missing,
                                           searchPath: userModelsDirectory.path)
        }

        guard let dict = dictionary(forRecogniser: rec, tier: tier, isCustom: recognizer.customFileName != nil) else {
            throw PPOCRError.dictionaryMissing
        }

        return Paths(detModel: det, recModel: rec, clsModel: cls,
                     docOriModel: docOri, dictionary: dict)
    }

    /// A dictionary sitting next to a recogniser wins: a model dropped in by
    /// the user brings its own charset, and mixing the two produces gibberish.
    private static func dictionary(forRecogniser rec: URL, tier: PPModelTier, isCustom: Bool) -> URL? {
        let sidecar = "\(rec.deletingPathExtension().lastPathComponent)_dict.txt"
        if let url = existingUserFile(sidecar) { return url }
        if isCustom { return nil }
        return locate(tier.dictionaryFileName, bundledFallback: true)
    }

    // MARK: - Inventory, for the model manager

    /// True when the tier can be used right now, with the built-in recogniser.
    static func isInstalled(_ tier: PPModelTier) -> Bool {
        (try? resolve(tier: tier, recognizer: .builtin)) != nil
    }

    /// True when the file is present in the user models folder.
    static func isDownloaded(_ fileName: String) -> Bool {
        existingUserFile(fileName) != nil
    }

    struct InstalledRecognizer: Identifiable, Hashable {
        var fileName: String
        var id: String { fileName }

        /// `korean_PP-OCRv5_mobile_rec.onnx` → `korean_PP-OCRv5_mobile_rec`
        var displayName: String { (fileName as NSString).deletingPathExtension }
    }

    /// Recognisers the user installed, excluding the ones the app ships.
    static func installedCustomRecognizers() -> [InstalledRecognizer] {
        let builtin = Set(PPModelTier.allCases.map(\.recFileName))
        let names = (try? FileManager.default.contentsOfDirectory(atPath: userModelsDirectory.path)) ?? []
        return names
            .filter { $0.hasSuffix("_rec.onnx") && !builtin.contains($0) }
            .sorted()
            .map { InstalledRecognizer(fileName: $0) }
    }
}
