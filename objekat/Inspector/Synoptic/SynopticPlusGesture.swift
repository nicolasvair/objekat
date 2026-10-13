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
}
