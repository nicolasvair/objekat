import Foundation

// MARK: - The fine adjustment: ⇧ held = a tenth of the travel
//
// ONE rule for every value a hand lays down (a box, a tool's drag, a wheel, an automation point, a
// trim): ⇧ held makes the same travel worth `factor` (a tenth) of what it is worth bare. The
// modifier is read CONTINUOUSLY — pressed or released in the middle of a gesture — and that is the
// whole reason this unit exists: the naive form `value = anchor + travel * (fine ? 0.1 : 1)` jumps
// at the instant ⇧ changes, since the whole travel done so far is suddenly worth a different
// amount. A gesture holds a `FineAdjust` and asks it for the EFFECTIVE travel; it accumulates what
// the hand has already earned and re-anchors the origin of the raw travel whenever ⇧ flips, so the
// value is continuous at the switch and only the SLOPE changes.
//
//     var fine = FineAdjust()
//     … on each frame:
//     let travel = fine.effective(rawTravel, fine: shiftIsHeld)   // same unit as rawTravel
//     value = anchor + travel * rate
//
// No dependency: pure, compiled alone by `tools/test_fine_adjust.swift`.

struct FineAdjust: Equatable {

    /// What ⇧ multiplies the travel by. The only definition: boxes, wheels, arrows and automation
    /// all read it, so "fine" cannot mean one thing here and another there.
    static let factor: Double = 0.1

    /// The big step (⌘↑/↓) of a LEVEL in dB — the Volume tool and the volume, gain and send boxes
    /// alike: 3 dB. Not the generic ×10: ±10 dB on one key was refused as too easy to mistake.
    static let dbBigStep: Double = 3
    /// The fine step (⇧↑/↓) of a level in dB, tool and boxes alike: half a dB.
    static let dbFineStep: Double = 0.5
    /// The big step (⌘↑/↓) of a pan, tool and boxes alike: half the travel.
    static let panBigStep: Double = 0.5

    /// The effective travel earned before the last time ⇧ changed.
    private var banked: Double = 0
    /// The raw travel at the last time ⇧ changed (the re-anchored origin).
    private var origin: Double = 0
    /// ⇧ as of the last call.
    private var wasFine: Bool

    init(fine: Bool = false) { wasFine = fine }

    /// The effective travel for `travel` (the raw travel since the gesture began), ⇧ being `fine`
    /// right now. Continuous at every switch of `fine`.
    mutating func effective(_ travel: Double, fine: Bool) -> Double {
        if fine != wasFine {
            banked += (travel - origin) * (wasFine ? Self.factor : 1)
            origin = travel
            wasFine = fine
        }
        return banked + (travel - origin) * (fine ? Self.factor : 1)
    }

    /// A one-shot delta (a wheel notch, an event's increment): scaled by the factor under ⇧, as is
    /// otherwise. Stateless — a notch has no travel to re-anchor.
    static func scaled(_ delta: Double, fine: Bool) -> Double { fine ? delta * factor : delta }

    /// `value` brought onto the grid of `quantum` bare, onto the grid of `quantum * factor` under ⇧
    /// (a box that snaps while dragging: the detent follows the slope).
    static func snapped(_ value: Double, to quantum: Double, fine: Bool) -> Double {
        let q = fine ? quantum * factor : quantum
        guard q > 0 else { return value }
        return (value / q).rounded() * q
    }

    /// A step (an arrow, a quantum): `step` bare, `step * factor` under ⇧ — unless the caller names
    /// its own fine step.
    static func step(_ step: Double, fine: Bool, fineStep: Double? = nil) -> Double {
        fine ? (fineStep ?? step * factor) : step
    }
}

/// A `FineAdjust` held by REFERENCE, for a gesture whose state lives in a value-type `@State`
/// (a drag struct read by the view): mutating a struct held there writes the state, and a write
/// per frame would invalidate the view per frame. The tracker is mutated in place; the struct
/// that holds it never changes.
final class FineAdjustTracker {
    private var adjust: FineAdjust

    /// `fine`: ⇧ already held when the gesture began, so the whole drag starts fine.
    init(fine: Bool = false) { adjust = FineAdjust(fine: fine) }

    func effective(_ travel: Double, fine: Bool) -> Double { adjust.effective(travel, fine: fine) }
}
