// The automation pencil's TOUCH WRITE — what the curve becomes when a hand writes over it during
// playback — asserted with no screen, no engine and no transport (@see AutomationTouchWrite).
//
//     cd tools && swiftc -parse-as-library \
//         ../objekat/SoundObject/AutomationTouchWrite.swift \
//         ../objekat/SoundObject/AutomationCurveShape.swift \
//         ../objekat/SoundObject/AutomationCurveMath.swift \
//         ../objekat/SoundObject/Automation.swift \
//         test_automation_touch_write.swift -o /tmp/touchwrite && /tmp/touchwrite
//
// Exit: 0 if every assertion passes, 1 otherwise.

import Foundation

let sendMinDb: Float = -60
let sendMaxDb: Float = 6
extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}

var fails: [String] = []
var total = 0
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    total += 1
    if ok { print("ok    " + label) } else { fails.append(label); print("FAIL  \(label)  \(detail)") }
}
func val(_ pts: [AutomationPoint], _ t: Double, _ def: Float = 0) -> Double {
    Double(AutomationCurveMath.value(at: t, in: pts.sorted { $0.t < $1.t }, default: def))
}

typealias W = AutomationTouchWrite
let range: ClosedRange<Float> = -96...40

/// A hand writing `v(t)` from `a` to `b` at the session's 30 Hz.
func play(_ w: inout W, from a: Double, to b: Double, _ v: (Double) -> Float) {
    var t = a
    while t <= b + 1e-9 { w.write(t: t, v: v(t)); t += 1.0 / 30 }
}

func testReplacement() {
    let orig = [AutomationPoint(t: 0, v: -40), AutomationPoint(t: 10, v: 0)]
    var w = W(original: orig, range: range, bounds: 0...10, defaultValue: 0)
    play(&w, from: 2, to: 4) { _ in -6 }
    let out = w.points(holding: false)
    let a = w.passes[0].start, b = w.passes[0].end
    check("written stretch holds the hand's value",
          stride(from: a, through: b, by: 0.01).allSatisfy { abs(val(out, $0) - -6) < 1e-4 })
    check("before the entry ramp: the original, untouched",
          stride(from: 0.0, through: a - W.entryRamp, by: 0.01).allSatisfy { abs(val(out, $0) - val(orig, $0)) < 1e-4 })
    check("after the return glide: the original, untouched",
          stride(from: b + W.returnGlide, through: 10.0, by: 0.01).allSatisfy { abs(val(out, $0) - val(orig, $0)) < 1e-4 })
    check("original points inside the stretch are gone",
          !out.contains { $0.t > a - W.entryRamp + 1e-9 && $0.t < b + W.returnGlide - 1e-9 && $0.v != -6 })
    check("thinning: a held value is two points", out.filter { $0.v == -6 }.count == 2,
          "\(out.filter { $0.v == -6 }.count)")
    check("every written point is straight", out.filter { $0.v == -6 }.allSatisfy { $0.c == 0 })
    check("the glide lands on the original curve", abs(val(out, b + W.returnGlide) - val(orig, b + W.returnGlide)) < 1e-4)
}

func testThinning() {
    var w = W(original: [], range: range, bounds: 0...20, defaultValue: 0)
    play(&w, from: 0, to: 10) { t in Float(-20 + 10 * sin(t)) }
    let samples = w.passes[0].samples
    let kept = W.thinned(samples, tolerance: W.valueTolerance * Double(range.upperBound - range.lowerBound))
    var worst = 0.0
    for s in samples {
        worst = max(worst, abs(val(kept.map { AutomationPoint(t: $0.t, v: $0.v) }, s.t) - Double(s.v)))
    }
    check("thinning keeps a sine within the tolerance", worst <= W.valueTolerance * 136 + 1e-6, "\(worst)")
    check("thinning drops samples on a smooth gesture (\(samples.count) → \(kept.count))", kept.count < samples.count / 2)
    let ramp = (0...30).map { W.Sample(t: Double($0) / 30, v: Float($0)) }
    check("a straight ramp thins to its two ends", W.thinned(ramp, tolerance: 0.01).count == 2)
}

func testMergeClampBounds() {
    var w = W(original: [], range: range, bounds: 1...5, defaultValue: 0)
    check("refused before the window", !w.write(t: 0.5, v: 0))
    check("refused after the window", !w.write(t: 5.5, v: 0))
    w.write(t: 2, v: 100)
    check("value clamped to the range", w.passes[0].samples[0].v == 40)
    w.write(t: 2.002, v: -10)
    check("a sample 2 ms later is merged (value updated, instant kept)",
          w.passes[0].samples.count == 1 && w.passes[0].samples[0].v == -10 && w.passes[0].samples[0].t == 2)
    w.write(t: 2.05, v: -12)
    check("a sample 50 ms later is a new sample", w.passes[0].samples.count == 2)
}

func testHold() {
    var w = W(original: [AutomationPoint(t: 0, v: 0)], range: range, bounds: 0...10, defaultValue: 0)
    play(&w, from: 1, to: 2) { _ in -30 }
    let live = w.points(holding: true)
    let last = w.passes[0].end
    check("holding: the hand's value is held ahead of the playhead",
          abs(val(live, last + W.holdAhead * 0.9) - -30) < 1e-4)
    let done = w.points(holding: false)
    check("released: no hold — the glide starts at the last sample",
          abs(val(done, last + W.returnGlide) - 0) < 1e-4)
}

func testPasses() {
    let orig = [AutomationPoint(t: 0, v: 0), AutomationPoint(t: 10, v: 0)]
    var w = W(original: orig, range: range, bounds: 0...10, defaultValue: 0)
    play(&w, from: 2, to: 4) { _ in -10 }
    play(&w, from: 1, to: 3) { _ in -20 }      // the loop wrapped round
    check("going backwards opens a new pass", w.passes.count == 2)
    let out = w.points(holding: false)
    check("the later pass wins where they overlap", abs(val(out, 2.5) - -20) < 1e-4)
    check("the earlier pass survives past the later one", abs(val(out, 3.6) - -10) < 1e-4)
    check("outside both, the original", abs(val(out, 6) - 0) < 1e-4 && abs(val(out, 0.5) - 0) < 1e-4)
    var j = W(original: orig, range: range, bounds: 0...10, defaultValue: 0)
    play(&j, from: 1, to: 2) { _ in -10 }
    play(&j, from: 5, to: 6) { _ in -10 }      // a seek forward
    check("a forward jump opens a new pass", j.passes.count == 2)
    check("the stretch jumped over keeps the original", abs(val(j.points(holding: false), 3.5) - 0) < 1e-4)
}

func testEmptyAndCurved() {
    var w = W(original: [], range: range, bounds: 0...10, defaultValue: -12)
    play(&w, from: 3, to: 4) { _ in 0 }
    let out = w.points(holding: false)
    check("no curve before: the static value rules on both sides",
          abs(val(out, 1) - -12) < 1e-4 && abs(val(out, 8) - -12) < 1e-4 && abs(val(out, 3.5) - 0) < 1e-4)
    let curved = [AutomationPoint(t: 0, v: -60, c: 0.8), AutomationPoint(t: 10, v: 20, c: -0.6),
                  AutomationPoint(t: 12, v: -10)]
    var c = W(original: curved, range: range, bounds: 0...12, defaultValue: 0)
    play(&c, from: 4, to: 6) { _ in -30 }
    let o = c.points(holding: false)
    let a = c.passes[0].start - W.entryRamp, b = c.passes[0].end + W.returnGlide
    var worst = 0.0
    for k in 0...1200 {
        let t = Double(k) * 0.01
        if t <= a || t >= b { worst = max(worst, abs(val(o, t) - val(curved, t))) }
    }
    check("a bent segment cut by the write keeps its EXACT shape on both sides", worst < 1e-3, "\(worst)")
}

@main
struct TouchWriteTests {
    static func main() {
        testReplacement(); testThinning(); testMergeClampBounds(); testHold(); testPasses(); testEmptyAndCurved()
        print("\n\(total - fails.count)/\(total) passed")
        if !fails.isEmpty { print("FAILED: \(fails)"); exit(1) }
    }
}
