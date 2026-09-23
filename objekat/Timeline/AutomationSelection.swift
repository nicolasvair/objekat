import CoreGraphics
import Foundation

// MARK: - Transforming a selection of automation points: the arithmetic, and nothing else
//
// No view here, no view-model, not even a `ParamRef` — everything is NORMALISED. That is the whole
// point: the transformation is the half of this feature an eye would otherwise have to check, and
// a unit that depends on nothing but CoreGraphics can be compiled on its own and asserted with no
// screen (@see tools/test_automation_transform.swift). The same reasoning, and the same shape, as
// `SynopticMarquee` — which is the other geometry of this project that had nothing behind it.

/// A point as the transformation sees it: a time, and a NORMALISED value (0 = the bottom of the
/// parameter's range, 1 = its top). Deliberately not an `AutomationPoint`: a volume runs from
/// -96 to +40 dB and a pan from -1 to +1, and "a point at 0 does not move" has to mean the same
/// thing on both. The conversion lives at the geometry's door, once.
struct AutomationSample: Equatable {
    var t: Double
    var n: Double
    init(t: Double, n: Double) { self.t = t; self.n = n }
}

enum AutomationTransform {

    /// The eight grips of the box. A corner is NOT a fifth kind of thing: it is a vertical scale
    /// (like `top` / `bottom`) whose factor is interpolated in time.
    enum Handle: Equatable {
        case top, bottom, left, right
        case topLeft, topRight, bottomLeft, bottomRight

        /// Does this grip pull the box's TOP edge? The two corners of the top do, like `top`
        /// itself — which is what makes four corners out of two anchors × two pulled edges.
        var pullsTop: Bool {
            switch self {
            case .top, .topLeft, .topRight: return true
            default:                        return false
            }
        }

        /// Does this grip move TIME rather than value? `left` and `right` alone. A corner does
        /// not: it is a vertical scale with a gradient, and letting it drag time as well would
        /// make one gesture out of two (@see the invariants on `apply`).
        var movesTime: Bool { self == .left || self == .right }
    }

    /// The selection's TIME envelope — every row together, since the box's X axis is global.
    ///
    /// It carries no vertical extent, and that is not an oversight: nothing reads the points'
    /// height any more. The box's Y covers the ROWS the selection touches, not the matter inside
    /// them (@see the note on the two axes, in `AutomationBandGeometry.selectionBox`), so a
    /// vertical span here would only be a second, contradictory answer to the same question.
    struct TimeSpan: Equatable {
        var t0: Double
        var t1: Double
        init(t0: Double, t1: Double) { self.t0 = t0; self.t1 = t1 }
    }

    /// What a grip does to TIME. Separate from the value factor because the two axes are read
    /// differently: in X the box hugs the material, so the pulled edge follows the hand exactly.
    enum TimeChange: Equatable {
        case none
        /// A constant delta — the fallback when the selection has no time extent to stretch.
        case shift(Double)
        /// Stretch around a fixed instant: `t' = anchor + (t - anchor) * k`.
        case scale(anchor: Double, k: Double)
    }

    /// The request a grip makes — ONE for the WHOLE selection, however many rows it spans. It
    /// carries PROPORTIONS, and a proportion has no unit to be per-row about: that single value
    /// travelling to every row IS "the same proportions, not the same values", made into a type.
    struct Request: Equatable {
        /// The vertical factor. 1 = nothing moves.
        var valueK: Double = 1
        /// Where the value scale is ANCHORED: false = normalised 0 (`top` and the two TOP
        /// corners), true = normalised 1 (`bottom` and the two BOTTOM corners).
        var anchorHigh: Bool = false
        /// Non-nil ⇒ the factor is INTERPOLATED in time: `valueK` at `pulledT`, 1.0 at
        /// `oppositeT`. That is a corner, and the only thing that makes one. In SECONDS, and
        /// shared by every row, the box's X axis being global.
        var skew: (pulledT: Double, oppositeT: Double)? = nil
        var time: TimeChange = .none

        init(valueK: Double = 1, anchorHigh: Bool = false,
             skew: (pulledT: Double, oppositeT: Double)? = nil, time: TimeChange = .none) {
            self.valueK = valueK
            self.anchorHigh = anchorHigh
            self.skew = skew
            self.time = time
        }

        /// Written by hand: a tuple carries no synthesised `Equatable`, and `skew` is the one
        /// field that is one.
        static func == (a: Request, b: Request) -> Bool {
            guard a.valueK == b.valueK, a.anchorHigh == b.anchorHigh, a.time == b.time
            else { return false }
            switch (a.skew, b.skew) {
            case (nil, nil):                 return true
            case (let x?, let y?):           return x.pulledT == y.pulledT && x.oppositeT == y.oppositeT
            default:                         return false
            }
        }
    }

    // MARK: - Reading the gesture

    /// The selection's time envelope. nil on an empty selection — there is no box to draw and no
    /// grip to pull.
    static func timeSpan(of samples: [AutomationSample]) -> TimeSpan? {
        guard let lo = samples.map(\.t).min(), let hi = samples.map(\.t).max() else { return nil }
        return TimeSpan(t0: lo, t1: hi)
    }

    /// The vertical factor a grip asks for: how far the PULLED edge has travelled, measured
    /// against the box's own height, the OPPOSITE edge standing still. A pure ratio of pixels — it
    /// reads NO point, which is exactly why the "extreme sitting on the anchor" case that used to
    /// need a nil has nothing left to be undefined about.
    ///
    /// 1 at rest (the pointer on the pulled edge), 0 on the anchor edge, and UNBOUNDED past the
    /// pulled one: asking for more than the range allows is how a selection whose top already sits
    /// at the ceiling raises the rest. NOTHING on the pointer's path may clamp, and this is that
    /// path — which is why there is no bounding here and none in the geometry that feeds it.
    ///
    /// THE BOX IS NOT A FRAME, IT IS A DIAL, and that is worth saying because it reads the other
    /// way round: its edges say where to take hold and what travel to cover; the ANCHORING, for
    /// its part, is SEMANTIC and PER ROW (normalised 0 for the top grip, 1 for the bottom one, in
    /// `apply`). Pixels serve to read `k`, never to anchor.
    ///
    /// No guard on the denominator: the box covers at least one whole row in Y (@see
    /// `AutomationBandGeometry.selectionBox`), so the two edges are never the same pixel.
    static func boxFactor(pulled: Double, opposite: Double, pointer: Double) -> Double {
        (pointer - opposite) / (pulled - opposite)
    }

    /// The time factor a horizontal grip asks for: the extreme point of the selection is carried
    /// onto `target`, `anchor` standing still.
    ///
    /// nil when the selection has NO time extent — one point, or several stacked at the same
    /// instant. The caller then falls back on `.shift`. Unlike the vertical case, this
    /// degeneracy is real: here the extreme IS the material, and material with no extent cannot
    /// be stretched, only moved.
    ///
    /// Bounded to >= 0: pulling the right grip past the anchor would MIRROR the selection about
    /// it, and the mirror is another gesture — it exists already
    /// (@see `AutomationLane.mirrored(over:)`).
    static func timeFactor(extreme: Double, target: Double, anchor: Double) -> Double? {
        let span = extreme - anchor
        guard abs(span) > 1e-12 else { return nil }
        return max(0, (target - anchor) / span)
    }

    /// value ↔ NORMALISED against explicit bounds. Here and not only in the geometry so that the
    /// round trip can be asserted with no screen on the REAL bounds (-96…40 dB, -1…1): the
    /// geometry's `normalized(_:ref:)` is a two-line wrapper whose only job is the `ParamRef`
    /// lookup.
    static func normalized(_ v: Double, lo: Double, hi: Double) -> Double {
        let span = hi - lo
        guard span > 0 else { return 0.5 }
        return (v - lo) / span
    }

    static func denormalized(_ n: Double, lo: Double, hi: Double) -> Double {
        lo + n * (hi - lo)
    }

    /// ⇧ = fine adjustment: the factor is brought back towards 1 by a factor of four. Not a
    /// comfort on this gesture — a row is some sixteen pixels tall, so `k = 2` sits sixteen pixels
    /// above the box's edge, and without this the grip would be unusable on anything but a coarse
    /// move. `k == 1` stays `1`, so ⇧ never moves anything by itself.
    static func fine(_ k: Double) -> Double { 1 + (k - 1) / 4 }

    /// WHAT the gesture asks for, decided from the grip and the pointer; `apply` is what carries
    /// it out.
    ///
    /// `verticalK` comes from `boxFactor` and is bounded to >= 0 HERE, so that the ratio itself
    /// stays pure: a negative factor would mirror the curve about its anchor, and the mirror is
    /// another gesture.
    static func request(_ handle: Handle, span: TimeSpan,
                        verticalK: Double, targetT: Double, fineTune: Bool) -> Request {
        var r = Request()

        if handle.movesTime {
            // In X the box HUGS THE MATERIAL: the pulled edge is the selection's own extreme
            // point, so it follows the hand exactly, and the opposite extreme is the pivot.
            let pulledT   = handle == .left ? span.t0 : span.t1
            let anchorT   = handle == .left ? span.t1 : span.t0
            if let k = timeFactor(extreme: pulledT, target: targetT, anchor: anchorT) {
                r.time = .scale(anchor: anchorT, k: fineTune ? fine(k) : k)
            } else {
                let d = targetT - pulledT
                r.time = .shift(fineTune ? d / 4 : d)
            }
            return r
        }

        // Every other grip is a VERTICAL scale. Its anchor is semantic and per row: the top grip
        // and the two top corners leave normalised 0 alone, the bottom ones leave normalised 1.
        r.valueK = max(0, fineTune ? fine(verticalK) : verticalK)
        r.anchorHigh = !handle.pullsTop

        switch handle {
        case .topLeft, .bottomLeft:   r.skew = (pulledT: span.t0, oppositeT: span.t1)
        case .topRight, .bottomRight: r.skew = (pulledT: span.t1, oppositeT: span.t0)
        default:                      break
        }
        return r
    }

    // MARK: - Carrying it out

    /// The transformation itself, ALWAYS from the ORIGINAL samples. Four invariants, each of them
    /// a way this comes apart when it is written otherwise:
    ///
    /// - the factor reads the ORIGINAL `t`, never `t'`. Otherwise a gesture that also moves time
    ///   would run after its own tail, the gradient chasing the points it has just displaced;
    /// - the corners do NOT move time (`time == .none`). Four corners = 2 anchors × 2 pulled
    ///   edges, and nothing else;
    /// - the clamp is a clamp of OUTPUT, per point, recomputed from the originals on every frame
    ///   and NEVER fed back. That is what makes the whole thing non-destructive: a selection whose
    ///   top point already sits at the ceiling can be pushed up (that one stays, the others rise)
    ///   and brought back down to exactly where it was. Composing on the current state instead
    ///   would flatten the curve against the bound and keep it there;
    /// - `valueK` and the `k` of `.scale` are >= 0 (bounded upstream, in `request` and
    ///   `timeFactor`). A negative factor mirrors, and the mirror is another gesture.
    static func apply(_ r: Request, to samples: [AutomationSample]) -> [AutomationSample] {
        samples.map { s in
            let f   = factor(r, atT: s.t)
            let raw = r.anchorHigh ? 1 - (1 - s.n) * f : s.n * f
            // No bound on `t`, on purpose and in step with `updateAutomationPoints`: a negative
            // time is matter hidden behind the object's left edge, not an error.
            return AutomationSample(t: movedT(r, s.t), n: bounded(raw, 0, 1))
        }
    }

    /// The vertical factor AT AN INSTANT: `valueK` everywhere, except under a corner, where it
    /// runs from `valueK` on the pulled edge to 1 on the opposite one.
    ///
    /// Split out of `apply` because the BOX THE EYE FOLLOWS has to read the very same number
    /// (@see `drawnQuad`). Two copies of this gradient would come apart on the day one of them
    /// gains a bound, and the symptom — a box agreeing with the points everywhere but under a
    /// corner — is the kind one looks at for a long time before believing.
    static func factor(_ r: Request, atT t: Double) -> Double {
        guard let skew = r.skew else { return r.valueK }
        let span = skew.oppositeT - skew.pulledT
        // A selection with NO time extent (one point, or several at the same instant): the
        // gradient has nowhere to run, so a corner degenerates into a flat scale — full
        // everywhere. Stated rather than divided through, which would give a NaN.
        let u = abs(span) < 1e-12 ? 0 : bounded((t - skew.pulledT) / span, 0, 1)
        return r.valueK + (1 - r.valueK) * u
    }

    /// Where an instant lands. Split out for the same reason as `factor`, and used on the BOX'S
    /// OWN EDGES, which are not points of the material.
    static func movedT(_ r: Request, _ t: Double) -> Double {
        switch r.time {
        case .none:                     return t
        case .shift(let d):             return t + d
        case .scale(let anchor, let k): return anchor + (t - anchor) * k
        }
    }

    // MARK: - The box the eye follows

    /// The box AS DRAWN while a grip is held — four corners, clockwise from the top left.
    ///
    /// The box that MEASURES is frozen at the grab and must stay so: a dial read off its own
    /// output runs away under the hand, which is the classic blow-up of a scale by grip (@see
    /// `AutomationBandView.transformBox`). But a frozen box drawn is a box that lets go of the
    /// fingers holding it — one pulls a grip and the rectangle stays behind. So the MEASURE and
    /// the DRAWING are separated: the pixels are still read against the frozen box, and what is
    /// drawn is that same box put through the transformation the hand is asking for.
    ///
    /// Nothing here is bounded, deliberately. `k` past the pulled edge is how a selection already
    /// against the ceiling raises the rest (@see `boxFactor`), and the box escaping its row is the
    /// only thing that SAYS SO on screen while the points pile up at the bound. A clamp would hide
    /// exactly what the eye needs to see to make sense of what the points are doing.
    ///
    /// `t0` / `t1` are the instants of the box's own EDGES — not the selection's time envelope.
    /// The two differ on a selection with no extent, whose box is widened to a grabbable width
    /// (@see `AutomationBandGeometry.boxMinSide`); read from the envelope, that box would collapse
    /// to a line the moment it was drawn.
    static func drawnQuad(_ r: Request, box: CGRect, t0: Double, t1: Double,
                          xOfT: (Double) -> Double) -> [CGPoint] {
        let x0 = xOfT(movedT(r, t0))
        let x1 = xOfT(movedT(r, t1))
        // In pixels y runs DOWNWARDS, so normalised 1 is `minY`: anchoring high anchors the TOP
        // edge and pulls the bottom one.
        let anchorY = r.anchorHigh ? box.minY : box.maxY
        let pulledY = r.anchorHigh ? box.maxY : box.minY
        let yL = anchorY + (pulledY - anchorY) * factor(r, atT: t0)
        let yR = anchorY + (pulledY - anchorY) * factor(r, atT: t1)
        // A corner tilts the pulled edge — `factor` differs at the two ends — so the shape is a
        // TRAPEZIUM and not a rectangle. That is not a flourish: the slant IS the gradient the
        // corner applies, and a rectangle there would claim a uniform scale the points do not get.
        return r.anchorHigh
            ? [CGPoint(x: x0, y: box.minY), CGPoint(x: x1, y: box.minY),
               CGPoint(x: x1, y: yR),       CGPoint(x: x0, y: yL)]
            : [CGPoint(x: x0, y: yL),       CGPoint(x: x1, y: yR),
               CGPoint(x: x1, y: box.maxY), CGPoint(x: x0, y: box.maxY)]
    }

    /// The eight grips of a quadrilateral: its corners, and the middle of each side. On a
    /// rectangle it gives `AutomationBandGeometry.handleCenters` back, pixel for pixel — which is
    /// what lets the drawing follow a tilted box without the hit test, which knows only rectangles,
    /// having to learn anything.
    static func quadHandles(_ q: [CGPoint]) -> [CGPoint] {
        guard q.count == 4 else { return [] }
        let mid = { (a: CGPoint, b: CGPoint) in
            CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        }
        return [q[0], mid(q[0], q[1]), q[1], mid(q[0], q[3]),
                mid(q[1], q[2]), q[3], mid(q[3], q[2]), q[2]]
    }

    // MARK: - What a rectangle takes

    /// The indices of the points a rectangle takes. `inset` is the half-side of the square around
    /// a point the rectangle has to touch.
    ///
    /// UNLIKE `SynopticMarquee.touching`, a FLAT rectangle is NOT refused — and that divergence is
    /// deliberate, so nobody harmonises the two later and breaks the gesture: sweeping left to
    /// right ALONG a row is the most natural way to take a stretch of curve, and a three-pixel
    /// tall rectangle is exactly what that hand produces. A card in the signal view is a surface
    /// one draws over; a curve is a line one draws ALONG. Only a rectangle with no extent at all —
    /// a click that never travelled — takes nothing.
    static func touching(_ rect: CGRect, points: [CGPoint], inset: Double) -> [Int] {
        let r = rect.standardized
        guard r.width > 0 || r.height > 0 else { return [] }
        return points.indices.filter { i in
            let p = points[i]
            return p.x >= r.minX - inset && p.x <= r.maxX + inset
                && p.y >= r.minY - inset && p.y <= r.maxY + inset
        }
    }
}

/// The project's own `clamped(to:)` lives on `Comparable`, in `EditViewModel+Types.swift` — a file
/// this one must not drag in, being compiled ALONE by the headless test. So the bound is spelled
/// here as a `fileprivate` function rather than as a second extension: an extension would shadow
/// the project's for every `Double` in the target, which is a wide consequence for a two-line
/// convenience.
fileprivate func bounded(_ x: Double, _ lo: Double, _ hi: Double) -> Double {
    min(max(x, lo), hi)
}
