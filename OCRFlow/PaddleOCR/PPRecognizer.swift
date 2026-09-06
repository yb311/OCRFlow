import Foundation

/// CTC text recogniser (PP-OCRv6 rec) with PaddleOCR's aspect-ratio batching.
struct PPRecognizer {
    let session: PPSession
    /// Index 0 is the CTC blank, then the dictionary, then the space character —
    /// the layout `CTCLabelDecode` builds from `character_dict`.
    let charset: [String]

    init(session: PPSession, dictionaryURL: URL) throws {
        self.session = session
        guard let raw = try? String(contentsOf: dictionaryURL, encoding: .utf8) else {
            throw PPOCRError.dictionaryMissing
        }
        var characters = raw.components(separatedBy: "\n")
        if characters.last == "" { characters.removeLast() }
        guard !characters.isEmpty else { throw PPOCRError.dictionaryMissing }
        self.charset = ["<blank>"] + characters + [" "]
    }

    struct Result {
        var text: String
        var confidence: Double
    }

    func recognize(_ crops: [PPImageBuffer], config: PPOCRConfig) throws -> [Result] {
        guard !crops.isEmpty else { return [] }
        var results = [Result](repeating: Result(text: "", confidence: 0), count: crops.count)

        let imgH = max(1, config.recImageHeight)
        let baseW = max(1, config.recImageWidth)
        let batchSize = max(1, config.recBatchSize)

        // Grouping similar aspect ratios keeps the zero padding — and therefore
        // the wasted compute — small within each batch.
        let order = crops.indices.sorted {
            let a = Double(crops[$0].width) / Double(max(crops[$0].height, 1))
            let b = Double(crops[$1].width) / Double(max(crops[$1].height, 1))
            return a < b
        }

        var start = 0
        while start < order.count {
            let end = min(start + batchSize, order.count)
            let slice = Array(order[start..<end])

            var maxRatio = Double(baseW) / Double(imgH)
            for i in slice {
                maxRatio = max(maxRatio, Double(crops[i].width) / Double(max(crops[i].height, 1)))
            }
            let batchW = max(1, Int(Double(imgH) * maxRatio))
            let plane = 3 * imgH * batchW
            var tensor = [Float](repeating: 0, count: slice.count * plane)

            for (slot, i) in slice.enumerated() {
                let crop = crops[i]
                let ratio = Double(crop.width) / Double(max(crop.height, 1))
                let wanted = Int(ceil(Double(imgH) * ratio))
                let targetW = wanted > batchW ? batchW : max(1, wanted)
                let scaled = crop.resized(toWidth: targetW, height: imgH)
                // (x / 255 - 0.5) / 0.5, i.e. the recogniser's own normalisation
                // rather than the ImageNet statistics used by det and cls.
                scaled.writeNormalizedCHW(into: &tensor, offset: slot * plane,
                                          mean: (0.5, 0.5, 0.5), std: (0.5, 0.5, 0.5),
                                          padTo: batchW, padHeight: imgH)
            }

            let (values, shape) = try session.run(
                input: tensor, shape: [slice.count, 3, imgH, batchW])
            guard shape.count == 3, shape[0] == slice.count else {
                throw PPOCRError.unexpectedOutputShape("识别模型输出维度 \(shape)")
            }
            let steps = shape[1], classes = shape[2]
            // A recogniser and a dictionary from different releases decode into
            // plausible-looking gibberish rather than failing, so refuse the
            // pairing outright the first time the shape is known.
            guard classes == charset.count else {
                throw PPOCRError.charsetMismatch(expected: charset.count, actual: classes)
            }

            for (slot, i) in slice.enumerated() {
                results[i] = Self.ctcDecode(values, base: slot * steps * classes,
                                            steps: steps, classes: classes, charset: charset)
            }
            start = end
        }
        return results
    }

    /// Greedy CTC decoding: take the arg-max per timestep, collapse repeats,
    /// drop blanks, and average the kept probabilities into a confidence.
    static func ctcDecode(_ values: [Float], base: Int, steps: Int, classes: Int,
                          charset: [String]) -> Result {
        var text = ""
        var probSum: Double = 0
        var kept = 0
        var previous = -1

        for t in 0..<steps {
            let row = base + t * classes
            var best = 0
            var bestValue = values[row]
            for c in 1..<classes where values[row + c] > bestValue {
                bestValue = values[row + c]
                best = c
            }
            defer { previous = best }
            guard best != 0, best != previous else { continue }
            if best < charset.count { text += charset[best] }
            probSum += Double(bestValue)
            kept += 1
        }
        return Result(text: text, confidence: kept > 0 ? probSum / Double(kept) : 0)
    }
}
