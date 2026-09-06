import Foundation
import CoreGraphics

/// PP-DocLayoutV3: finds the blocks that make up a page and, in the same
/// forward pass, the order they should be read in.
///
/// This is the first stage of PaddleOCR-VL. The official docs are explicit that
/// the VLM alone is not the whole story — "to fully leverage the capabilities of
/// PaddleOCR-VL, it is necessary to adopt the complete pipeline that integrates
/// layout analysis and VLM-based recognition" — because feeding a whole page to
/// the VLM in one shot silently drops content.
struct PPLayoutDetector {
    let session: PPSession

    /// The exported graph has a fixed 800×800 input; `keep_ratio` is false in
    /// the model's `inference.yml`, so the page is stretched, not letterboxed.
    static let inputSide = 800

    /// PaddleDetection's own default, from `draw_threshold` in `inference.yml`.
    static let defaultScoreThreshold = 0.5

    func detect(_ image: PPImageBuffer, scoreThreshold: Double = defaultScoreThreshold) throws -> [PPLayoutBlock] {
        let side = Self.inputSide
        let resized = image.resized(toWidth: side, height: side)

        // PaddleDetection's deploy preprocessing, which differs from PP-OCR's:
        // the image is decoded to RGB (not BGR) and only scaled by 1/255 —
        // `norm_type: none` means no mean/std normalisation at all.
        var tensor = [Float](repeating: 0, count: 3 * side * side)
        let plane = side * side
        resized.pixels.withUnsafeBufferPointer { src in
            tensor.withUnsafeMutableBufferPointer { dst in
                for i in 0..<plane {
                    // PPImageBuffer stores BGR; the layout model wants RGB.
                    dst[i]             = Float(src[i * 3 + 2]) / 255
                    dst[plane + i]     = Float(src[i * 3 + 1]) / 255
                    dst[2 * plane + i] = Float(src[i * 3    ]) / 255
                }
            }
        }

        // `scale_factor` is resized ÷ original, which is what the graph's own
        // post-processing divides by to hand boxes back in source coordinates.
        let scaleY = Float(side) / Float(max(image.height, 1))
        let scaleX = Float(side) / Float(max(image.width, 1))

        // Only the detections are wanted. The graph also emits a
        // [queries, 200, 200] instance-mask tensor — 48 MB per page — that V3
        // uses for multi-point boxes on curved scans; we crop rectangles, so
        // asking for it would just pay for a large copy we throw away.
        let outputs = try session.run(
            inputs: [
                "image":        .float(tensor, shape: [1, 3, side, side]),
                "scale_factor": .float([scaleY, scaleX], shape: [1, 2]),
                "im_shape":     .float([Float(side), Float(side)], shape: [1, 2]),
            ],
            outputNames: ["fetch_name_0"])

        return try decode(outputs, scoreThreshold: scoreThreshold,
                          width: CGFloat(image.width), height: CGFloat(image.height))
    }

    // MARK: - Output decoding

    /// Decodes `[queries, 7]` rows of `[class, score, x1, y1, x2, y2, order]`.
    ///
    /// The first six columns are PaddleDetection's usual layout. The seventh is
    /// PP-DocLayoutV3's reading-order key: it is not a dense rank but a
    /// position on the query axis, so it is only meaningful as a sort key.
    /// Verified against PaddleOCR's own published output for the reference
    /// page, where sorting on it reproduces the documented reading order —
    /// including placing a figure's caption directly after the figure, which
    /// no purely geometric ordering gets right.
    private func decode(_ outputs: [String: PPTensor], scoreThreshold: Double,
                        width: CGFloat, height: CGFloat) throws -> [PPLayoutBlock] {
        guard let detections = outputs["fetch_name_0"]?.floats else {
            throw PPOCRError.unexpectedOutputShape("版面模型未返回检测结果")
        }
        let stride = 7
        let page = CGRect(x: 0, y: 0, width: width, height: height)

        var blocks: [PPLayoutBlock] = []
        var orderKeys: [Float] = []
        for i in 0..<(detections.count / stride) {
            let row = i * stride
            let score = Double(detections[row + 1])
            guard score >= scoreThreshold else { continue }
            guard let label = PPLayoutLabel(rawValue: Int(detections[row])) else { continue }

            let x1 = CGFloat(detections[row + 2]), y1 = CGFloat(detections[row + 3])
            let x2 = CGFloat(detections[row + 4]), y2 = CGFloat(detections[row + 5])
            let rect = CGRect(x: min(x1, x2), y: min(y1, y2),
                              width: abs(x2 - x1), height: abs(y2 - y1)).intersection(page)
            guard !rect.isNull, rect.width > 1, rect.height > 1 else { continue }

            blocks.append(PPLayoutBlock(rect: rect, label: label, score: score))
            orderKeys.append(detections[row + 6])
        }

        return PPReadingOrder.sort(blocks, modelKeys: orderKeys)
    }
}
