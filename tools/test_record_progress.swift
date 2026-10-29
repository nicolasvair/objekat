// The take being recorded, as the timeline draws it — `RecordProgress`, asserted with no screen and no
// engine (the unit depends on Foundation only). Pinned down: the block runs from the press to the
// playhead, bounded by the zone's window; it is absent while the head has not reached the window; it
// stops growing at the window's end; and it sits on the lane the take will land on (the TOP lane of the
// zone's takes: nothing lies above it, so no row held open by a child pushes it), or on the zone's own row
// when the zone is closed.
//
//     swiftc -parse-as-library \
//         ../objekat/SoundObject/RecordProgress.swift test_record_progress.swift \
//         -o /tmp/trp && /tmp/trp
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

        print(fails.isEmpty ? "ALL PASS (\(total))" : "\(fails.count) FAILED of \(total)")
        exit(fails.isEmpty ? 0 : 1)
    }
}
