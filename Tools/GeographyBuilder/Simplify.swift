import Foundation

/// Douglas–Peucker simplification of one ring, with `tolerance` in meters.
///
/// Distances are measured in a local equirectangular projection around the
/// ring's mean latitude, which is accurate enough at the scale of a
/// tolerance. Each ring is simplified on its own, so neighboring polygons can
/// open small gaps or overlaps along shared borders.
///
/// A ring that would drop below four points keeps its original points: it's
/// already small, and keeping it keeps small islands and states.
func simplifiedRing(_ ring: [SIMD2<Double>], tolerance: Double) -> [SIMD2<Double>] {
    guard ring.count > 4, tolerance > 0 else { return ring }
    let meanLatitude = ring.reduce(0) { $0 + $1.y } / Double(ring.count)
    let metersPerDegree = 111_320.0
    let scale = SIMD2(metersPerDegree * cos(meanLatitude * .pi / 180), metersPerDegree)
    let points = ring.map { $0 * scale }

    var keep = [Bool](repeating: false, count: points.count)
    keep[0] = true
    keep[points.count - 1] = true
    var stack = [(0, points.count - 1)]
    while let (first, last) = stack.popLast() {
        guard last > first + 1 else { continue }
        let a = points[first], b = points[last]
        let ab = b - a
        let lengthSquared = (ab * ab).sum()
        var farthest = first, farthestDistance = 0.0
        for i in first + 1..<last {
            let ap = points[i] - a
            let distance: Double
            if lengthSquared == 0 {
                distance = (ap * ap).sum().squareRoot()
            } else {
                let t = min(max((ap * ab).sum() / lengthSquared, 0), 1)
                let d = ap - ab * t
                distance = (d * d).sum().squareRoot()
            }
            if distance > farthestDistance {
                farthest = i
                farthestDistance = distance
            }
        }
        if farthestDistance > tolerance {
            keep[farthest] = true
            stack.append((first, farthest))
            stack.append((farthest, last))
        }
    }
    let result = ring.indices.filter { keep[$0] }.map { ring[$0] }
    return result.count >= 4 ? result : ring
}
