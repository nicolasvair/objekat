// The take being recorded, as the timeline draws it — `RecordProgress`, asserted with no screen and no
// engine (the unit depends on Foundation only). Pinned down: the block runs from the press to the
// playhead, bounded by the zone's window; it is absent while the head has not reached the window; it
// stops growing at the window's end; and it sits on the lane the take will land on (the TOP lane of the
// zone's takes: nothing lies above it, so no row held open by a child pushes it), or on the zone's own row
// when the zone is closed. The previous takes being pushed down since the press, the lane is read from their lanes with
// the shift taken off; each finished pass of a loop leaves a ghost on the lane it will have at the stop.
//
//     swiftc -parse-as-library \
//         ../objekat/SoundObject/RecordTakePlanner.swift ../objekat/SoundObject/RecordProgress.swift \
//         test_record_progress.swift -o /tmp/trp && /tmp/trp
//
// Exit: 0 if every assertion passes, 1 otherwise.

import Foundation

var fails: [String] = []
var total = 0

func check(_ name: String, _ ok: Bool) {
    total += 1
    if !ok { fails.append(name); print("FAIL  \(name)") }
}

typealias R = RecordProgress

func span(_ press: Double, _ head: Double, _ ws: Double = 10, _ we: Double = 20) -> R.Span? {
    R.span(recordStart: press, head: head, windowStart: ws, windowEnd: we)
}

@main
enum Run {
    static func main() {
        // ── Time ───────────────────────────────────────────────────────────────────────────────────────────
        check("press before the window, head inside: from the window's start to the head", span(0, 14) == .init(start: 10, end: 14))
        check("press inside, head inside: press to head", span(12, 15) == .init(start: 12, end: 15))
        check("head past the window's end: stops at the end", span(12, 99) == .init(start: 12, end: 20))
        check("press before, head after: the whole window", span(0, 99) == .init(start: 10, end: 20))
        check("head before the window: nothing yet", span(0, 8) == nil)
        check("head exactly at the window's start: nothing yet", span(0, 10) == nil)
        check("press past the window's end: nothing", span(25, 30) == nil)
        check("press exactly at the window's end: nothing", span(20, 30) == nil)
        check("head at the press: nothing (no length yet)", span(12, 12) == nil)
        check("head behind the press (a glitch): nothing", span(15, 12) == nil)
        check("it grows: 11, 12, 13 give increasing ends", [11.0, 12, 13].compactMap { span(5, $0)?.end } == [11, 12, 13])
        check("a window starting at 0", R.span(recordStart: 0, head: 3, windowStart: 0, windowEnd: 8) == .init(start: 0, end: 3))

        // ── Lane ───────────────────────────────────────────────────────────────────────────────────────────
        check("open zone on row 4, no child: the first row under it (5)",
              R.displayLane(groupDisplayLane: 4, opensInline: true, takeLane: 0) == 5)
        check("open zone, takes from lane 0: the take goes on the top one (row 5), whatever lies below",
              R.displayLane(groupDisplayLane: 4, opensInline: true, takeLane: 0) == 5)
        check("... takes starting on lane 2: row 7",
              R.displayLane(groupDisplayLane: 4, opensInline: true, takeLane: 2) == 7)
        check("a closed zone: its own row",
              R.displayLane(groupDisplayLane: 4, opensInline: false, takeLane: 2) == 4)
        check("a zone at row 0, open, first take: row 1",
              R.displayLane(groupDisplayLane: 0, opensInline: true, takeLane: 0) == 1)

        // ── The lane while the previous takes are already pushed down ─────────────────────────────────────
        do {
            // The caller subtracts the shift from the children's lanes before asking `takeLane`: the children sit on
            // 1 and 2 after the press (they were on 0 and 1), the block goes on the EMPTY top lane (0).
            func children(_ lanes: [Int], shift: Int) -> [RecordTakePlanner.Child] {
                lanes.map { RecordTakePlanner.Child(id: UUID(), start: 0, end: 1, lane: $0 - shift, isMuted: false) }
            }
            let top = RecordTakePlanner.takeLane(children: children([1, 2], shift: 1))
            check("children on 1 and 2 with a shift of 1: the block goes on lane 0, the empty top lane", top == 0)
            check("... which is the row under an open zone at row 4: 5",
                  R.displayLane(groupDisplayLane: 4, opensInline: true, takeLane: top) == 5)
            check("after two laps (shift 3), children on 3 and 4: still lane 0",
                  RecordTakePlanner.takeLane(children: children([3, 4], shift: 3)) == 0)
            check("a zone whose takes start on lane 2 (shift 1): lane 2",
                  RecordTakePlanner.takeLane(children: children([3, 4], shift: 1)) == 2)
            check("an empty zone (no child): lane 0", RecordTakePlanner.takeLane(children: []) == 0)
        }

        // ── The ghosts ─────────────────────────────────────────────────────────────────────────────────────
        do {
            check("one pass finished: its ghost is just under the current one", R.ghostLane(top: 0, finished: 1, pass: 0) == 1)
            check("three finished: the oldest is the lowest, the newest of them just under the current",
                  (0..<3).map { R.ghostLane(top: 0, finished: 3, pass: $0) } == [3, 2, 1])
            check("the ghosts follow a top lane that is not 0", (0..<2).map { R.ghostLane(top: 2, finished: 2, pass: $0) } == [4, 3])
            check("a ghost on a reserved row is drawn", R.isReserved(lane: 2, reservedRows: 4))
            check("a ghost on the first row past the zone's rows is not", !R.isReserved(lane: 4, reservedRows: 4))
            check("a negative lane is not a row", !R.isReserved(lane: -1, reservedRows: 4))
            // The final layout, built as it grows: with L passes finished the previous children (original lane 0) are on
            // 1 + L, under the lowest ghost (lane L); at the stop there are L + 1 takes and they go to L + 1: nothing jumps.
            for l in 0...5 {
                let lowestGhost = l == 0 ? nil : R.ghostLane(top: 0, finished: l, pass: 0)
                let childrenNow = 1 + l
                let childrenAtStop = l + 1
                check("L=\(l): the previous children do not move at the stop", childrenNow == childrenAtStop)
                check("L=\(l): and sit just under the lowest ghost", lowestGhost.map { $0 + 1 == childrenNow } ?? true)
            }
        }

        print(fails.isEmpty ? "ALL PASS (\(total))" : "\(fails.count) FAILED of \(total)")
        exit(fails.isEmpty ? 0 : 1)
    }
}
