// The wall at t = 0 and who it applies to (`Shared/ZeroClamp.swift`), asserted with no screen.
//
//     swiftc -parse-as-library ../objekat/Shared/ZeroClamp.swift test_zero_clamp.swift -o /tmp/zeroclamp && /tmp/zeroclamp
//
// Exit: 0 if every assertion passes, 1 otherwise.

import Foundation

var fails: [String] = []
var total = 0
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    total += 1
    if ok { print("ok    " + label) } else { fails.append(label); print("FAIL  \(label)  \(detail)") }
}

@main struct Runner { static func main() {
    // clamp: a root object stops at 0, a descendant has no wall
    check("root: -1.5 -> 0", ZeroClamp.clamp(-1.5, isRoot: true) == 0)
    check("root: 3 -> 3", ZeroClamp.clamp(3, isRoot: true) == 3)
    check("root: exactly 0 -> 0", ZeroClamp.clamp(0, isRoot: true) == 0)
    check("child: -2 stays -2 (the c03 case: -2 +1 s = -1)", ZeroClamp.clamp(-2 + 1, isRoot: false) == -1)
    check("child: -50 stays -50", ZeroClamp.clamp(-50, isRoot: false) == -50)
    check("child: 4 -> 4", ZeroClamp.clamp(4, isRoot: false) == 4)
    check("lowestStart: root 0, child -inf", ZeroClamp.lowestStart(isRoot: true) == 0
          && ZeroClamp.lowestStart(isRoot: false) == -.infinity)

    // leftTravelLimit: only the root objects wall the selection
    check("only descendants: no wall", ZeroClamp.leftTravelLimit(starts: [(-2, false), (5, false)]) == -.infinity)
    check("a root at 3: the selection may travel 3 s left",
          ZeroClamp.leftTravelLimit(starts: [(3, true)]) == -3)
    check("two roots (3 and 1): the leftmost decides",
          ZeroClamp.leftTravelLimit(starts: [(3, true), (1, true)]) == -1)
    check("a root at 4 and a child at -2: the child is free",
          ZeroClamp.leftTravelLimit(starts: [(4, true), (-2, false)]) == -4)
    check("a root group at 2 carrying children at -2: the GROUP stops at 0 (dt >= -2), the children are not asked",
          ZeroClamp.leftTravelLimit(starts: [(2, true)]) == -2)
    check("empty selection: no wall", ZeroClamp.leftTravelLimit(starts: []) == -.infinity)
    // a drag clamped the way the handler does it: dt = max(dt, limit)
    let limit = ZeroClamp.leftTravelLimit(starts: [(2, true), (-3, false)])
    check("hand asks -10 s: root group lands at 0 (dt = -2), child lands at -5",
          max(-10, limit) == -2 && -3 + max(-10, limit) == -5)

    // trimLimit
    check("root at 2, content before 10: wall at 0 wins (-2)", ZeroClamp.trimLimit(start: 2, room: 10, isRoot: true) == -2)
    check("root at 2, content before 0.5: the file wins (-0.5)", ZeroClamp.trimLimit(start: 2, room: 0.5, isRoot: true) == -0.5)
    check("child at -2, content before 1: the file only (-1) — the old wall forced +2",
          ZeroClamp.trimLimit(start: -2, room: 1, isRoot: false) == -1)
    check("child at -2, no source (group / aux / MIDI): free", ZeroClamp.trimLimit(start: -2, room: .infinity, isRoot: false) == -.infinity)
    check("root group at 3, no source: wall at 0 (-3)", ZeroClamp.trimLimit(start: 3, room: .infinity, isRoot: true) == -3)
    // what the OLD formula gave for the child, to document the bug: max(-start, -room) = max(2, -1) = 2
    check("old formula on the child at -2 was +2 (forced crop) — the bug", max(-(-2.0), -1.0) == 2)

    print(fails.isEmpty ? "ALL PASS (\(total))" : "FAILED \(fails.count)/\(total): \(fails)")
    exit(fails.isEmpty ? 0 : 1)
} }
