import Foundation

// MARK: - The "+" gestures of the signal view (PURE: no view, no layout, no model)
//
// A "+" of the signal view is taken in the hand (docs/plan_synoptic_rework.md §B.2):
//   - let go under `clickThreshold` = a CLICK (the plugin browser, as before);
//   - dragged to the RIGHT                 → a gain stage; past `panMuteThreshold` → gain + pan + mute;
//   - dragged right and DOWN (−30°)        → a parallel branch of the element under the "+";
//   - dragged right and UP (+30°)          → a send taken at that "+".
// Each direction has `angleTolerance` (±15°) round it, so the three sectors tile −45°…+45° and touch
// without overlapping; a drag steeper than that, or one going LEFT, asks for nothing.
//
// The angle is measured from the horizontal, POSITIVE UPWARD — the screen's y grows downwards, so
// the translation's height is negated. Which results a given "+" offers is the caller's (`allowed`):
// a result it does not offer comes back as `.none`, which the ghost reads as "not here".
//
// This file is compiled alone by `tools/test_synoptic_plus_gesture.swift`: it must stay free of
// every other type of the app.

/// What a drag started on a "+" asks for.
enum PlusGestureResult: Equatable, Hashable {
    /// Nothing: a click, a drag going left, too steep, or a result this "+" does not offer.
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
    /// The direction of the branch (−) and of the send (+), in degrees from the horizontal.
    static let diagonalAngle: Double = 30
    /// The tolerance round each of the three directions (0°, +30°, −30°), in degrees.
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
        guard !isClick(translation), translation.width > 0 else { return .none }
        let theta = angle(translation)
        if abs(theta) < angleTolerance {
            return translation.width < panMuteThreshold ? .gain : .gainPanMute
        }
        let lo = diagonalAngle - angleTolerance, hi = diagonalAngle + angleTolerance
        if theta >= lo && theta <= hi { return .send }
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
