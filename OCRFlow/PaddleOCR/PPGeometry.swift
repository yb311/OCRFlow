import Foundation
import CoreGraphics

// MARK: - Rotated rectangle

/// Minimum-area rotated rectangle, expressed by its centre and two orthonormal axes.
///
/// Working with explicit axes instead of an angle avoids the sign/quadrant
/// conventions of `cv2.minAreaRect`, which are irrelevant to the DB
/// post-processing: everything downstream only needs the four corners and the
/// length of the shorter side.
struct PPRotatedRect {
    var center: CGPoint
    /// Extent along `axisU` (`width`) and `axisV` (`height`).
    var size: CGSize
    var axisU: CGPoint
    var axisV: CGPoint

    var minSide: CGFloat { min(size.width, size.height) }

    var corners: [CGPoint] {
        let hu = size.width / 2, hv = size.height / 2
        let du = CGPoint(x: axisU.x * hu, y: axisU.y * hu)
        let dv = CGPoint(x: axisV.x * hv, y: axisV.y * hv)
        return [
            CGPoint(x: center.x - du.x - dv.x, y: center.y - du.y - dv.y),
            CGPoint(x: center.x + du.x - dv.x, y: center.y + du.y - dv.y),
            CGPoint(x: center.x + du.x + dv.x, y: center.y + du.y + dv.y),
            CGPoint(x: center.x - du.x + dv.x, y: center.y - du.y + dv.y),
        ]
    }

    /// Grows the rectangle by `distance` on every side.
    ///
    /// PaddleOCR runs the mini-box through a `pyclipper` round-join offset and
    /// takes `minAreaRect` of the result; for a rectangle that is exactly this
    /// expansion, up to `pyclipper`'s integer quantisation of the input path.
    func expanded(by distance: CGFloat) -> PPRotatedRect {
        PPRotatedRect(center: center,
                      size: CGSize(width: size.width + 2 * distance,
                                   height: size.height + 2 * distance),
                      axisU: axisU, axisV: axisV)
    }
}

enum PPGeometry {

    // MARK: - Convex hull

    /// Andrew's monotone chain. Returns the hull in counter-clockwise order
    /// (in a y-down image space) without repeating the first point.
    static func convexHull(_ points: [CGPoint]) -> [CGPoint] {
        guard points.count > 2 else { return points }
        let pts = points.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }

        func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }

        var lower: [CGPoint] = []
        for p in pts {
            while lower.count >= 2, cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 {
                lower.removeLast()
            }
            lower.append(p)
        }
        var upper: [CGPoint] = []
        for p in pts.reversed() {
            while upper.count >= 2, cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 {
                upper.removeLast()
            }
            upper.append(p)
        }
        lower.removeLast()
        upper.removeLast()
        return lower + upper
    }

    // MARK: - Minimum-area rectangle

    /// Rotating calipers: the minimum-area enclosing rectangle always has one
    /// side flush with a hull edge, so it is enough to test every edge.
    static func minAreaRect(_ points: [CGPoint]) -> PPRotatedRect? {
        guard !points.isEmpty else { return nil }
        let hull = convexHull(points)
        guard hull.count >= 2 else {
            let p = hull.first ?? points[0]
            return PPRotatedRect(center: p, size: .zero,
                                 axisU: CGPoint(x: 1, y: 0), axisV: CGPoint(x: 0, y: 1))
        }

        var best: PPRotatedRect?
        var bestArea = CGFloat.greatestFiniteMagnitude

        for i in 0..<hull.count {
            let a = hull[i], b = hull[(i + 1) % hull.count]
            let ex = b.x - a.x, ey = b.y - a.y
            let len = (ex * ex + ey * ey).squareRoot()
            guard len > 1e-9 else { continue }
            let ux = ex / len, uy = ey / len          // edge direction
            let vx = -uy, vy = ux                     // normal

            var minU = CGFloat.greatestFiniteMagnitude, maxU = -CGFloat.greatestFiniteMagnitude
            var minV = CGFloat.greatestFiniteMagnitude, maxV = -CGFloat.greatestFiniteMagnitude
            for p in hull {
                let du = p.x * ux + p.y * uy
                let dv = p.x * vx + p.y * vy
                minU = min(minU, du); maxU = max(maxU, du)
                minV = min(minV, dv); maxV = max(maxV, dv)
            }
            let w = maxU - minU, h = maxV - minV
            let area = w * h
            if area < bestArea {
                bestArea = area
                let cu = (minU + maxU) / 2, cv = (minV + maxV) / 2
                best = PPRotatedRect(
                    center: CGPoint(x: ux * cu + vx * cv, y: uy * cu + vy * cv),
                    size: CGSize(width: w, height: h),
                    axisU: CGPoint(x: ux, y: uy),
                    axisV: CGPoint(x: vx, y: vy))
            }
        }
        return best
    }

    // MARK: - Corner ordering

    /// Port of PaddleOCR's `DBPostProcess.get_mini_boxes` corner ordering:
    /// sort by x, then pick top-left / top-right / bottom-right / bottom-left.
    static func orderMiniBox(_ corners: [CGPoint]) -> [CGPoint] {
        precondition(corners.count == 4)
        let p = corners.sorted { $0.x < $1.x }
        let i1: Int, i4: Int, i2: Int, i3: Int
        if p[1].y > p[0].y { i1 = 0; i4 = 1 } else { i1 = 1; i4 = 0 }
        if p[3].y > p[2].y { i2 = 2; i3 = 3 } else { i2 = 3; i3 = 2 }
        return [p[i1], p[i2], p[i3], p[i4]]
    }

    /// Port of `predict_det.order_points_clockwise`: the corner with the
    /// smallest x+y is top-left, the largest is bottom-right, and the remaining
    /// two are split by y-x.
    static func orderClockwise(_ pts: [CGPoint]) -> [CGPoint] {
        precondition(pts.count == 4)
        let sums = pts.map { $0.x + $0.y }
        var tlIdx = 0, brIdx = 0
        for i in 1..<4 {
            if sums[i] < sums[tlIdx] { tlIdx = i }
            if sums[i] > sums[brIdx] { brIdx = i }
        }
        let rest = pts.indices.filter { $0 != tlIdx && $0 != brIdx }.map { pts[$0] }
        guard rest.count == 2 else { return pts }
        let d0 = rest[0].y - rest[0].x, d1 = rest[1].y - rest[1].x
        let tr = d0 <= d1 ? rest[0] : rest[1]
        let bl = d0 <= d1 ? rest[1] : rest[0]
        return [pts[tlIdx], tr, pts[brIdx], bl]
    }

    // MARK: - Polygon measures

    static func polygonArea(_ pts: [CGPoint]) -> CGFloat {
        guard pts.count >= 3 else { return 0 }
        var sum: CGFloat = 0
        for i in 0..<pts.count {
            let a = pts[i], b = pts[(i + 1) % pts.count]
            sum += a.x * b.y - b.x * a.y
        }
        return abs(sum) / 2
    }

    static func polygonPerimeter(_ pts: [CGPoint]) -> CGFloat {
        guard pts.count >= 2 else { return 0 }
        var sum: CGFloat = 0
        for i in 0..<pts.count {
            let a = pts[i], b = pts[(i + 1) % pts.count]
            sum += hypot(b.x - a.x, b.y - a.y)
        }
        return sum
    }

    static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(b.x - a.x, b.y - a.y)
    }
}
