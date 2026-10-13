import Foundation

// MARK: - The "+" gestures of the signal view (PURE: no view, no layout, no model)
//
// A "+" of the signal view is taken in the hand (docs/plan_synoptic_rework.md §B.2):
//   - let go under `clickThreshold` = a CLICK (the plugin browser, as before);
//   - dragged to the RIGHT                 → a gain stage; past `panMuteThreshold` → gain + pan + mute;
//   - dragged right and DOWN (−30°)        → a parallel branch of the element under the "+";
//   - dragged to the LEFT (180°)           → a send taken at that "+" (the send wires leave the trunk by
//                                            the left, user decision of 13 October 2026).
// Each direction has `angleTolerance` (±15°) round it: right −15°…+15°, branch −45°…−15°, left 165°…195°.
// Anything else (up-right, steep, down-left…) asks for nothing.
//
// The angle is measured from the horizontal, POSITIVE UPWARD — the screen's y grows downwards, so
// the translation's height is negated. Which results a given "+" offers is the caller's (`allowed`):
// a result it does not offer comes back as `.none`, which the ghost reads as "not here".
//
// This file is compiled alone by `tools/test_synoptic_plus_gesture.swift`: it must stay free of
// every other type of the app.

/// What a drag started on a "+" asks for.
enum PlusGestureResult: Equatable, Hashable {
    /// Nothing: a click, a drag in no offered direction (up-right, too steep…), or a result this "+" does
    /// not offer.
    case none
    /// A gain stage (one dB box).
    case gain
    /// A gain + pan + mute stage.
    case gainPanMute
    /// A parallel branch of the element under the "+" (the element above, for a series' tail "+").
    case branch
    /// A send taken at this "+".
    case send
}

enum SynopticPlusGesture {

    /// Under this distance (pt) the gesture is a CLICK.
    static let clickThreshold: CGFloat = 6
    /// From this horizontal travel (pt) a rightward drag asks for gain + pan + mute instead of gain.
    static let panMuteThreshold: CGFloat = 80
    /// The direction of the branch (down-right, −`diagonalAngle`), in degrees from the horizontal.
    static let diagonalAngle: Double = 30
    /// The direction of the send: straight LEFT, in degrees from the horizontal.
    static let sendAngle: Double = 180
    /// The tolerance round each of the three directions (0°, −30°, 180°), in degrees.
    static let angleTolerance: Double = 15

    /// Every result a "+" can offer (the trunk's).
    static let everything: Set<PlusGestureResult> = [.gain, .gainPanMute, .branch, .send]

    /// True when the hand travelled less than `clickThreshold`: the gesture is a click.
    static func isClick(_ translation: CGSize) -> Bool {
        hypot(translation.width, translation.height) < clickThreshold
    }

    /// The drag's angle from the horizontal, in degrees, POSITIVE UPWARD (−180…180).
    static func angle(_ translation: CGSize) -> Double {
        atan2(Double(-translation.height), Double(translation.width)) * 180 / .pi
    }

    /// What the drag asks for, whatever the "+" offers.
    static func intent(_ translation: CGSize) -> PlusGestureResult {
        guard !isClick(translation) else { return .none }
        let theta = angle(translation)
        if translation.width < 0 {
            // LEFT: the send, ±tolerance round 180° (the angle wraps there: +170° and −170° are both 10° off).
            return 180 - abs(theta) < angleTolerance ? .send : .none
        }
        guard translation.width > 0 else { return .none }
        if abs(theta) < angleTolerance {
            return translation.width < panMuteThreshold ? .gain : .gainPanMute
        }
        let lo = diagonalAngle - angleTolerance, hi = diagonalAngle + angleTolerance
        if theta <= -lo && theta >= -hi { return .branch }
        return .none
    }

    /// What the drag does on a "+" that offers `allowed`: its intent, or `.none` when that "+" does not
    /// offer it.
    static func classify(_ translation: CGSize, allowed: Set<PlusGestureResult>) -> PlusGestureResult {
        let r = intent(translation)
        return allowed.contains(r) ? r : .none
    }

    // MARK: The zones drawn round a "+" while it is dragged (§B.2, user request of 13 October 2026)
    //
    // As soon as a drag leaves a "+", the directions it offers are drawn round it, faintly, each with its
    // icon; the one the hand is in lights up. The zones are THIS classifier drawn: every point inside a zone
    // classifies to that zone's result (asserted by tools/test_synoptic_plus_gesture.swift), so what is
    // drawn can never disagree with what letting go does. The gain / gain + pan + mute cut is the classifier's
    // own: a VERTICAL line at `panMuteThreshold` of horizontal travel, not an arc.

    /// Where a zone starts: just outside the "+" disc (its radius is 10 pt).
    static let sectorInnerRadius: CGFloat = 14
    /// Where a zone ends (the gain + pan + mute zone runs from the 80 pt line to here).
    static let sectorOuterRadius: CGFloat = 120

    /// The zones a "+" that offers `allowed` draws — one per offered result, in a fixed order (gain, gain + pan
    /// + mute, branch, send). A result it does not offer has NO zone (absent, not greyed).
    static func sectors(allowed: Set<PlusGestureResult>) -> [PlusSector] {
        let tol = angleTolerance, r0 = sectorInnerRadius, r1 = sectorOuterRadius
        var out: [PlusSector] = []
        if allowed.contains(.gain) {
            out.append(PlusSector(result: .gain, fromAngle: -tol, toAngle: tol,
                                  inner: .radius(r0), outer: .vertical(panMuteThreshold)))
        }
        if allowed.contains(.gainPanMute) {
            out.append(PlusSector(result: .gainPanMute, fromAngle: -tol, toAngle: tol,
                                  inner: .vertical(panMuteThreshold), outer: .radius(r1)))
        }
        if allowed.contains(.branch) {
            out.append(PlusSector(result: .branch, fromAngle: -diagonalAngle - tol, toAngle: -diagonalAngle + tol,
                                  inner: .radius(r0), outer: .radius(r1)))
        }
        if allowed.contains(.send) {
            out.append(PlusSector(result: .send, fromAngle: sendAngle - tol, toAngle: sendAngle + tol,
                                  inner: .radius(r0), outer: .radius(r1)))
        }
        return out
    }

    /// The zone a drag of `translation` is in, among `sectors`: the one of its classified result (nil = none —
    /// a click, or a direction nothing is offered in).
    static func highlighted(_ translation: CGSize, in sectors: [PlusSector]) -> PlusGestureResult? {
        let r = classify(translation, allowed: Set(sectors.map(\.result)))
        return r == .none ? nil : r
    }
}

/// One zone drawn round a "+" (@see SynopticPlusGesture.sectors): an angular range (degrees from the
/// horizontal, POSITIVE UPWARD, as `SynopticPlusGesture.angle`) between an inner and an outer boundary,
/// each a circle round the "+" or a vertical line at some horizontal travel.
struct PlusSector: Equatable {
    enum Bound: Equatable {
        /// A circle of this radius round the "+".
        case radius(CGFloat)
        /// The vertical line at this horizontal travel from the "+" (right of it).
        case vertical(CGFloat)

        /// The distance from the "+" to this boundary in the direction `degrees`.
        func distance(at degrees: Double) -> CGFloat {
            switch self {
            case .radius(let r):   return r
            case .vertical(let x): return x / CGFloat(cos(degrees * .pi / 180))
            }
        }
    }

    let result: PlusGestureResult
    /// The angular range, `fromAngle` < `toAngle` (the send's runs 165…195: past 180 is the same as −180…).
    let fromAngle: Double
    let toAngle: Double
    let inner: Bound
    let outer: Bound

    var midAngle: Double { (fromAngle + toAngle) / 2 }

    /// The translation (from the "+") of the point at `degrees`, `distance` away — in the SCREEN's sense
    /// (y grows downward).
    static func offset(_ degrees: Double, _ distance: CGFloat) -> CGSize {
        let a = degrees * .pi / 180
        return CGSize(width: distance * CGFloat(cos(a)), height: -distance * CGFloat(sin(a)))
    }

    /// The zone's outline, as offsets from the "+": the inner boundary from `fromAngle` to `toAngle`, then
    /// the outer one back. `steps` points per boundary.
    func outline(steps: Int = 12) -> [CGSize] {
        let n = max(2, steps)
        func angle(_ i: Int) -> Double { fromAngle + (toAngle - fromAngle) * Double(i) / Double(n - 1) }
        let innerPts = (0..<n).map { i in PlusSector.offset(angle(i), inner.distance(at: angle(i))) }
        let outerPts = (0..<n).reversed().map { i in PlusSector.offset(angle(i), outer.distance(at: angle(i))) }
        return innerPts + outerPts
    }

    /// Where the zone's icon sits (an offset from the "+"): on its middle direction, halfway between its
    /// boundaries.
    var iconOffset: CGSize {
        let a = midAngle
        return PlusSector.offset(a, (inner.distance(at: a) + outer.distance(at: a)) / 2)
    }
}
