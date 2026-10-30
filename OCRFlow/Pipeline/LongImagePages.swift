import CoreGraphics
import Foundation
import ImageIO
import os

/// A picture much taller than it is wide — a long screenshot of a web page,
/// a chat, an article — read as pages of a usual shape.
///
/// Recognition scales each page down to a set size. Taken whole, a long
/// screenshot would shrink until its text is too small to read; cut into
/// pages, each between two lines of text, it reads like any document.
enum LongImagePages {
    /// Taller than this many widths, a picture is cut.
    static let tallness = 2.5
    /// Pages at most this many widths tall: about A4.
    static let pageShape = 1.4

    /// Whether the file's header says the picture is long. Cheap: nothing is
    /// decoded.
    static func mayBeLong(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              var width = properties[kCGImagePropertyPixelWidth] as? Int,
              var height = properties[kCGImagePropertyPixelHeight] as? Int else { return false }
        // Turned on its side by its EXIF tag.
        if let orientation = properties[kCGImagePropertyOrientation] as? Int, orientation >= 5 {
            swap(&width, &height)
        }
        return width > 0 && Double(height) > Double(width) * tallness
    }

    /// The rows of the upright picture each page takes, top to bottom. Nil
    /// when the picture is not long.
    static func pages(of url: URL) -> [Range<Int>]? {
        guard mayBeLong(url) else { return nil }
        let key = cacheKey(url)
        if let cached = cuts.withLock({ $0[key] }) { return cached }
        guard let image = decoded(url, key: key) else { return nil }
        let pages = cut(image)
        cuts.withLock { $0[key] = pages }
        return pages
    }

    /// One page, cut out of the whole picture.
    static func page(_ index: Int, of url: URL, cutAt pages: [Range<Int>]) -> CGImage? {
        guard pages.indices.contains(index), let image = decoded(url, key: cacheKey(url)) else { return nil }
        let rows = pages[index]
        return image.cropping(to: CGRect(x: 0, y: rows.lowerBound, width: image.width, height: rows.count))
    }

    // MARK: - Where to cut

    /// Pages no taller than `pageShape` widths, each cut in the widest blank
    /// gap between lines near its foot, or failing that across the row with
    /// least on it.
    static func cut(_ image: CGImage) -> [Range<Int>] {
        cut(height: image.height, pageHeight: max(64, Int(Double(image.width) * pageShape)), ink: ink(of: image))
    }

    /// `ink[y]` is how much is on row `y`: 0 for a blank one.
    static func cut(height: Int, pageHeight: Int, ink: [Int]) -> [Range<Int>] {
        var pages: [Range<Int>] = []
        var start = 0
        while start < height {
            // The rest fits, or nearly: one last page.
            if height - start <= pageHeight + pageHeight / 8 {
                pages.append(start..<height)
                break
            }
            let window = (start + pageHeight * 7 / 10)..<(start + pageHeight)
            var bestGap: Range<Int>?
            var run = window.lowerBound
            for y in window {
                if ink[y] > 0 { run = y + 1; continue }
                let gap = run..<(y + 1)
                if gap.count > (bestGap?.count ?? 0) { bestGap = gap }
            }
            let end: Int
            if let bestGap {
                end = (bestGap.lowerBound + bestGap.upperBound) / 2
            } else {
                // Text all the way: the lightest row, the lower the better.
                end = window.reversed().min { ink[$0] < ink[$1] } ?? window.upperBound
            }
            pages.append(start..<end)
            start = end
        }
        return pages
    }

    /// How much is on each row: the spread between its lightest and darkest
    /// pixels, ignoring a faint one — a background gradient, a hairline.
    private static func ink(of image: CGImage) -> [Int] {
        // Narrowed, not shortened: every row is kept.
        let width = min(image.width, 400), height = image.height
        var pixels = [UInt8](repeating: 255, count: width * height)
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                    bitmapInfo: CGImageAlphaInfo.none.rawValue)
            context?.interpolationQuality = .low
            context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return pixels.withUnsafeBufferPointer { pixels in
            (0..<height).map { y in
                var low: UInt8 = 255, high: UInt8 = 0
                for x in 0..<width {
                    let value = pixels[y * width + x]
                    low = min(low, value)
                    high = max(high, value)
                }
                let spread = Int(high) - Int(low)
                return spread > 24 ? spread : 0
            }
        }
    }

    // MARK: - Cache

    /// Where each long picture was cut, so it is worked out once.
    private static let cuts = OSAllocatedUnfairLock(initialState: [String: [Range<Int>]]())
    /// The last long picture decoded: its pages are read one after another,
    /// and decoding a long picture takes a while.
    private static let last = OSAllocatedUnfairLock<(key: String, image: CGImage)?>(uncheckedState: nil)

    private static func cacheKey(_ url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let date = values?.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
        return "\(url.path(percentEncoded: false))|\(date)|\(values?.fileSize ?? 0)"
    }

    private static func decoded(_ url: URL, key: String) -> CGImage? {
        if let hit = last.withLock({ $0?.key == key ? $0?.image : nil }) { return hit }
        guard let image = PageImages.wholeImage(at: url) else { return nil }
        last.withLock { $0 = (key, image) }
        return image
    }
}
