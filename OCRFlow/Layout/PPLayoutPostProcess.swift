import Foundation
import CoreGraphics

/// Cleans up what the layout model reports before anything is read out of it.
///
/// PP-DocLayoutV3 is a detector: it answers with every region it believes in,
/// and those regions overlap. A paragraph containing `$k \geq 2$` produces both
/// a `text` box for the paragraph and an `inline_formula` box for the fragment
/// inside it; a column edge produces slivers that clip words in half. Handing
/// each of those to the VLM separately is how one page turns into fifty blocks
/// where the reference pipeline produces thirty-seven — the extra thirteen
/// being the same formulas a second time, plus the slivers, which the model can
/// only guess at because it is shown half a word.
///
/// PaddleOCR's own pipeline runs the same two steps (`nms=True` by default, and
/// `merge_bboxes_mode: large` for the overlaps that survive it), which is why
/// its output does not have them.
enum PPLayoutPostProcess {

    /// Everything, in the order the caller should apply it.
    static func clean(_ blocks: [PPLayoutBlock],
                      keys: [Float],
                      nmsThreshold: Double = 0.5,
                      containmentThreshold: Double = 0.8) -> (blocks: [PPLayoutBlock], keys: [Float]) {
        var kept = Array(blocks.indices)
        kept = survivingNMS(kept, blocks: blocks, threshold: nmsThreshold)
        kept = survivingContainment(kept, blocks: blocks, threshold: containmentThreshold)
        let order = Set(kept)
        // The reading-order keys are positional, so they have to be filtered in
        // step with the blocks rather than re-derived.
        let indices = blocks.indices.filter(order.contains)
        return (indices.map { blocks[$0] },
                indices.compactMap { keys.indices.contains($0) ? keys[$0] : nil })
    }

    // MARK: - Non-maximum suppression

    /// Drops the lower-scoring of two boxes of the same class that describe the
    /// same region.
    static func survivingNMS(_ candidates: [Int], blocks: [PPLayoutBlock],
                             threshold: Double) -> [Int] {
        let byScore = candidates.sorted { blocks[$0].score > blocks[$1].score }
        var kept: [Int] = []
        for index in byScore {
            let box = blocks[index].rect
            let label = blocks[index].label
            let duplicate = kept.contains { other in
                blocks[other].label == label
                    && intersectionOverUnion(box, blocks[other].rect) > threshold
            }
            if !duplicate { kept.append(index) }
        }
        return kept
    }

    // MARK: - Containment

    /// Drops a region that sits inside a larger one.
    ///
    /// The larger region's own recognition already covers it: asked to read a
    /// paragraph, the VLM returns the inline formulas in it as `$…$`, so
    /// reading the formula's box again only duplicates them.
    ///
    /// Regions that need a prompt of their own survive regardless — a table
    /// inside a figure is still a table, and no amount of reading the figure
    /// will produce its HTML.
    static func survivingContainment(_ candidates: [Int], blocks: [PPLayoutBlock],
                                     threshold: Double) -> [Int] {
        candidates.filter { index in
            let block = blocks[index]
            if block.label.survivesContainment { return true }
            let area = block.rect.width * block.rect.height
            guard area > 0 else { return false }

            return !candidates.contains { other in
                guard other != index else { return false }
                let container = blocks[other]
                guard container.rect.width * container.rect.height > area else { return false }
                let overlap = container.rect.intersection(block.rect)
                guard !overlap.isNull else { return false }
                return (overlap.width * overlap.height) / area >= threshold
            }
        }
    }

    // MARK: - Cropping

    /// Grows a region before it is cropped out of the page.
    ///
    /// A box that hugs the glyphs clips their edges, and a model shown a
    /// clipped word drops it. PaddleOCR exposes the same knob as
    /// `unclip_ratio`.
    static func expanded(_ rect: CGRect, ratio: CGFloat, within bounds: CGSize) -> CGRect {
        guard ratio > 1 else { return rect }
        let dx = rect.width * (ratio - 1) / 2
        let dy = rect.height * (ratio - 1) / 2
        return rect.insetBy(dx: -dx, dy: -dy)
            .intersection(CGRect(origin: .zero, size: bounds))
    }

    // MARK: - Geometry

    static func intersectionOverUnion(_ a: CGRect, _ b: CGRect) -> Double {
        let overlap = a.intersection(b)
        guard !overlap.isNull else { return 0 }
        let intersection = Double(overlap.width * overlap.height)
        let union = Double(a.width * a.height + b.width * b.height) - intersection
        return union > 0 ? intersection / union : 0
    }
}

extension PPLayoutLabel {
    /// True when a region has to be read on its own even if it sits inside
    /// another: its content is not something the enclosing region's prompt
    /// would ever produce.
    var survivesContainment: Bool {
        switch self {
        case .table, .chart, .image, .headerImage, .footerImage, .seal, .displayFormula:
            return true
        default:
            return false
        }
    }
}
