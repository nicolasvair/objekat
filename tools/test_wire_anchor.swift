// Where a link wire lands on a block — the arithmetic, asserted with no screen.
//
//     swiftc -parse-as-library \
//         ../objekat/Timeline/WireAnchor.swift test_wire_anchor.swift \
//         -o /tmp/wireanchor && /tmp/wireanchor
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

func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }

@main
enum WireAnchorTest {
  static func main() {
    let vw = 1000.0
    let m = wireAnchorMargin

    // Wholly visible: the exact middle.
    check("whole block keeps its middle",
          near(wireAnchorX(blockX: 300, blockWidth: 200, scrollX: 0, viewportWidth: vw), 400))
    check("block flush with the window keeps its middle",
          near(wireAnchorX(blockX: 0, blockWidth: 1000, scrollX: 0, viewportWidth: vw), 500))

    // Wholly outside: the exact middle, whichever side.
    check("block right of the window: its middle",
          near(wireAnchorX(blockX: 3000, blockWidth: 200, scrollX: 0, viewportWidth: vw), 3100))
    check("block left of the window: its middle",
          near(wireAnchorX(blockX: 0, blockWidth: 200, scrollX: 2000, viewportWidth: vw), 100))

    // Wider than the window: the middle of what is seen.
    check("long block from 0, scroll 0: middle of the window",
          near(wireAnchorX(blockX: 0, blockWidth: 10_000, scrollX: 0, viewportWidth: vw), 500))
    check("long block follows the scroll",
          near(wireAnchorX(blockX: 0, blockWidth: 10_000, scrollX: 4000, viewportWidth: vw), 4500))
    let band = wireAnchorX(blockX: 0, blockWidth: 1e6, scrollX: 12345, viewportWidth: vw)
    check("infinite-bus-like band stays in view",
          band >= 12345 + m && band <= 12345 + vw - m, "\(band)")

    // Cut by one edge: the middle of the visible part.
    check("cut on the left: middle of the visible part",
          near(wireAnchorX(blockX: 0, blockWidth: 1600, scrollX: 1000, viewportWidth: vw), 1300))
    check("cut on the right: middle of the visible part",
          near(wireAnchorX(blockX: 600, blockWidth: 2000, scrollX: 0, viewportWidth: vw), 800))

    // Clamped by the margin.
    let sliverL = wireAnchorX(blockX: 0, blockWidth: 1010, scrollX: 1000, viewportWidth: vw)
    check("a sliver at the window's left edge: stays in the block, at its end",
          sliverL >= 1000 && sliverL <= 1010, "\(sliverL)")
    let cutL = wireAnchorX(blockX: 0, blockWidth: 1100, scrollX: 1000 - 400, viewportWidth: vw)
    check("a block end inside the left of the window: within the visible part",
          cutL >= 600 && cutL <= 1100, "\(cutL)")
    let sliverR = wireAnchorX(blockX: 1990, blockWidth: 5000, scrollX: 1000, viewportWidth: vw)
    check("a sliver at the window's right edge: stays in the block",
          sliverR >= 1990 && sliverR <= 2000, "\(sliverR)")

    // Never outside the block, even with a margin.
    let tiny = wireAnchorX(blockX: 1000, blockWidth: 6, scrollX: 1004, viewportWidth: vw)
    check("a few px of block visible: stays on the block", tiny >= 1000 && tiny <= 1006, "\(tiny)")

    // Degenerate window.
    check("window narrower than two margins collapses onto its middle",
          near(wireAnchorX(blockX: 0, blockWidth: 5000, scrollX: 100, viewportWidth: 30), 115))

    // Sweep: whenever the block overlaps the window, the wire is inside the block AND inside the
    // window; and once more than two margins of the block are visible, a margin inside it.
    var ok = true
    var s = -200.0
    while s < 12_000 {
        let x = wireAnchorX(blockX: 500, blockWidth: 9000, scrollX: s, viewportWidth: vw)
        let v0 = max(500, s), v1 = min(9500, s + vw)
        if v1 > v0 {
            if x < 500 || x > 9500 { ok = false }
            if x < s - 1e-9 || x > s + vw + 1e-9 { ok = false }
            if v1 - v0 > 2 * m && (x < v0 + m - 1e-9 || x > v1 - m + 1e-9) { ok = false }
        }
        s += 37
    }
    check("sweep over scrolls: the wire never leaves the block nor the window", ok)

    print("\n\(total - fails.count)/\(total) passed")
    exit(fails.isEmpty ? 0 : 1)
  }
}
