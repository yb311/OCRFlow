import CoreGraphics

/// A small grey copy of a capture, for telling whether the screen has
/// changed — a new page turned up, or it has finished drawing — without
/// comparing full pictures.
///
/// Small changes are not counted: a blinking caret, a clock ticking over, the
/// edge of a fading scroll bar.
struct PageFingerprint: Sendable {
    let width: Int
    let height: Int
    private let pixels: [UInt8]

    /// How many pixels must change, as a share of all of them, for it to be
    /// a different page.
    static let changedShare = 0.002
    /// How far a pixel's grey must move to count as changed.
    private static let tolerance = 24

    init?(_ image: CGImage, width: Int = 160) {
        let height = max(1, Int((Double(image.height) * Double(width) / Double(max(image.width, 1))).rounded()))
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// The share of pixels that changed. A different shape is a whole change.
    func change(from other: PageFingerprint) -> Double {
        guard width == other.width, height == other.height else { return 1 }
        var changed = 0
        for index in pixels.indices where abs(Int(pixels[index]) - Int(other.pixels[index])) > Self.tolerance {
            changed += 1
        }
        return Double(changed) / Double(pixels.count)
    }

    func isSamePage(as other: PageFingerprint) -> Bool {
        change(from: other) < Self.changedShare
    }
}
