// The X of a crossfade is drawn from a CACHED unit path stretched onto the zone, with at most 128
// samples per curve (it was a fresh `min(width, 512)` polyline per frame, two `pow`s a sample).
// Asserted with no screen:
//
//   1. the unit points, stretched, ARE the point-by-point calculation (<0.5 px, in practice 1e-9):
//      the cache can only be wrong about the zone's box, never about the curve;
//   2. the 128-sample polyline stays within 0.5 px of the exact curve (dense reference), for the
//      five families x three bends x zones of 4, 64 and 900 px, at the largest block height;
//   3. the budget: never more than min(width, 128) segments (16 for the very narrow), a straight curve is one;
//   4. the cache: the same key makes nothing twice, a width that only MOVES the zone never misses,
//      a different curve / side / count is its own entry, and it stays bounded.
//
//   swiftc -parse-as-library objekat/SoundObject/FadeCurve.swift objekat/Shared/CrossfadeCurveSampling.swift \
//       tools/test_crossfade_curve_cache.swift -o /tmp/test_xf_cache && /tmp/test_xf_cache

import Foundation

@main
struct T {
    static var fails = 0
    static var total = 0
    static func check(_ label: String, _ ok: Bool, _ detail: String = "") {
        total += 1
        if !ok { fails += 1; print("FAIL  \(label)  \(detail)") }
    }

    /// Distance from `p` to the polyline `poly` (px).
    static func dist(_ p: (Double, Double), _ poly: [(Double, Double)]) -> Double {
        var best = Double.infinity
        for k in 1..<poly.count {
            let (ax, ay) = poly[k - 1], (bx, by) = poly[k]
            let dx = bx - ax, dy = by - ay
            let l2 = dx * dx + dy * dy
            var t = l2 > 0 ? ((p.0 - ax) * dx + (p.1 - ay) * dy) / l2 : 0
            t = min(1, max(0, t))
            let ex = ax + t * dx - p.0, ey = ay + t * dy - p.1
            best = min(best, (ex * ex + ey * ey).squareRoot())
        }
        return best
    }

    static func main() {
        let families: [FadeShape] = [.linear, .convex, .concave, .sCurve, .sCurveInverse]
        let bends: [Double] = [0.25, 0.6, 1.0]
        let widths: [Double] = [4, 64, 900]
        let height = 900.0                      // the largest block there is (maxBlockHeight)
        var worst = 0.0, worstLabel = ""

        for shape in families {
            for amount in (shape == .linear ? [0.0] : bends) {
                let curve = FadeCurve(shape: shape, amount: amount)
                for w in widths {
                    for incoming in [true, false] {
                        let n = CrossfadeCurveSampling.sampleCount(forWidth: w)
                        let label = "\(shape) bend \(amount) \(Int(w))px \(incoming ? "in" : "out")"
                        let unit = CrossfadeCurveSampling.unitPoints(curve: curve, incoming: incoming, segments: n)
                        // 3. the budget
                        check("\(label): at most max(16, min(width,128)) segments (\(unit.count - 1))",
                              unit.count - 1 <= max(16, min(Int(w), 128)) && unit.count >= 2)
                        if curve.isStraight { check("\(label): straight = 1 segment", unit.count == 2) }
                        // ends exactly where the old formulas put them
                        check("\(label): starts at the silent end, ends at full level",
                              abs(unit.first!.y - 1) < 1e-12 && abs(unit.last!.y) < 1e-12
                              && abs(unit.first!.x - (incoming ? 0 : 1)) < 1e-12
                              && abs(unit.last!.x - (incoming ? 1 : 0)) < 1e-12)

                        // 1. stretched unit points == the direct calculation, at the same progress
                        var maxDiff = 0.0
                        for (i, u) in unit.enumerated() {
                            let a = curve.isStraight ? Double(i) : CrossfadeCurveSampling.progress(index: i, of: unit.count - 1)
                            let x = incoming ? a * w : w - a * w          // the old per-frame formulas
                            let y = height * (1 - curve.gain(a))
                            maxDiff = max(maxDiff, abs(u.x * w - x), abs(u.y * height - y))
                        }
                        check("\(label): cached == point-by-point (\(maxDiff))", maxDiff < 0.5)

                        // 2. the polyline against the exact curve
                        let poly = unit.map { ($0.x * w, $0.y * height) }
                        var err = 0.0
                        let dense = 4000
                        for k in 0...dense {
                            let a = Double(k) / Double(dense)
                            let ex = incoming ? a * w : w - a * w
                            err = max(err, dist((ex, height * (1 - curve.gain(a))), poly))
                        }
                        if err > worst { worst = err; worstLabel = label }
                        check("\(label): within 0.5 px of the exact curve (\(String(format: "%.3f", err)))", err < 0.5)
                    }
                }
            }
        }
        print(String(format: "worst polyline error: %.3f px (%@)", worst, worstLabel))

        // 3b. the count follows the width and never exceeds the cap
        check("count: 4 px -> 16 (the floor)", CrossfadeCurveSampling.sampleCount(forWidth: 4) == 16)
        check("count: 0.4 px -> 16", CrossfadeCurveSampling.sampleCount(forWidth: 0.4) == 16)
        check("count: 64 px -> 64", CrossfadeCurveSampling.sampleCount(forWidth: 64) == 64)
        check("count: 900 px -> 128", CrossfadeCurveSampling.sampleCount(forWidth: 900) == 128)
        check("count: inf -> 16", CrossfadeCurveSampling.sampleCount(forWidth: .infinity) == 16)

        // 4. the cache
        let cache = CrossfadeCurveCache<Int>(capacity: 8)
        let c1 = FadeCurve(shape: .convex, amount: 0.5)
        var made = 0
        func get(_ c: FadeCurve, _ incoming: Bool, _ n: Int) -> Int {
            cache.value(for: .init(curve: c, incoming: incoming, segments: n)) { made += 1; return made }
        }
        let first = get(c1, true, 128)
        check("cache: second ask is a hit, same value", get(c1, true, 128) == first && made == 1)
        // a drag that only moves / widens past the cap: same key, no work at all
        for _ in 0..<500 { _ = get(c1, true, CrossfadeCurveSampling.sampleCount(forWidth: 300 + Double.random(in: 0..<600))) }
        check("cache: 500 frames of a wide zone never miss again (misses \(cache.misses))", cache.misses == 1)
        _ = get(c1, false, 128)
        _ = get(FadeCurve(shape: .convex, amount: 0.6), true, 128)
        _ = get(FadeCurve(shape: .concave, amount: 0.5), true, 128)
        _ = get(c1, true, 64)
        check("cache: other side / bend / family / count are their own entries", cache.misses == 5 && cache.count == 5)
        // a straight curve is one entry whatever the count
        let s1 = get(.linear, true, 10), s2 = get(.linear, true, 99)
        check("cache: a straight curve ignores the count", s1 == s2)
        // bounded
        for i in 0..<50 { _ = get(FadeCurve(shape: .convex, amount: Double(i) / 100), true, 128) }
        check("cache: stays bounded (\(cache.count) <= 8)", cache.count <= 8)

        print(fails == 0 ? "ALL PASS (\(total))" : "FAILED \(fails) of \(total)")
        exit(fails == 0 ? 0 : 1)
    }
}
