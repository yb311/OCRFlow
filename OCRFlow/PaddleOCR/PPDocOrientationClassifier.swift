import Foundation
import CoreGraphics

/// PP-LCNet document orientation classifier: detects a page that has been
/// scanned or photographed at 90°, 180° or 270° and reports how to undo it.
///
/// PP-OCR's detector is trained on upright text and collapses on a rotated
/// page — a 180°-flipped newspaper drops from ~140 detected lines to ~16 — so
/// straightening the whole image first is what makes those pages readable at
/// all. The per-line classifier cannot substitute: it only sees crops that
/// detection already found.
struct PPDocOrientationClassifier {
    let session: PPSession

    /// `ResizeImage(resize_short: 256)` then `CropImage(size: 224)`.
    private static let resizeShort = 256
    private static let cropSize = 224
    private static let mean: (Float, Float, Float) = (0.485, 0.456, 0.406)
    private static let std: (Float, Float, Float) = (0.229, 0.224, 0.225)

    /// Clockwise rotation the model believes was applied to the page.
    enum Orientation: Int {
        case upright = 0, cw90 = 1, cw180 = 2, cw270 = 3
    }

    func classify(_ image: PPImageBuffer) throws -> Orientation {
        let shortSide = min(image.width, image.height)
        guard shortSide > 0 else { return .upright }
        let scale = Double(Self.resizeShort) / Double(shortSide)
        let scaled = image.resized(toWidth: Int((Double(image.width) * scale).rounded()),
                                   height: Int((Double(image.height) * scale).rounded()))
        let crop = scaled.centerCropped(to: Self.cropSize)

        var tensor = [Float](repeating: 0, count: 3 * Self.cropSize * Self.cropSize)
        crop.writeNormalizedCHW(into: &tensor, offset: 0, mean: Self.mean, std: Self.std,
                                padTo: Self.cropSize, padHeight: Self.cropSize)

        let (values, shape) = try session.run(
            input: tensor, shape: [1, 3, Self.cropSize, Self.cropSize])
        guard shape.count == 2, shape[1] == 4, values.count >= 4 else {
            throw PPOCRError.unexpectedOutputShape("文档方向模型输出维度 \(shape)")
        }
        var best = 0
        for i in 1..<4 where values[i] > values[best] { best = i }
        return Orientation(rawValue: best) ?? .upright
    }

    /// Counter-rotates the image so the text ends up upright.
    static func straighten(_ image: PPImageBuffer, from orientation: Orientation) -> PPImageBuffer {
        switch orientation {
        case .upright: return image
        case .cw90:    return image.rotated90CCW()
        case .cw180:   return image.rotated180()
        case .cw270:   return image.rotated90CW()
        }
    }

    /// Maps a point in the straightened image back to the original image, so
    /// detected boxes stay aligned with the picture the user is looking at.
    static func mapBack(_ p: CGPoint, orientation: Orientation,
                        originalWidth w: Int, originalHeight h: Int) -> CGPoint {
        switch orientation {
        case .upright:
            return p
        case .cw90:
            // Straightened = original rotated CCW: (x, y) -> (y, W-1-x) reversed.
            return CGPoint(x: CGFloat(w - 1) - p.y, y: p.x)
        case .cw180:
            return CGPoint(x: CGFloat(w - 1) - p.x, y: CGFloat(h - 1) - p.y)
        case .cw270:
            return CGPoint(x: p.y, y: CGFloat(h - 1) - p.x)
        }
    }
}
