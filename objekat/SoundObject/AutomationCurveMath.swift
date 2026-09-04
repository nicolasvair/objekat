import Foundation

// Evaluating an automation curve between its points — the one thing that turns the
// `AutomationPoint.c` field into a shape.
//
// It is a LINE-BY-LINE PORT of the engine: `tracktion_core/utilities/tracktion_Bezier.h`
// (getBezierPoint / getBezierEnds / getBezierYFromX) and `AutomationCurve::getValueAt`. The aim
// is not to imitate the look of a Tracktion curve, it is to be the SAME function: what the
// editor draws at step 2 is exactly what the engine will play at step 3, where `c` goes into
// the parameter curve as it is (the conversion is the identity, @see Automation.swift).
// Any divergence here would be paid for in 'it doesn't sound like it is drawn'.
//
// The engine's convention, kept: `c` belongs to the LEFT point of the segment; 0 = straight;
// |c| ≤ 0.5 = a quadratic bézier with one control point; |c| > 0.5 additionally adds PLATEAUX
// at both ends (the segment stays flat a while before tipping over); ±1 = a step.
enum AutomationCurveMath {

    /// The bézier control point of a segment (x = time, y = value).
    static func bezierPoint(x1: Double, y1: Double, x2: Double, y2: Double,
                            c: Double) -> (x: Double, y: Double) {
        if y2 > y1 {
            let run  = x2 - x1
            let rise = y2 - y1
            let xc = x1 + run / 2
            let yc = y1 + rise / 2
            return (xc - run / 2 * -c, yc + rise / 2 * -c)
        }
        let run  = x2 - x1
        let rise = y1 - y2
        let xc = x1 + run / 2
        let yc = y2 + rise / 2
        return (xc - run / 2 * -c, yc - rise / 2 * -c)
    }

    /// The bézier's bounds when |c| > 0.5: the segment holds its starting (or ending) value
    /// over part of its span, and only curves between those two bounds.
    static func bezierEnds(x1: Double, y1: Double, x2: Double, y2: Double,
                           c: Double) -> (x1: Double, y1: Double, x2: Double, y2: Double) {
        let minic = (abs(c) - 0.5) * 2.0
        let run   = minic * (x2 - x1)
        let rise  = minic * ((y2 > y1) ? (y2 - y1) : (y1 - y2))
        if c > 0 {
            return (x1 + run, y1, x2, y1 < y2 ? (y2 - rise) : (y2 + rise))
        }
        return (x1, y1 < y2 ? (y1 + rise) : (y1 - rise), x2 - run, y2)
    }

    /// The y of the quadratic bézier (x1,y1)–(xb,yb)–(x2,y2) for a given x.
    static func bezierY(atX x: Double, x1: Double, y1: Double,
                        xb: Double, yb: Double, x2: Double, y2: Double) -> Double {
        // A straight (or vertical) segment: nothing to solve. NB: `y1 == y2` returns y1 — a FLAT
        // segment therefore does not curve, whatever `c` says. That is a property of the engine, not
        // a display shortcut: the editor refuses curvature on a flat segment rather than store a `c`
        // with no effect (@see AutomationBandView).
        if x1 == x2 || y1 == y2 { return y1 }
        if x <= x1 { return y1 }
        if x >= x2 { return y2 }

        // A quadratic equation in t solved back from x, then y(t).
        let a = x1 - 2 * xb + x2
        let b = -2 * x1 + 2 * xb
        let c = x1 - x

        var t: Double
        if a == 0 {
            t = -c / b
        } else {
            let disc = max(0, b * b - 4 * a * c)
            t = (-b + disc.squareRoot()) / (2 * a)
            if t < 0 || t > 1 { t = (-b - disc.squareRoot()) / (2 * a) }
        }
        t = t.clamped(to: 0...1)
        return pow(1 - t, 2) * y1 + 2 * t * (1 - t) * yb + pow(t, 2) * y2
    }

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
        let x1 = p1.t, y1 = Double(p1.v)
        let x2 = p2.t, y2 = Double(p2.v)
        let c  = Double(p1.c)

        if c == 0 {
            guard x2 > x1 else { return p2.v }
            let alpha = (t - x1) / (x2 - x1)
            return Float(y1 + alpha * (y2 - y1))
        }

        if c >= -0.5 && c <= 0.5 {
            let bp = bezierPoint(x1: x1, y1: y1, x2: x2, y2: y2, c: c)
            return Float(bezierY(atX: t, x1: x1, y1: y1, xb: bp.x, yb: bp.y, x2: x2, y2: y2))
        }

        let ends = bezierEnds(x1: x1, y1: y1, x2: x2, y2: y2, c: c)
        if t >= x1 && t <= ends.x1 { return p1.v }
        if t >= ends.x2 && t <= x2 { return p2.v }
        let bp = bezierPoint(x1: x1, y1: y1, x2: x2, y2: y2, c: c)
        return Float(bezierY(atX: t, x1: ends.x1, y1: ends.y1,
                             xb: bp.x, yb: bp.y, x2: ends.x2, y2: ends.y2))
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
    /// The segment that straddles zero is carried over with the SAME curvature over a shorter
    /// span, as at a cut (@see AutomationLane.split): the value at 0 is exact, and only the
    /// inside of that one segment is redrawn.
    static func clippedAtZero(_ sorted: [AutomationPoint], default def: Float) -> [AutomationPoint] {
        guard let first = sorted.first, first.t < 0 else { return sorted }
        let v = value(at: 0, in: sorted, default: def)
        let c = sorted.last(where: { $0.t <= 0 })?.c ?? 0
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
