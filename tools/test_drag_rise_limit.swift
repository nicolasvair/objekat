// `DragRiseLimit` — the protection of a dragged level box: a DRAG cannot raise the value by more than
// `limit` above where THIS drag started (the monitor volume of an input: a slip of the hand must not
// send +24 dB into the speakers), while going down is free and a typed value is never concerned (the
// caller does not ask the function). Pure, no screen. Run from `tools/`:
//
//     cd tools && swiftc -parse-as-library \
//         ../objekat/Shared/FineAdjust.swift \
//         test_drag_rise_limit.swift \
//         -o /tmp/drl && /tmp/drl
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
struct Test {
    static func main() {
        check("no limit: the proposal goes through", DragRiseLimit.clamp(start: 0, proposed: 24, limit: nil) == 24)
        check("under the ceiling: untouched", DragRiseLimit.clamp(start: 0, proposed: 5, limit: 6) == 5)
        check("exactly the ceiling: untouched", DragRiseLimit.clamp(start: 0, proposed: 6, limit: 6) == 6)
        check("over the ceiling: held at start + limit", DragRiseLimit.clamp(start: 0, proposed: 24, limit: 6) == 6)
        check("the ceiling follows the START of the drag", DragRiseLimit.clamp(start: -12, proposed: 20, limit: 6) == -6)
        check("a start above zero", DragRiseLimit.clamp(start: 10, proposed: 24, limit: 6) == 16)
        check("going down is never limited", DragRiseLimit.clamp(start: 0, proposed: -24, limit: 6) == -24)
        check("the start itself is a valid value", DragRiseLimit.clamp(start: 3, proposed: 3, limit: 6) == 3)
        check("a fractional start", abs(DragRiseLimit.clamp(start: 0.4, proposed: 99, limit: 6) - 6.4) < 1e-12)
        check("a zero limit pins the drag at its start from above", DragRiseLimit.clamp(start: 2, proposed: 9, limit: 0) == 2)
        check("a zero limit still lets it go down", DragRiseLimit.clamp(start: 2, proposed: -1, limit: 0) == -1)
        check("a negative limit is read as zero (never below the start)",
              DragRiseLimit.clamp(start: 2, proposed: 9, limit: -4) == 2)

        print("\n\(total - fails.count)/\(total) assertions passed")
        if !fails.isEmpty { print("FAILED: \(fails)"); exit(1) }
    }
}
