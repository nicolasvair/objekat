import Foundation

// MARK: - Isolating the part of the objects a time selection covers
//
// A time selection is a RANGE of time over some DISPLAY rows. Several actions mean "the part of
// the objects inside the range, and nothing else" (the object menu applied to the zone, @see
// `ObjectActionScope.zone`). They all go through the same two moves, written once here and with
// no branch for the depth of the object — a top-level clip, a child of an open group, a group
// itself are all entries of `laneEntries`:
//
//   `timeSelectionTargets`   which objects the range crosses (read-only)
//   `isolateTimeSelection`   cut them at the range's two bounds, so that the part inside is an
//                            object of its own, and select those pieces
//
// A target is an object the range touches on one of its display rows. An INFINITE BUS is left out
// (its band has no start and no end: the window it stores is not matter anybody traced), and so is
// anything whose ANCESTOR is a target too — cutting the group already cuts what it holds, and a
// child cut a second time on its own would be cut twice.

extension EditViewModel {

    /// The objects the range crosses, on the display rows it covers — not cut, not selected.
    /// Touching at a bound only (an object that ends exactly where the range starts) is not
    /// crossing.
    func timeSelectionTargets(_ sel: TimeSelection) -> [LaneEntry] {
        let t1 = sel.timeRange.lowerBound, t2 = sel.timeRange.upperBound
        let entries = laneEntries
        let crossing = entries.filter { e in
            sel.lanes.contains(e.displayLane)
                && !e.item.isInfiniteBus
                && e.absStart < t2
                && e.absStart + e.item.duration > t1
        }
        return withoutDescendantsOfThemselves(crossing, in: entries)
    }

    /// The objects lying ENTIRELY inside the range (to the 1 ms the cuts keep), on its rows — what
    /// `isolateTimeSelection` leaves behind it. Same exclusions as the targets.
    func timeSelectionInterior(_ sel: TimeSelection) -> [LaneEntry] {
        let t1 = sel.timeRange.lowerBound, t2 = sel.timeRange.upperBound
        let entries = laneEntries
        let inside = entries.filter { e in
            sel.lanes.contains(e.displayLane)
                && !e.item.isInfiniteBus
                && e.item.duration > 0.0005
                && e.absStart > t1 - 0.001
                && e.absStart + e.item.duration < t2 + 0.001
        }
        return withoutDescendantsOfThemselves(inside, in: entries)
    }

    /// `picked` without the entries one of whose ancestors is in `picked` as well (it leaves with
    /// its ancestor). Walked through the parent ids of the WHOLE display list.
    private func withoutDescendantsOfThemselves(_ picked: [LaneEntry], in all: [LaneEntry]) -> [LaneEntry] {
        guard picked.count > 1 else { return picked }
        let ids = Set(picked.map(\.item.id))
        let parentOf = Dictionary(all.map { ($0.item.id, $0.parentID) }, uniquingKeysWith: { a, _ in a })
        return picked.filter { e in
            var ancestor = e.parentID
            while let a = ancestor {
                if ids.contains(a) { return false }
                ancestor = parentOf[a] ?? nil
            }
            return true
        }
    }

    /// True when isolating would cut something: an object of the range straddles one of its two
    /// bounds. When false the range already is made of whole objects.
    func timeSelectionNeedsIsolation(_ sel: TimeSelection) -> Bool {
        let t1 = sel.timeRange.lowerBound, t2 = sel.timeRange.upperBound
        return timeSelectionTargets(sel).contains { e in
            let end = e.absStart + e.item.duration
            return (e.absStart < t1 - 0.001 && end > t1 + 0.001)
                || (e.absStart < t2 - 0.001 && end > t2 + 0.001)
        }
    }

    /// Cuts the objects the range crosses at its two bounds — first the start, then the end — so
    /// that the part inside is an object in its own right, and SELECTS those pieces (the range
    /// stays). Returns them, in the display list's order.
    ///
    /// The targets are read AGAIN between the two passes: the first cut hands the right half a
    /// fresh id (the left keeps the original's), so the second must find the object that now
    /// straddles the end, not the one it was before. The cut is the ordinary one (`cut`), whose
    /// crossfade refit, note-aware MIDI split and fade rules therefore apply unchanged.
    ///
    /// UNDOABLE PRIMITIVE: each cut pushes its own undo point, like any `cut`. A caller that wants
    /// ONE step wraps the call (@see `singleUndoStep`, `isolateTimeSelectionAsOneStep`).
    @discardableResult
    func isolateTimeSelection(_ sel: TimeSelection) -> [UUID] {
        let t1 = sel.timeRange.lowerBound, t2 = sel.timeRange.upperBound
        guard t2 > t1 + 0.001 else { return [] }
        for t in [t1, t2] {
            let crossing = timeSelectionTargets(sel)
                .filter { $0.absStart < t - 0.001 && $0.absStart + $0.item.duration > t + 0.001 }
                .map(\.item.id)
            guard !crossing.isEmpty else { continue }
            cut(ids: crossing, atTime: t, keeping: nil)
        }
        let pieces = timeSelectionInterior(sel).map(\.item.id)
        selectIDs(Set(pieces))
        return pieces
    }

    /// `isolateTimeSelection` as ONE undo step of its own — and none at all when nothing had to be
    /// cut (the range already was made of whole objects: nothing changed, so nothing to undo).
    /// What an action that keeps its own undo point after it (a consolidation, a script) calls
    /// first: the isolation and the action are then two steps, which is the accepted cost.
    @discardableResult
    func isolateTimeSelectionAsOneStep(_ sel: TimeSelection) -> [UUID] {
        guard timeSelectionNeedsIsolation(sel) else {
            let pieces = timeSelectionInterior(sel).map(\.item.id)
            selectIDs(Set(pieces))
            return pieces
        }
        return singleUndoStep { isolateTimeSelection(sel) }
    }
}
