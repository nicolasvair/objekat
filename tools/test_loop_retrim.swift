// The loop-anchored retrim of a LOOPING clip (`Shared/LoopRetrim.swift`), asserted with no screen.
//
//     swiftc -parse-as-library ../objekat/Shared/LoopRetrim.swift test_loop_retrim.swift -o /tmp/looptrim && /tmp/looptrim
//
// A model of what is HEARD stands in for the engine: at timeline instant `t`, a clip whose left
// edge is at `startTime`, entering its file at `sourceOffset`, with IN/OUT bounds `a`/`b` (local
// seconds) plays the file at
//     fileIN + posmod(t − g, P)·v     with  g = startTime + min(0, a),  P = (b − a)
// (the engine's loop reader and `WaveformDrawing.LoopFold`). The retrim must leave that function
// unchanged at every instant that stays inside the window.
// Exit: 0 if every assertion passes, 1 otherwise.

import Foundation

var fails: [String] = []
var total = 0
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    total += 1
    if ok { print("ok    " + label) } else { fails.append(label); print("FAIL  \(label)  \(detail)") }
}
func near(_ a: Double, _ b: Double, _ eps: Double = 1e-9) -> Bool { abs(a - b) < eps }

/// A looping clip as the model stores it.
struct Clip {
    var start: Double
    var so: Double
    var v: Double
    var a: Double           // IN, local
    var b: Double           // OUT, local
    var fileIn: Double { so + a * v }
    var fileOut: Double { so + b * v }

    /// What is heard at timeline instant `t` (a position in the FILE, seconds).
    func heard(at t: Double) -> Double {
        let p = b - a
        let g = start + min(0, a)
        var x = (t - g).truncatingRemainder(dividingBy: p)
        if x < 0 { x += p }
        return (so + a * v) + x * v
    }

    /// The window's left edge goes to `newStart`.
    func retrimmed(to newStart: Double) -> Clip {
        guard let w = LoopRetrim.anchored(startTime: start, sourceOffset: so, speedRatio: v,
                                          fileLoopIn: fileIn, fileLoopOut: fileOut,
                                          newStart: newStart) else { return self }
        return Clip(start: newStart, so: w.sourceOffset, v: v, a: w.loopStart, b: w.loopEnd)
    }
}

/// The largest difference of what is heard between two states over [from, to], 1 ms apart.
func maxDiff(_ x: Clip, _ y: Clip, from: Double, to: Double) -> Double {
    var m = 0.0
    var t = from
    while t <= to {
        m = max(m, abs(x.heard(at: t) - y.heard(at: t)))
        t += 0.001
    }
    return m
}

@main struct Runner { static func main() {
    // The scenario of the bug: a 1 s ramp, looped, 4 s, laid at 2 s.
    let base = Clip(start: 2, so: 0, v: 1, a: 0, b: 1)

    // ── T1: a small trim (+0.25) ─────────────────────────────────────────────────────────────
    let t1 = base.retrimmed(to: 2.25)
    check("T1 start follows", near(t1.start, 2.25))
    check("T1 sourceOffset = 0.25", near(t1.so, 0.25), "\(t1.so)")
    check("T1 IN = -0.25", near(t1.a, -0.25), "\(t1.a)")
    check("T1 OUT = 0.75", near(t1.b, 0.75), "\(t1.b)")
    check("T1 the grid is fixed: what is heard is unchanged on [2.25, 6]",
          maxDiff(base, t1, from: 2.25, to: 6) < 1e-6)
    check("T1 the pattern restarts at 3, 4, 5 (the same instants as before)",
          near(t1.heard(at: 3.0001), 0.0001, 1e-6) && near(t1.heard(at: 4.0001), 0.0001, 1e-6)
              && near(t1.heard(at: 5.0001), 0.0001, 1e-6))

    // ── T2: a trim past one period (+1.5) ────────────────────────────────────────────────────
    let t2 = base.retrimmed(to: 3.5)
    check("T2 sourceOffset = 0.5 (a whole repeat swallowed)", near(t2.so, 0.5), "\(t2.so)")
    check("T2 IN = -0.5 and OUT = 0.5", near(t2.a, -0.5) && near(t2.b, 0.5), "\(t2.a) \(t2.b)")
    check("T2 identical on [3.5, 6]", maxDiff(base, t2, from: 3.5, to: 6) < 1e-6)

    // ── T3: round trips are EXACT ────────────────────────────────────────────────────────────
    for d in [0.25, 1.5, 0.1, 0.3333333333, 2.7] {
        let back = base.retrimmed(to: 2 + d).retrimmed(to: 2)
        check("T3 round trip +\(d)", near(back.so, 0, 1e-9) && near(back.a, 0, 1e-9) && near(back.b, 1, 1e-9)
              && near(back.start, 2), "so \(back.so) a \(back.a) b \(back.b)")
    }
    // Many small steps there and back stay on the grid.
    var walk = base
    for i in 1...40 { walk = walk.retrimmed(to: 2 + Double(i) * 0.07) }
    for i in stride(from: 39, through: 0, by: -1) { walk = walk.retrimmed(to: 2 + Double(i) * 0.07) }
    check("T3 40 steps forward and 40 back", near(walk.so, 0, 1e-7) && near(walk.a, 0, 1e-7), "so \(walk.so) a \(walk.a)")

    // ── T4: extension to the LEFT shows the previous repeats ─────────────────────────────────
    let t4 = base.retrimmed(to: 1.0)
    check("T4 extended by 1 s: the grid holds, nothing moves in the file", near(t4.so, 0, 1e-9) && near(t4.a, 0, 1e-9),
          "so \(t4.so) a \(t4.a)")
    check("T4 [1, 2] now plays the previous repeat; [2, 6] unchanged", maxDiff(base, t4, from: 2, to: 6) < 1e-6)
    let t4b = base.retrimmed(to: 1.75)
    check("T4b extended by 0.25: enters the file 0.75 in", near(t4b.so, 0.75) && near(t4b.a, -0.75), "\(t4b.so) \(t4b.a)")
    check("T4b [2, 6] unchanged", maxDiff(base, t4b, from: 2, to: 6) < 1e-6)

    // ── T5: IN INSIDE the block — the matter before IN is never heard (convention kept) ───────
    let inBlock = Clip(start: 2, so: 0, v: 1, a: 0.25, b: 0.75)
    check("T5 fixture: the left edge plays IN", near(inBlock.heard(at: 2.0), 0.25))
    let t5 = inBlock.retrimmed(to: 2.1)
    check("T5 trim +0.1: the grid is fixed (origin = the old edge, not IN)",
          maxDiff(inBlock, t5, from: 2.1, to: 5) < 1e-6)
    check("T5 canonical form: IN <= 0", t5.a <= 0 && near(t5.b - t5.a, 0.5), "\(t5.a) \(t5.b)")
    let t5b = inBlock.retrimmed(to: 1.9)
    check("T5 extension -0.1: still on the grid", maxDiff(inBlock, t5b, from: 2.0, to: 5) < 1e-6)

    // ── T6: speed 2 ─────────────────────────────────────────────────────────────────────────
    let fast = Clip(start: 2, so: 0, v: 2, a: 0, b: 0.5)         // 1 s of file at x2 = 0.5 s period
    let t6 = fast.retrimmed(to: 2.2)
    check("T6 speed 2: sourceOffset advances by 0.2 x 2 = 0.4", near(t6.so, 0.4), "\(t6.so)")
    check("T6 speed 2: IN = -0.2, OUT = 0.3", near(t6.a, -0.2) && near(t6.b, 0.3), "\(t6.a) \(t6.b)")
    check("T6 speed 2: identical on [2.2, 5]", maxDiff(fast, t6, from: 2.2, to: 5) < 1e-6)
    let t6b = fast.retrimmed(to: 2.7)                            // past one period (0.5)
    check("T6 speed 2: +0.7 = one repeat + 0.2", near(t6b.so, 0.4) && near(t6b.a, -0.2), "\(t6b.so) \(t6b.a)")

    // ── T7: a sub-slice [0.25, 0.75] of a longer file, offset in the file ───────────────────
    let slice = Clip(start: 1, so: 0.5, v: 1, a: -0.25, b: 0.25)     // fileIn 0.25, fileOut 0.75
    let t7 = slice.retrimmed(to: 1.1)
    check("T7 slice: identical", maxDiff(slice, t7, from: 1.1, to: 4) < 1e-6)
    check("T7 slice: stays within [fileIN, fileOUT)", t7.so >= 0.25 - 1e-9 && t7.so < 0.75, "\(t7.so)")

    // ── no period → nil (the ordinary trim stays in charge) ──────────────────────────────────
    check("degenerate loop: nil", LoopRetrim.anchored(startTime: 0, sourceOffset: 0, speedRatio: 1,
                                                       fileLoopIn: 0.5, fileLoopOut: 0.5, newStart: 1) == nil)

    // ── a zero trim changes nothing ─────────────────────────────────────────────────────────
    let t0 = base.retrimmed(to: 2)
    check("zero trim: the same state", near(t0.so, 0) && near(t0.a, 0) && near(t0.b, 1))

    print("\n\(total) assertions, \(fails.count) failed")
    print(fails.isEmpty ? "ALL PASS" : "FAILED:\n  " + fails.joined(separator: "\n  "))
    exit(fails.isEmpty ? 0 : 1)
} }
