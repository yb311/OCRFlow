import Foundation
import CoreGraphics

/// Differentiable-Binarization text detection, mirroring PaddleOCR's
/// `DetResizeForTest` → model → `DBPostProcess` → `filter_tag_det_res` chain.
struct PPDetector {
    let session: PPSession

    private static let mean: (Float, Float, Float) = (0.485, 0.456, 0.406)
    private static let std: (Float, Float, Float) = (0.229, 0.224, 0.225)

    /// Returns text quads in source-image coordinates, in reading order.
    func detect(_ image: PPImageBuffer, config: PPOCRConfig) throws -> [[CGPoint]] {
        let (resized, mapW, mapH) = Self.resizeForDetection(image, limitSideLen: config.detLimitSideLen)

        var tensor = [Float](repeating: 0, count: 3 * mapH * mapW)
        resized.writeNormalizedCHW(into: &tensor, offset: 0, mean: Self.mean, std: Self.std)

        let (values, shape) = try session.run(input: tensor, shape: [1, 3, mapH, mapW])
        guard shape.count == 4, shape[0] == 1, shape[1] == 1 else {
            throw PPOCRError.unexpectedOutputShape("检测模型输出维度 \(shape)")
        }
        let probH = shape[2], probW = shape[3]
        guard values.count >= probH * probW else {
            throw PPOCRError.unexpectedOutputShape("检测概率图数据不足")
        }

        let thresh = Float(config.detThresh)
        var mask = [Bool](repeating: false, count: probH * probW)
        for i in 0..<(probH * probW) { mask[i] = values[i] > thresh }

        let components = PPConnectedComponents.componentHullCandidates(
            mask: mask, width: probW, height: probH, limit: config.detMaxCandidates)

        let minSide = CGFloat(config.detMinSize)
        var quads: [[CGPoint]] = []

        for points in components {
            guard let rect = PPGeometry.minAreaRect(points), rect.minSide >= minSide else { continue }

            let miniBox = PPGeometry.orderMiniBox(rect.corners)
            let score = Self.boxScore(prob: values, width: probW, height: probH, quad: miniBox)
            guard score >= config.detBoxThresh else { continue }

            // PaddleOCR grows the box by area * ratio / perimeter, which for a
            // rectangle works out to a uniform outset of that many pixels.
            let area = PPGeometry.polygonArea(miniBox)
            let perimeter = PPGeometry.polygonPerimeter(miniBox)
            guard perimeter > 0 else { continue }
            let distance = area * CGFloat(config.detUnclipRatio) / perimeter

            let grown = rect.expanded(by: distance)
            guard grown.minSide >= minSide + 2 else { continue }

            let srcW = CGFloat(image.width), srcH = CGFloat(image.height)
            let quad = PPGeometry.orderMiniBox(grown.corners).map { p in
                CGPoint(x: min(max((p.x / CGFloat(probW) * srcW).rounded(), 0), srcW),
                        y: min(max((p.y / CGFloat(probH) * srcH).rounded(), 0), srcH))
            }
            quads.append(quad)
        }

        return Self.sortInReadingOrder(Self.filter(quads, width: image.width, height: image.height))
    }

    // MARK: - Preprocessing

    /// `DetResizeForTest(resize_long: N)`: scale the long side down to at most
    /// `N`, then round both sides to a multiple of 32 for the FPN backbone.
    static func resizeForDetection(_ image: PPImageBuffer, limitSideLen: Int) -> (PPImageBuffer, Int, Int) {
        let h = Double(image.height), w = Double(image.width)
        let limit = Double(max(32, limitSideLen))
        let ratio = max(h, w) > limit ? limit / max(h, w) : 1.0
        // Python's round() is half-to-even; matching it keeps the output size
        // identical to the reference pipeline on exact .5 boundaries.
        func snap(_ v: Double) -> Int {
            max(Int((v / 32).rounded(.toNearestOrEven)) * 32, 32)
        }
        let rw = snap(Double(Int(w * ratio)))
        let rh = snap(Double(Int(h * ratio)))
        return (image.resized(toWidth: rw, height: rh), rw, rh)
    }

    // MARK: - Post-processing

    /// Mean probability inside the candidate box (`box_score_fast`).
    ///
    /// The mini box is always convex, so membership reduces to four half-plane
    /// tests instead of rasterising the polygon.
    static func boxScore(prob: [Float], width: Int, height: Int, quad: [CGPoint]) -> Double {
        let xs = quad.map(\.x), ys = quad.map(\.y)
        let xmin = Int(min(max(xs.min()!.rounded(.down), 0), CGFloat(width - 1)))
        let xmax = Int(min(max(xs.max()!.rounded(.up), 0), CGFloat(width - 1)))
        let ymin = Int(min(max(ys.min()!.rounded(.down), 0), CGFloat(height - 1)))
        let ymax = Int(min(max(ys.max()!.rounded(.up), 0), CGFloat(height - 1)))
        guard xmax >= xmin, ymax >= ymin else { return 0 }

        // Orientation of the quad decides the sign the inside test looks for.
        var signedArea: CGFloat = 0
        for i in 0..<4 {
            let a = quad[i], b = quad[(i + 1) % 4]
            signedArea += a.x * b.y - b.x * a.y
        }
        let positive = signedArea >= 0

        var sum: Double = 0
        var count = 0
        for y in ymin...ymax {
            let fy = CGFloat(y)
            for x in xmin...xmax {
                let fx = CGFloat(x)
                var inside = true
                for i in 0..<4 {
                    let a = quad[i], b = quad[(i + 1) % 4]
                    let cross = (b.x - a.x) * (fy - a.y) - (b.y - a.y) * (fx - a.x)
                    if positive ? (cross < 0) : (cross > 0) { inside = false; break }
                }
                if inside {
                    sum += Double(prob[y * width + x])
                    count += 1
                }
            }
        }
        return count > 0 ? sum / Double(count) : 0
    }

    /// `filter_tag_det_res`: normalise corner order, clip into the image and
    /// drop degenerate boxes.
    static func filter(_ quads: [[CGPoint]], width: Int, height: Int) -> [[CGPoint]] {
        let maxX = CGFloat(width - 1), maxY = CGFloat(height - 1)
        var out: [[CGPoint]] = []
        for quad in quads {
            let ordered = PPGeometry.orderClockwise(quad).map {
                CGPoint(x: min(max($0.x, 0), maxX), y: min(max($0.y, 0), maxY))
            }
            let w = Int(PPGeometry.distance(ordered[0], ordered[1]))
            let h = Int(PPGeometry.distance(ordered[0], ordered[3]))
            guard w > 3, h > 3 else { continue }
            out.append(ordered)
        }
        return out
    }

    /// `sorted_boxes`: top-to-bottom, then left-to-right within a ~10px band.
    static func sortInReadingOrder(_ quads: [[CGPoint]]) -> [[CGPoint]] {
        // Swift's sort is not stable, while PaddleOCR relies on Python's stable
        // `sorted`; carrying the original index as a tiebreaker reproduces it
        // and keeps the output order reproducible run to run.
        var boxes = quads.enumerated().sorted { a, b in
            if a.element[0].y != b.element[0].y { return a.element[0].y < b.element[0].y }
            if a.element[0].x != b.element[0].x { return a.element[0].x < b.element[0].x }
            return a.offset < b.offset
        }.map(\.element)
        guard boxes.count > 1 else { return boxes }
        for i in 0..<(boxes.count - 1) {
            var j = i
            while j >= 0 {
                if abs(boxes[j + 1][0].y - boxes[j][0].y) < 10, boxes[j + 1][0].x < boxes[j][0].x {
                    boxes.swapAt(j, j + 1)
                    j -= 1
                } else {
                    break
                }
            }
        }
        return boxes
    }
}
