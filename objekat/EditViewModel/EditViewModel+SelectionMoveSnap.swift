import Foundation

// The model-side half of the snap of a CARRIED time selection. The precedence itself (the range's
// bounds first, the grabbed object's edges second, the grid last) is pure arithmetic and lives in
// `Shared/SelectionMoveSnap.swift`; this knows what the targets are and what to leave out of them.
// `snappedTime` / `snapTime` are not touched — a dozen other gestures stand on them.
extension EditViewModel {

    /// The ids to leave OUT of the targets while the range `range` × `lanes` is carried WITHOUT ⌥.
    ///
    /// `moved` are the objects the gesture carries. What the drag does first — cut everything that
    /// straddles the two bounds (`prepareTimeSelectionTranslate`) — leaves, outside the range, the
    /// two scraps of each object cut: one ENDING exactly at the start, one STARTING exactly at the
    /// end. Left in the targets they would be a magnet on oneself: eight pixels of reach around the
    /// very place the range has just left, winning every time, so the range would stick to a travel
    /// of zero. They are recognised by where they touch the range, on its own lanes. (With ⌥ nothing
    /// is cut and nothing is carried out of its place: the originals stay, and they ARE targets —
    /// the caller simply passes no exclusion.) The descendants of everything excluded follow, so
    /// that the marks a carried group's children hold do not become a target either.
    func selectionMoveExcluded(range: ClosedRange<Double>, lanes: Set<Int>, moved: Set<UUID>) -> Set<UUID> {
        let eps = 1e-6
        var out = moved
        // `laneEntries` lists a group before its children: one pass sees the parent first.
        for e in laneEntries {
            if let p = e.parentID, out.contains(p) { out.insert(e.item.id); continue }
            guard lanes.contains(e.displayLane), !out.contains(e.item.id) else { continue }
            if abs(e.absStart + e.item.duration - range.lowerBound) < eps
                || abs(e.absStart - range.upperBound) < eps {
                out.insert(e.item.id)
            }
        }
        return out
    }

    /// The snap of the range `range` carried by `rawDt`, with NO side effect (@see `snappedTime`).
    ///
    /// `objectStart` / `objectEnd` are the grabbed object's edges BEFORE the travel. The floor is
    /// the range's own start at zero: it is the selection that is walled, not its first object.
    func snappedSelectionMove(range: ClosedRange<Double>, rawDt: Double,
                              objectStart: Double?, objectEnd: Double?,
                              excluding: Set<UUID>) -> SelectionMoveSnap.Result {
        SelectionMoveSnap.resolve(
            lo: range.lowerBound, hi: range.upperBound, rawDt: rawDt,
            objectStart: objectStart, objectEnd: objectEnd,
            // Only the REAL marks: the grid is the third step of the precedence, never a rival.
            targets: effectiveSnapEnabled ? snapTargets(excluding: excluding) : [],
            gridInterval: effectiveSnapGrid,
            tolerance: 8.0 / pixelsPerSecond,
            onTargetEpsilon: 0.5 / max(Self.minPixelsPerSecond, pixelsPerSecond),
            snapEnabled: effectiveSnapEnabled,
            minDt: -range.lowerBound)
    }

    /// The same, plus the guide line it leaves behind (@see `snapTime`): on the winning edge, yellow
    /// when it landed on a mark, grey otherwise — and grey on the start when the wall stopped it.
    func snapSelectionMove(range: ClosedRange<Double>, rawDt: Double,
                           objectStart: Double?, objectEnd: Double?,
                           excluding: Set<UUID>) -> SelectionMoveSnap.Result {
        let r = snappedSelectionMove(range: range, rawDt: rawDt,
                                     objectStart: objectStart, objectEnd: objectEnd,
                                     excluding: excluding)
        snapGuide = SnapGuide(time: r.guideTime, onTarget: r.onTarget)
        return r
    }
}
