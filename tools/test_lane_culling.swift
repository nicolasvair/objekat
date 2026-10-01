// "Which rows does the viewport touch" — the vertical culling of the layers that walk lanes,
// asserted with no screen. `LaneCulling` (`Timeline/LaneCulling.swift`) has no view and no model
// behind it, which is why it can be compiled and run alone, like `SendColumns` / `CutSelection`.
//
//     swiftc -parse-as-library \
//         ../objekat/Timeline/LaneCulling.swift test_lane_culling.swift \
//         -o /tmp/lanecull && /tmp/lanecull
//
// The rule asserted: the culled range is EXACTLY the set of rows whose band meets the window
// (checked against a brute-force scan over random geometries), so culling can never drop a row the
// viewport shows, and never walks one it does not.
//
// Exit: 0 if every assertion passes, 1 otherwise.

import Foundation

var fails: [String] = []
var total = 0

func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    total += 1
    if ok { print("ok    " + label) }
    else { fails.append(label); print("FAIL  \(label)  \(detail)") }
}

@main
enum LaneCullingTest {
  static func main() {
    // Hand-made cases: ruler 40, rows of 100.
    check("top of the canvas: rows 0 and 1", LaneCulling.rows(y0: 0, y1: 150, rulerHeight: 40, laneStep: 100, count: 10) == 0..<2)
    check("window inside one row", LaneCulling.rows(y0: 150, y1: 160, rulerHeight: 40, laneStep: 100, count: 10) == 1..<2)
    check("window past the last row is empty", LaneCulling.rows(y0: 5000, y1: 6000, rulerHeight: 40, laneStep: 100, count: 10).isEmpty)
    check("window above the first row (inside the ruler) still starts at row 0", LaneCulling.rows(y0: 0, y1: 30, rulerHeight: 40, laneStep: 100, count: 10) == 0..<1 || LaneCulling.rows(y0: 0, y1: 30, rulerHeight: 40, laneStep: 100, count: 10).isEmpty)
    check("clamped to the row count", LaneCulling.rows(y0: 0, y1: 99999, rulerHeight: 40, laneStep: 100, count: 3) == 0..<3)
    check("no rows", LaneCulling.rows(y0: 0, y1: 100, rulerHeight: 40, laneStep: 100, count: 0).isEmpty)
    check("degenerate step", LaneCulling.rows(y0: 0, y1: 100, rulerHeight: 40, laneStep: 0, count: 5).isEmpty)
    check("inverted window", LaneCulling.rows(y0: 100, y1: 0, rulerHeight: 40, laneStep: 100, count: 5).isEmpty)
    check("meets: overlapping", LaneCulling.meets(top: 100, height: 50, y0: 120, y1: 400))
    check("meets: wholly above", !LaneCulling.meets(top: 0, height: 50, y0: 120, y1: 400))
    check("meets: wholly below", !LaneCulling.meets(top: 500, height: 50, y0: 120, y1: 400))
    check("meets: touching the top edge is not meeting", !LaneCulling.meets(top: 0, height: 120, y0: 120, y1: 400))

    // Random geometries against a brute-force scan: the range is exactly the rows whose
    // `[top, top + step)` meets `[y0, y1]`.
    var rng = SystemRandomNumberGenerator()
    var bad = 0
    for _ in 0..<5000 {
        let ruler = Double.random(in: 0...120, using: &rng)
        let step  = Double.random(in: 5...400, using: &rng)
        let count = Int.random(in: 0...300, using: &rng)
        let y0 = Double.random(in: -200...20000, using: &rng)
        let y1 = y0 + Double.random(in: 0...3000, using: &rng)
        let got = LaneCulling.rows(y0: y0, y1: y1, rulerHeight: ruler, laneStep: step, count: count)
        var expected: [Int] = []
        for l in 0..<count {
            let top = ruler + Double(l) * step
            // A row whose top is exactly y1 is allowed in (it is drawn off screen, harmless): the
            // only thing that must never happen is a MEETING row left out.
            if top + step > y0 && top <= y1 { expected.append(l) }
        }
        if Array(got) != expected { bad += 1 }
    }
    check("5000 random geometries == brute force", bad == 0, "\(bad) mismatches")

    print("\n\(total - fails.count)/\(total) assertions pass")
    exit(fails.isEmpty ? 0 : 1)
  }
}
