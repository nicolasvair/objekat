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

    // ── the bounds AS SHOWN (`displayShift`): the first cycle that starts at or after the edge ──
    // IN inside the block (>= 0): shown where it is.
    check("D1 IN >= 0: no shift", LoopRetrim.displayShift(start: 0.25, end: 0.75) == 0
          && LoopRetrim.displayShift(start: 0, end: 1) == 0)
    // IN in ]-P, 0[ (what a left trim leaves): the next cycle, one period on.
    let d2 = LoopRetrim.displayed(start: -0.3, end: 0.7)
    check("D2 IN = -0.3, P = 1: shown at 0.7 / 1.7", near(d2.start, 0.7) && near(d2.end, 1.7) && near(d2.shift, 1), "\(d2)")
    // IN exactly one period before the edge: ON the edge, not a period further (float noise included).
    check("D3 IN = -P: shown on the edge", near(LoopRetrim.displayed(start: -1, end: 0).start, 0)
          && near(LoopRetrim.displayed(start: -1 + 1e-12, end: 0 + 1e-12).start, 0, 1e-9))
    // IN several periods before (set by hand / by repeated trims): k minimal.
    let d4 = LoopRetrim.displayed(start: -2.5, end: -1.5)             // P = 1
    check("D4 IN = -2.5, P = 1: k = 3, shown at 0.5", near(d4.start, 0.5) && near(d4.shift, 3), "\(d4)")
    // The shown IN is always in [0, P) when IN < 0, whatever the period.
    var okRange = true
    for i in 0..<2000 {
        let p = 0.05 + Double(i % 37) * 0.13
        let a = -Double(i % 91) * 0.071
        let d = LoopRetrim.displayed(start: a, end: a + p)
        if !(d.start >= -1e-9 && d.start < p + 1e-9 && near(d.end - d.start, p)) { okRange = false }
        // the shown IN is a repeat of the stored IN
        let k = d.shift / p
        if abs(k - k.rounded()) > 1e-6 { okRange = false }
    }
    check("D5 random: shown IN in [0, P), a whole number of periods away", okRange)
    // A clip trimmed to the left by a clip's anchored retrim: the shown IN is the next repeat's
    // start, i.e. the timeline instant where a repeat of the pattern begins (grid g + k P).
    let base5 = Clip(start: 2, so: 0, v: 1, a: 0, b: 1)
    let tr = base5.retrimmed(to: 2.3)                                   // IN = -0.3
    let shown = LoopRetrim.displayed(start: tr.a, end: tr.b)
    check("D6 after a left trim, the shown IN lands on the grid (2 + k)",
          near((tr.start + shown.start - 2).truncatingRemainder(dividingBy: 1), 0)
          || near(abs((tr.start + shown.start - 2).truncatingRemainder(dividingBy: 1)), 1), "\(tr.start + shown.start)")
    // a drag of the shown marker by d moves the stored one by d: stored = shown - shift.
    check("D7 stored = shown - shift", near((d2.start + 0.1) - d2.shift, -0.3 + 0.1))
    // no period: shown where it is
    check("D8 no period: no shift", LoopRetrim.displayShift(start: -1, end: -1) == 0)

    // ── a looping GROUP's left edge (`porthole`) ──────────────────────────────────────────────
    // group at 2, IN = 0, OUT = 1 (P = 1); left edge to 2.3: the content stays, IN = -0.3.
    let g1 = LoopRetrim.porthole(startTime: 2, loopStart: 0, loopEnd: 1, at: 2.3, allowEarlier: true)!
    check("G1 trim +0.3: no shift, IN -0.3 / OUT 0.7", near(g1.shift, 0) && near(g1.loopStart, -0.3) && near(g1.loopEnd, 0.7), "\(g1)")
    // ... and back to 2.0 from that state (start 2.3, IN -0.3): the identity.
    let g1b = LoopRetrim.porthole(startTime: 2.3, loopStart: g1.loopStart, loopEnd: g1.loopEnd, at: 2, allowEarlier: true)!
    check("G1b out and back: the identity", near(g1b.shift, 0) && near(g1b.loopStart, 0) && near(g1b.loopEnd, 1), "\(g1b)")
    // past one period: 2.3 -> 3.4 = one cycle gone + 0.4 (k = 1): the content moves by +1 (whole period).
    let g2 = LoopRetrim.porthole(startTime: 2, loopStart: 0, loopEnd: 1, at: 3.4, allowEarlier: true)!
    check("G2 trim +1.4: shift +1, IN -0.4", near(g2.shift, 1) && near(g2.loopStart, -0.4), "\(g2)")
    // extending to the left of the grid's origin: the pattern gains a cycle (k = -1, content moves by -P).
    let g3 = LoopRetrim.porthole(startTime: 2, loopStart: 0, loopEnd: 1, at: 1.7, allowEarlier: true)!
    check("G3 extension -0.3: shift -1, IN -0.7", near(g3.shift, -1) && near(g3.loopStart, -0.7), "\(g3)")
    // ... and back in: the identity again (start 1.7, IN -0.7 and content moved by -1).
    let g3b = LoopRetrim.porthole(startTime: 1.7, loopStart: g3.loopStart, loopEnd: g3.loopEnd, at: 2, allowEarlier: true)!
    check("G3b extension then back: shift +1, bounds 0 / 1", near(g3b.shift, 1) && near(g3b.loopStart, 0) && near(g3b.loopEnd, 1), "\(g3b)")
    // the cut / deletion rule is untouched (no extension past the origin).
    let g4 = LoopRetrim.porthole(startTime: 2, loopStart: 0, loopEnd: 1, at: 1.7, allowEarlier: false)!
    check("G4 cut rule: k never negative", near(g4.shift, 0) && near(g4.loopStart, 0.3), "\(g4)")
    // IN inside the block: the grid starts at the edge (a = 0.25 > 0 -> origin = startTime).
    let g5 = LoopRetrim.porthole(startTime: 2, loopStart: 0.25, loopEnd: 0.75, at: 2.1, allowEarlier: true)!
    check("G5 IN inside: content moves by -a, IN = -0.1", near(g5.shift, -0.25) && near(g5.loopStart, -0.1), "\(g5)")
    check("G6 no period: nil", LoopRetrim.porthole(startTime: 0, loopStart: 1, loopEnd: 1, at: 2, allowEarlier: true) == nil)

    print("\n\(total) assertions, \(fails.count) failed")
    print(fails.isEmpty ? "ALL PASS" : "FAILED:\n  " + fails.joined(separator: "\n  "))
    exit(fails.isEmpty ? 0 : 1)
} }
