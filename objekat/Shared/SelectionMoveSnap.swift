import Foundation

// What a time selection LANDS ON when it is carried by the hand — the arithmetic, with no model
// and no view behind it, so it can be compiled and asserted alone:
//
//     swiftc -parse-as-library ../objekat/Shared/SelectionMoveSnap.swift test_selection_move_snap.swift \
//         -o /tmp/selmovesnap && /tmp/selmovesnap
//
// Why it is not `EditViewModel.snappedTime`. That one answers "where does THIS instant land", and
// the move of an object asks it twice — for the grabbed object's start and for its end. Carrying a
// RANGE is a different question: what the eye aligns is the range's own bounds, and above all its
// START, which is where the caret sits. With the old two questions the start of the selection could
// only snap when it happened to coincide with an edge of the object one grabbed — never when the
// range began in silence, never when the grab was on an object lying inside it.
//
// The ONLY references are the range's two bounds — never the edges of the object one grabbed
// (decided 5 October 2026: an object edge lying inside the range made the selection jump onto a
// mark its own bounds were nowhere near). The order of precedence, in two steps (the first one that
// finds something decides):
//
//   1. A REAL target — an edge, a marker, a region's bound; the grid does not count — within the
//      tolerance of the range's START, or of its END. The nearer wins and a tie goes to the start
//      (the caret). A real target is never beaten by the grid, which `snappedTime` allows.
//   2. The grid, on the range's start or end — again the nearer, ties to the start.
//
// With the snap off (⌘ inverts it, that is the caller's business) nothing is looked at: the range
// follows the hand.
//
// The floor: the range itself stops at zero. It is the SELECTION that is walled, not the first
// object inside it — an object lying later than the start of the range does not limit the travel.
enum SelectionMoveSnap {

    /// Which edge decided.
    enum Edge: String {
        /// The range's start (the caret). Also the answer with the snap off, and at the wall.
        case start
        /// The range's end.
        case end
    }

    struct Result: Equatable {
        /// The travel to apply, floor included.
        var dt: Double
        /// Where the guide line stands: the winning edge, AFTER the travel.
        var guideTime: Double
        /// True when the edge landed on a real mark (the guide goes yellow).
        var onTarget: Bool
        var edge: Edge
        /// True when the floor stopped the travel (the guide is then grey, on the start).
        var clamped: Bool
    }

    /// - `lo`, `hi`: the range BEFORE the travel. `rawDt`: what the hand asked for.
    /// - `targets`: the real marks, the grid aside (@see `EditViewModel.snapTargets`).
    /// - `gridInterval`: the grid; <= 0 means none.
    /// - `tolerance`: the reach of a target, in seconds (8 px, so it follows the zoom).
    /// - `onTargetEpsilon`: how close a grid line must fall to a mark to count as landing on it.
    /// - `minDt`: the floor of the travel (the range's start at zero is `-lo`).
    static func resolve(lo: Double, hi: Double, rawDt: Double,
                        targets: [Double], gridInterval: Double,
                        tolerance: Double, onTargetEpsilon: Double,
                        snapEnabled: Bool, minDt: Double) -> Result {

        // The nearest target within reach of `t`: its value and how far it is.
        func nearest(to t: Double) -> (value: Double, distance: Double)? {
            var best: (value: Double, distance: Double)? = nil
            for target in targets {
                let d = abs(target - t)
                guard d <= tolerance else { continue }
                if best == nil || d < best!.distance { best = (target, d) }
            }
            return best
        }
        func gridPoint(near t: Double) -> Double {
            gridInterval > 0 ? (t / gridInterval).rounded() * gridInterval : t
        }

        var dt = rawDt
        var edge = Edge.start
        var onTarget = false

        if snapEnabled {
            // 1. the range's own bounds against the real marks
            let aLo = nearest(to: lo + rawDt)
            let aHi = nearest(to: hi + rawDt)
            if aLo != nil || aHi != nil {
                if let l = aLo, aHi == nil || l.distance <= aHi!.distance {
                    dt = l.value - lo; edge = .start
                } else if let h = aHi {
                    dt = h.value - hi; edge = .end
                }
                onTarget = true
            }
            // 2. the grid, on the range's bounds
            else if gridInterval > 0 {
                let pLo = gridPoint(near: lo + rawDt)
                let pHi = gridPoint(near: hi + rawDt)
                let dLo = abs(pLo - (lo + rawDt))
                let dHi = abs(pHi - (hi + rawDt))
                if dHi < dLo {
                    dt = pHi - hi; edge = .end
                    onTarget = targets.contains { abs($0 - pHi) <= onTargetEpsilon }
                } else {
                    dt = pLo - lo; edge = .start
                    onTarget = targets.contains { abs($0 - pLo) <= onTargetEpsilon }
                }
            }
        }

        // The floor, and the guide at the value KEPT: a wall is grey, and it is the START that
        // stands on it.
        if dt < minDt {
            return Result(dt: minDt, guideTime: lo + minDt, onTarget: false, edge: .start, clamped: true)
        }
        let anchor = edge == .start ? lo : hi
        return Result(dt: dt, guideTime: anchor + dt, onTarget: onTarget, edge: edge, clamped: false)
    }
}
