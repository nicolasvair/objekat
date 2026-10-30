import Foundation

// MARK: - The take being recorded, as the timeline draws it — the pure rules
//
// While a recording runs, the timeline shows a translucent red block that grows with the playhead and
// vanishes at the stop, when the real take appears. Two questions, answered here and nowhere else (the
// overlay AND `rec.status` ask the same functions, so what is drawn and what a script reads cannot drift):
//
//   - WHERE in time: from the press of "record" to the playhead, BOUNDED BY THE ZONE'S WINDOW — what the
//     take will show once it exists (the file is longer than the window, but only the window is seen);
//   - ON WHICH LANE: the one the take will land on, the TOP lane of the zone's takes — the lane
//     `RecordTakePlanner.takeLane` gives (the previous takes go down by one at the stop) — and not the
//     zone's own row. Nothing of the zone lies above that lane, so no row held open by a child pushes it.
//     A zone that is not open shows none of its children: there the block stays on the zone's own row.
//
// A plain Foundation unit with no model behind it, compiled and asserted alone
// (tools/test_record_progress.swift).

enum RecordProgress {

    struct Span: Equatable {
        let start: Double
        let end: Double
    }

    /// The stretch of the timeline the block covers: from the press (`recordStart`) to the playhead
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
}
