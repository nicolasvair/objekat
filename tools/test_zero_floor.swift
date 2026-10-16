// The floor at t = 0 for every moved object (`Shared/ZeroFloor.swift`), asserted with no screen.
//
//     swiftc -parse-as-library ../objekat/Shared/ZeroFloor.swift test_zero_floor.swift -o /tmp/zerofloor && /tmp/zerofloor
//
// Every example of the rules R1–R9 (16 October 2026), in absolute timeline seconds.
// Exit: 0 if every assertion passes, 1 otherwise.

import Foundation

var fails: [String] = []
var total = 0
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    total += 1
    if ok { print("ok    " + label) } else { fails.append(label); print("FAIL  \(label)  \(detail)") }
}
func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }

/// A drag: the anchors and the successive TOTAL travels the hand asks for, frame by frame. Returns
/// the travel applied at each frame.
func drag(_ starts: [String: Double], _ frames: [Double]) -> [Double] {
    var g = ZeroFloor.Gesture<String>()
    return frames.map { g.clamp(starts: starts, proposedDelta: $0) }
}

@main struct Runner { static func main() {
    // ── R1: any object, any depth, is floored at 0 ─────────────────────────────────────────────
    check("R1 root at 3 dragged -10 stops at 0 (dt -3)", near(drag(["x": 3], [-10])[0], -3))
    check("R1 child at 10 (in A@20) dragged -15 stops at 0 (moved -10)",
          near(drag(["c": 10], [-15])[0], -10))
    check("R1 grandchild at 4 dragged -4 exactly lands at 0", near(drag(["g": 4], [-4])[0], -4))
    check("R1 an object at exactly 0 cannot move left", near(drag(["z": 0], [-2])[0], 0))
    check("R1 rightwards is never limited", near(drag(["c": 10], [7])[0], 7))

    // ── R2: a group is floored by its OWN start; its children are not asked ────────────────────
    let a = drag(["A": 20], [-25])[0]
    check("R2 group A@20 dragged -25 stops at 0 (moved -20)", near(a, -20))
    check("R2 ... its child c@10 is carried to -10", near(10 + a, -10))

    // ── R3: an object that starts negative is free while it stays negative ─────────────────────
    check("R3 c@-10 dragged -5 -> -15", near(-10 + drag(["c": -10], [-5])[0], -15))
    check("R3 c@-10 dragged +4 -> -6", near(-10 + drag(["c": -10], [4])[0], -6))
    check("R3 c@-10 dragged -100 -> -110 (no floor at all)", near(-10 + drag(["c": -10], [-100])[0], -110))

    // ── R4: sticky within the gesture ───────────────────────────────────────────────────────────
    let sticky = drag(["c": -10], [5, 15, 12, 4, -20])
    check("R4 frame 1: +5 -> c at -5 (not crossed yet)", near(-10 + sticky[0], -5))
    check("R4 frame 2: +15 -> c at +5 (crossed)", near(-10 + sticky[1], 5))
    check("R4 frame 3: back to +12 -> c at +2", near(-10 + sticky[2], 2))
    check("R4 frame 4: back to +4 -> stops at 0 (sticky)", near(-10 + sticky[3], 0), "\(sticky)")
    check("R4 frame 5: back to -20 -> still 0", near(-10 + sticky[4], 0), "\(sticky)")
    let jump = drag(["c": -10], [10, -3])
    check("R4 landing EXACTLY on 0 counts as reaching it", near(-10 + jump[1], 0), "\(jump)")
    let fresh = drag(["c": -10], [-3])
    check("R4 a NEW gesture starts with nothing crossed", near(-10 + fresh[0], -13))
    // After release the object sits at >= 0, so the next gesture is plain R1.
    check("R4 after release at +5, a new gesture floors at 0 (R1)", near(5 + drag(["c": 5], [-9])[0], 0))
    var g = ZeroFloor.Gesture<String>()
    _ = g.clamp(starts: ["c": -10], proposedDelta: 15)
    check("R4 the gesture remembers the crossing", g.crossed == ["c"])

    // ── R5: one common travel, the most constraining object wins ───────────────────────────────
    let r5a = drag(["c1": 3, "c2": 8, "x": 12], [-10])[0]
    check("R5 c1@3, c2@8, root x@12 dragged -10 -> all move -3", near(r5a, -3))
    check("R5 ... c1 0, c2 5, x 9", near(3 + r5a, 0) && near(8 + r5a, 5) && near(12 + r5a, 9))
    let r5b = drag(["c1": -10, "c2": 5], [-8])[0]
    check("R5 c1@-10, c2@5 dragged -8 -> c2 blocks, all move -5", near(r5b, -5))
    check("R5 ... c1 -> -15, c2 -> 0", near(-10 + r5b, -15) && near(5 + r5b, 0))
    // A negative object that crosses, in a selection: from then on IT limits the travel.
    let r5c = drag(["n": -2, "p": 6], [3, -1])
    check("R5 n@-2 crosses at +3 (n +1); back to -1: n holds at 0 (dt +2)",
          near(r5c[0], 3) && near(r5c[1], 2), "\(r5c)")

    // ── R6: nested groups ──────────────────────────────────────────────────────────────────────
    // A@20 ⊃ B@15 ⊃ c@12 (absolute). Dragging B left by 20: B stops at 0, c goes to -3.
    let r6 = drag(["B": 15], [-20])[0]
    check("R6 B@15 dragged -20 stops at 0 (moved -15)", near(r6, -15))
    check("R6 ... c@12 carried to -3", near(12 + r6, -3))
    check("R6 ... A@20 does not move (not part of the gesture)", true)

    // ── the stateless forms (a release, an API call) ────────────────────────────────────────────
    check("stateless: same answer as a one-frame drag (R5a)",
          near(ZeroFloor.clampedDelta(startsAt: [3, 8, 12], proposedDelta: -10), -3))
    check("stateless: a negative start is free",
          near(ZeroFloor.clampedDelta(startsAt: [-10], proposedDelta: -5), -5))
    // Idempotence: a travel a gesture floored (with a crossing) is left alone by the stateless form.
    var g2 = ZeroFloor.Gesture<String>()
    _ = g2.clamp(starts: ["c": -10], proposedDelta: 15)
    let held = g2.clamp(starts: ["c": -10], proposedDelta: 4)
    check("stateless re-clamp of a sticky travel changes nothing",
          near(ZeroFloor.clampedDelta(startsAt: [-10], proposedDelta: held), held) && near(held, 10))
    check("clampedStart: 3 -> -1 lands at 0", near(ZeroFloor.clampedStart(from: 3, to: -1), 0))
    check("clampedStart: -2 -> -5 stays -5 (R3)", near(ZeroFloor.clampedStart(from: -2, to: -5), -5))
    check("clampedStart: -2 -> -1 stays -1 (R3)", near(ZeroFloor.clampedStart(from: -2, to: -1), -1))
    check("clampedStart: 0 -> 4 = 4", near(ZeroFloor.clampedStart(from: 0, to: 4), 4))
    check("an empty selection has no wall", ZeroFloor.leftTravelLimit(starts: []) == -.infinity)
    check("a start of -1e-12 is not negative (float noise)", !ZeroFloor.isNegative(-1e-12))

    // ── R7: the left-edge trim ─────────────────────────────────────────────────────────────────
    check("R7 child at 2, content before 10: floor wins (-2)", near(ZeroFloor.trimLimit(start: 2, room: 10), -2))
    check("R7 at 2, content before 0.5: the file wins (-0.5)", near(ZeroFloor.trimLimit(start: 2, room: 0.5), -0.5))
    check("R7 group at 3, no source: floor (-3)", near(ZeroFloor.trimLimit(start: 3, room: .infinity), -3))
    check("R7 at -2: no extension at all (0), and no forced crop (the old bug was +2)",
          near(ZeroFloor.trimLimit(start: -2, room: 1), 0))
    check("R7 at -2 with no source: still 0", near(ZeroFloor.trimLimit(start: -2, room: .infinity), 0))
    check("R7 trimmedStart: 2 -> -1 floors at 0", near(ZeroFloor.trimmedStart(from: 2, to: -1), 0))
    check("R7 trimmedStart: -2 -> -1 (a crop of the negative head) kept", near(ZeroFloor.trimmedStart(from: -2, to: -1), -1))
    check("R7 trimmedStart: -2 -> -3 (an extension) refused, stays -2", near(ZeroFloor.trimmedStart(from: -2, to: -3), -2))
    check("R7 trimmedStart: 2 -> 1 = 1", near(ZeroFloor.trimmedStart(from: 2, to: 1), 1))

    // ── R9: no snap onto an invisible edge ─────────────────────────────────────────────────────
    check("R9 an edge at -0.5 is not a target", !ZeroFloor.isSnapTarget(-0.5))
    check("R9 an edge at 0 is a target", ZeroFloor.isSnapTarget(0))
    check("R9 an edge at 3 is a target", ZeroFloor.isSnapTarget(3))

    // ── the root landing ─────────────────────────────────────────────────────────────────────────
    check("rootStart: -3 -> 0, 2 -> 2", near(ZeroFloor.rootStart(-3), 0) && near(ZeroFloor.rootStart(2), 2))

    print(fails.isEmpty ? "ALL PASS (\(total))" : "FAILED \(fails.count)/\(total): \(fails)")
    exit(fails.isEmpty ? 0 : 1)
} }
