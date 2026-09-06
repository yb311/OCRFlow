import Foundation

/// PP-LCNet textline orientation classifier: decides whether a cropped line is
/// upright or rotated by 180°.
///
/// PaddleOCR runs this between detection and recognition because the CTC
/// recogniser has no way to read upside-down text; a flipped line would
/// otherwise come back as confident nonsense.
struct PPTextLineClassifier {
    let session: PPSession

    /// Fixed input geometry of the classifier (`ResizeImage: [160, 80]`).
    private static let inputWidth = 160
    private static let inputHeight = 80
    private static let mean: (Float, Float, Float) = (0.485, 0.456, 0.406)
    private static let std: (Float, Float, Float) = (0.229, 0.224, 0.225)

    /// Rotates any crop the model reports as upside down, above `clsThresh`.
    func correctOrientation(_ crops: [PPImageBuffer], config: PPOCRConfig) throws
        -> (crops: [PPImageBuffer], rotated: [Bool]) {

        var result = crops
        var rotated = [Bool](repeating: false, count: crops.count)
        let plane = 3 * Self.inputHeight * Self.inputWidth
        let batchSize = max(1, config.clsBatchSize)

        var start = 0
        while start < crops.count {
            let end = min(start + batchSize, crops.count)
            let count = end - start
            var tensor = [Float](repeating: 0, count: count * plane)
            for i in start..<end {
                let scaled = crops[i].resized(toWidth: Self.inputWidth, height: Self.inputHeight)
                scaled.writeNormalizedCHW(into: &tensor, offset: (i - start) * plane,
                                          mean: Self.mean, std: Self.std)
            }

            let (values, shape) = try session.run(
                input: tensor, shape: [count, 3, Self.inputHeight, Self.inputWidth])
            guard shape.count == 2, shape[0] == count, shape[1] == 2 else {
                throw PPOCRError.unexpectedOutputShape("方向分类模型输出维度 \(shape)")
            }

            for i in 0..<count {
                let a = values[i * 2], b = values[i * 2 + 1]
                // Softmax over two logits reduces to a logistic on their difference.
                let pFlipped = Double(1 / (1 + exp(a - b)))
                if pFlipped > 0.5, pFlipped > config.clsThresh {
                    result[start + i] = crops[start + i].rotated180()
                    rotated[start + i] = true
                }
            }
            start = end
        }
        return (result, rotated)
    }
}
