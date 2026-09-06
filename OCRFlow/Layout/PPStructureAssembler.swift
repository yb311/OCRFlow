import Foundation
import CoreGraphics

/// Puts recognised text lines into the structure the layout model found.
///
/// This is how PaddleOCR's own document pipeline decides reading order, and it
/// is the reason the official demo reads a newspaper correctly while a purely
/// geometric ordering does not. The order is a *model prediction*, not a guess
/// made from where the boxes happen to sit: PP-DocLayoutV3 detects the regions
/// of a page — columns, headings, figures, captions — and emits a reading-order
/// key alongside each one. Text lines are then poured into those regions.
///
/// The alternative — inferring columns from whitespace between text lines —
/// needs a new rule for every page that breaks it: a byline under the masthead,
/// a right-aligned formula number, a two-line caption beside a photo. The
/// regions remove the guesswork, because the model was trained on exactly those
/// layouts.
enum PPStructureAssembler {

    struct Page {
        /// Every recognised line, in reading order.
        var lines: [PPTextLine] = []
        /// The regions the layout model found, in reading order, each carrying
        /// the text of the lines that fell inside it.
        var blocks: [PPLayoutBlock] = []
    }

    /// A line belongs to a region when most of it is inside that region.
    private static let claimThreshold: CGFloat = 0.5

    /// Assigns `lines` to `blocks` and returns both in reading order.
    ///
    /// `blocks` must already be in the model's reading order — `PPLayoutDetector`
    /// sorts them on the way out.
    static func assemble(lines: [PPTextLine], blocks: [PPLayoutBlock]) -> Page {
        guard !blocks.isEmpty else {
            return Page(lines: lines, blocks: [])
        }
        guard !lines.isEmpty else {
            return Page(lines: [], blocks: blocks)
        }

        let unit = medianHeight(of: lines)
        var buckets = [[Int]](repeating: [], count: blocks.count)
        var orphans: [Int] = []

        for (index, line) in lines.enumerated() {
            if let owner = owningBlock(of: line.boundingBox, in: blocks) {
                buckets[owner].append(index)
            } else {
                orphans.append(index)
            }
        }

        // A line the layout model did not cover still has to be read. Attaching
        // it to the region it sits closest to keeps it in the flow instead of
        // dropping it or piling every stray line up at the end of the page.
        for index in orphans {
            guard let nearest = nearestBlock(to: lines[index].boundingBox, in: blocks) else { continue }
            buckets[nearest].append(index)
        }

        var ordered: [PPTextLine] = []
        ordered.reserveCapacity(lines.count)
        var filled: [PPLayoutBlock] = []
        filled.reserveCapacity(blocks.count)

        for (blockIndex, block) in blocks.enumerated() {
            let inside = sortWithinRegion(buckets[blockIndex], lines: lines, unit: unit)
            var block = block
            block.text = inside
                .map { lines[$0].text }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            filled.append(block)
            ordered.append(contentsOf: inside.map { lines[$0] })
        }

        return Page(lines: ordered, blocks: filled)
    }

    // MARK: - Assignment

    /// The most specific region that contains most of `rect`.
    ///
    /// Regions nest — a table sits inside no region, but a figure caption often
    /// overlaps the figure's own box — so the smallest qualifying region wins.
    private static func owningBlock(of rect: CGRect, in blocks: [PPLayoutBlock]) -> Int? {
        let area = rect.width * rect.height
        guard area > 0 else { return nil }

        var best: (index: Int, area: CGFloat)?
        for (index, block) in blocks.enumerated() {
            let overlap = block.rect.intersection(rect)
            guard !overlap.isNull else { continue }
            guard (overlap.width * overlap.height) / area >= claimThreshold else { continue }
            let blockArea = block.rect.width * block.rect.height
            if best == nil || blockArea < best!.area {
                best = (index, blockArea)
            }
        }
        return best?.index
    }

    private static func nearestBlock(to rect: CGRect, in blocks: [PPLayoutBlock]) -> Int? {
        var best: (index: Int, distance: CGFloat)?
        for (index, block) in blocks.enumerated() {
            let distance = squaredDistance(from: rect, to: block.rect)
            if best == nil || distance < best!.distance {
                best = (index, distance)
            }
        }
        return best?.index
    }

    /// Squared distance between two rectangles, zero when they overlap.
    private static func squaredDistance(from a: CGRect, to b: CGRect) -> CGFloat {
        let dx = max(0, max(b.minX - a.maxX, a.minX - b.maxX))
        let dy = max(0, max(b.minY - a.maxY, a.minY - b.maxY))
        return dx * dx + dy * dy
    }

    // MARK: - Ordering inside one region

    /// PaddleOCR's `sorted_boxes` within the region: top to bottom, and left to
    /// right for anything sharing a line. Inside a single column that is the
    /// right answer and needs no cleverness — the cleverness was only ever
    /// needed because the whole page was being sorted at once.
    ///
    /// The band tolerance is a fraction of the line height rather than
    /// PaddleOCR's fixed 10 px, so it behaves the same on a phone screenshot
    /// and on a 300 dpi scan.
    private static func sortWithinRegion(_ indices: [Int], lines: [PPTextLine],
                                         unit: CGFloat) -> [Int] {
        guard indices.count > 1 else { return indices }
        let tolerance = max(unit * 0.5, 1)
        return indices.sorted { a, b in
            let boxA = lines[a].boundingBox, boxB = lines[b].boundingBox
            if abs(boxA.minY - boxB.minY) > tolerance { return boxA.minY < boxB.minY }
            if boxA.minX != boxB.minX { return boxA.minX < boxB.minX }
            return a < b
        }
    }

    private static func medianHeight(of lines: [PPTextLine]) -> CGFloat {
        let heights = lines.map(\.boundingBox.height).filter { $0 > 0 }.sorted()
        guard !heights.isEmpty else { return 1 }
        return heights[heights.count / 2]
    }
}
