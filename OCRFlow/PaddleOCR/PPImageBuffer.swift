import Foundation
import CoreGraphics

/// A tightly packed 8-bit BGR image.
///
/// PaddleOCR's reference pipeline reads images with OpenCV, so every model in
/// the chain was calibrated on **BGR** input with the channel-wise statistics
/// applied in that order. Keeping the same layout here means the preprocessing
/// constants can be used verbatim.
final class PPImageBuffer {
    let width: Int
    let height: Int
    /// `height * width * 3` bytes, B, G, R interleaved.
    private(set) var pixels: [UInt8]

    private static let bytesPerPixel = 3

    init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    // MARK: - Bridging from Core Graphics

    /// Renders a `CGImage` onto an opaque white background and converts to BGR.
    ///
    /// Compositing rather than dropping the alpha channel keeps transparent
    /// PNGs (screenshots, exported diagrams) legible instead of turning their
    /// unpainted areas into whatever noise happens to sit in the colour
    /// channels.
    convenience init?(cgImage: CGImage) {
        let w = cgImage.width, h = cgImage.height
        guard w > 0, h > 0 else { return nil }

        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let ok: Bool = rgba.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(
                data: raw.baseAddress,
                width: w, height: h,
                bitsPerComponent: 8,
                bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
            return true
        }
        guard ok else { return nil }

        var bgr = [UInt8](repeating: 0, count: w * h * 3)
        rgba.withUnsafeBufferPointer { src in
            bgr.withUnsafeMutableBufferPointer { dst in
                for i in 0..<(w * h) {
                    dst[i * 3 + 0] = src[i * 4 + 2]   // B
                    dst[i * 3 + 1] = src[i * 4 + 1]   // G
                    dst[i * 3 + 2] = src[i * 4 + 0]   // R
                }
            }
        }
        self.init(width: w, height: h, pixels: bgr)
    }

    // MARK: - Sampling

    @inline(__always)
    private func clampX(_ v: Int) -> Int { v < 0 ? 0 : (v >= width ? width - 1 : v) }

    @inline(__always)
    private func clampY(_ v: Int) -> Int { v < 0 ? 0 : (v >= height ? height - 1 : v) }

    // MARK: - Resize

    /// Bilinear resize matching `cv2.resize(..., INTER_LINEAR)`.
    ///
    /// The half-pixel centre convention (`src = (dst + 0.5) * scale - 0.5`) is
    /// what OpenCV uses; sampling at `dst * scale` instead would shift the
    /// image by up to half a pixel and measurably move the detector's output.
    /// The buffer as an image again, for the rectified page the preview shows.
    var cgImage: CGImage? {
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        pixels.withUnsafeBufferPointer { src in
            rgba.withUnsafeMutableBufferPointer { dst in
                for i in 0..<(width * height) {
                    dst[i * 4]     = src[i * 3 + 2]
                    dst[i * 4 + 1] = src[i * 3 + 1]
                    dst[i * 4 + 2] = src[i * 3]
                }
            }
        }
        return rgba.withUnsafeMutableBytes { raw -> CGImage? in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return nil }
            return ctx.makeImage()
        }
    }

    func resized(toWidth newW: Int, height newH: Int) -> PPImageBuffer {
        let newW = max(1, newW), newH = max(1, newH)
        if newW == width && newH == height { return PPImageBuffer(width: width, height: height, pixels: pixels) }

        var out = [UInt8](repeating: 0, count: newW * newH * 3)
        let scaleX = Double(width) / Double(newW)
        let scaleY = Double(height) / Double(newH)

        // Precompute the horizontal taps once; they repeat for every row.
        var x0s = [Int](repeating: 0, count: newW)
        var x1s = [Int](repeating: 0, count: newW)
        var fxs = [Double](repeating: 0, count: newW)
        for dx in 0..<newW {
            let sx = (Double(dx) + 0.5) * scaleX - 0.5
            var x0 = Int(sx.rounded(.down))
            var fx = sx - Double(x0)
            if x0 < 0 { x0 = 0; fx = 0 }
            if x0 >= width - 1 { x0 = max(0, width - 1); fx = 0 }
            x0s[dx] = x0
            x1s[dx] = min(x0 + 1, width - 1)
            fxs[dx] = fx
        }

        pixels.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for dy in 0..<newH {
                    let sy = (Double(dy) + 0.5) * scaleY - 0.5
                    var y0 = Int(sy.rounded(.down))
                    var fy = sy - Double(y0)
                    if y0 < 0 { y0 = 0; fy = 0 }
                    if y0 >= height - 1 { y0 = max(0, height - 1); fy = 0 }
                    let y1 = min(y0 + 1, height - 1)
                    let row0 = y0 * width * 3, row1 = y1 * width * 3
                    let dstRow = dy * newW * 3

                    for dx in 0..<newW {
                        let x0 = x0s[dx] * 3, x1 = x1s[dx] * 3
                        let fx = fxs[dx]
                        let w00 = (1 - fx) * (1 - fy), w10 = fx * (1 - fy)
                        let w01 = (1 - fx) * fy,       w11 = fx * fy
                        let o = dstRow + dx * 3
                        for c in 0..<3 {
                            let v = Double(src[row0 + x0 + c]) * w00
                                  + Double(src[row0 + x1 + c]) * w10
                                  + Double(src[row1 + x0 + c]) * w01
                                  + Double(src[row1 + x1 + c]) * w11
                            dst[o + c] = UInt8(max(0, min(255, v.rounded())))
                        }
                    }
                }
            }
        }
        return PPImageBuffer(width: newW, height: newH, pixels: out)
    }

    // MARK: - Perspective crop

    /// Port of PaddleOCR's `get_rotate_crop_image`.
    ///
    /// The quad is mapped onto an upright rectangle whose size is taken from
    /// the longest opposing edges, sampled bilinearly with replicated borders.
    /// A crop that ends up at least 1.5× taller than wide is rotated
    /// counter-clockwise, which is how vertical columns of CJK text are handed
    /// to the (horizontal-only) recogniser.
    func perspectiveCrop(quad: [CGPoint]) -> PPImageBuffer? {
        precondition(quad.count == 4)
        let cropW = Int(max(PPGeometry.distance(quad[0], quad[1]),
                            PPGeometry.distance(quad[2], quad[3])))
        let cropH = Int(max(PPGeometry.distance(quad[0], quad[3]),
                            PPGeometry.distance(quad[1], quad[2])))
        guard cropW > 0, cropH > 0 else { return nil }

        let dst: [CGPoint] = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: CGFloat(cropW), y: 0),
            CGPoint(x: CGFloat(cropW), y: CGFloat(cropH)),
            CGPoint(x: 0, y: CGFloat(cropH)),
        ]
        // Solve for the homography that carries the upright rectangle onto the
        // quad, so the warp can be evaluated by inverse mapping.
        guard let h = PPImageBuffer.perspectiveTransform(from: dst, to: quad) else { return nil }

        var out = [UInt8](repeating: 0, count: cropW * cropH * 3)
        pixels.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { d in
                for y in 0..<cropH {
                    let fy = Double(y)
                    for x in 0..<cropW {
                        let fx = Double(x)
                        var den = h[6] * fx + h[7] * fy + 1
                        if abs(den) < 1e-12 { den = 1e-12 }
                        let sx = (h[0] * fx + h[1] * fy + h[2]) / den
                        let sy = (h[3] * fx + h[4] * fy + h[5]) / den

                        let ix = Int(sx.rounded(.down)), iy = Int(sy.rounded(.down))
                        let ax = sx - Double(ix), ay = sy - Double(iy)
                        let x0 = clampX(ix), x1 = clampX(ix + 1)
                        let y0 = clampY(iy), y1 = clampY(iy + 1)
                        let r0 = y0 * width * 3, r1 = y1 * width * 3
                        let c0 = x0 * 3, c1 = x1 * 3
                        let w00 = (1 - ax) * (1 - ay), w10 = ax * (1 - ay)
                        let w01 = (1 - ax) * ay,       w11 = ax * ay
                        let o = (y * cropW + x) * 3
                        for c in 0..<3 {
                            let v = Double(src[r0 + c0 + c]) * w00
                                  + Double(src[r0 + c1 + c]) * w10
                                  + Double(src[r1 + c0 + c]) * w01
                                  + Double(src[r1 + c1 + c]) * w11
                            d[o + c] = UInt8(max(0, min(255, v.rounded())))
                        }
                    }
                }
            }
        }
        let crop = PPImageBuffer(width: cropW, height: cropH, pixels: out)
        return Double(cropH) / Double(max(cropW, 1)) >= 1.5 ? crop.rotated90CCW() : crop
    }

    /// Direct linear solve of the 8 unknowns of a planar homography.
    private static func perspectiveTransform(from src: [CGPoint], to dst: [CGPoint]) -> [Double]? {
        var a = [Double](repeating: 0, count: 8 * 9)   // augmented 8×9
        for i in 0..<4 {
            let u = Double(src[i].x), v = Double(src[i].y)
            let x = Double(dst[i].x), y = Double(dst[i].y)
            let r0 = (i * 2) * 9
            a[r0 + 0] = u; a[r0 + 1] = v; a[r0 + 2] = 1
            a[r0 + 6] = -u * x; a[r0 + 7] = -v * x; a[r0 + 8] = x
            let r1 = (i * 2 + 1) * 9
            a[r1 + 3] = u; a[r1 + 4] = v; a[r1 + 5] = 1
            a[r1 + 6] = -u * y; a[r1 + 7] = -v * y; a[r1 + 8] = y
        }
        // Gaussian elimination with partial pivoting.
        for col in 0..<8 {
            var pivot = col
            for r in (col + 1)..<8 where abs(a[r * 9 + col]) > abs(a[pivot * 9 + col]) { pivot = r }
            guard abs(a[pivot * 9 + col]) > 1e-12 else { return nil }
            if pivot != col {
                for k in 0...8 { a.swapAt(col * 9 + k, pivot * 9 + k) }
            }
            let d = a[col * 9 + col]
            for k in col...8 { a[col * 9 + k] /= d }
            for r in 0..<8 where r != col {
                let f = a[r * 9 + col]
                if f == 0 { continue }
                for k in col...8 { a[r * 9 + k] -= f * a[col * 9 + k] }
            }
        }
        return (0..<8).map { a[$0 * 9 + 8] }
    }

    // MARK: - Rotation

    func rotated90CCW() -> PPImageBuffer {
        let nw = height, nh = width
        var out = [UInt8](repeating: 0, count: nw * nh * 3)
        pixels.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for y in 0..<height {
                    for x in 0..<width {
                        // np.rot90: dst[width-1-x][y] = src[y][x]
                        let o = ((width - 1 - x) * nw + y) * 3
                        let i = (y * width + x) * 3
                        dst[o] = src[i]; dst[o + 1] = src[i + 1]; dst[o + 2] = src[i + 2]
                    }
                }
            }
        }
        return PPImageBuffer(width: nw, height: nh, pixels: out)
    }

    func rotated90CW() -> PPImageBuffer {
        let nw = height, nh = width
        var out = [UInt8](repeating: 0, count: nw * nh * 3)
        pixels.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for y in 0..<height {
                    for x in 0..<width {
                        let o = (x * nw + (height - 1 - y)) * 3
                        let i = (y * width + x) * 3
                        dst[o] = src[i]; dst[o + 1] = src[i + 1]; dst[o + 2] = src[i + 2]
                    }
                }
            }
        }
        return PPImageBuffer(width: nw, height: nh, pixels: out)
    }

    /// Centre crop, clamped to the image bounds.
    func centerCropped(to side: Int) -> PPImageBuffer {
        let cw = min(side, width), ch = min(side, height)
        let x0 = (width - cw) / 2, y0 = (height - ch) / 2
        var out = [UInt8](repeating: 0, count: cw * ch * 3)
        pixels.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for y in 0..<ch {
                    let s = ((y0 + y) * width + x0) * 3
                    let d = y * cw * 3
                    for i in 0..<(cw * 3) { dst[d + i] = src[s + i] }
                }
            }
        }
        return PPImageBuffer(width: cw, height: ch, pixels: out)
    }

    func rotated180() -> PPImageBuffer {
        var out = [UInt8](repeating: 0, count: pixels.count)
        let n = width * height
        pixels.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for i in 0..<n {
                    let o = (n - 1 - i) * 3, j = i * 3
                    dst[o] = src[j]; dst[o + 1] = src[j + 1]; dst[o + 2] = src[j + 2]
                }
            }
        }
        return PPImageBuffer(width: width, height: height, pixels: out)
    }

    // MARK: - Tensor conversion

    /// Writes the image into `dst` as planar CHW float, applying
    /// `(pixel / 255 - mean[c]) / std[c]` channel by channel.
    ///
    /// `mean`/`std` are indexed by the buffer's own channel order (B, G, R),
    /// matching how `NormalizeImage` broadcasts over an OpenCV BGR array.
    func writeNormalizedCHW(into dst: inout [Float], offset: Int,
                            mean: (Float, Float, Float), std: (Float, Float, Float),
                            padTo padWidth: Int? = nil, padHeight: Int? = nil) {
        let outW = padWidth ?? width
        let outH = padHeight ?? height
        let plane = outW * outH
        let m = [mean.0, mean.1, mean.2]
        let s = [std.0, std.1, std.2]
        pixels.withUnsafeBufferPointer { src in
            dst.withUnsafeMutableBufferPointer { d in
                for c in 0..<3 {
                    let invS = 1 / s[c], mc = m[c]
                    let base = offset + c * plane
                    for y in 0..<min(height, outH) {
                        let srcRow = y * width * 3
                        let dstRow = base + y * outW
                        for x in 0..<min(width, outW) {
                            d[dstRow + x] = (Float(src[srcRow + x * 3 + c]) / 255 - mc) * invS
                        }
                    }
                }
            }
        }
    }
}
