import Foundation

// What a plain MOVE of objects LANDS ON — the arithmetic, with no model and no view behind it, so
// it can be compiled and asserted alone:
//
//     swiftc -parse-as-library ../objekat/Shared/ObjectMoveSnap.swift test_object_move_snap.swift \
//         -o /tmp/objmovesnap && /tmp/objmovesnap
//
// The grabbed object has two edges the eye can align, and the START has priority (decided 17
// November 2026): the start is what the hand reads and what a sound's attack is made of, so an
// alignment of the start is never traded for a nearer one of the end. The order, the first step
// that finds something deciding:
//
//   1. a REAL target — an object's edge, a marker, a region's bound, the caret; the grid does not
//      count — within the tolerance of the START → the start lands on it, even if the end is
//      nearer to a target of its own;
//   2. else a real target within the tolerance of the END → the end lands on it;
//   3. else the GRID, on the START.
//
// A real target is never beaten by the grid (a grid line nearer than a mark 7 px away does not
// take the edge). With the snap off (⌘ inverts it, that is the caller's business) nothing is
// looked at: the object follows the hand.
//
// The floor at zero is NOT here: the caller clamps the travel (@see ZeroFloor) and re-pins the guide.
// Carrying a time selection has its own, with the same precedence on the range's bounds
// (@see SelectionMoveSnap).
enum ObjectMoveSnap {

    /// Which edge decided.
    enum Edge: String {
        /// The object's start. Also the answer with the snap off, and on the grid.
        case start
        /// The object's end (only when the start had no real target within reach).
        case end
    }

    struct Result: Equatable {
        /// Where the grabbed object's START lands (the floor not applied).
        var start: Double
        /// Where the guide line stands: the winning edge, after the travel.
        var guideTime: Double
        /// True when the edge landed on a real mark (the guide goes yellow).
        var onTarget: Bool
        var edge: Edge
    }

    /// - `rawStart`, `duration`: the grabbed object's start AFTER the raw travel, and its length.
    /// - `targets`: the real marks, the grid aside (@see `EditViewModel.snapTargets`).
    /// - `gridInterval`: the grid; <= 0 means none.
    /// - `tolerance`: the reach of a target, in seconds (8 px, so it follows the zoom).
    /// - `onTargetEpsilon`: how close a grid line must fall to a mark to count as landing on it.
    static func resolve(rawStart: Double, duration: Double,
                        targets: [Double], gridInterval: Double,
                        tolerance: Double, onTargetEpsilon: Double,
                        snapEnabled: Bool) -> Result {
        guard snapEnabled else {
            return Result(start: rawStart, guideTime: rawStart, onTarget: false, edge: .start)
        }

        // The nearest target within reach of `t`.
        func nearest(to t: Double) -> Double? {
            var best: Double? = nil
            for target in targets where abs(target - t) <= tolerance {
                if best == nil || abs(target - t) < abs(best! - t) { best = target }
            }
            return best
        }

        // 1. the start against the real marks
        if let t = nearest(to: rawStart) {
            return Result(start: t, guideTime: t, onTarget: true, edge: .start)
        }
        // 2. the end against the real marks
        if let t = nearest(to: rawStart + duration) {
            return Result(start: t - duration, guideTime: t, onTarget: true, edge: .end)
        }
        // 3. the grid, on the start
        let g = gridInterval > 0 ? (rawStart / gridInterval).rounded() * gridInterval : rawStart
        return Result(start: g, guideTime: g,
                      onTarget: targets.contains { abs($0 - g) <= onTargetEpsilon }, edge: .start)
    }
}
