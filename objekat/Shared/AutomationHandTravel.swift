import Foundation

// The automation band's vertical axis under the HAND. A row maps the parameter's whole range onto
// its own height, so on a default row a dB is under one pixel and the most common edit — one or
// two dB — was a matter of luck. The first steps away from where the gesture was recognised are
// therefore FINE (a few px per detent step); past them, the travel reverts to the row's own
// geometry, so the whole range stays reachable. Continuous at the knee: no jump, only the rate
// changes. Pure arithmetic, asserted by tools/test_automation_hand_travel.swift.
enum AutomationHandTravel {
    /// Hand travel (px) per detent step inside the fine zone.
    static let pxPerStep: Double = 4
    /// How many steps the fine zone spans, each way.
    static let fineSteps: Double = 6

    /// `dy`: the hand's vertical travel since the gesture's anchor (px, down positive).
    /// `rowPxPerStep`: what ONE detent step takes on the row (px). Returns the travel the
    /// row's geometry must read. A row already coarser than the fine rate is left alone.
    static func rowTravel(handDy dy: Double, rowPxPerStep: Double) -> Double {
        guard rowPxPerStep > 0, rowPxPerStep < pxPerStep else { return dy }
        let ratio = rowPxPerStep / pxPerStep
        let knee  = fineSteps * pxPerStep
        let a     = abs(dy)
        let out   = a <= knee ? a * ratio : knee * ratio + (a - knee)
        return dy < 0 ? -out : out
    }

    // MARK: - The wheel over a line (precise deltas)
    //
    // The same idea for a trackpad / Magic Mouse / smooth-scrolling mouse carrying a line: a flat
    // rate either needed a hard push (10 pt per step) or, once lowered, sat still for the first
    // points and then ran off (3 pt per step, read off the hand on 4 October 2026); and a first version
    // of this (1 / 8 / 3 pt) still started far too fast — the precise deltas macOS sends are large. So the steps are
    // read off the gesture's TOTAL travel: the first comes after a short, deliberate travel, the next few are slow
    // and spaced (one or two dB is the common edit), and only past that knee does the rate pick up.

    /// Travel (pt) before the FIRST step. 1 pt was felt as far too quick (4 October 2026).
    static let wheelFirstPt: Double = 8
    /// Travel (pt) per step inside the fine zone.
    static let wheelFinePtPerStep: Double = 20
    /// How many steps the fine zone spans (the first one included).
    static let wheelFineSteps: Int = 4
    /// Travel (pt) per step past the fine zone.
    static let wheelCoarsePtPerStep: Double = 6

    /// Whole steps for a gesture's total travel `travel` (pt, upwards positive). Odd, monotone.
    static func wheelSteps(travel: Double) -> Int {
        let a = abs(travel)
        guard a >= wheelFirstPt else { return 0 }
        let e = a - wheelFirstPt
        let fineSpan = Double(wheelFineSteps - 1) * wheelFinePtPerStep
        let n = e < fineSpan
            ? 1 + Int(e / wheelFinePtPerStep)
            : wheelFineSteps + Int((e - fineSpan) / wheelCoarsePtPerStep)
        return travel < 0 ? -n : n
    }

    /// The steps to ADD for one event: `wheelSteps` of the new total minus what was already
    /// applied, but at most ONE per event while still inside the fine zone — an accelerated event
    /// at the very start must not leap over the dB one was aiming at.
    static func wheelStepDelta(travel: Double, applied: Int) -> Int {
        let target = wheelSteps(travel: travel)
        var d = target - applied
        if abs(applied) < wheelFineSteps { d = max(-1, min(1, d)) }
        return d
    }
}
