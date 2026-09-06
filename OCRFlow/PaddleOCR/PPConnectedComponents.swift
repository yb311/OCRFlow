import Foundation
import CoreGraphics

/// Extracts the text regions of a binarised DB probability map.
///
/// PaddleOCR calls `cv2.findContours` here and then immediately reduces every
/// contour to `cv2.minAreaRect`. Since a component's minimum-area rectangle is
/// determined by its convex hull, and the hull of a component equals the hull
/// of its outer contour, labelling the components directly gives identical
/// boxes without porting a border-following algorithm.
///
/// Only the per-row extreme pixels are kept: an interior pixel can never be a
/// hull vertex, so this shrinks the point set fed to the hull from the whole
/// blob to at most two points per scanline.
enum PPConnectedComponents {

    /// Hull candidate points, one group per 8-connected component.
    static func componentHullCandidates(mask: [Bool], width: Int, height: Int,
                                        limit: Int) -> [[CGPoint]] {
        guard width > 0, height > 0, mask.count >= width * height else { return [] }

        var visited = [Bool](repeating: false, count: width * height)
        var groups: [[CGPoint]] = []
        var stack: [Int] = []
        // Row extents for the component currently being flooded, indexed by y.
        var rowMin = [Int](repeating: Int.max, count: height)
        var rowMax = [Int](repeating: Int.min, count: height)
        var touchedRows: [Int] = []

        mask.withUnsafeBufferPointer { m in
            for seed in 0..<(width * height) {
                guard m[seed], !visited[seed] else { continue }
                if groups.count >= limit { return }

                stack.removeAll(keepingCapacity: true)
                touchedRows.removeAll(keepingCapacity: true)
                stack.append(seed)
                visited[seed] = true

                while let idx = stack.popLast() {
                    let y = idx / width
                    let x = idx - y * width
                    if rowMin[y] == Int.max { touchedRows.append(y) }
                    if x < rowMin[y] { rowMin[y] = x }
                    if x > rowMax[y] { rowMax[y] = x }

                    let yLo = max(0, y - 1), yHi = min(height - 1, y + 1)
                    let xLo = max(0, x - 1), xHi = min(width - 1, x + 1)
                    for ny in yLo...yHi {
                        let row = ny * width
                        for nx in xLo...xHi {
                            let n = row + nx
                            if m[n] && !visited[n] {
                                visited[n] = true
                                stack.append(n)
                            }
                        }
                    }
                }

                var pts: [CGPoint] = []
                pts.reserveCapacity(touchedRows.count * 2)
                for y in touchedRows {
                    let lo = rowMin[y], hi = rowMax[y]
                    pts.append(CGPoint(x: CGFloat(lo), y: CGFloat(y)))
                    if hi != lo { pts.append(CGPoint(x: CGFloat(hi), y: CGFloat(y))) }
                    rowMin[y] = Int.max
                    rowMax[y] = Int.min
                }
                groups.append(pts)
            }
        }
        return groups
    }
}
