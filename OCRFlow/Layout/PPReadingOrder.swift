import Foundation
import CoreGraphics

/// Recursive XY-cut: puts a page's boxes into the order a person reads them.
///
/// The projection is cut on **columns first**, then on horizontal bands. That
/// order is what makes multi-column pages come out right: a newspaper's gutter
/// runs the full height of the page, so it is found before any paragraph gap,
/// and each column is then read top to bottom on its own. Cutting bands first
/// — the usual textbook formulation — interleaves the columns whenever their
/// paragraph gaps happen to line up, which on a body text set to one baseline
/// grid is most of the time.
///
/// A heading that spans the columns keeps the column cut from firing at the top
/// level (no clean vertical gap crosses it), so the page is cut into bands
/// there instead and the columns are found inside the band below it — which is
/// exactly the reading order a person would use.
///
/// Distances are measured in `unit`: the median box height, i.e. roughly one
/// line of text. Thresholds expressed that way hold for a phone screenshot and
/// for a 300 dpi broadsheet alike.
enum PPXYCut {

    /// Indices into `rects`, in reading order.
    static func order(_ rects: [CGRect]) -> [Int] {
        guard rects.count > 1 else { return Array(rects.indices) }
        let heights = rects.map(\.height).filter { $0 > 0 }.sorted()
        guard let unit = heights.isEmpty ? nil : heights[heights.count / 2], unit > 0 else {
            return Array(rects.indices)
        }
        return cut(Array(rects.indices), rects: rects, unit: unit, depth: 0)
    }

    /// A column gutter has to be about a line's worth of whitespace running the
    /// full height of the group; anything narrower is word spacing.
    private static let columnGap: CGFloat = 1.0
    /// Bands are separated by much less — the leading between two paragraphs,
    /// or simply the gap between two lines.
    private static let bandGap: CGFloat = 0.35
    /// Deep recursion means the thresholds are chopping single boxes apart;
    /// stop and fall back rather than spend the time.
    private static let maxDepth = 24

    private static func cut(_ items: [Int], rects: [CGRect], unit: CGFloat, depth: Int) -> [Int] {
        guard items.count > 1, depth < maxDepth else { return items }

        // Columns first — see the type comment.
        if let columns = split(items, rects: rects, vertical: true, minGap: unit * columnGap),
           areColumns(columns, rects: rects) {
            return cut(columns.first, rects: rects, unit: unit, depth: depth + 1)
                 + cut(columns.second, rects: rects, unit: unit, depth: depth + 1)
        }
        if let bands = split(items, rects: rects, vertical: false, minGap: unit * bandGap) {
            return cut(bands.first, rects: rects, unit: unit, depth: depth + 1)
                 + cut(bands.second, rects: rects, unit: unit, depth: depth + 1)
        }
        return fallbackOrder(items, rects: rects, unit: unit)
    }

    /// Splits the boxes in two at the **widest** strip of whitespace along x
    /// (`vertical: true`, i.e. a column gutter) or along y (a band). Returns
    /// nil when the widest one is still narrower than `minGap`, i.e. there is
    /// nothing worth cutting on this axis.
    ///
    /// Cutting only at the widest valley — rather than at every gap that clears
    /// the threshold — is what keeps a page with a headline over two columns in
    /// order. Every line gap in the body also clears the band threshold, so
    /// cutting on all of them would slice the page into rows and read the
    /// columns across each row, which is the very thing this is here to avoid.
    /// The widest gap is the one under the headline; the columns below it are
    /// then found by the recursion.
    private static func split(_ items: [Int], rects: [CGRect],
                              vertical: Bool, minGap: CGFloat) -> (first: [Int], second: [Int])? {
        func interval(_ index: Int) -> (lo: CGFloat, hi: CGFloat) {
            let rect = rects[index]
            return vertical ? (rect.minX, rect.maxX) : (rect.minY, rect.maxY)
        }

        let sorted = items.sorted { interval($0).lo < interval($1).lo }
        var reach = interval(sorted[0]).hi
        var widest: (gap: CGFloat, position: Int)?

        for position in 1..<sorted.count {
            let span = interval(sorted[position])
            let gap = span.lo - reach
            if gap > (widest?.gap ?? minGap) { widest = (gap, position) }
            reach = max(reach, span.hi)
        }

        guard let widest, widest.gap >= minGap else { return nil }
        return (Array(sorted[..<widest.position]), Array(sorted[widest.position...]))
    }

    /// True when both sides of a vertical cut run far enough down the page to be
    /// columns.
    ///
    /// A gutter is not the only vertical whitespace on a page: a page number in
    /// a corner, or a right-aligned formula number, also has clear air beside
    /// it. Splitting on those would move them to the end of the document, past
    /// everything they sit next to. A column, unlike a corner label, occupies a
    /// good share of the height of the region it was cut out of.
    private static let minColumnShare: CGFloat = 0.25

    private static func areColumns(_ groups: (first: [Int], second: [Int]), rects: [CGRect]) -> Bool {
        func extent(_ indices: [Int]) -> (lo: CGFloat, hi: CGFloat)? {
            guard let lo = indices.map({ rects[$0].minY }).min(),
                  let hi = indices.map({ rects[$0].maxY }).max() else { return nil }
            return (lo, hi)
        }
        guard let a = extent(groups.first), let b = extent(groups.second) else { return false }
        let union = max(a.hi, b.hi) - min(a.lo, b.lo)
        guard union > 0 else { return true }
        return min(a.hi - a.lo, b.hi - b.lo) >= union * minColumnShare
    }

    /// Nothing separates these boxes cleanly: read top to bottom, left to right,
    /// with a tolerance so a slightly ragged row stays one row.
    private static func fallbackOrder(_ items: [Int], rects: [CGRect], unit: CGFloat) -> [Int] {
        items.sorted { a, b in
            let tolerance = unit * 0.5
            if abs(rects[a].minY - rects[b].minY) > tolerance { return rects[a].minY < rects[b].minY }
            if rects[a].minX != rects[b].minX { return rects[a].minX < rects[b].minX }
            return a < b
        }
    }
}

/// Puts layout blocks into the order a person would read them.
///
/// PP-DocLayoutV3 predicts reading order itself — the seventh column of each
/// detection is a sort key on the query axis — and that is what gets used. It
/// beats geometry on the cases that matter: on PaddleOCR's own reference page
/// it places a figure's caption immediately after the figure, where a purely
/// spatial ordering drops it into the middle of an unrelated column.
///
/// `PPXYCut` is the fallback for when the model gives degenerate keys. It is
/// deterministic and has handled multi-column pages for decades, so a page
/// still comes out readable even if the model's key is unusable.
enum PPReadingOrder {

    static func sort(_ blocks: [PPLayoutBlock], modelKeys: [Float]) -> [PPLayoutBlock] {
        guard blocks.count > 1 else { return numbered(blocks) }

        // Ties mean the key carries no ordering information for those blocks,
        // so only trust it when it separates every block.
        let usable = modelKeys.count == blocks.count && Set(modelKeys).count == blocks.count
        guard usable else {
            return numbered(PPXYCut.order(blocks.map(\.rect)).map { blocks[$0] })
        }

        let ordered = zip(blocks, modelKeys)
            .sorted { $0.1 < $1.1 }
            .map(\.0)
        return numbered(ordered)
    }

    private static func numbered(_ blocks: [PPLayoutBlock]) -> [PPLayoutBlock] {
        blocks.enumerated().map { index, block in
            var block = block
            block.readingOrder = index
            return block
        }
    }
}
