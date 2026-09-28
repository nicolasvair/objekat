import Foundation

// MARK: - The vertical lane snap
//
// The arithmetic alone: no view, no model, no scroll. A unit of its own for the reason
// `SendColumns`, `SynopticMarquee` and `PianoRollFraming` are — this is the half of the feature
// with nothing behind it, so it can be compiled alone and asserted with no screen
// (@see tools/test_vertical_lane_snap.swift).
//
// The request: once vertical zoom makes a lane taller than 70 % of the available height, the
// vertical view SNAPS to the lanes — settling framed on one, moving from it to the next — and the
// zoom itself is clamped so a lane can never exceed 90 %. Independent of the TIME snap
// (`snapEnabled`, the grid): nothing here reads or writes it.
//
// "Available height" is the lane area under the sticky header (`viewportHeight − rulerHeight`),
// read live — it changes with the window and with the marker rows shown. The ratio is measured
// against the BLOCK, never `laneStep`: the 4 pt gap between lanes is not "the lane".
enum VerticalLaneSnap {

    /// The ratio (`blockHeight / available`) above which the vertical view snaps lane to lane.
    /// Named and isolated here so it can be tuned by hand.
    static let enterRatio: Double = 0.70

    /// The ratio the vertical zoom is clamped at: a lane can never take more of the available
    /// height than this.
    static let maxRatio: Double = 0.90

    /// A trackpad gesture's vertical travel, in points, needed to step one lane while snapped
    /// (D6.3). Crossed as soon as it is reached — the rest of the gesture, momentum included, is
    /// swallowed.
    static let trackpadStepThreshold: Double = 24

    /// The step animation's duration (D6.5, D9).
    static let easeOutDuration: Double = 0.18

    /// How long the vertical zoom must sit still before the end-of-session framing fires (D8) —
    /// shorter than the existing 0.4 s zoom-session gap, because THIS is meant to feel like an
    /// immediate settle and not a lazily-detected end of session.
    static let zoomSettleDebounce: Double = 0.2

    /// Where the framed lane is put inside the available area.
    enum Framing { case centre, top }

    /// `.centre` (recommended, and what is wired): a sliver of the previous and the next lane
    /// stays visible, saying "there is more, this way". `.top` would show the next lane only.
    /// One constant so the choice can be revisited after the feel test with no other change.
    static let framing: Framing = .centre

    /// The zoom's ceiling for a given available height — the old `max(120, …)` floor is gone (it
    /// could exceed the window on a small one); the floor is now simply `minBlockHeight`.
    static func maxBlockHeight(available: Double, minBlockHeight: Double) -> Double {
        max(minBlockHeight, maxRatio * available)
    }

    /// Whether the snap is active: the block occupies more than `enterRatio` of the available
    /// height. Exactly `enterRatio` is NOT active (T1: false at 0.70, true just above).
    static func isActive(blockHeight: Double, available: Double) -> Bool {
        guard available > 0 else { return false }
        return blockHeight / available > enterRatio
    }

    /// The scroll `y` that frames display row `i`: centred in the available area (or top-aligned,
    /// see `framing`), clamped into `[0, maxScrollY]`. Lane 0 cannot be centred upwards — it rests
    /// at 0, i.e. top-aligned with its margin entirely below (D5's one accepted exception).
    static func scrollY(forLane i: Int, blockHeight: Double, laneStep: Double,
                        available: Double, maxScrollY: Double) -> Double {
        guard i > 0 else { return 0 }
        let top = Double(i) * laneStep
        let raw: Double
        switch framing {
        case .centre: raw = top + blockHeight / 2 - available / 2
        case .top:    raw = top
        }
        return min(max(0, raw), max(0, maxScrollY))
    }

    /// The display row whose target `scrollY(forLane:)` is nearest to a given scroll position —
    /// "the lane currently framed". Ties resolve to the LOWER index (the first row met scanning
    /// upward from 0), which is deterministic and matches `neighbour`'s own scan order.
    static func nearestLane(scrollY: Double, blockHeight: Double, laneStep: Double,
                            available: Double, maxScrollY: Double, laneCount: Int) -> Int {
        guard laneCount > 0 else { return 0 }
        var best = 0
        var bestDist = Double.infinity
        for i in 0..<laneCount {
            let t = self.scrollY(forLane: i, blockHeight: blockHeight, laneStep: laneStep,
                                 available: available, maxScrollY: maxScrollY)
            let d = abs(t - scrollY)
            if d < bestDist { bestDist = d; best = i }
        }
        return best
    }

    /// The next lane to frame in `direction` (+1 down, −1 up) from `lane`. Skips rows whose target
    /// is not DISTINCT from the current one (several rows can clamp onto `maxScrollY` at the
    /// bottom) — "next lane" is the first row whose target differs by more than 0.5 pt. `nil` at
    /// an end: row 0 going up, or no row left with a distinct target going down.
    static func neighbour(of lane: Int, direction: Int, blockHeight: Double, laneStep: Double,
                          available: Double, maxScrollY: Double, laneCount: Int) -> Int? {
        guard direction != 0, laneCount > 0, lane >= 0, lane < laneCount else { return nil }
        let currentTarget = scrollY(forLane: lane, blockHeight: blockHeight, laneStep: laneStep,
                                    available: available, maxScrollY: maxScrollY)
        var i = lane
        while true {
            i += direction > 0 ? 1 : -1
            guard i >= 0, i < laneCount else { return nil }
            let t = scrollY(forLane: i, blockHeight: blockHeight, laneStep: laneStep,
                            available: available, maxScrollY: maxScrollY)
            if abs(t - currentTarget) > 0.5 { return i }
        }
    }

    /// Whether `scrollY` sits on the nearest lane's own target, within `tolerance` (D7's safety
    /// net reads this on scroll idle).
    static func isOnGrid(scrollY: Double, blockHeight: Double, laneStep: Double, available: Double,
                         maxScrollY: Double, laneCount: Int, tolerance: Double = 0.5) -> Bool {
        let n = nearestLane(scrollY: scrollY, blockHeight: blockHeight, laneStep: laneStep,
                            available: available, maxScrollY: maxScrollY, laneCount: laneCount)
        let t = self.scrollY(forLane: n, blockHeight: blockHeight, laneStep: laneStep,
                             available: available, maxScrollY: maxScrollY)
        return abs(scrollY - t) <= tolerance
    }

    /// D3 — resizing the window while snapped keeps the FRACTION of the available height the lane
    /// occupied, re-clamped at the 90 % cap: enlarging the window by 30 % must not silently drop a
    /// 75 % lane under 70 % (the mode switching off under the hand), and shrinking must not clamp
    /// to 90 % and then hold it there once the window grows back.
    static func resizedBlockHeight(blockHeight: Double, oldAvailable: Double,
                                   newAvailable: Double, minBlockHeight: Double) -> Double {
        guard oldAvailable > 0 else { return blockHeight }
        let ratio = blockHeight / oldAvailable
        let raw = ratio * newAvailable
        let capped = min(raw, maxBlockHeight(available: newAvailable, minBlockHeight: minBlockHeight))
        return max(minBlockHeight, capped)
    }
}
