import Foundation

/// A spatial index over the flat display list (`EditViewModel.laneEntries`), so that 'which block is
/// under the pointer' costs O(log N) instead of a walk of the WHOLE list at every mouse move.
///
/// ⚠️ ONE CONTRACT: every answer is STRICTLY the one `laneEntries.first(where: <the same
/// predicate>)` / `.contains(where:)` would have given — the first in the order of the list (which is
/// the model's order within a lane), overlaps, crossfades, nested children and infinite buses
/// included. The index narrows the candidates with a deliberately WIDE window (a conservative
/// superset, tolerance included), then applies the ORIGINAL predicate, character for character, to
/// each candidate. It never decides a hit by itself.
/// (This is NOT the 'the canvas draws the selected blocks above the others, yet the hit goes to the
/// first of the model' question: that gap is the callers', and it is left exactly as it was.)
///
/// It knows nothing of `SoundObject`: it is built from plain `Box`es (one per entry, in the list's
/// order) so that `tools/test_lane_entry_index.swift` can compile it alone and compare it with the
/// brute force. Answers are POSITIONS in that list; the caller indexes its own array.
///
/// Built lazily by `EditViewModel` and dropped in `rebuildLaneEntries` — the same instant the list is
/// rebuilt, so it can never be older than the list it answers for (@see EditViewModel+LaneEntryIndex).
struct LaneEntryIndex {

    /// What the hit-test reads of an entry: `absStart` / `item.duration` / `displayLane`, and the
    /// window of the timeline OUTSIDE which the block lies under an out-of-range veil (a child
    /// sticking out of its group's window — @see `LaneClip`). The window only ever REMOVES hits: the
    /// candidates are still narrowed on the full extent, the exact predicate then refuses the masked
    /// part.
    struct Box {
        let displayLane: Int
        let start: Double
        let duration: Double
        let clipLo: Double
        let clipHi: Double

        init(displayLane: Int, start: Double, duration: Double,
             clipLo: Double = -.infinity, clipHi: Double = .infinity) {
            self.displayLane = displayLane
            self.start = start
            self.duration = duration
            self.clipLo = clipLo
            self.clipHi = clipHi
        }
    }

    /// Number of entries the index was built for (a cheap sanity check for the owner).
    let count: Int

    private let boxes: [Box]
    private let laneKeys: [Int]          // the distinct display lanes, ascending
    private let lanes: [LaneTree]        // parallel to `laneKeys`
    private let firstByID: [UUID: Int]

    init(boxes: [Box], ids: [UUID]) {
        self.boxes = boxes
        self.count = boxes.count

        var byLane: [Int: [Int]] = [:]
        for (p, b) in boxes.enumerated() { byLane[b.displayLane, default: []].append(p) }
        let keys = byLane.keys.sorted()
        laneKeys = keys
        lanes = keys.map { LaneTree(positions: byLane[$0]!, boxes: boxes) }

        // The FIRST entry with an id, exactly like `first(where: { $0.item.id == id })`.
        var byID: [UUID: Int] = [:]
        byID.reserveCapacity(ids.count)
        for (p, id) in ids.enumerated() where byID[id] == nil { byID[id] = p }
        firstByID = byID
    }

    // MARK: - Queries

    /// The position of the first entry whose block contains the point — the predicate every hover
    /// site spells out by hand:
    ///
    ///     bx = absStart * pps ; bw = max(duration * pps, 2) ; by = rulerHeight + displayLane * laneStep
    ///     x >= bx && x <= bx + bw && y >= by && y <= by + blockHeight
    ///     && LaneClip.unmasked(x, ...)       // not under the veil of an ancestor group
    func firstBlock(atX x: Double, y: Double, pixelsPerSecond pps: Double,
                    rulerHeight: Double, laneStep: Double, blockHeight: Double) -> Int? {
        func hit(_ b: Box) -> Bool {
            let bx = b.start * pps
            let bw = max(b.duration * pps, 2)
            let by = rulerHeight + Double(b.displayLane) * laneStep
            return x >= bx && x <= bx + bw && y >= by && y <= by + blockHeight
                && LaneClip.unmasked(x: x, clipLo: b.clipLo, clipHi: b.clipHi, pixelsPerSecond: pps)
        }

        // Anything the window arithmetic below could not stay exact on → the plain walk.
        guard x.isFinite, y.isFinite, pps.isFinite, pps > 0,
              rulerHeight.isFinite, laneStep.isFinite, laneStep > 0, blockHeight.isFinite
        else { return boxes.firstIndex(where: hit) }

        // The lanes the point can fall in: by ≤ y ≤ by + blockHeight, with a lane of slack each side
        // (the exact test is made per lane just below, with the original expression).
        let lowF  = ((y - rulerHeight - blockHeight) / laneStep).rounded(.up) - 1
        let highF = ((y - rulerHeight) / laneStep).rounded(.down) + 1
        guard lowF.isFinite, highF.isFinite else { return boxes.firstIndex(where: hit) }
        let low  = Int(max(min(lowF,  1e15), -1e15))
        let high = Int(max(min(highF, 1e15), -1e15))
        guard low <= high else { return nil }

        // The time window, in SECONDS. A block is at least 2 px wide, whatever its duration, so the
        // right side is searched `2 / pps` further back than the stored end.
        let t   = x / pps
        let eps = LaneEntryIndex.tolerance(around: t)
        let maxStart = t + eps
        let minEnd   = t - 2 / pps - eps

        var best = Int.max
        var i = LaneEntryIndex.lowerBound(laneKeys, low)
        while i < laneKeys.count, laneKeys[i] <= high {
            let by = rulerHeight + Double(laneKeys[i]) * laneStep
            if y >= by && y <= by + blockHeight {
                lanes[i].firstMatch(maxStart: maxStart, minEnd: minEnd, best: &best,
                                    matches: { hit(boxes[$0]) })
            }
            i += 1
        }
        return best == Int.max ? nil : best
    }

    /// True if some block of that display lane covers `t` with `margin` taken off each side —
    /// `blockCovers`'s predicate:
    ///
    ///     lane == displayLane && t >= start + margin && t <= start + duration - margin
    func laneCovers(displayLane lane: Int, at t: Double, margin: Double) -> Bool {
        func hit(_ b: Box) -> Bool {
            b.displayLane == lane
                && t >= b.start + margin
                && t <= b.start + b.duration - margin
        }
        guard t.isFinite, margin.isFinite else { return boxes.contains(where: hit) }
        guard let i = LaneEntryIndex.find(laneKeys, lane) else { return false }

        let eps = LaneEntryIndex.tolerance(around: abs(t) + abs(margin))
        var best = Int.max
        lanes[i].firstMatch(maxStart: t - margin + eps, minEnd: t + margin - eps, best: &best,
                            matches: { hit(boxes[$0]) })
        return best != Int.max
    }

    /// The first position carrying that id — `first(where: { $0.item.id == id })`.
    func firstPosition(forID id: UUID) -> Int? { firstByID[id] }

    // MARK: - Internals

    /// Wide enough to swallow every rounding of the products / sums the predicates make (1e-16
    /// relative), narrow enough to leave only a handful of false candidates. Candidates are always
    /// re-tested with the exact predicate, so this can only cost time, never correctness.
    private static func tolerance(around t: Double) -> Double { 1e-6 + 1e-9 * abs(t) }

    private static func lowerBound(_ a: [Int], _ v: Int) -> Int {
        var lo = 0, hi = a.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if a[mid] < v { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    private static func find(_ a: [Int], _ v: Int) -> Int? {
        let i = lowerBound(a, v)
        return i < a.count && a[i] == v ? i : nil
    }
}

/// One display lane's blocks as an implicit, balanced interval tree: the entries sorted by start, the
/// node of a range [lo, hi) being its midpoint, each node remembering the largest END and the
/// smallest LIST POSITION of its subtree. A query skips a subtree when nothing in it can reach the
/// point (`maxEnd`) or when it cannot beat the best position already found (`minPos`), so a point
/// costs O(log N + candidates).
///
/// Entries whose numbers are not finite (they would poison the ordering) sit in `loose` and are
/// always tried — there are none in practice, but the answer must not depend on it.
private struct LaneTree {
    private var pos: [Int] = []          // list positions, sorted by (start, position)
    private var start: [Double] = []
    private var end: [Double] = []       // start + max(duration, 0)
    private var maxEnd: [Double] = []
    private var minPos: [Int] = []
    private var loose: [Int] = []

    init(positions: [Int], boxes: [LaneEntryIndex.Box]) {
        var tree: [(pos: Int, start: Double, end: Double)] = []
        tree.reserveCapacity(positions.count)
        for p in positions {
            let b = boxes[p]
            let e = b.start + max(b.duration, 0)
            if b.start.isFinite && b.duration.isFinite && e.isFinite {
                tree.append((p, b.start, e))
            } else {
                loose.append(p)
            }
        }
        tree.sort { $0.start != $1.start ? $0.start < $1.start : $0.pos < $1.pos }
        pos   = tree.map(\.pos)
        start = tree.map(\.start)
        end   = tree.map(\.end)
        maxEnd = [Double](repeating: -.infinity, count: tree.count)
        minPos = [Int](repeating: Int.max, count: tree.count)
        _ = summarize(0, tree.count)
    }

    /// Fills `maxEnd` / `minPos` of the subtree [lo, hi) and returns its summary.
    private mutating func summarize(_ lo: Int, _ hi: Int) -> (maxEnd: Double, minPos: Int) {
        guard lo < hi else { return (-.infinity, Int.max) }
        let mid = (lo + hi) / 2
        let l = summarize(lo, mid)
        let r = summarize(mid + 1, hi)
        maxEnd[mid] = max(end[mid], l.maxEnd, r.maxEnd)
        minPos[mid] = min(pos[mid], l.minPos, r.minPos)
        return (maxEnd[mid], minPos[mid])
    }

    /// Lowers `best` to the smallest position, among the entries starting at or before `maxStart` and
    /// ending at or after `minEnd`, that `matches` accepts (the exact predicate).
    func firstMatch(maxStart: Double, minEnd: Double, best: inout Int,
                    matches: (Int) -> Bool) {
        for p in loose where p < best && matches(p) { best = p }
        visit(0, pos.count, maxStart, minEnd, &best, matches)
    }

    private func visit(_ lo: Int, _ hi: Int, _ maxStart: Double, _ minEnd: Double,
                       _ best: inout Int, _ matches: (Int) -> Bool) {
        guard lo < hi else { return }
        let mid = (lo + hi) / 2
        if maxEnd[mid] < minEnd || minPos[mid] >= best { return }
        visit(lo, mid, maxStart, minEnd, &best, matches)
        // Past `maxStart` neither this node nor anything to its right can contain the point.
        guard start[mid] <= maxStart else { return }
        if end[mid] >= minEnd, pos[mid] < best, matches(pos[mid]) { best = pos[mid] }
        visit(mid + 1, hi, maxStart, minEnd, &best, matches)
    }
}


/// The out-of-range veil, seen by the hit-test. A group's children keep their ABSOLUTE times and may
/// stick out of the group's window [start, start + duration]; the timeline greys that part out
/// (`rangeMasksCanvas`) and it must not answer the hand either — no hover, no cursor, no click, no
/// drag, no handle. Each `LaneEntry` therefore carries the window its block is visible through: the
/// intersection of the windows of ALL its ancestor groups (an infinite bus has no window, hence no
/// veil). A top-level entry has the open window.
///
/// Pure (no `SoundObject`), compiled alone by `tools/test_lane_entry_index.swift`.
nonisolated enum LaneClip {
    typealias Window = (lo: Double, hi: Double)

    /// No ancestor: nothing is masked.
    static let open: Window = (-.infinity, .infinity)

    /// The window of the CHILDREN of a group, given the window the group itself is seen through.
    /// `infinite` (a bus) adds no veil.
    static func narrowed(_ inherited: Window, groupStart: Double, groupDuration: Double,
                         infinite: Bool) -> Window {
        guard !infinite, groupStart.isFinite, groupDuration.isFinite else { return inherited }
        return (max(inherited.lo, groupStart), min(inherited.hi, groupStart + max(groupDuration, 0)))
    }

    /// True if the point (canvas px) is NOT under the veil. Bounds included (the veil starts where
    /// the window ends, the pixel on the edge itself still belongs to the block).
    static func unmasked(x: Double, clipLo: Double, clipHi: Double, pixelsPerSecond pps: Double) -> Bool {
        (clipLo == -.infinity || x >= clipLo * pps) && (clipHi == .infinity || x <= clipHi * pps)
    }
}
