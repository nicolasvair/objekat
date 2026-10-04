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
}
