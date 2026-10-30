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
        guard count > 1 else { return nil }
        var sizes: [(width: Int, height: Int)] = []
        for index in 0..<count {
            guard let image = picture(index) else { return nil }
            sizes.append((image.width, image.height))
        }
        guard let width = sizes.map(\.width).min(), let height = sizes.map(\.height).min(),
              sizes.allSatisfy({ $0.width - width <= 4 && $0.height - height <= 4 }) else { return nil }

        // A pixel or two of difference, from rounding, is cut off; so is a
        // sidebar that stays put.
        var cut = CGRect(x: 0, y: 0, width: width, height: height)
        func frame(_ index: Int) -> CGImage? {
            guard let image = picture(index) else { return nil }
            return image.width == Int(cut.width) && image.height == Int(cut.height) && cut.minX == 0
                ? image : image.cropping(to: cut)
        }
        /// Each pair of neighbours in turn, in grey.
        func pairs(_ body: (Gray, Gray) -> Bool) -> Bool {
            guard let first = frame(0) else { return false }
            var previous = Gray(first)
            for index in 1..<count {
                guard let image = frame(index) else { return false }
                let next = Gray(image)
                guard body(previous, next) else { return false }
                previous = next
            }
            return true
        }

        var moving = [Bool](repeating: false, count: width)
        guard pairs({ markMovingColumns(from: $0, to: $1, in: &moving); return true }) else { return nil }
        if let span = columns(moving), span.count < width * 9 / 10 {
            cut = CGRect(x: span.lowerBound, y: 0, width: span.count, height: height)
        }

        var top = height / 2, bottom = height / 2 - 1
        guard pairs({ a, b in
            top = sameRows(a, b, from: 0, by: 1, upTo: top)
            bottom = sameRows(a, b, from: height - 1, by: -1, upTo: bottom)
            return true
        }) else { return nil }

        var shifts: [Int] = []
        guard pairs({ a, b in
            guard let shift = shift(from: a, to: b, top: top, bottom: bottom, near: shifts.last) else { return false }
            shifts.append(shift)
            return true
        }) else { return nil }
        return compose(count: count, shifts: shifts, height: height, top: top, bottom: bottom,
                       maxHeight: maxHeight, picture: frame)
    }

    // MARK: - Measuring

    /// A picture in grey, one byte a pixel, and each row in brief: the mean
    /// of each of a few dozen stretches across it.
    struct Gray {
        static let blocks = 32
        let width: Int
        let height: Int
        let pixels: [UInt8]
        /// `blocks` values a row.
        let rows: [Float]
        /// Whether each row has anything on it.
        let busy: [Bool]

        init(_ image: CGImage) {
            let width = image.width, height = image.height
            self.width = width
            self.height = height
            var pixels = [UInt8](repeating: 255, count: width * height)
            pixels.withUnsafeMutableBytes { buffer in
                let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                        bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                        bitmapInfo: CGImageAlphaInfo.none.rawValue)
                context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
            let blocks = Self.blocks
            var rows = [Float](repeating: 0, count: height * blocks)
            var busy = [Bool](repeating: false, count: height)
            pixels.withUnsafeBufferPointer { pixels in
                for y in 0..<height {
                    let row = y * width
                    var low: UInt8 = 255, high: UInt8 = 0
                    for block in 0..<blocks {
                        let start = block * width / blocks
                        let end = max(start + 1, min(width, (block + 1) * width / blocks))
                        var sum = 0
                        for x in start..<end {
                            let value = pixels[row + x]
                            sum += Int(value)
                            low = min(low, value)
                            high = max(high, value)
                        }
                        rows[y * blocks + block] = Float(sum) / Float(end - start)
                    }
                    busy[y] = high - low > 48
                }
            }
            self.pixels = pixels
            self.rows = rows
            self.busy = busy
        }

        /// How different row `y` here is from row `other` of `picture`: the
        /// mean difference of their stretches, 0 to 255.
        func roughDifference(row y: Int, from picture: Gray, row other: Int) -> Float {
            var sum: Float = 0
            let a = y * Self.blocks, b = other * Self.blocks
            for block in 0..<Self.blocks { sum += abs(rows[a + block] - picture.rows[b + block]) }
            return sum / Float(Self.blocks)
        }

        /// The same, pixel by pixel.
        func difference(row y: Int, from picture: Gray, row other: Int) -> Float {
            var sum = 0
            let a = y * width, b = other * picture.width
            for x in 0..<width { sum += abs(Int(pixels[a + x]) - Int(picture.pixels[b + x])) }
            return Float(sum) / Float(width)
        }
    }

    /// Marks the columns that differ between two pictures.
    static func markMovingColumns(from a: Gray, to b: Gray, in moving: inout [Bool]) {
        let rows = Array(stride(from: 0, to: a.height, by: 4))
        for x in 0..<min(moving.count, a.width) where !moving[x] {
            var sum = 0
            for y in rows { sum += abs(Int(a.pixels[y * a.width + x]) - Int(b.pixels[y * b.width + x])) }
            if sum > rows.count * 3 / 2 { moving[x] = true }
        }
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
    static func shift(from a: Gray, to b: Gray, top: Int, bottom: Int, near expected: Int?) -> Int? {
        let middle = a.height - top - bottom
        let minOverlap = max(16, middle / 10)
        guard middle > minOverlap + 1 else { return nil }

        // Every distance, roughly: every third row of the overlap.
        var candidates: [(shift: Int, error: Float)] = []
        for shift in 1...(middle - minOverlap) {
            var sum: Float = 0, count = 0
            var y = 0
            while y < middle - shift {
                sum += a.roughDifference(row: top + shift + y, from: b, row: top + y)
                count += 1
                y += 3
            }
            candidates.append((shift, sum / Float(count)))
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

    private static func compose(count: Int, shifts: [Int], height: Int, top: Int, bottom: Int, maxHeight: Int,
                                picture: (Int) -> CGImage?) -> [CGImage]? {
        let middle = height - top - bottom
        // What each picture adds: all of the first above the footer, then
        // only what came into view at the bottom.
        var slices: [Slice] = [(0, 0..<(top + middle))]
        for (index, shift) in zip(1..<count, shifts) {
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
        groups[groups.count - 1].append((count - 1, (height - bottom)..<height))

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
