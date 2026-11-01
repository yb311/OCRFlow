import CoreGraphics
import Foundation

/// Joins a view into one long picture as it scrolls, frame by frame, while
/// the frames come in.
///
/// Each frame is matched only against the last one taken in, and only the
/// rows that came into view are kept — copied out, so the frames themselves
/// can go: what is held is about the size of the finished picture. Frames
/// that do not carry on from the last — scrolled back, or too far at once —
/// are passed over until one does.
///
/// Not tied to any thread; used from one queue at a time.
final class LiveStitcher: @unchecked Sendable {
    enum Outcome: Equatable {
        case grew(by: Int)
        case unchanged
        /// Does not carry on from the last taken in.
        case lost
    }

    /// Width, in pixels, of the picture shown while it grows; nil when none
    /// is shown.
    let previewWidth: Int?

    private var first: CGImage?
    private var firstGray: ScrollStitcher.Gray?
    /// The bar at the bottom that stays put, as it was last.
    private var foot: CGImage?
    private var lastGray: ScrollStitcher.Gray?
    private var lastShift: Int?
    /// The rows at the top and bottom that stay put, once something moved.
    private var edges: (top: Int, bottom: Int)?
    /// What came into view, in order: rows copied out of the frames.
    private var slices: [CGImage] = []
    /// The same, small, for showing while it grows.
    private(set) var previewSlices: [CGImage] = []
    /// Rows at the bottom see-through at the sides: a window's rounded
    /// corners, which stay put as a bar at the bottom does.
    private var corners = 0
    private(set) var grown = 0
    /// Frames taken in.
    private(set) var taken = 0

    var width: Int { first?.width ?? 0 }
    var height: Int { first?.height ?? 0 }

    init(previewWidth: Int? = nil) {
        self.previewWidth = previewWidth
    }

    func add(_ frame: CGImage) -> Outcome {
        guard let first, let lastGray else {
            let copy = Self.copy(frame) ?? frame
            self.first = copy
            corners = Self.clearRowsAtBottom(frame)
            let gray = ScrollStitcher.Gray(copy)
            firstGray = gray
            lastGray = gray
            taken = 1
            return .grew(by: 0)
        }
        guard frame.width == first.width, frame.height == first.height else { return .lost }
        let gray = ScrollStitcher.Gray(frame)
        let edges = edges ?? (ScrollStitcher.sameRows(lastGray, gray, from: 0, by: 1, upTo: height / 2),
                              max(corners, ScrollStitcher.sameRows(lastGray, gray, from: height - 1, by: -1,
                                                                   upTo: height / 2 - 1)))
        // Close to the last distance first: cheap, and right nearly always.
        var shift: Int?
        if let lastShift {
            shift = ScrollStitcher.shift(from: lastGray, to: gray, top: edges.top, bottom: edges.bottom, near: lastShift,
                                         within: max(1, lastShift - 48)...(lastShift + 48))
        }
        if shift == nil {
            shift = ScrollStitcher.shift(from: lastGray, to: gray, top: edges.top, bottom: edges.bottom, near: lastShift)
        }
        guard let shift else {
            // Over the whole frame until the bars that stay put are known:
            // a change in place leaves the rows above and below it alike,
            // which would pass for such bars.
            let fixed = self.edges ?? (0, 0)
            guard ScrollStitcher.changedInPlace(from: lastGray, to: gray, top: fixed.top, bottom: fixed.bottom)
            else { return .lost }
            // Changed, not scrolled — its window came to the front, say, as
            // the capture began: carried on from as it looks now, and begun
            // from it while nothing has been joined.
            self.lastGray = gray
            if grown == 0, let copy = Self.copy(frame) {
                self.first = copy
                firstGray = gray
            }
            return .unchanged
        }
        guard shift > 0 else { return .unchanged }

        if self.edges == nil { self.edges = edges }
        let end = height - edges.bottom
        guard let slice = Self.copy(frame, rows: (end - shift)..<end) else { return .lost }
        slices.append(slice)
        if let previewWidth, let small = Self.scaled(slice, toWidth: previewWidth) { previewSlices.append(small) }
        grown += shift
        taken += 1
        if edges.bottom > 0 { foot = Self.copy(frame, rows: end..<height) }
        self.lastGray = gray
        lastShift = shift
        return .grew(by: shift)
    }

    /// The first frame, small, down to the bottom bar that stays put — what
    /// the rest is shown joined under.
    func previewHead() -> CGImage? {
        guard let first, let previewWidth else { return nil }
        let end = height - (edges?.bottom ?? 0)
        return Self.copy(first, rows: 0..<end).flatMap { Self.scaled($0, toWidth: previewWidth) }
    }

    /// The finished picture — in parts, each no taller than `maxHeight`,
    /// when it is very long — as wide as the frames: the user chose the
    /// area, and all of it is kept, whether or not each column changed as
    /// it scrolled (the first letters of lines that all begin alike do not).
    func finish(maxHeight: Int = ScrollStitcher.maxHeight) -> [CGImage] {
        guard let first else { return [] }
        let edges = edges ?? (0, 0)
        let end = height - edges.bottom
        var pieces: [CGImage] = []
        if let head = Self.copy(first, rows: 0..<end) { pieces.append(head) }
        pieces += slices
        if edges.bottom > 0, let foot = foot ?? Self.copy(first, rows: end..<height) { pieces.append(foot) }

        // Into parts; each after the first starts with the header again.
        var parts: [[CGImage]] = [[]]
        var partHeight = 0
        let header = edges.top > 0 ? Self.copy(first, rows: 0..<edges.top) : nil
        for piece in pieces {
            if partHeight > 0, partHeight + piece.height > maxHeight {
                parts.append(header.map { [$0] } ?? [])
                partHeight = header?.height ?? 0
            }
            parts[parts.count - 1].append(piece)
            partHeight += piece.height
        }
        return parts.compactMap { Self.stack($0) }
    }

    // MARK: - Pictures

    /// How many rows at the bottom are see-through at either side. Joined
    /// on from there, every strip would bring a window's rounded corners
    /// with it, a dark notch down both sides.
    static func clearRowsAtBottom(_ image: CGImage) -> Int {
        let width = image.width, rows = min(64, image.height / 4)
        guard rows > 0, let bottom = image.cropping(to: CGRect(x: 0, y: image.height - rows, width: width, height: rows))
        else { return 0 }
        guard let context = context(width: width, height: rows, like: image) else { return 0 }
        context.draw(bottom, in: CGRect(x: 0, y: 0, width: width, height: rows))
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return 0 }
        // From the bottom up; the first row in memory is the top. Alpha is
        // each pixel's last byte.
        func alpha(_ x: Int, _ y: Int) -> UInt8 { data[y * context.bytesPerRow + x * 4 + 3] }
        var count = 0
        for y in (0..<rows).reversed() {
            guard alpha(0, y) < 250 || alpha(width - 1, y) < 250 else { break }
            count += 1
        }
        return count
    }

    /// Its own pixels, apart from the frame they came from — whose buffer
    /// the capture wants back.
    static func copy(_ image: CGImage, rows: Range<Int>? = nil) -> CGImage? {
        let rows = rows ?? 0..<image.height
        guard !rows.isEmpty, let context = context(width: image.width, height: rows.count, like: image) else { return nil }
        // Drawn so that `rows` fill the context.
        context.draw(image, in: CGRect(x: 0, y: rows.upperBound - image.height, width: image.width, height: image.height))
        return context.makeImage()
    }

    static func scaled(_ image: CGImage, toWidth width: Int) -> CGImage? {
        let height = max(1, Int((Double(image.height) * Double(width) / Double(image.width)).rounded()))
        guard let context = context(width: width, height: height, like: image) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// One under another, top first, cut to `columns`.
    static func stack(_ images: [CGImage], columns: Range<Int>? = nil) -> CGImage? {
        guard let first = images.first else { return nil }
        let columns = columns ?? 0..<first.width
        let total = images.reduce(0) { $0 + $1.height }
        guard let context = context(width: columns.count, height: total, like: first) else { return nil }
        var y = total
        for image in images {
            y -= image.height
            context.draw(image, in: CGRect(x: -columns.lowerBound, y: y, width: image.width, height: image.height))
        }
        return context.makeImage()
    }

    private static func context(width: Int, height: Int, like image: CGImage) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
                      ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }
}
