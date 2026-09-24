// Reordering the stem bar by drag — the arithmetic behind it, asserted with no screen.
// `StemReorder.targetIndex` (`objekat/Shared/StemReorder.swift`) has no model behind it at all,
// which is why it can be compiled and run alone, exactly like `CutSelection` / `TempoText`
// before it.
//
//     swiftc -parse-as-library \
//         ../objekat/Shared/StemReorder.swift test_stem_reorder.swift \
//         -o /tmp/stemreorder && /tmp/stemreorder
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
enum StemReorderTest {
  static func main() {

    // Four strips: Main (0), then three stems of VARYING width — 50, 80, 40 px — laid out
    // left to right with no gap.
    // Main: 0..50, A: 50..130, B: 130..210, C: 210..250
    let frames: [CGRect] = [
        CGRect(x: 0,   y: 0, width: 50, height: 24),   // Main
        CGRect(x: 50,  y: 0, width: 80, height: 24),   // A, mid = 90
        CGRect(x: 130, y: 0, width: 80, height: 24),   // B, mid = 170
        CGRect(x: 210, y: 0, width: 40, height: 24),   // C, mid = 230
    ]

    // MARK: - Dragging C (index 3) far to the left: before the first stem (A).

    check("before the first",
          StemReorder.targetIndex(pointerX: 10, frames: frames, dragged: 3) == 1,
          "\(StemReorder.targetIndex(pointerX: 10, frames: frames, dragged: 3))")

    // MARK: - Dragging A (index 1) far to the right: after the last stem (C).

    check("after the last",
          StemReorder.targetIndex(pointerX: 500, frames: frames, dragged: 1) == 3,
          "\(StemReorder.targetIndex(pointerX: 500, frames: frames, dragged: 1))")

    // MARK: - Dragging B (index 2) and releasing over its own original midpoint: unchanged.

    check("on itself: unchanged",
          StemReorder.targetIndex(pointerX: 170, frames: frames, dragged: 2) == 2,
          "\(StemReorder.targetIndex(pointerX: 170, frames: frames, dragged: 2))")

    // MARK: - Dragging A past B but not past C: lands at B's slot (index 2).

    check("past one neighbour, not the next",
          StemReorder.targetIndex(pointerX: 200, frames: frames, dragged: 1) == 2,
          "\(StemReorder.targetIndex(pointerX: 200, frames: frames, dragged: 1))")

    // MARK: - Only Main + one stem: the lone stem never moves.

    let two: [CGRect] = [CGRect(x: 0, y: 0, width: 50, height: 24),
                          CGRect(x: 50, y: 0, width: 80, height: 24)]
    check("Main + one stem: stays at 1",
          StemReorder.targetIndex(pointerX: 999, frames: two, dragged: 1) == 1)
    check("Main + one stem: pointer far left still 1",
          StemReorder.targetIndex(pointerX: -50, frames: two, dragged: 1) == 1)

    // MARK: - Never targets index 0 (the Main), whatever the pointer.

    check("never targets the Main slot",
          StemReorder.targetIndex(pointerX: -1000, frames: frames, dragged: 3) >= 1)

    // MARK: - Summary

    print("\n\(total - fails.count)/\(total) passed")
    if !fails.isEmpty {
        print("FAILURES:")
        for f in fails { print(" - \(f)") }
        exit(1)
    }
    exit(0)
  }
}
