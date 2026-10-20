// The SHAPE of a bent automation segment — the family, its exact properties, the knob the hand
// turns and the sampling the engine is handed — asserted with no screen and no engine.
//
//     cd tools && swiftc -parse-as-library \
//         ../objekat/SoundObject/AutomationCurveShape.swift \
//         ../objekat/SoundObject/AutomationCurveMath.swift \
//         ../objekat/SoundObject/Automation.swift \
//         test_automation_curve_shape.swift -o /tmp/curveshape && /tmp/curveshape
//
// Exit: 0 if every assertion passes, 1 otherwise.

import Foundation

// `Automation.swift` reads two globals and one extension of the app; stubbed here.
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
func near(_ a: Double, _ b: Double, _ eps: Double = 1e-9) -> Bool { abs(a - b) <= eps }

typealias S = AutomationCurveShape
let cs: [Double] = [-0.999, -0.99, -0.9, -0.75, -0.5, -0.25, -0.05, 0, 0.05, 0.25, 0.5, 0.75, 0.9, 0.99, 0.999]
let us: [Double] = (0...200).map { Double($0) / 200 }

// MARK: - The family

func testFamily() {
    var endsOK = true, monoOK = true, rangeOK = true, symOK = true, invOK = true, midOK = true
    for c in cs {
        if !(near(S.progress(0, c: c), 0) && near(S.progress(1, c: c), 1)) { endsOK = false }
        var prev = -1.0
        for u in us {
            let f = S.progress(u, c: c)
            if f < prev - 1e-12 { monoOK = false }
            if f < -1e-12 || f > 1 + 1e-12 { rangeOK = false }
            prev = f
            // point symmetry: 1 − f_c(1 − u) = f_{−c}(u)
            if !near(1 - S.progress(1 - u, c: c), S.progress(u, c: -c), 1e-12) { symOK = false }
            // inverse: f_{−c}(f_c(u)) = u
            if !near(S.progress(S.progress(u, c: c), c: -c), u, 1e-9) { invOK = false }
        }
        if !near(S.progress(0.5, c: c), (1 - c) / 2, 1e-12) { midOK = false }
    }
    check("ends: f(0) = 0, f(1) = 1 for every c", endsOK)
    check("monotonic for every c", monoOK)
    check("never overshoots [0, 1]", rangeOK)
    check("symmetric: 1 − f_c(1 − u) = f_{−c}(u)", symOK)
    check("f_{−c} is the inverse of f_c", invOK)
    check("midpoint = (1 − c) / 2", midOK)
    check("c = 0 is the straight line", us.allSatisfy { near(S.progress($0, c: 0), $0) })
    check("c > 0 holds the start value longer (below the chord)",
          S.progress(0.3, c: 0.5) < 0.3 && S.progress(0.7, c: 0.5) < 0.7)
    check("c = +1 is a step at the END", S.progress(0.999, c: 1) == 0 && S.progress(1, c: 1) == 1)
    check("c = −1 is a step at the START", S.progress(0, c: -1) == 0 && S.progress(0.001, c: -1) == 1)
    // Smooth in c: no regime change (the old |c| > 0.5 plateau-and-cliff). The value at a fixed u
    // moves continuously and monotonically with c.
    var smooth = true
    for u in [0.1, 0.5, 0.9] {
        var prev = 2.0
        for k in 0...1998 {
            let c = -0.999 + Double(k) * 0.001
            let f = S.progress(u, c: c)
            if f > prev + 1e-12 { smooth = false }
            if prev < 2, abs(f - prev) > 0.02 { smooth = false }
            prev = f
        }
    }
    check("continuous and monotonic in c (no cliff anywhere below |c| = 0.999)", smooth)
    check("flat segment never bends", S.value(at: 0.4, t1: 0, v1: 3, t2: 1, v2: 3, c: 0.9) == 3)
    check("value(): rising, c = 0.5, midpoint",
          near(S.value(at: 1.5, t1: 1, v1: -10, t2: 2, v2: 10, c: 0.5), -10 + 20 * 0.25))
    check("value(): falling bends the other way",
          S.value(at: 0.5, t1: 0, v1: 10, t2: 1, v2: 0, c: 0.5) > 5)
}

// MARK: - Old files: the stored c read as it is

func testCompat() {
    // The old quadratic bézier's midpoints, for reference: c = 0.25 → 0.377, c = 0.5 → 0.264.
    check("compat: c = 0.25 lands next to the old bézier (0.375 vs 0.377)",
          abs(S.progress(0.5, c: 0.25) - 0.377) < 0.005)
    check("compat: c = 0.5 lands next to the old bézier (0.25 vs 0.264)",
          abs(S.progress(0.5, c: 0.5) - 0.264) < 0.02)
    check("compat: c = 0.75 is now a smooth bend, no plateau at the start",
          S.progress(0.05, c: 0.75) > 0 && S.progress(0.95, c: 0.75) < 1)
}

// MARK: - Exact restriction

func testRestriction() {
    var ok = true
    var worst = 0.0
    for c in cs where abs(c) < 1 {
        for (a, b) in [(0.0, 0.3), (0.2, 0.9), (0.5, 1.0), (0.05, 0.07), (0.0, 1.0)] {
            let cp = S.subCurvature(c, from: a, to: b)
            let fa = S.progress(a, c: c), fb = S.progress(b, c: c)
            for s in stride(from: 0.0, through: 1.0, by: 0.05) {
                let direct = (S.progress(a + (b - a) * s, c: c) - fa) / (fb - fa)
                let piece = S.progress(s, c: cp)
                worst = max(worst, abs(direct - piece))
                if abs(direct - piece) > 1e-9 { ok = false }
            }
        }
    }
    check("a piece of a bent segment is EXACTLY a member of the family", ok, "worst \(worst)")
    check("restriction to [0, 1] is the identity", near(S.subCurvature(0.6, from: 0, to: 1), 0.6, 1e-12))
    check("a step's piece that misses the jump is flat", S.subCurvature(1, from: 0, to: 0.5) == 0)
    check("a step's piece that holds the jump keeps it", S.subCurvature(1, from: 0.5, to: 1) == 1)

    // split(at:) through the model: both halves together draw the original curve exactly.
    let lane = AutomationLane(param: .volume, points: [
        AutomationPoint(t: 0, v: -20, c: 0.7), AutomationPoint(t: 2, v: 6, c: -0.4),
        AutomationPoint(t: 3, v: -6)])
    for s in [0.5, 1.3, 2.5] {
        let (l, r) = lane.split(at: s)
        var maxErr = 0.0
        for k in 0...300 {
            let t = Double(k) * 0.01
            let ref = Double(lane.value(at: t, default: 0))
            let got = t < s ? Double(l.value(at: t, default: 0)) : Double(r.value(at: t - s, default: 0))
            maxErr = max(maxErr, abs(ref - got))
        }
        check("split at \(s): the two halves redraw the curve exactly", maxErr < 1e-4, "max \(maxErr)")
    }
    // mirrored(over:) is exact too.
    let m = lane.mirrored(over: 3)
    var mErr = 0.0
    for k in 0...300 {
        let t = Double(k) * 0.01
        mErr = max(mErr, abs(Double(lane.value(at: t, default: 0)) - Double(m.value(at: 3 - t, default: 0))))
    }
    check("mirrored: the reversed curve is the curve read backwards", mErr < 1e-4, "max \(mErr)")
    // clippedAtZero keeps the straddling segment's shape.
    let neg = [AutomationPoint(t: -1, v: 0, c: 0.8), AutomationPoint(t: 1, v: 10)]
    let clipped = AutomationCurveMath.clippedAtZero(neg, default: 0)
    var cErr = 0.0
    for k in 0...100 {
        let t = Double(k) * 0.01
        cErr = max(cErr, abs(Double(AutomationCurveMath.value(at: t, in: neg, default: 0))
                             - Double(AutomationCurveMath.value(at: t, in: clipped, default: 0))))
    }
    check("clippedAtZero: the part after zero keeps its exact shape", cErr < 1e-4, "max \(cErr)")
}

// MARK: - The knob

func testKnob() {
    check("knob 0 = straight", S.curvature(forKnob: 0) == 0)
    let end = S.curvature(forKnob: 1)
    check("knob end is a NEAR-step (0.985 < c < 0.995)", end > 0.985 && end < 0.995, "\(end)")
    check("knob is antisymmetric", near(S.curvature(forKnob: -0.4), -S.curvature(forKnob: 0.4), 1e-12))
    var mono = true, round = true
    var prev = -2.0
    for k in -100...100 {
        let b = Double(k) / 100
        let c = S.curvature(forKnob: b)
        if c <= prev { mono = false }
        prev = c
        if !near(S.knob(forCurvature: c), b, 1e-9) { round = false }
    }
    check("knob → c strictly increasing", mono)
    check("knob round trip c → knob → c", round)
    check("an old file's c = ±1 sits at the knob's end", S.knob(forCurvature: 1) == 1 && S.knob(forCurvature: -1) == -1)
    // Fine near 0, not saturating in 2 ticks: the midpoint's move per notch.
    func mid(_ notches: Int) -> Double {
        S.progress(0.5, c: S.curvature(forKnob: Double(notches) * S.knobStepPerNotch))
    }
    let first = abs(mid(1) - mid(0))
    check("first notch is FINE (midpoint moves < 2.5 % of the height)", first < 0.025, "\(first)")
    check("two notches are far from saturated (midpoint still > 0.45)", mid(2) > 0.45, "\(mid(2))")
    var steps: [Double] = []
    for n in 0..<20 { steps.append(abs(mid(n + 1) - mid(n))) }
    check("every notch visibly moves the curve (> 0.3 % of the height)", steps.allSatisfy { $0 > 0.003 },
          "\(steps.map { String(format: "%.4f", $0) })")
    check("no notch leaps (< 6 % of the height)", steps.allSatisfy { $0 < 0.06 })
    check("20 notches reach the knob's end", near(S.curvature(forKnob: 20 * S.knobStepPerNotch), end, 1e-12))
    check("adjusted: back to the centre is EXACTLY straight",
          S.adjusted(S.adjusted(0, knobDelta: 0.15), knobDelta: -0.15) == 0)
    check("adjusted: a step comes back into the family on the first notch",
          abs(S.adjusted(1, knobDelta: -0.05)) < 0.99)
}

// MARK: - The detent at the straight line (⌥-wheel and ⌥-drag)

func testDetent() {
    let d = S.knobDetentDrag
    let n = S.knobStepPerNotch
    // No detent = the plain sum.
    check("no dead zone = plain travel", S.knob(throughDetentFrom: 0.3, travel: -0.1, deadZone: 0) == 0.3 - 0.1)
    // Far from the centre the detent changes nothing: the live travel is never rescaled.
    check("detent leaves a travel away from the centre untouched",
          near(S.knob(throughDetentFrom: 0.4, travel: 0.2, deadZone: d), 0.6, 1e-12))
    check("detent leaves a travel that stops short of the centre untouched",
          near(S.knob(throughDetentFrom: 0.4, travel: -0.3, deadZone: d), 0.1, 1e-12))
    // Landing on and holding the centre.
    check("a travel that just reaches the centre lands EXACTLY on it",
          S.knob(throughDetentFrom: 0.4, travel: -0.4, deadZone: d) == 0)
    check("past the centre by less than 2·dz: still straight",
          S.knob(throughDetentFrom: 0.4, travel: -0.4 - 2 * d + 1e-9, deadZone: d) == 0)
    check("past the centre by more than 2·dz: bends the other way by the excess",
          near(S.knob(throughDetentFrom: 0.4, travel: -0.4 - 2 * d - 0.05, deadZone: d), -0.05, 1e-12))
    // Leaving straight costs dz.
    check("from straight, a travel ≤ dz stays straight",
          S.knob(throughDetentFrom: 0, travel: d, deadZone: d) == 0
          && S.knob(throughDetentFrom: 0, travel: -d, deadZone: d) == 0)
    check("from straight, a travel > dz bends by the excess",
          near(S.knob(throughDetentFrom: 0, travel: d + 0.07, deadZone: d), 0.07, 1e-12))
    // Antisymmetric.
    var anti = true
    for o in stride(from: -0.9, through: 0.9, by: 0.1) {
        for t in stride(from: -1.5, through: 1.5, by: 0.05) {
            let a = S.knob(throughDetentFrom: o, travel: t, deadZone: d)
            let b = S.knob(throughDetentFrom: -o, travel: -t, deadZone: d)
            if !near(a, -b, 1e-12) { anti = false }
        }
    }
    check("detent is antisymmetric", anti)
    // Monotonic in the travel (a hand going one way never makes the knob come back).
    var mono = true
    for o in stride(from: -0.9, through: 0.9, by: 0.15) {
        var prev = -Double.infinity
        for k in -300...300 {
            let b = S.knob(throughDetentFrom: o, travel: Double(k) / 100, deadZone: d)
            if b < prev - 1e-12 { mono = false }
            prev = b
        }
    }
    check("detent is monotonic in the travel", mono)
    // Zero travel gives the origin back (to rounding), whatever it is.
    var back = true
    for o in [-0.8, -0.3, -0.01, 0, 0.01, 0.3, 0.8]
    where !near(S.knob(throughDetentFrom: o, travel: 0, deadZone: d), o, 1e-12) { back = false }
    check("zero travel = the origin, whatever it is", back)

    // The WHEEL, in notches (what the view-model does: one state carried notch after notch).
    func wheel(from knob: Double, notches: [Int]) -> [Double] {
        var st = S.WheelDetent(knob: knob)
        return notches.map { k in st = S.wheelStep(st, notches: k); return st.knob }
    }
    let down = wheel(from: 3 * n, notches: Array(repeating: -1, count: 6))
    check("wheel: crossing straight lands on it and holds it one extra notch (2 notches at 0)",
          down.filter { $0 == 0 }.count == 2, "\(down)")
    check("wheel: before reaching straight the notches are the plain ones",
          near(down[0], 2 * n, 1e-12) && near(down[1], n, 1e-12), "\(down)")
    check("wheel: then leaves straight on the other side, one notch at a time",
          near(down[4], -n, 1e-12) && near(down[5], -2 * n, 1e-12), "\(down)")
    // Phase independence: a knob OFF the notch grid (left there by a drag) holds just the same.
    var phaseOK = true
    for k0 in stride(from: 0.012, through: 0.4, by: 0.0137) {
        let run = wheel(from: k0, notches: Array(repeating: -1, count: 20))
        let z = run.filter { $0 == 0 }.count
        if z != 2 { phaseOK = false }
    }
    check("wheel: every crossing holds exactly 2 notches, whatever the starting phase", phaseOK)
    let up = wheel(from: 0, notches: [1, 1, 1])
    check("wheel: from straight, the first notch bends by a full notch",
          near(up[0], n, 1e-12) && near(up[2], 3 * n, 1e-12), "\(up)")
    check("wheel: turning back right after landing leaves at once (the hold is directional)",
          wheel(from: n, notches: [-1, 1]) == [0, n])
    check("wheel: a multi-notch event = the same notches one by one",
          S.wheelStep(S.WheelDetent(knob: 3 * n), notches: -6) == {
              var st = S.WheelDetent(knob: 3 * n)
              for _ in 0..<6 { st = S.wheelStep(st, notches: -1) }
              return st }())
    check("wheel: the knob stays within its travel",
          wheel(from: 0.98, notches: [1, 1]).allSatisfy { $0 <= 1 }
          && wheel(from: -0.98, notches: [-1, -1]).allSatisfy { $0 >= -1 })
    check("wheel: zero notches change nothing",
          S.wheelStep(S.WheelDetent(knob: 0, hold: 1), notches: 0) == S.WheelDetent(knob: 0, hold: 1))
    check("detented: a straight result is EXACTLY 0",
          S.detented(Float(S.curvature(forKnob: 0.3)), knobTravel: -0.3 - d, deadZone: d) == 0)

    // The DRAG, in pixels: 60 px per knob unit (AutomationBandView.curveDragTravel = 120, dk = dy·2/120).
    let pxPerKnob = 60.0
    func drag(_ c: Float, px: Double) -> Float { S.detented(c, knobTravel: px / pxPerKnob, deadZone: d) }
    let bent = Float(S.curvature(forKnob: 0.5))       // 30 px from straight
    var held = 0
    for px in stride(from: -60.0, through: 0, by: 1) where drag(bent, px: px) == 0 { held += 1 }
    check("drag: passing through straight holds it for about 12 px (11…13)", (11...13).contains(held), "\(held)")
    check("drag: 30 px back lands exactly straight", drag(bent, px: -30) == 0)
    check("drag: 6 px from straight do not bend it yet", drag(0, px: 6) == 0 && drag(0, px: -6) == 0)
    check("drag: 7 px from straight do", drag(0, px: 7) != 0 && drag(0, px: -7) != 0)
}

// MARK: - The segments a selection holds

func testSegmentOwners() {
    // Storage order deliberately not time order.
    let pts = [AutomationPoint(t: 2, v: 1, c: 0.5), AutomationPoint(t: 0, v: 0, c: 0.3),
               AutomationPoint(t: 1, v: 3, c: -0.2), AutomationPoint(t: 3, v: 0, c: 0.4)]
    check("all selected → every segment, left owner, in time order",
          S.segmentOwners(of: pts, selected: [0, 1, 2, 3]) == [1, 2, 0])
    check("a hole in the selection breaks the segment on both sides",
          S.segmentOwners(of: pts, selected: [1, 0, 3]) == [0])
    check("one point holds no segment", S.segmentOwners(of: pts, selected: [2]).isEmpty)
    check("nothing selected, nothing held", S.segmentOwners(of: pts, selected: []).isEmpty)
    check("empty curve", S.segmentOwners(of: [], selected: [0]).isEmpty)
    let same = [AutomationPoint(t: 1, v: 0), AutomationPoint(t: 1, v: 2)]
    check("two points at the same instant hold no segment", S.segmentOwners(of: same, selected: [0, 1]).isEmpty)
}

// MARK: - The engine's sampling

func testSampling() {
    let range: ClosedRange<Float> = -96...40
    let span = Double(range.upperBound - range.lowerBound)
    var allOK = true
    var maxCount = 0
    for c in cs where abs(c) < 1 {
        let pts = [AutomationPoint(t: 1, v: -60, c: Float(c)), AutomationPoint(t: 3, v: 12)]
        let lin = AutomationCurveShape.engineSegments(pts, range: range)
        maxCount = max(maxCount, lin.count)
        if lin.contains(where: { $0.c != 0 }) { allOK = false }
        // Linear interpolation over `lin` (what the engine does with c = 0) vs the drawn curve.
        var worst = 0.0
        for k in 0...4000 {
            let t = 1 + Double(k) * 0.0005
            let drawn = Double(AutomationCurveMath.value(at: t, in: pts, default: 0))
            let heard = Double(AutomationCurveMath.value(at: t, in: lin, default: 0))
            // Within a 1 ms piece (the minimum span) a near-step may stray further: excluded,
            // that is the sampling's stated floor.
            worst = max(worst, abs(drawn - heard))
        }
        let tol = AutomationCurveShape.engineTolerance * span
        if abs(c) <= 0.99, worst > tol * 1.01 { allOK = false; print("   c=\(c) worst \(worst) tol \(tol)") }
    }
    check("sampled curve heard within 0.1 % of the range of the drawn one (|c| ≤ 0.99)", allOK)
    check("sampling stays bounded (\(maxCount) points max)", maxCount < 400, "\(maxCount)")
    let straight = AutomationCurveShape.engineSegments(
        [AutomationPoint(t: 0, v: 0), AutomationPoint(t: 1, v: 5)], range: range)
    check("a straight curve is handed over untouched", straight.count == 2)
    let step = AutomationCurveShape.engineSegments(
        [AutomationPoint(t: 0, v: 0, c: 1), AutomationPoint(t: 1, v: 5)], range: range)
    check("a step keeps its c = 1 (the engine's own step is the same)", step.count == 2 && step[0].c == 1)
    let flat = AutomationCurveShape.engineSegments(
        [AutomationPoint(t: 0, v: 3, c: 0.8), AutomationPoint(t: 1, v: 3)], range: range)
    check("a flat bent segment goes straight (c dropped)", flat.count == 2 && flat[0].c == 0)
}

@main
struct CurveShapeTests {
    static func main() {
        testFamily(); testCompat(); testRestriction(); testKnob(); testDetent(); testSegmentOwners(); testSampling()
        print("\n\(total - fails.count)/\(total) passed")
        if !fails.isEmpty { print("FAILED: \(fails)"); exit(1) }
    }
}

