// Reordering the project tabs by drag — the arithmetic behind it, asserted with no screen.
// `TabReorder` (`objekat/Shared/TabReorder.swift`) has no model behind it at all, which is why
// it can be compiled and run alone, exactly like `StemReorder` before it.
//
//     swiftc -parse-as-library \
//         ../objekat/Shared/TabReorder.swift test_tab_reorder.swift \
//         -o /tmp/tabreorder && /tmp/tabreorder
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
enum TabReorderTest {
  static func main() {

    // Three tabs of VARYING width — 100, 40, 60 px — with the strip's 4 px spacing.
    // A: 0..100 (mid 50), B: 104..144 (mid 124), C: 148..208 (mid 178)
    let spacing: CGFloat = 4
    let frames: [CGRect] = [
        CGRect(x: 0,   y: 0, width: 100, height: 20),
        CGRect(x: 104, y: 0, width: 40,  height: 20),
        CGRect(x: 148, y: 0, width: 60,  height: 20),
    ]

    // MARK: - targetIndex: the dragged tab's CENTRE against the others' midpoints

    check("no travel: stays put (first)", TabReorder.targetIndex(frames: frames, dragged: 0, dx: 0) == 0)
    check("no travel: stays put (middle)", TabReorder.targetIndex(frames: frames, dragged: 1, dx: 0) == 1)
    check("no travel: stays put (last)", TabReorder.targetIndex(frames: frames, dragged: 2, dx: 0) == 2)

    // A's centre is 50; it passes B's midpoint (124) past dx = 74, C's (178) past dx = 128.
    check("A short of B's midpoint: stays",
          TabReorder.targetIndex(frames: frames, dragged: 0, dx: 73) == 0)
    check("A past B's midpoint: second",
          TabReorder.targetIndex(frames: frames, dragged: 0, dx: 75) == 1)
    check("A past C's midpoint: last",
          TabReorder.targetIndex(frames: frames, dragged: 0, dx: 129) == 2)
    check("A far beyond the strip: still last, never out of range",
          TabReorder.targetIndex(frames: frames, dragged: 0, dx: 10_000) == 2)

    // C's centre is 178; it passes B's midpoint (124) below dx = -54, A's (50) below dx = -128.
    check("C short of B's midpoint: stays",
          TabReorder.targetIndex(frames: frames, dragged: 2, dx: -53) == 2)
    check("C past B's midpoint: second",
          TabReorder.targetIndex(frames: frames, dragged: 2, dx: -55) == 1)
    check("C past A's midpoint: first",
          TabReorder.targetIndex(frames: frames, dragged: 2, dx: -129) == 0)
    check("C far before the strip: still first, never negative",
          TabReorder.targetIndex(frames: frames, dragged: 2, dx: -10_000) == 0)

    // The threshold is on FROZEN midpoints, so going back is symmetric: no flicker at the line.
    check("A back just short of B's midpoint: first again",
          TabReorder.targetIndex(frames: frames, dragged: 0, dx: 73.9) == 0)

    check("an out-of-range dragged index answers itself",
          TabReorder.targetIndex(frames: frames, dragged: 7, dx: 50) == 7)

    // MARK: - shift: the neighbours make room by the DRAGGED tab's width + spacing

    // A (100 wide) aimed at the end: B and C each slide LEFT by 104.
    check("A → last: B slides left by A's width + spacing",
          TabReorder.shift(of: 1, dragged: 0, target: 2, frames: frames, spacing: spacing) == -104)
    check("A → last: C slides left too",
          TabReorder.shift(of: 2, dragged: 0, target: 2, frames: frames, spacing: spacing) == -104)
    check("A → second: only B slides, C stays",
          TabReorder.shift(of: 1, dragged: 0, target: 1, frames: frames, spacing: spacing) == -104
          && TabReorder.shift(of: 2, dragged: 0, target: 1, frames: frames, spacing: spacing) == 0)

    // C (60 wide) aimed at the front: A and B each slide RIGHT by 64.
    check("C → first: A and B slide right by C's width + spacing",
          TabReorder.shift(of: 0, dragged: 2, target: 0, frames: frames, spacing: spacing) == 64
          && TabReorder.shift(of: 1, dragged: 2, target: 0, frames: frames, spacing: spacing) == 64)
    check("C → second: only B slides",
          TabReorder.shift(of: 0, dragged: 2, target: 1, frames: frames, spacing: spacing) == 0
          && TabReorder.shift(of: 1, dragged: 2, target: 1, frames: frames, spacing: spacing) == 64)

    check("no move: nobody slides",
          (0..<3).allSatisfy {
              TabReorder.shift(of: $0, dragged: 1, target: 1, frames: frames, spacing: spacing) == 0
          })
    check("the dragged tab itself never shifts (its offset is the hand's)",
          TabReorder.shift(of: 0, dragged: 0, target: 2, frames: frames, spacing: spacing) == 0)

    // MARK: - The preview and the drop agree

    // Where the preview puts each tab (layout x + shift) must be where the reordered strip lays
    // it out — otherwise the neighbours would jump at the drop. Sweep every drag and every target.
    for dragged in 0..<3 {
        for target in 0..<3 {
            var order = Array(0..<3)
            let moved = order.remove(at: dragged)
            order.insert(moved, at: target)
            // The reordered strip's layout, from the widths alone.
            var x: CGFloat = 0
            var laidOut: [Int: CGFloat] = [:]
            for i in order { laidOut[i] = x; x += frames[i].width + spacing }
            for i in 0..<3 where i != dragged {
                let preview = frames[i].minX
                    + TabReorder.shift(of: i, dragged: dragged, target: target,
                                       frames: frames, spacing: spacing)
                check("drag \(dragged) → \(target): tab \(i) previewed where it lands",
                      abs(preview - laidOut[i]!) < 1e-9, "\(preview) vs \(laidOut[i]!)")
            }
        }
    }

    print("\n\(total) assertion(s), " + (fails.isEmpty ? "ALL PASS" : "\(fails.count) FAILED: \(fails)"))
    exit(fails.isEmpty ? 0 : 1)
  }
}
