import Foundation

// Evaluating an automation curve between its points — the one thing that turns the
// `AutomationPoint.c` field into a shape.
//
// The shape itself lives in `AutomationCurveShape` (the rational tension family, October 2026).
// It used to be a line-by-line port of Tracktion's bézier (`tracktion_Bezier.h`), whose
// |c| > 0.5 regime held a plateau and then jumped — the "clips violently" of the ⌥ bend. The
// engine still evaluates its own bézier, so it is never handed a bent segment any more: the push
// SAMPLES each one into straight pieces (@see AutomationCurveShape.engineSegments,
// EditViewModel.engineCurvePoints). What the editor draws through this function is therefore
// what the engine plays, within the sampling tolerance.
//
// The convention kept: `c` belongs to the LEFT point of the segment; 0 = straight; c > 0 holds
// the start value longer; ±1 = a step.
enum AutomationCurveMath {

    /// The curve's value at time `t`, over a list ALREADY SORTED by increasing time.
    /// Outside the points: a plateau (the first / last point's value) — that is the engine's
    /// contract, and what the band draws to the left of the first point as to the right of the last.
    static func value(at t: Double, in sorted: [AutomationPoint], default def: Float) -> Float {
        guard !sorted.isEmpty else { return def }
        // The engine's `nextIndexAfter`: the first point whose time is >= t.
        let index = sorted.firstIndex { $0.t >= t } ?? sorted.count
        if index <= 0      { return sorted[0].v }
        if index >= sorted.count { return sorted[sorted.count - 1].v }

        let p1 = sorted[index - 1]
        let p2 = sorted[index]
        return Float(AutomationCurveShape.value(at: t, t1: p1.t, v1: Double(p1.v),
                                                t2: p2.t, v2: Double(p2.v), c: Double(p1.c)))
    }

    /// The curvatures the segment that STRADDLES `s` must carry on either side of a cut at `s`
    /// (the family is closed under restriction, @see AutomationCurveShape.subCurvature): `left`
    /// for its part before `s` (carried by its own left point, at `leftIndex` in `sorted`),
    /// `right` for the part after (carried by the point laid at `s`). nil when no segment
    /// straddles `s` strictly.
    static func cutCurvatures(at s: Double,
                              in sorted: [AutomationPoint]) -> (leftIndex: Int, left: Float, right: Float)? {
        guard let j = sorted.firstIndex(where: { $0.t > s }), j > 0 else { return nil }
        let p = sorted[j - 1], q = sorted[j]
        guard p.t < s, q.t > p.t else { return nil }
        let u = (s - p.t) / (q.t - p.t)
        let c = Double(p.c)
        return (j - 1,
                Float(AutomationCurveShape.subCurvature(c, from: 0, to: u)),
                Float(AutomationCurveShape.subCurvature(c, from: u, to: 1)))
    }

    /// A SORTED list bounded at the timeline's zero: earlier points are replaced by ONE
    /// point at 0, at the value the curve takes there.
    ///
    /// Used at the one place where a negative time would be lost: the engine clips the times it is
    /// given to 0 (`setAutomationCurve:`) and would therefore stack several values at the same
    /// instant. The case is rare — it takes an object laid at the very start of the project and
    /// trimmed from the left — but the silence of that clipping is not: the curve would start
    /// holding the oldest point's value instead of the right one.
    ///
    /// The segment that straddles zero keeps its shape EXACTLY: the new point at 0 carries the
    /// curvature of the part that remains (@see AutomationCurveShape.subCurvature).
    static func clippedAtZero(_ sorted: [AutomationPoint], default def: Float) -> [AutomationPoint] {
        guard let first = sorted.first, first.t < 0 else { return sorted }
        let v = value(at: 0, in: sorted, default: def)
        let c = cutCurvatures(at: 0, in: sorted)?.right
            ?? (sorted.last(where: { $0.t <= 0 })?.c ?? 0)
        return [AutomationPoint(t: 0, v: v, c: c)] + sorted.filter { $0.t > 0 }
    }
}

extension AutomationLane {
    /// The value of THIS curve at time `t` (relative to the object's start). `default` is used when
    /// the curve has no point at all — a case that should not exist (@see the invariant 'no point
    /// = no automation'), but which a read must not pay for with a crash.
    func value(at t: Double, default def: Float) -> Float {
        AutomationCurveMath.value(at: t, in: sortedPoints, default: def)
    }
}
