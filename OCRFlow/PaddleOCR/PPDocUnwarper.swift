import Foundation
import CoreGraphics

/// UVDoc: flattens a photographed page that is curled, folded or held.
///
/// PaddleOCR calls this 图片扭曲矫正 and runs it before anything else, for the
/// same reason it straightens a rotated scan: detection and recognition both
/// assume text runs in straight lines, and on a page photographed in someone's
/// hand it does not.
///
/// The network predicts a sampling grid and applies it to the image itself —
/// the graph ends in `GridSample` — so what comes back is the rectified page,
/// not a transform to apply. That is also why the boxes found afterwards belong
/// to the rectified page and not the original, and why the preview has to show
/// the rectified page for them to line up.
struct PPDocUnwarper {
    let session: PPSession

    /// Long side the page is scaled to before rectification.
    ///
    /// The grid is predicted from a downscaled view of the page no matter what
    /// is fed in, and the sampling then runs at the size it was given. Keeping
    /// that size bounded stops a 12-megapixel phone photo from turning into a
    /// hundred megabytes of float tensors for no gain in the grid's accuracy.
    static let maximumSide = 2048

    func rectify(_ image: PPImageBuffer) throws -> PPImageBuffer {
        let source = Self.bounded(image)
        let width = source.width, height = source.height
        let plane = width * height

        // RGB, scaled to 0…1 and nothing else: UVDoc has no mean/std step.
        var tensor = [Float](repeating: 0, count: 3 * plane)
        source.pixels.withUnsafeBufferPointer { src in
            tensor.withUnsafeMutableBufferPointer { dst in
                for i in 0..<plane {
                    dst[i]             = Float(src[i * 3 + 2]) / 255
                    dst[plane + i]     = Float(src[i * 3 + 1]) / 255
                    dst[2 * plane + i] = Float(src[i * 3])     / 255
                }
            }
        }

        let (values, shape) = try session.run(input: tensor, shape: [1, 3, height, width])
        guard shape.count == 4, shape[1] == 3 else {
            throw PPOCRError.unexpectedOutputShape("扭曲矫正模型输出维度 \(shape)")
        }
        let outHeight = shape[2], outWidth = shape[3]
        let outPlane = outHeight * outWidth
        guard values.count >= 3 * outPlane else {
            throw PPOCRError.unexpectedOutputShape("扭曲矫正模型输出数据不足")
        }

        var bgr = [UInt8](repeating: 0, count: outPlane * 3)
        values.withUnsafeBufferPointer { src in
            bgr.withUnsafeMutableBufferPointer { dst in
                for i in 0..<outPlane {
                    dst[i * 3]     = Self.byte(src[2 * outPlane + i])
                    dst[i * 3 + 1] = Self.byte(src[outPlane + i])
                    dst[i * 3 + 2] = Self.byte(src[i])
                }
            }
        }
        return PPImageBuffer(width: outWidth, height: outHeight, pixels: bgr)
    }

    private static func byte(_ value: Float) -> UInt8 {
        UInt8(min(max(value * 255, 0), 255))
    }

    private static func bounded(_ image: PPImageBuffer) -> PPImageBuffer {
        let longest = max(image.width, image.height)
        guard longest > maximumSide else { return image }
        let scale = Double(maximumSide) / Double(longest)
        return image.resized(toWidth: max(1, Int(Double(image.width) * scale)),
                             height: max(1, Int(Double(image.height) * scale)))
    }
}
