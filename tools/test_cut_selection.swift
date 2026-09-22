// "A cut does not re-aim the selection, the selection follows the matter" — the arithmetic behind
// it, asserted with no screen. `cutSelectionSide` (`Shared/CutSelection.swift`) has no model
// behind it at all, which is why it can be compiled and run alone, exactly like
// `SendColumns` / `SynopticMarquee` / `PianoRollFraming` before it.
//
//     swiftc -parse-as-library \
//         ../objekat/Shared/CutSelection.swift test_cut_selection.swift \
//         -o /tmp/cutsel && /tmp/cutsel
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
enum CutSelectionTest {
  static func main() {

    // MARK: - A plain division (keeping: nil) — durations decide

    // A 10 s object, cut at 80% (8 s in): left = 8 s, right = 2 s. The RIGHT piece is shorter,
    // so it is the one that inherits the selection.
    check("cut at 80% selects the shorter, right-hand piece",
          cutSelectionSide(objectStart: 0, objectDuration: 10, splitTime: 8, keeping: nil) == .right)

    // Cut at 20% (2 s in): left = 2 s, right = 8 s. The LEFT piece is shorter this time.
    check("cut at 20% selects the shorter, left-hand piece",
          cutSelectionSide(objectStart: 0, objectDuration: 10, splitTime: 2, keeping: nil) == .left)

    // Pile at the midpoint: the two halves are exactly equal. Ties go left — the left half
    // always keeps the object's own id, so this costs the selection nothing at all.
    check("an exact half-and-half cut ties, and the tie goes left",
          cutSelectionSide(objectStart: 0, objectDuration: 10, splitTime: 5, keeping: nil) == .left)

    // A difference of 1e-12 is floating-point noise, well under the 1e-9 tolerance: still a tie,
    // still left.
    check("a 1e-12 difference is noise, and still ties left",
          cutSelectionSide(objectStart: 0, objectDuration: 10, splitTime: 5 + 1e-12, keeping: nil) == .left,
          "a difference this small must not read as a real asymmetry")

    // Just past the tolerance, the two halves are genuinely unequal, and the shorter one
    // (still the left one here, being fractionally under 5 s) wins.
    check("just past the 1e-9 tolerance, the smaller half wins outright",
          cutSelectionSide(objectStart: 0, objectDuration: 10, splitTime: 5 - 1e-6, keeping: nil) == .left)
    // And the mirror: nudge the cut the other way — now the RIGHT half is fractionally shorter.
    check("nudging the cut the other way flips which half is shorter",
          cutSelectionSide(objectStart: 0, objectDuration: 10, splitTime: 5 + 1e-6, keeping: nil) == .right,
          "a genuine (if tiny) asymmetry must flip the answer, unlike the 1e-12 case above")

    // MARK: - An object starting before zero (a cropped child of a group, brought back to 0)

    // start = -2, duration = 4 → the object spans [-2, 2]. Cut at -1: left = -1 - (-2) = 1 s,
    // right = 2 - (-1) = 3 s. The left piece (1 s) is the shorter one.
    check("a negative start still measures durations correctly, and the shorter piece wins",
          cutSelectionSide(objectStart: -2, objectDuration: 4, splitTime: -1, keeping: nil) == .left,
          "left = 1s, right = 3s — the left, shorter piece must be the answer")

    // MARK: - An oriented cut (keeping != nil) — the surviving half always wins, whatever its size

    // keeping: .left, with the LEFT piece being the LONGER one (9 s vs 1 s): the duration
    // comparison would have picked .right on its own, but there is no `.right` piece left to
    // select — `keeping` overrides the arithmetic entirely.
    check("keeping .left wins regardless of which half is longer",
          cutSelectionSide(objectStart: 0, objectDuration: 10, splitTime: 9, keeping: .left) == .left)
    check("keeping .right wins regardless of which half is longer",
          cutSelectionSide(objectStart: 0, objectDuration: 10, splitTime: 1, keeping: .right) == .right)

    // MARK: - A sweep: for a plain division, the answer is always the half of minimal duration

    struct SweepCase { let start: Double; let duration: Double; let splitTime: Double }
    let sweep: [SweepCase] = [
        SweepCase(start: 0,   duration: 12,  splitTime: 3),     // left 3, right 9    → left
        SweepCase(start: 0,   duration: 12,  splitTime: 9),     // left 9, right 3    → right
        SweepCase(start: 5,   duration: 20,  splitTime: 6),     // left 1, right 19   → left
        SweepCase(start: 5,   duration: 20,  splitTime: 24),    // left 19, right 1   → right
        SweepCase(start: -10, duration: 15,  splitTime: -9),    // left 1, right 14   → left
        SweepCase(start: -10, duration: 15,  splitTime: 4),     // left 14, right 1   → right
    ]
    for (i, c) in sweep.enumerated() {
        let leftDur  = c.splitTime - c.start
        let rightDur = c.start + c.duration - c.splitTime
        let expected: CutSelectionSide = rightDur < leftDur - 1e-9 ? .right : .left
        let got = cutSelectionSide(objectStart: c.start, objectDuration: c.duration,
                                   splitTime: c.splitTime, keeping: nil)
        check("sweep #\(i): the minimal-duration half wins (left=\(leftDur), right=\(rightDur))",
              got == expected)
    }

    print("\n\(total - fails.count)/\(total) passed")
    if !fails.isEmpty {
        print("FAILURES:")
        for f in fails { print(" - \(f)") }
        exit(1)
    }
  }
}
