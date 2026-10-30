import CoreGraphics

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
        guard images.count > 1,
              let width = images.map(\.width).min(), let height = images.map(\.height).min(),
              images.allSatisfy({ $0.width - width <= 4 && $0.height - height <= 4 }) else { return nil }
        // A pixel or two of difference, from rounding, is cut off.
        var images = images.compactMap { image in
            image.width == width && image.height == height
                ? image : image.cropping(to: CGRect(x: 0, y: 0, width: width, height: height))
        }
        guard images.count > 1, let first = images.first else { return nil }
        var grays = images.map(Gray.init)
        if let span = movingColumns(grays), span.count < first.width * 9 / 10 {
            let cut = CGRect(x: span.lowerBound, y: 0, width: span.count, height: first.height)
            let cropped = images.compactMap { $0.cropping(to: cut) }
            guard cropped.count == images.count else { return nil }
            images = cropped
            grays = images.map(Gray.init)
        }
        let (top, bottom) = fixedEdges(grays)
        var shifts: [Int] = []
        for (a, b) in zip(grays, grays.dropFirst()) {
            guard let shift = shift(from: a, to: b, top: top, bottom: bottom, near: shifts.last) else { return nil }
            shifts.append(shift)
        }
        return compose(images, shifts: shifts, top: top, bottom: bottom, maxHeight: maxHeight)
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

    /// The columns that change from one picture to the next, with a little
    /// room either side. Nil when nothing changes.
    static func movingColumns(_ grays: [Gray]) -> Range<Int>? {
        guard let first = grays.first else { return nil }
        let rows = Array(stride(from: 0, to: first.height, by: 4))
        func moves(_ x: Int) -> Bool {
            zip(grays, grays.dropFirst()).contains { a, b in
                var sum = 0
                for y in rows { sum += abs(Int(a.pixels[y * a.width + x]) - Int(b.pixels[y * b.width + x])) }
                return sum > rows.count * 3 / 2
            }
        }
        guard let left = (0..<first.width).first(where: moves),
              let right = (0..<first.width).last(where: moves) else { return nil }
        let room = 12
        return max(0, left - room)..<min(first.width, right + 1 + room)
    }

    /// Rows at the top and at the bottom that are the same in every picture.
    ///
    /// Nearly the same: a title bar over scrolled content lets it show
    /// through faintly, and shades a little darker or lighter as its window
    /// comes and goes from the front.
    static func fixedEdges(_ grays: [Gray]) -> (top: Int, bottom: Int) {
        guard let first = grays.first else { return (0, 0) }
        let height = first.height
        func same(_ y: Int) -> Bool {
            zip(grays, grays.dropFirst()).allSatisfy { $0.difference(row: y, from: $1, row: y) < 4 }
        }
        var top = 0
        while top < height / 2, same(top) { top += 1 }
        var bottom = 0
        while bottom < height / 2 - 1, same(height - 1 - bottom) { bottom += 1 }
        return (top, bottom)
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

    private typealias Slice = (image: CGImage, rows: Range<Int>)

    private static func compose(_ images: [CGImage], shifts: [Int], top: Int, bottom: Int,
                                maxHeight: Int) -> [CGImage]? {
        let height = images[0].height
        let middle = height - top - bottom
        // What each picture adds, as rows of it: all of the first above the
        // footer, then only what came into view at the bottom.
        var slices: [Slice] = [(images[0], 0..<(top + middle))]
        for (image, shift) in zip(images.dropFirst(), shifts) {
            slices.append((image, (top + middle - shift)..<(top + middle)))
        }

        // Grouped into parts no taller than the limit. A part after the
        // first starts with the header again, so each reads on its own.
        var groups: [[Slice]] = [[]]
        var groupHeight = 0
        for slice in slices {
            if !groups[groups.count - 1].isEmpty, groupHeight + slice.rows.count + top + bottom > maxHeight {
                groups.append([(slice.image, 0..<top)])
                groupHeight = top
            }
            groups[groups.count - 1].append(slice)
            groupHeight += slice.rows.count
        }
        groups[groups.count - 1].append((images[images.count - 1], (height - bottom)..<height))

        var parts: [CGImage] = []
        for group in groups {
            guard let part = draw(group) else { return nil }
            parts.append(part)
        }
        return parts
    }

    private static func draw(_ slices: [Slice]) -> CGImage? {
        guard let first = slices.first?.image else { return nil }
        let width = first.width
        let total = slices.reduce(0) { $0 + $1.rows.count }
        guard let context = CGContext(data: nil, width: width, height: total, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: first.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
                                          ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        var y = total
        for slice in slices where !slice.rows.isEmpty {
            guard let cut = slice.image.cropping(to: CGRect(x: 0, y: slice.rows.lowerBound,
                                                            width: width, height: slice.rows.count)) else { return nil }
            y -= slice.rows.count
            context.draw(cut, in: CGRect(x: 0, y: y, width: width, height: slice.rows.count))
        }
        return context.makeImage()
    }
}
