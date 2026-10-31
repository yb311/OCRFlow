import Accelerate
import CoreGraphics
import Foundation
import ImageIO

/// Joins pictures of something scrolled, one after another, into one long
/// picture.
///
/// Nothing is known about what was scrolled. Rows at the top and bottom that
/// stay put in every picture — a toolbar, a sticky header, a status bar — are
/// kept once, and columns beside the scrolling part that stay put — a
/// sidebar — are left out. In between, each picture is matched against the
/// one before to find how far it moved, and only what came into view is
/// added.
enum ScrollStitcher {
    /// Taller than this, the picture is cut into several: a picture of
    /// hundreds of megabytes in memory helps no one.
    static let maxHeight = 40_000

    /// The long picture — or several, when it would be taller than
    /// `maxHeight`. Nil when the pictures are not one scrolled view, such as
    /// slides turned one by one.
    static func stitch(_ images: [CGImage], maxHeight: Int = maxHeight) -> [CGImage]? {
        stitch(count: images.count, maxHeight: maxHeight) { images[$0] }
    }

    /// The same, from files.
    static func stitch(_ files: [URL], maxHeight: Int = maxHeight) -> [CGImage]? {
        stitch(count: files.count, maxHeight: maxHeight) { index in
            guard let source = CGImageSourceCreateWithURL(files[index] as CFURL, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        }
    }

    /// The pictures are asked for as they are needed, a pair at a time, and
    /// several times over: hundreds of screenfuls do not fit in memory at
    /// once.
    static func stitch(count: Int, maxHeight: Int = maxHeight, picture: (Int) -> CGImage?) -> [CGImage]? {
        join(count: count, maxHeight: maxHeight, picture: picture)?.parts
    }

    /// The long picture, and whether the last of the pictures is in it.
    ///
    /// A picture that does not carry on from the last one taken in — scrolled
    /// too far at once, or caught as its window changed size — is left out,
    /// and joining goes on from the next that does: scrolling back a little
    /// mends a gap. Nil when none carries on from the first.
    static func join(count: Int, maxHeight: Int = maxHeight,
                     picture: (Int) -> CGImage?) -> (parts: [CGImage], usesLast: Bool)? {
        guard count > 1, let base = picture(0) else { return nil }
        let width = base.width, height = base.height
        // Only those the size of the first; a pixel or two off, from
        // rounding, is cut off.
        var candidates: [Int] = [0]
        for index in 1..<count {
            guard let image = picture(index), image.width >= width, image.height >= height,
                  image.width - width <= 4, image.height - height <= 4 else { continue }
            candidates.append(index)
        }
        guard candidates.count > 1 else { return nil }

        // So is a sidebar that stays put.
        var cut = CGRect(x: 0, y: 0, width: width, height: height)
        func frame(_ index: Int) -> CGImage? {
            guard let image = picture(index) else { return nil }
            return image.width == Int(cut.width) && image.height == Int(cut.height) && cut.minX == 0
                ? image : image.cropping(to: cut)
        }
        /// Each pair of neighbours among the candidates in turn, in grey.
        func pairs(_ body: (Gray, Gray) -> Void) -> Bool {
            guard let first = frame(candidates[0]) else { return false }
            var previous = Gray(first)
            for index in candidates.dropFirst() {
                guard let image = frame(index) else { return false }
                let next = Gray(image)
                body(previous, next)
                previous = next
            }
            return true
        }

        var moving = [Bool](repeating: false, count: width)
        guard pairs({ markMovingColumns(from: $0, to: $1, in: &moving) }) else { return nil }
        if let span = columns(moving), span.count < width * 9 / 10 {
            cut = CGRect(x: span.lowerBound, y: 0, width: span.count, height: height)
        }

        // The edges every pair shares — but one: the first picture is
        // usually taken while choosing what to capture, its window in the
        // background, and a background window's title bar is lighter. Pairs
        // that do not join still share the bars that stay put.
        var tops: [Int] = [], bottoms: [Int] = []
        guard pairs({ a, b in
            tops.append(sameRows(a, b, from: 0, by: 1, upTo: height / 2))
            bottoms.append(sameRows(a, b, from: height - 1, by: -1, upTo: height / 2 - 1))
        }) else { return nil }
        func shared(_ counts: [Int]) -> Int {
            let sorted = counts.sorted()
            return sorted.count >= 3 ? sorted[1] : sorted[0]
        }
        let top = shared(tops), bottom = shared(bottoms)

        // Each against the last taken in.
        guard let first = frame(candidates[0]) else { return nil }
        var last = Gray(first)
        var taken: [(index: Int, shift: Int)] = [(candidates[0], 0)]
        for index in candidates.dropFirst() {
            guard let image = frame(index) else { return nil }
            let next = Gray(image)
            guard let shift = shift(from: last, to: next, top: top, bottom: bottom, near: taken.last?.shift) else { continue }
            taken.append((index, shift))
            last = next
        }
        guard taken.count > 1,
              let parts = compose(taken: taken, height: height, top: top, bottom: bottom,
                                  maxHeight: maxHeight, picture: frame) else { return nil }
        return (parts, taken.last?.index == count - 1)
    }

    // MARK: - Measuring

    /// A picture in grey, and each row in brief: the mean of each of a few
    /// dozen stretches across it.
    ///
    /// The arithmetic is vectorised (Accelerate): a frame is compared with
    /// the one before several times a second while a view scrolls, and
    /// plain loops over every pixel are too slow for that, in a debug build
    /// by far.
    struct Gray {
        static let blocks = 32
        let width: Int
        let height: Int
        /// 0 to 255, a pixel each, row by row.
        let values: [Float]
        /// `blocks` values a row.
        let rows: [Float]
        /// Whether each row has anything on it.
        let busy: [Bool]

        init(_ image: CGImage) {
            let width = image.width, height = image.height
            self.width = width
            self.height = height
            let bytes = Self.lightness(of: image)
            let values = vDSP.integerToFloatingPoint(bytes, floatingPointType: Float.self)
            self.values = values
            // Each of the stretches, the mean of its pixels.
            var rows = [Float](repeating: 0, count: height * Self.blocks)
            var busy = [Bool](repeating: false, count: height)
            let stretches = (0...Self.blocks).map { $0 * width / Self.blocks }
            values.withUnsafeBufferPointer { values in
                rows.withUnsafeMutableBufferPointer { rows in
                    for y in 0..<height {
                        let row = values.baseAddress! + y * width
                        for block in 0..<Self.blocks {
                            let start = min(stretches[block], width - 1)
                            let count = max(1, stretches[block + 1] - stretches[block])
                            vDSP_meanv(row + start, 1, rows.baseAddress! + y * Self.blocks + block, vDSP_Length(count))
                        }
                        var lowest: Float = 0, highest: Float = 0
                        vDSP_minv(row, 1, &lowest, vDSP_Length(width))
                        vDSP_maxv(row, 1, &highest, vDSP_Length(width))
                        busy[y] = highest - lowest > 48
                    }
                }
            }
            self.rows = rows
            self.busy = busy
        }

        /// How light each pixel is, 0 to 255, row by row — straight from the
        /// picture's own bytes when they are the usual four to a pixel, a
        /// frame's way: drawing every frame in grey takes far longer.
        private static func lightness(of image: CGImage) -> [UInt8] {
            let width = image.width, height = image.height
            var bytes = [UInt8](repeating: 255, count: width * height)
            let alpha = image.alphaInfo
            let first = [.premultipliedFirst, .first, .noneSkipFirst].contains(alpha)
            let little = image.bitmapInfo.contains(.byteOrder32Little)
            // R, G and B by how bright each looks, in the order they lie.
            let weights: [Int16] = switch (first, little) {
            case (true, true): [29, 150, 77, 0]     // B G R A
            case (true, false): [0, 77, 150, 29]    // A R G B
            case (false, true): [0, 29, 150, 77]    // A B G R
            case (false, false): [77, 150, 29, 0]   // R G B A
            }
            if image.bitsPerPixel == 32, image.bitsPerComponent == 8, alpha != .none, alpha != .alphaOnly,
               image.colorSpace?.model == .rgb, let data = image.dataProvider?.data,
               CFDataGetLength(data) >= image.bytesPerRow * height {
                bytes.withUnsafeMutableBytes { output in
                    var source = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: CFDataGetBytePtr(data)),
                                               height: vImagePixelCount(height), width: vImagePixelCount(width),
                                               rowBytes: image.bytesPerRow)
                    var destination = vImage_Buffer(data: output.baseAddress, height: vImagePixelCount(height),
                                                    width: vImagePixelCount(width), rowBytes: width)
                    _ = vImageMatrixMultiply_ARGB8888ToPlanar8(&source, &destination, weights, 256, nil, 0,
                                                               vImage_Flags(kvImageNoFlags))
                }
                return bytes
            }
            bytes.withUnsafeMutableBytes { buffer in
                let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                        bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                        bitmapInfo: CGImageAlphaInfo.none.rawValue)
                context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
            return bytes
        }

        /// How different row `y` here is from row `other` of `picture`: the
        /// mean difference of their pixels, 0 to 255.
        func difference(row y: Int, from picture: Gray, row other: Int) -> Float {
            Self.meanDifference(values, at: y * width, picture.values, at: other * picture.width, count: width)
        }

        private static func meanDifference(_ a: [Float], at i: Int, _ b: [Float], at j: Int, count: Int) -> Float {
            a.withUnsafeBufferPointer { a in
                b.withUnsafeBufferPointer { b in
                    Self.meanDifference(a.baseAddress! + i, b.baseAddress! + j, count: count)
                }
            }
        }

        /// The mean of how far apart `count` values are, from `a` and `b` on.
        static func meanDifference(_ a: UnsafePointer<Float>, _ b: UnsafePointer<Float>, count: Int) -> Float {
            withUnsafeTemporaryAllocation(of: Float.self, capacity: count) { difference in
                var result: Float = 0
                vDSP_vsub(b, 1, a, 1, difference.baseAddress!, 1, vDSP_Length(count))
                vDSP_meamgv(difference.baseAddress!, 1, &result, vDSP_Length(count))
                return result
            }
        }
    }

    /// Marks the columns that differ between two pictures.
    static func markMovingColumns(from a: Gray, to b: Gray, in moving: inout [Bool]) {
        let width = min(moving.count, a.width)
        var sums = [Float](repeating: 0, count: width)
        var difference = [Float](repeating: 0, count: width)
        var samples = 0
        a.values.withUnsafeBufferPointer { av in
            b.values.withUnsafeBufferPointer { bv in
                for y in stride(from: 0, to: a.height, by: 4) {
                    vDSP_vsub(bv.baseAddress! + y * b.width, 1, av.baseAddress! + y * a.width, 1, &difference, 1, vDSP_Length(width))
                    vDSP_vabs(difference, 1, &difference, 1, vDSP_Length(width))
                    vDSP_vadd(sums, 1, difference, 1, &sums, 1, vDSP_Length(width))
                    samples += 1
                }
            }
        }
        for x in 0..<width where !moving[x] && sums[x] > Float(samples) * 1.5 { moving[x] = true }
    }

    /// The marked columns, first to last, with a little room either side.
    /// Nil when none is marked.
    static func columns(_ moving: [Bool]) -> Range<Int>? {
        guard let left = moving.firstIndex(of: true), let right = moving.lastIndex(of: true) else { return nil }
        let room = 12
        return max(0, left - room)..<min(moving.count, right + 1 + room)
    }

    /// How many rows from `start`, going `step` at a time, two pictures share
    /// — at most `limit`.
    ///
    /// Nearly the same is the same: a title bar over scrolled content lets it
    /// show through faintly, and shades a little darker or lighter as its
    /// window comes and goes from the front.
    static func sameRows(_ a: Gray, _ b: Gray, from start: Int, by step: Int, upTo limit: Int) -> Int {
        var count = 0
        while count < limit, a.difference(row: start + count * step, from: b, row: start + count * step) < 4 {
            count += 1
        }
        return count
    }

    /// How many rows `b` has moved on from `a` between the fixed edges. Nil
    /// when it does not carry on from `a`.
    ///
    /// The rows they share must agree, and include enough with something on
    /// them that the match means something: blank against blank fits any
    /// distance.
    ///
    /// `within` narrows the search to distances near what is expected — a
    /// view scrolled smoothly moves about as far from one frame to the next.
    static func shift(from a: Gray, to b: Gray, top: Int, bottom: Int, near expected: Int?,
                      within: ClosedRange<Int>? = nil) -> Int? {
        let middle = a.height - top - bottom
        let minOverlap = max(16, middle / 10)
        guard middle > minOverlap + 1 else { return nil }
        var range = 1...(middle - minOverlap)
        if let within {
            let low = max(range.lowerBound, within.lowerBound), high = min(range.upperBound, within.upperBound)
            guard low <= high else { return nil }
            range = low...high
        }

        // Not moved at all: scrolling by hand catches the same screenful
        // twice now and then.
        let unmoved = (top..<(top + middle)).filter { a.difference(row: $0, from: b, row: $0) > 12 }.count
        if unmoved * 20 <= middle { return 0 }

        // Every distance, roughly: the overlap's stretches, all at once.
        let candidates: [(shift: Int, error: Float)] = a.rows.withUnsafeBufferPointer { ar in
            b.rows.withUnsafeBufferPointer { br in
                range.map { shift in
                    (shift, Gray.meanDifference(ar.baseAddress! + (top + shift) * Gray.blocks,
                                                br.baseAddress! + top * Gray.blocks,
                                                count: (middle - shift) * Gray.blocks))
                }
            }
        }
        // Whether the best is good enough is for the exact comparison below:
        // over a short overlap, one line a title bar draws under itself
        // outweighs everything else in a mean.
        guard let best = candidates.min(by: { $0.error < $1.error }) else { return nil }
        // Near-ties, as on a page of evenly spaced lines, go to the distance
        // the last picture moved, or else to the most overlap.
        let close = candidates.filter { $0.error <= best.error + 0.5 }
        let chosen = close.min { lhs, rhs in
            if let expected { return abs(lhs.shift - expected) < abs(rhs.shift - expected) }
            return lhs.shift < rhs.shift
        } ?? best

        // Then exactly, row by row.
        var mismatched = 0, busy = 0
        let overlap = middle - chosen.shift
        for y in 0..<overlap {
            let row = top + chosen.shift + y
            if a.busy[row] { busy += 1 }
            if a.difference(row: row, from: b, row: top + y) > 12 { mismatched += 1 }
        }
        guard busy >= 8, mismatched * 20 <= overlap else { return nil }
        return chosen.shift
    }

    // MARK: - Drawing

    /// Rows of one of the pictures.
    private typealias Slice = (picture: Int, rows: Range<Int>)

    /// `taken`: the pictures joined, each with how far it moved on from the
    /// one before.
    private static func compose(taken: [(index: Int, shift: Int)], height: Int, top: Int, bottom: Int, maxHeight: Int,
                                picture: (Int) -> CGImage?) -> [CGImage]? {
        let middle = height - top - bottom
        // What each picture adds: all of the first above the footer, then
        // only what came into view at the bottom.
        var slices: [Slice] = [(taken[0].index, 0..<(top + middle))]
        for (index, shift) in taken.dropFirst() {
            slices.append((index, (top + middle - shift)..<(top + middle)))
        }

        // Grouped into parts no taller than the limit. A part after the
        // first starts with the header again, so each reads on its own.
        var groups: [[Slice]] = [[]]
        var groupHeight = 0
        for slice in slices {
            if !groups[groups.count - 1].isEmpty, groupHeight + slice.rows.count + top + bottom > maxHeight {
                groups.append([(slice.picture, 0..<top)])
                groupHeight = top
            }
            groups[groups.count - 1].append(slice)
            groupHeight += slice.rows.count
        }
        groups[groups.count - 1].append((taken[taken.count - 1].index, (height - bottom)..<height))

        var parts: [CGImage] = []
        for group in groups {
            guard let part = draw(group, picture: picture) else { return nil }
            parts.append(part)
        }
        return parts
    }

    private static func draw(_ slices: [Slice], picture: (Int) -> CGImage?) -> CGImage? {
        guard let first = slices.first.flatMap({ picture($0.picture) }) else { return nil }
        let width = first.width
        let total = slices.reduce(0) { $0 + $1.rows.count }
        guard let context = CGContext(data: nil, width: width, height: total, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: first.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
                                          ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        var y = total
        var loaded: (index: Int, image: CGImage) = (slices[0].picture, first)
        for slice in slices where !slice.rows.isEmpty {
            if loaded.index != slice.picture {
                guard let image = picture(slice.picture) else { return nil }
                loaded = (slice.picture, image)
            }
            guard let cut = loaded.image.cropping(to: CGRect(x: 0, y: slice.rows.lowerBound,
                                                             width: width, height: slice.rows.count)) else { return nil }
            y -= slice.rows.count
            context.draw(cut, in: CGRect(x: 0, y: y, width: width, height: slice.rows.count))
        }
        return context.makeImage()
    }
}
