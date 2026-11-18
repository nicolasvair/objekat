// "What a plain move of objects lands on" (`Shared/ObjectMoveSnap.swift`), asserted with no screen.
//
//     swiftc -parse-as-library ../objekat/Shared/ObjectMoveSnap.swift test_object_move_snap.swift \
//         -o /tmp/objmovesnap && /tmp/objmovesnap
//
// Exit: 0 if every assertion passes, 1 otherwise.

import Foundation

var fails: [String] = []
var total = 0
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    total += 1
    if ok { print("ok    " + label) } else { fails.append(label); print("FAIL  \(label)  \(detail)") }
}
func near(_ a: Double, _ b: Double, _ tol: Double = 1e-9) -> Bool { abs(a - b) <= tol }

typealias M = ObjectMoveSnap

/// 100 px/s: 8 px = 0.08 s of tolerance, a grid of 0.5 s. The object lasts 2 s by default.
func resolve(rawStart: Double, duration: Double = 2, targets: [Double] = [],
             grid: Double = 0.5, snap: Bool = true) -> M.Result {
    M.resolve(rawStart: rawStart, duration: duration, targets: targets, gridInterval: grid,
              tolerance: 0.08, onTargetEpsilon: 0.005, snapEnabled: snap)
}

@main struct Runner { static func main() {
    // 1. The start has a real target within reach: it wins, even if the end is nearer to its own.
    do {
        let r = resolve(rawStart: 10.0625, targets: [10.0, 12.03125])   // start .0625 away, end (12.0625) .03125
        check("start on a target wins although the end is nearer to another",
              r.edge == .start && near(r.start, 10.0) && r.onTarget && near(r.guideTime, 10.0), "\(r)")
    }
    // 2. Only the end has one.
    do {
        let r = resolve(rawStart: 10.3, targets: [12.33])                // end 12.3 -> 12.33
        check("only the end on a target: the end lands, the start follows",
              r.edge == .end && near(r.start, 10.33) && r.onTarget && near(r.guideTime, 12.33), "\(r)")
    }
    // 3. Neither: the grid, on the START (the end sits nearer to a line here: 10.2 -> 0.3 vs 12.2 -> 0.2).
    do {
        let r = resolve(rawStart: 10.2)                                  // end 12.2: .2 from 12.0; start .2 from 10.0
        check("no target: the grid takes the start", r.edge == .start && near(r.start, 10.0) && !r.onTarget, "\(r)")
    }
    do {
        let r = resolve(rawStart: 10.3, duration: 2.1)                   // end 12.4 is .1 from 12.5; start .2 from 10.5
        check("the grid is never read on the end, even when it is nearer",
              r.edge == .start && near(r.start, 10.5), "\(r)")
    }
    // A target beyond the reach does nothing.
    do {
        let r = resolve(rawStart: 10.3, targets: [10.39])                // 0.09 > 0.08
        check("out of reach (9 px): the grid decides", !r.onTarget && near(r.start, 10.5), "\(r)")
    }
    // A real target is never beaten by a nearer grid line.
    do {
        let r = resolve(rawStart: 10.01, targets: [10.07])               // grid line 10.0 is nearer than the mark
        check("a real target is never beaten by the grid", near(r.start, 10.07) && r.onTarget, "\(r)")
    }
    // A grid line falling on a mark counts as landing on it.
    do {
        let r = resolve(rawStart: 10.2, targets: [10.0, 100.0])          // 0.2 is out of reach: the grid, 10.0 ...
        check("a grid line falling on a mark counts as on target", near(r.start, 10.0) && r.onTarget, "\(r)")
    }
    // Snap off: the hand, a grey guide on the start.
    do {
        let r = resolve(rawStart: 10.03, targets: [10.0], snap: false)
        check("snap off: the raw start, grey guide", near(r.start, 10.03) && !r.onTarget && near(r.guideTime, 10.03), "\(r)")
    }
    // No grid at all: the object follows the hand.
    do {
        let r = resolve(rawStart: 10.23, grid: 0)
        check("no grid: follows the hand", near(r.start, 10.23) && !r.onTarget, "\(r)")
    }
    // Zero-length object: the start still wins.
    do {
        let r = resolve(rawStart: 5.03, duration: 0, targets: [5.0])
        check("a zero-length object: the start wins", r.edge == .start && near(r.start, 5.0), "\(r)")
    }
    // The floor at 0 is the caller's: a start left of 0 comes back untouched by the pure rule.
    do {
        let r = resolve(rawStart: -1.2, grid: 0)
        check("no floor in the pure rule (the caller clamps)", near(r.start, -1.2), "\(r)")
    }

    print("\n\(total - fails.count)/\(total) ok")
    exit(fails.isEmpty ? 0 : 1)
} }
