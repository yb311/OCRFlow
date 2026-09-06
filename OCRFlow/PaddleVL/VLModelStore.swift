import Foundation

/// Locates the PaddleOCR-VL weights and the layout model backing them.
///
/// None of this ships inside the app — the smallest usable pair is about a
/// gigabyte — so everything here lives in the user models folder and arrives
/// through the model manager.
enum VLModelStore {

    struct Paths {
        var model: URL
        var mmproj: URL
    }

    static let layoutModelFileName = "PP-DocLayoutV3.onnx"

    static func resolve(variant: VLModelVariant) throws -> Paths {
        var missing: [String] = []
        let model = PPModelStore.existingUserFile(variant.modelFileName)
        if model == nil { missing.append(variant.modelFileName) }
        let mmproj = PPModelStore.existingUserFile(variant.mmprojFileName)
        if mmproj == nil { missing.append(variant.mmprojFileName) }

        guard let model, let mmproj else {
            throw VLError.modelsMissing(variant: variant, missing: missing,
                                        searchPath: PPModelStore.userModelsDirectory.path)
        }
        return Paths(model: model, mmproj: mmproj)
    }

    /// The layout stage is what makes this the full PaddleOCR-VL pipeline
    /// rather than the VLM on its own, so it is required unless the user has
    /// explicitly turned layout analysis off.
    static func resolveLayoutModel() throws -> URL {
        guard let url = PPModelStore.existingUserFile(layoutModelFileName) else {
            throw VLError.layoutModelMissing(searchPath: PPModelStore.userModelsDirectory.path)
        }
        return url
    }

    static func isInstalled(_ variant: VLModelVariant) -> Bool {
        (try? resolve(variant: variant)) != nil
    }

    static var isLayoutModelInstalled: Bool {
        PPModelStore.isDownloaded(layoutModelFileName)
    }

    /// True when the engine can run end to end with the given configuration.
    static func isReady(for config: VLConfig) -> Bool {
        isInstalled(config.variant) && (!config.useLayoutDetection || isLayoutModelInstalled)
    }
}
