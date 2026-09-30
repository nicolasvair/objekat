import Foundation

// A drag in the time ruler selects TIME, hence every lane. The two pieces of arithmetic that
// gesture needs, with no view and no model behind them so that they can be compiled and asserted
// alone —
//
//     swiftc -parse-as-library ../objekat/Shared/RulerSelection.swift test_ruler_selection.swift \
//         -o /tmp/rulersel && /tmp/rulersel
//
// "All lanes" is not a new notion of the selection: a `TimeSelection` still names a concrete set
// of DISPLAY lanes, and every consumer (ripple, delete, copy, the region and comment creation, the
// carets) reads that set unchanged. The ruler merely fills it with every object lane there is at
// the moment of the gesture. The cost is stated: a lane added afterwards is not in the set.

enum RulerSelection {

    /// Below this span a drag has traced nothing: the two ends snapped onto the same instant.
    static let minSpan: Double = 1e-9

    /// The range a ruler drag traces, from the instant pressed to the instant now under the hand.
    /// `extending` is the range already held when ⇧ was down at the start: the result GROWS to
    /// cover it, as the timeline's own ⇧ rubber band does. nil = no range (a zero-length drag).
    static func range(anchor: Double, current: Double,
                      extending: ClosedRange<Double>?) -> ClosedRange<Double>? {
        var lo = min(anchor, current)
        var hi = max(anchor, current)
        if let e = extending {
            lo = min(lo, e.lowerBound)
            hi = max(hi, e.upperBound)
        }
        lo = max(0, lo)
        guard hi - lo > minSpan else { return nil }
        return lo...hi
    }

    /// Every OBJECT display lane from row 0 down to `lastRow`, the automation rows left out: a
    /// time selection holds one kind of lane, and the ruler's is the objects' (@see
    /// EditViewModel.confine).
    static func objectLanes(lastRow: Int, automationLanes: Set<Int>) -> Set<Int> {
        Set(0...max(0, lastRow)).subtracting(automationLanes)
    }
}
