import Foundation
import CoreGraphics

/// A tightly packed RGB8 buffer, the layout `mtmd_bitmap_init` expects.
///
/// `PPImageBuffer` cannot be reused here: it stores BGR because that is what
/// PaddleOCR's own preprocessing assumes, and handing those bytes to mtmd would
/// swap every red and blue channel — which a text model tolerates just well
/// enough to produce subtly worse results instead of an obvious failure.
struct VLImageBuffer {
    let width: Int
    let height: Int
    /// `width * height * 3` bytes, row-major, R then G then B per pixel.
    let pixels: [UInt8]

    init?(cgImage: CGImage, cropping rect: CGRect? = nil) {
        let source: CGImage
        if let rect {
            let clamped = rect.integral.intersection(
                CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
            guard !clamped.isNull, clamped.width >= 1, clamped.height >= 1,
                  let cropped = cgImage.cropping(to: clamped) else { return nil }
            source = cropped
        } else {
            source = cgImage
        }

        let w = source.width, h = source.height
        guard w > 0, h > 0 else { return nil }

        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let drew: Bool = rgba.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(
                data: raw.baseAddress,
                width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            // Paint white first: a transparent PNG would otherwise composite
            // onto black and lose dark text entirely.
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.draw(source, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drew else { return nil }

        var rgb = [UInt8](repeating: 0, count: w * h * 3)
        rgba.withUnsafeBufferPointer { src in
            rgb.withUnsafeMutableBufferPointer { dst in
                for i in 0..<(w * h) {
                    dst[i * 3]     = src[i * 4]
                    dst[i * 3 + 1] = src[i * 4 + 1]
                    dst[i * 3 + 2] = src[i * 4 + 2]
                }
            }
        }

        self.width = w
        self.height = h
        self.pixels = rgb
    }
}
