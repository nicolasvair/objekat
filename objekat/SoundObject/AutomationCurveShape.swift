import Foundation

// The SHAPE of a bent automation segment — what `AutomationPoint.c` means, in one place.
//
// Until October 2026 `c` meant what Tracktion's own `AutomationCurve` makes of it: a quadratic
// bézier up to |c| = 0.5, then PLATEAUX at both ends and a DISCONTINUOUS jump to the far value
// beyond. Under the hand that read as "bends a little, then clips violently": past the middle of
// the range the segment stopped being a curve and became a held value plus a cliff.
//
// The family that replaces it is the rational "tension" curve, on the segment's normalised
// progress u ∈ [0, 1]:
//
//     f(u; c) = u (1 − c) / (1 + c − 2 c u)       equivalently  u / (u + (1 − u) r),  r = (1 + c) / (1 − c)
//
// and the value is `v1 + (v2 − v1) · f(u)`. What it buys, each property asserted by
// `tools/test_automation_curve_shape.swift`:
//
//   • MONOTONIC for every c: a bent segment never overshoots, never turns back.
//   • SMOOTH in c: no regime change anywhere — the bend grows continuously, and only c = ±1 is a
//     step (held until the end for +1, reached at once for −1, as Tracktion's ±1 already were).
//   • SYMMETRIC: `1 − f_c(1 − u) = f_{−c}(u)` — reversing a segment is negating its c, EXACTLY, so
//     `AutomationLane.mirrored` stays exact; and `f_{−c}` is also the inverse function of `f_c`
//     (bulged and hollowed are the same amount of bend seen from either side).
//   • its MIDPOINT is `(1 − c) / 2`, linear in c — the sign convention is the engine's (c > 0 holds
//     the start value longer, i.e. hollows a rising segment).
//   • CLOSED UNDER RESTRICTION: the part of a bent segment between two of its instants is again a
//     member of the family (`subCurvature`), so a cut, the timeline's zero and the touch-write's
//     boundaries keep the shape EXACTLY instead of approximating it.
//
// File compatibility: the stored `c` is read AS IT IS, nothing is migrated and the session format
// does not move. |c| ≤ 0.5 lands within a hair of the old bézier (midpoint at c = 0.25: 0.377 old,
// 0.375 new; at c = 0.5: 0.264 old, 0.25 new); ±1 stays a step; 0.5 < |c| < 1, which used to be a
// plateau and a cliff, becomes a smooth, stronger bend in the same direction.
//
// The engine does NOT know this family — Tracktion still evaluates its own bézier. So the drawing
// and the audio agree by construction: a bent segment is never handed to the engine as a bent
// segment, it is SAMPLED into straight ones (`engineSegments`) dense enough that the linear
// interpolation the engine does between them stays within a tolerance of this function
// (@see EditViewModel.engineCurvePoints). Only the exact steps (c = ±1) go through as they are,
// because Tracktion's ±1 already IS the same step.
enum AutomationCurveShape {

    // MARK: - The family

    /// The segment's normalised progress `f(u; c)`, for u ∈ [0, 1] (clamped).
    static func progress(_ u: Double, c: Double) -> Double {
        let u = min(max(u, 0), 1)
        if c == 0 { return u }
        if c >= 1 { return u >= 1 ? 1 : 0 }      // step at the END: the start value is held
        if c <= -1 { return u <= 0 ? 0 : 1 }     // step at the START: the end value at once
        // 1 + c − 2cu stays ≥ 1 − |c| > 0 on [0, 1]: no division by zero for |c| < 1.
        return u * (1 - c) / (1 + c - 2 * c * u)
    }

    /// The value of the segment (t1, v1) → (t2, v2) bent by `c`, at time `t`. A flat or
    /// zero-length segment is not bent (a flat segment has no direction to bend towards — the
    /// editor refuses curvature there, @see AutomationBandView.curvableSegment).
    static func value(at t: Double, t1: Double, v1: Double, t2: Double, v2: Double,
                      c: Double) -> Double {
        guard t2 > t1 else { return v2 }
        let u = (t - t1) / (t2 - t1)
        if c == 0 || v1 == v2 { return v1 + (v2 - v1) * min(max(u, 0), 1) }
        return v1 + (v2 - v1) * progress(u, c: c)
    }

    /// The curvature of the part [a, b] (0 ≤ a < b ≤ 1, in the segment's progress) of a segment
    /// bent by `c`, renormalised to its own [0, 1]: the family is closed under restriction, so
    /// the piece is drawn EXACTLY by its own curvature.
    ///
    /// With `r = (1 + c) / (1 − c)`: `r' = (a + (1 − a) r) / (b + (1 − b) r)`, `c' = (r' − 1) / (r' + 1)`.
    static func subCurvature(_ c: Double, from a: Double, to b: Double) -> Double {
        let a = min(max(a, 0), 1), b = min(max(b, 0), 1)
        guard b > a else { return 0 }
        if c == 0 { return 0 }
        // The steps: a piece that does not reach the jump is flat (its curvature says nothing),
        // a piece that holds it keeps the step.
        if c >= 1 { return b >= 1 ? 1 : 0 }
        if c <= -1 { return a <= 0 ? -1 : 0 }
        let r = (1 + c) / (1 - c)
        let rp = (a + (1 - a) * r) / (b + (1 - b) * r)
        return (rp - 1) / (rp + 1)
    }

    // MARK: - The knob the hand turns

    // The hand does not turn `c` directly. Equal steps of c are very unequal to the eye: near 0 a
    // step of 0.05 is barely visible, near 1 the same step changes a curve into a cliff. The hand
    // turns a KNOB b ∈ [−1, 1] instead, mapped onto the family's log-ratio:
    //
    //     ln r = 2·atanh(c) = α b + β b³
    //
    // α sets the fineness near the straight line (a wheel notch moves the midpoint ~1.5 % of the
    // segment's height there), β how far the end of the knob reaches (b = ±1 → |c| ≈ 0.990, a
    // near-step: the midpoint sits at 0.5 % of the height). Neither end saturates early: the
    // notches stay readable all the way (~4 % mid-range, ~1 % near the end).

    static let knobLinear: Double = 1.2
    static let knobCubic: Double = 4.1

    /// The knob's travel per wheel NOTCH: 20 notches from straight to the near-step.
    static let knobStepPerNotch: Double = 0.05

    /// Curvature for a knob position (b clamped to [−1, 1]).
    static func curvature(forKnob b: Double) -> Double {
        let b = min(max(b, -1), 1)
        let g = knobLinear * b + knobCubic * b * b * b
        return tanh(g / 2)
    }

    /// The knob position of a stored curvature — the inverse of `curvature(forKnob:)`, clamped:
    /// anything beyond the knob's end (an old file's c = ±1 step, say) sits AT the end, so the
    /// first notch towards the centre brings it back into the smooth family.
    static func knob(forCurvature c: Double) -> Double {
        if c == 0 { return 0 }
        let cMax = curvature(forKnob: 1)
        let a = abs(c)
        if a >= cMax { return c > 0 ? 1 : -1 }
        let g = log((1 + a) / (1 - a))                     // 2·atanh(|c|)
        // α b + β b³ is strictly increasing on [0, 1]: bisection, then a Newton polish.
        var lo = 0.0, hi = 1.0
        for _ in 0..<60 {
            let mid = (lo + hi) / 2
            if knobLinear * mid + knobCubic * mid * mid * mid < g { lo = mid } else { hi = mid }
        }
        var b = (lo + hi) / 2
        let d = knobLinear + 3 * knobCubic * b * b
        b -= (knobLinear * b + knobCubic * b * b * b - g) / d
        return c > 0 ? min(b, 1) : -min(b, 1)
    }

    /// `c` moved by `knobDelta` on the knob, with no detent.
    static func adjusted(_ c: Float, knobDelta: Double) -> Float {
        let b = knob(forCurvature: Double(c)) + knobDelta
        let out = curvature(forKnob: b)
        // Coming back to the centre lands EXACTLY on a straight segment, not on 1e-17.
        return abs(out) < 1e-6 ? 0 : Float(out)
    }

    // MARK: - The detent at the straight line

    // The straight line is the one curvature the hand wants to land on EXACTLY, and a continuous
    // knob gives it no reason to stop there: passing through it is one frame, and coming back to
    // it by hand meant aiming at a zero nobody can see. So the knob has a DETENT there — a small
    // dead zone of HAND travel inside which the segment stays straight.
    //
    // The model is a second axis, the hand's: H = b + dz·sign(b) away from the centre, and the
    // whole interval |H| ≤ dz maps onto b = 0 (the ⌥-DRAG's model; the wheel's is in notches, below).
    // Travelling through the centre therefore costs 2·dz
    // of extra travel spent on a straight segment (the detent), and starting FROM straight costs
    // dz before the segment bends at all. Everywhere else the knob moves exactly as it did, by the
    // same travel — the detent adds dead travel, it never rescales the live one.
    //
    // The DRAG applies it from an ANCHOR (the knob the gesture started on) and the gesture's TOTAL
    // travel since, never frame by frame: a relative step from inside the dead zone would read
    // "b = 0" back and lose how deep in the zone the hand already was, so the segment would stay
    // straight for ever (the same compounding the pan's detent had to be rid of — @see
    // EditViewModel+Pan).
    //
    // The WHEEL counts in NOTCHES, and a dead zone measured in knob units would hold one notch or
    // two depending on where the gesture started on the notch grid — a detent that is not the same
    // twice. So its rule is written in notches (@see wheelStep): the notch that reaches or crosses
    // straight LANDS on it, the next one in the same direction is held there, and the one after
    // leaves by one notch. Every crossing holds the same, whatever the phase.

    /// The wheel's detent state: the knob, and whether the notch that just landed on straight
    /// still owes a hold (+1 / −1: the direction it came in; 0: none owed).
    struct WheelDetent: Equatable {
        var knob: Double
        var hold: Int = 0
    }

    /// `notches` wheel notches (signed, in KNOB direction) applied one by one to `state`, each one
    /// `step` of knob (@see knobStepPerNotch), through the straight-line detent. The knob stays in
    /// [−1, 1], as it did when each notch re-read it off a clamped curvature.
    static func wheelStep(_ state: WheelDetent, notches: Int,
                          step: Double = knobStepPerNotch) -> WheelDetent {
        var s = state
        guard notches != 0 else { return s }
        let d = notches > 0 ? 1 : -1
        for _ in 0..<abs(notches) {
            if s.knob == 0 {
                if s.hold == d { s.hold = 0; continue }       // the held notch
                s.hold = 0
                s.knob = Double(d) * step
                continue
            }
            let next = s.knob + Double(d) * step
            // `abs(next) < tiny`: notches summed in floating point miss zero by 1e-17.
            if abs(next) < step * 1e-6 || (next > 0) != (s.knob > 0) {
                s.knob = 0                                     // lands on straight…
                s.hold = d                                     // …and owes one held notch
            } else {
                s.knob = min(max(next, -1), 1)
            }
        }
        return s
    }

    /// The detent's half-width on the ⌥-DRAG, in knob units: 0.1 = 6 px at the drag's 60 px per
    /// knob unit (@see AutomationBandView.curveDragTravel), so passing through straight holds it
    /// for some 12 px of hand travel. A first guess.
    static let knobDetentDrag: Double = 0.1

    /// The knob reached from `origin` after `travel` of hand travel, through the detent of
    /// half-width `deadZone` at 0 (no detent when `deadZone` ≤ 0). Not clamped: `curvature(forKnob:)`
    /// clamps.
    static func knob(throughDetentFrom origin: Double, travel: Double, deadZone dz: Double) -> Double {
        guard dz > 0 else { return origin + travel }
        let h0 = origin == 0 ? 0 : origin + (origin > 0 ? dz : -dz)
        let h = h0 + travel
        if abs(h) <= dz { return 0 }
        return h > 0 ? h - dz : h + dz
    }

    /// `c` moved by `knobTravel` (the gesture's TOTAL hand travel on the knob, from the curvature
    /// `origin` it started on) through the straight-line detent — the ⌥-drag's door.
    static func detented(_ origin: Float, knobTravel: Double, deadZone: Double) -> Float {
        let b = knob(throughDetentFrom: knob(forCurvature: Double(origin)),
                     travel: knobTravel, deadZone: deadZone)
        if b == 0 { return 0 }
        let out = curvature(forKnob: b)
        return abs(out) < 1e-6 ? 0 : Float(out)
    }

    // MARK: - Straightening

    /// The segments a SELECTION of points holds: for each pair of points consecutive in TIME whose
    /// two ends are both selected, the storage index of the left one (the point carrying the
    /// segment's curvature, @see AutomationPoint.c). Sorted by time. Two points at the same
    /// instant hold no segment.
    static func segmentOwners(of points: [AutomationPoint], selected: Set<Int>) -> [Int] {
        let order = points.indices.sorted { points[$0].t != points[$1].t
                                            ? points[$0].t < points[$1].t : $0 < $1 }
        var out: [Int] = []
        for k in 0..<max(0, order.count - 1) {
            let a = order[k], b = order[k + 1]
            if selected.contains(a), selected.contains(b), points[a].t < points[b].t { out.append(a) }
        }
        return out
    }

    // MARK: - Sampling for the engine

    /// The tolerance of the engine's sampling, as a fraction of the PARAMETER's range: the
    /// linear interpolation between the samples never strays further than this from the drawn
    /// curve. 0.1 % of a fader's 136 dB is 0.14 dB.
    static let engineTolerance: Double = 0.001

    /// The shortest span between two samples (s). Below it, a near-step's cliff is left to the
    /// engine's straight line — a millisecond is shorter than the engine's own parameter smoothing.
    static let engineMinSpan: Double = 0.001

    /// Depth limit of the subdivision (2^12 pieces at most per segment).
    static let engineMaxDepth = 12

    /// The progress values (strictly inside ]0, 1[, increasing) at which a bent segment must be
    /// sampled so that straight lines between the samples stay within `tolerance` (a fraction of
    /// the segment's own height, |v2 − v1|) of the curve. Empty for a straight segment.
    ///
    /// Adaptive: a piece is cut in two where its chord strays the most, until the stray is under
    /// the tolerance or the piece is shorter than `minSpan` (also in progress units). The stray of
    /// a chord is computed EXACTLY — f is convex (c > 0) or concave (c < 0) on the whole segment,
    /// so the largest stray is where f' equals the chord's slope, which has a closed form.
    static func samplingProgress(c: Double, tolerance: Double, minSpan: Double,
                                 maxDepth: Int = engineMaxDepth) -> [Double] {
        guard c != 0, abs(c) < 1, tolerance > 0 else { return [] }
        let r = (1 + c) / (1 - c)
        var out: [Double] = []
        func f(_ u: Double) -> Double { u / (u + (1 - u) * r) }
        /// The point of [a, b] where the chord strays the most, and that stray.
        func worst(_ a: Double, _ b: Double) -> (u: Double, err: Double) {
            let fa = f(a), fb = f(b)
            let slope = (fb - fa) / (b - a)
            guard slope > 0 else { return ((a + b) / 2, 0) }
            // f'(u) = r / (u + (1 − u) r)² = slope  ⇒  u + (1 − u) r = √(r / slope)
            let k = (r / slope).squareRoot()
            var u = (k - r) / (1 - r)
            if !(u > a && u < b) { u = (a + b) / 2 }
            let err = abs(f(u) - (fa + slope * (u - a)))
            return (u, err)
        }
        func refine(_ a: Double, _ b: Double, _ depth: Int) {
            guard depth < maxDepth, b - a > minSpan else { return }
            let w = worst(a, b)
            guard w.err > tolerance else { return }
            refine(a, w.u, depth + 1)
            out.append(w.u)
            refine(w.u, b, depth + 1)
        }
        refine(0, 1, 0)
        return out
    }

    /// The sorted points of ONE curve, with every bent segment replaced by straight ones — what
    /// the engine is handed. Each returned point has `c = 0`, except the exact steps (|c| ≥ 1),
    /// which Tracktion plays exactly as this family defines them and therefore keep their `c`.
    ///
    /// `range` is the parameter's full value range: the tolerance is a fraction of IT, not of the
    /// segment, so a small bend on a small segment costs nothing.
    static func engineSegments(_ sorted: [AutomationPoint],
                               range: ClosedRange<Float>) -> [AutomationPoint] {
        guard sorted.count > 1 else {
            return sorted.map { var p = $0; if abs(p.c) < 1 { p.c = 0 }; return p }
        }
        let span = max(Double(range.upperBound - range.lowerBound), 1e-9)
        var out: [AutomationPoint] = []
        out.reserveCapacity(sorted.count)
        for i in sorted.indices {
            let p = sorted[i]
            guard i + 1 < sorted.count else {
                out.append(AutomationPoint(t: p.t, v: p.v, c: abs(p.c) >= 1 ? p.c : 0))
                break
            }
            let q = sorted[i + 1]
            let c = Double(p.c)
            if abs(c) >= 1 || c == 0 || p.v == q.v || q.t <= p.t {
                out.append(AutomationPoint(t: p.t, v: p.v, c: abs(c) >= 1 && p.v != q.v ? p.c : 0))
                continue
            }
            out.append(AutomationPoint(t: p.t, v: p.v, c: 0))
            let height = abs(Double(q.v - p.v))
            let dur = q.t - p.t
            let us = samplingProgress(c: c,
                                      tolerance: engineTolerance * span / height,
                                      minSpan: engineMinSpan / dur)
            for u in us {
                let v = Double(p.v) + Double(q.v - p.v) * progress(u, c: c)
                out.append(AutomationPoint(t: p.t + u * dur, v: Float(v), c: 0))
            }
        }
        return out
    }
}
