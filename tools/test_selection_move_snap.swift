// "What a time selection lands on when the hand carries it" — the precedence, asserted with no
// screen. `SelectionMoveSnap` (`Shared/SelectionMoveSnap.swift`) has no view and no model behind
// it, which is why it can be compiled and run alone, like `CrossfadeGrab` / `CutSelection`.
//
//     swiftc -parse-as-library \
//         ../objekat/Shared/SelectionMoveSnap.swift test_selection_move_snap.swift \
//         -o /tmp/selmovesnap && /tmp/selmovesnap
//
// Numbers are chosen EXACT in binary (multiples of 1/16 and 1/8) where a tie has to be a tie: a
// decimal like 10.03 - 10.0 and 12.03 - 12.0 differ in the last bit and a "tie" would be luck.
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

func near(_ a: Double, _ b: Double, _ tol: Double = 1e-9) -> Bool { abs(a - b) <= tol }

typealias S = SelectionMoveSnap

/// 100 px/s: 8 px = 0.08 s of tolerance, a grid of 0.5 s.
func resolve(lo: Double = 4, hi: Double = 6, rawDt: Double,
             objectStart: Double? = nil, objectEnd: Double? = nil,
             targets: [Double] = [], grid: Double = 0.5, snap: Bool = true,
             minDt: Double? = nil) -> S.Result {
    S.resolve(lo: lo, hi: hi, rawDt: rawDt, objectStart: objectStart, objectEnd: objectEnd,
              targets: targets, gridInterval: grid, tolerance: 0.08, onTargetEpsilon: 0.005,
              snapEnabled: snap, minDt: minDt ?? -lo)
}

@main
enum SelectionMoveSnapTest {
  static func main() {

    // MARK: - 1. The range's own bounds against a real target

    // The START reaches a marker although the range begins in silence — no object edge anywhere.
    do {
        let r = resolve(rawDt: 6.02, targets: [10.03])
        check("start lands on a marker (no object grabbed at all)",
              near(4 + r.dt, 10.03) && r.edge == .start && r.onTarget && near(r.guideTime, 10.03), "\(r)")
    }
    // A real target beats the grid even when the grid line is NEARER: 10.01 is 0.01 from 10.0 and
    // 0.02 from the marker, and `snappedTime` would have kept the grid.
    do {
        let r = resolve(rawDt: 6.01, targets: [10.03])
        check("a real target is never beaten by the grid",
              near(4 + r.dt, 10.03) && r.onTarget, "\(r)")
    }
    // The END reaches a target the start does not.
    do {
        let r = resolve(rawDt: 7.98, targets: [14.03])   // end -> 13.98, start -> 11.98
        check("end lands on a marker", near(6 + r.dt, 14.03) && r.edge == .end && r.onTarget, "\(r)")
    }
    // Both within reach: the NEARER wins …
    do {
        let r = resolve(rawDt: 6.0, targets: [10.0625, 12.03125])   // start .0625 away, end .03125
        check("the nearer of the two bounds wins", r.edge == .end && near(6 + r.dt, 12.03125), "\(r)")
    }
    // … and an exact tie goes to the START — the caret.
    do {
        let r = resolve(rawDt: 6.0, targets: [10.0625, 12.0625])
        check("an exact tie goes to the start", r.edge == .start && near(4 + r.dt, 10.0625), "\(r)")
    }
    // Out of reach: 0.09 s is more than 8 px at 100 px/s. The marker is off the grid on purpose.
    do {
        let r = resolve(rawDt: 6.29, targets: [10.2])    // start -> 10.29, 0.09 from the marker
        check("out of reach (9 px) nothing pulls: the grid decides",
              !r.onTarget && near(4 + r.dt, 10.5), "\(r)")
    }

    // MARK: - 2. The grabbed object's edges come SECOND

    // The object grabbed starts at 4.8 and the marker is for IT: nothing within reach of the range.
    do {
        let r = resolve(rawDt: 6.10, objectStart: 4.8, objectEnd: 6, targets: [10.91])
        check("the object's start lands when the range's bounds find nothing",
              r.edge == .objectStart && near(4.8 + r.dt, 10.91) && r.onTarget && near(r.guideTime, 10.91), "\(r)")
    }
    // The same object edge is NEARER (0.01) than the start's target (0.07): the start still wins.
    do {
        let r = resolve(rawDt: 6.10, objectStart: 4.8, objectEnd: 6, targets: [10.03, 10.91])
        check("a nearer OBJECT edge does not beat a range bound within reach",
              r.edge == .start && near(4 + r.dt, 10.03), "\(r)")
    }
    do {
        // The object's end is 6.0, the marker 6.0625 is out of reach of 7.0: the grid decides.
        let r = resolve(rawDt: 1.0, objectStart: 4.0, objectEnd: 6.0, targets: [6.0625])
        check("out of reach of every edge it falls through to the grid",
              !r.onTarget && near(4 + r.dt, 5.0), "\(r)")
    }
    do {
        let r = resolve(lo: 4, hi: 10, rawDt: 0.5, objectStart: 4.0, objectEnd: 6.125, targets: [6.625])
        check("object end on a marker", r.edge == .objectEnd && near(6.125 + r.dt, 6.625) && r.onTarget, "\(r)")
    }

    // MARK: - 3. The grid, on the range's bounds

    do {
        let r = resolve(rawDt: 5.75)                      // start -> 9.75, end -> 11.75: both 0.25 off
        check("with no target, the grid takes the start (a tie)",
              r.edge == .start && near(4 + r.dt, 10.0) && !r.onTarget && near(r.guideTime, 10.0), "\(r)")
    }
    do {
        // A range whose END is the one near a grid line: 4 -> 6.1 (not a multiple of the grid).
        let r2 = resolve(lo: 4, hi: 6.1, rawDt: 3.4)      // start -> 7.4 (0.1 from 7.5), end -> 9.5 (0.0)
        check("the grid takes the END when it is nearer", r2.edge == .end && near(6.1 + r2.dt, 9.5), "\(r2)")
    }
    // A grid line that FALLS on a mark counts as landing on it (the guide goes yellow).
    do {
        let r = resolve(rawDt: 5.75, targets: [10.0])
        check("a grid line falling on a mark counts as landing on it", r.onTarget && near(4 + r.dt, 10.0), "\(r)")
    }
    do {
        let r = resolve(rawDt: 5.8, grid: 0)
        check("no grid at all: the range follows the hand", near(r.dt, 5.8) && !r.onTarget, "\(r)")
    }

    // MARK: - 4. The snap off

    do {
        let r = resolve(rawDt: 6.02, targets: [10.03], snap: false)
        check("snap off: the raw travel, a grey guide on the start",
              near(r.dt, 6.02) && !r.onTarget && r.edge == .start && near(r.guideTime, 10.02), "\(r)")
    }

    // MARK: - 5. The floor: the RANGE stops at zero

    do {
        let r = resolve(rawDt: -10)
        check("the range stops at zero", near(r.dt, -4) && r.clamped && near(r.guideTime, 0) && !r.onTarget, "\(r)")
    }
    // The first object inside begins at 4.8 — later than the range's start. It limits nothing: the
    // floor is the RANGE's start, so the travel is -4 (not -4.8, which would be the object's).
    do {
        let r = resolve(rawDt: -4.5, objectStart: 4.8, objectEnd: 6)
        check("a later object does not limit the travel: it is cut at the range's start",
              r.clamped && near(r.dt, -4) && near(r.guideTime, 0), "\(r)")
    }
    do {
        let r = resolve(rawDt: -3.0)                      // lands on 1.0: the grid
        check("short of the wall: not clamped", !r.clamped && near(4 + r.dt, 1.0), "\(r)")
    }
    // The wall wins over a target that would pull further than it.
    do {
        let r = resolve(rawDt: -3.97, targets: [0.03], minDt: -3.5)   // an explicit, tighter floor
        check("an explicit floor wins over a target", r.clamped && near(r.dt, -3.5), "\(r)")
    }

    print("\n\(total - fails.count)/\(total) assertions")
    if !fails.isEmpty { print("FAILED: \(fails)"); exit(1) }
  }
}
