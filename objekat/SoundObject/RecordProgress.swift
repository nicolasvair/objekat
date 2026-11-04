import Foundation

// MARK: - The take being recorded, as the timeline draws it — the pure rules
//
// While a recording runs, the timeline shows a translucent red block that grows with the playhead and
// vanishes at the stop, when the real take appears. Two questions, answered here and nowhere else (the
// overlay AND `rec.status` ask the same functions, so what is drawn and what a script reads cannot drift):
//
//   - WHERE in time: from the press of "record" to the playhead, BOUNDED BY THE ZONE'S WINDOW — what the
//     take will show once it exists (the file is longer than the window, but only the window is seen).
//     Recording THROUGH a loop, the head goes back at every wrap: the caller then gives the start of the
//     CURRENT pass (`OBJEngineCore.recordPassNow`) in place of the press, the block growing again from the
//     loop's start — one block per zone, on the lane its newest take will land on;
//   - ON WHICH LANE: the one the take will land on, the TOP lane of the zone's takes — the lane
//     `RecordTakePlanner.takeLane` gives — and not the zone's own row. Nothing of the zone lies above that lane,
//     so no row held open by a child pushes it. A zone that is not open shows none of its children: there the
//     block stays on the zone's own row. Since the press the previous takes are ALREADY one lane down (and one
//     more for every finished pass of a loop), so that this top lane is empty while the take is made: the caller
//     reads the lane from the children with that shift taken off;
//   - THE GHOSTS: through a loop, each finished pass that crossed the window leaves its span behind, on the lane
//     it will have at the stop — the final layout, built as it grows: with `L` passes finished, the current one
//     is on the top lane, pass `i` on `top + L - i` (`ghostLane`). A ghost is drawn only on a row the open zone
//     reserves (`isReserved`): a zone with nothing to push down shows the current pass alone.
//
// A plain Foundation unit with no model behind it, compiled and asserted alone
// (tools/test_record_progress.swift).

enum RecordProgress {

    struct Span: Equatable {
        let start: Double
        let end: Double
    }

    /// The stretch of the timeline the block covers: from the press (`recordStart`, or the start of the current pass
    /// when the recording runs through a loop) to the playhead
    /// (`head`), cut to the window [`windowStart`, `windowEnd`]. nil when nothing of it lies in the window
    /// yet (the head has not reached it, or the press was already past it).
    static func span(recordStart: Double, head: Double, windowStart: Double, windowEnd: Double) -> Span? {
        let start = max(recordStart, windowStart)
        let end = min(head, windowEnd)
        return end > start ? Span(start: start, end: end) : nil
    }

    /// The display lane of the block.
    /// - Parameters:
    ///   - groupDisplayLane: the zone's own display lane.
    ///   - opensInline: the zone shows its children (it is open).
    ///   - takeLane: the lane the take takes in the zone's own numbering (`RecordTakePlanner.takeLane`):
    ///     the highest child's, so no child lies above it and no row held open adds to it.
    static func displayLane(groupDisplayLane: Int, opensInline: Bool, takeLane: Int) -> Int {
        opensInline ? groupDisplayLane + 1 + takeLane : groupDisplayLane
    }

    /// The lane (the zone's own numbering) of the ghost of finished pass `pass` (0 = the first that crossed the window),
    /// when `finished` passes are done and the current one sits on `top`.
    static func ghostLane(top: Int, finished: Int, pass: Int) -> Int { top + finished - pass }

    /// True when the zone reserves a row for `lane` (`SoundObject.childLaneCount` rows from its first): a ghost on a
    /// lane the open zone does not hold would hang over the next object.
    static func isReserved(lane: Int, reservedRows: Int) -> Bool { lane >= 0 && lane < reservedRows }
}
