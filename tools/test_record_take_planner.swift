// What a finished recording becomes in a zone — `RecordTakePlanner`, asserted with no screen and no engine
// (the unit depends on Foundation only). Pinned down: the take is the file cropped to the zone's window
// (handles = the matter around it, reachable through `sourceOffset`), the lane below the lowest child, the
// previous unmuted takes crossing the window muted whole, and a capture outside the window (an object over
// the whole capture in the grey area, nothing muted).
//
//     swiftc -parse-as-library \
//         ../objekat/SoundObject/RecordTakePlanner.swift test_record_take_planner.swift \
//         -o /tmp/trtp && /tmp/trtp
//
// Exit: 0 if every assertion passes, 1 otherwise.

import Foundation

var fails: [String] = []
var total = 0

func check(_ name: String, _ ok: Bool) {
    total += 1
    if !ok { fails.append(name); print("FAIL  \(name)") }
}

func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }

typealias P = RecordTakePlanner

func child(_ s: Double, _ e: Double, lane: Int, muted: Bool = false, id: UUID = UUID()) -> P.Child {
    .init(id: id, start: s, end: e, lane: lane, isMuted: muted)
}

func plan(_ ws: Double, _ we: Double, _ kids: [P.Child] = [], origin: Double, length: Double) -> P.Plan {
    P.plan(windowStart: ws, windowEnd: we, children: kids, capture: .init(origin: origin, length: length))
}

@main
enum Run {
    static func main() {
        // ── A capture that covers the window: cropped, with handles ────────────────────────────────────────
        let a = plan(10, 20, origin: 5, length: 30)            // file 5..35
        check("covering: starts at the window", near(a.take.start, 10))
        check("covering: lasts the window", near(a.take.duration, 10))
        check("covering: the file is entered 5 s in (handle on the left)", near(a.take.sourceOffset, 5))
        check("covering: inside the window", !a.take.outsideWindow)
        check("covering: first take on lane 0", a.take.lane == 0)
        check("covering: nothing to mute", a.mutedIDs.isEmpty)

        // ── A capture that begins inside the window (record pressed late) ──────────────────────────────────
        let b = plan(10, 20, origin: 14, length: 30)           // file 14..44
        check("late press: starts where the file starts", near(b.take.start, 14))
        check("late press: ends at the window's end", near(b.take.duration, 6))
        check("late press: offset 0", near(b.take.sourceOffset, 0))

        // ── A capture that ends inside the window (stopped early) ──────────────────────────────────────────
        let c = plan(10, 20, origin: 0, length: 17)            // file 0..17
        check("early stop: starts at the window", near(c.take.start, 10))
        check("early stop: ends with the file", near(c.take.duration, 7))
        check("early stop: offset = distance from the file's origin", near(c.take.sourceOffset, 10))

        // ── A capture strictly inside the window ───────────────────────────────────────────────────────────
        let d = plan(10, 20, origin: 12, length: 3)
        check("inside: the whole file", near(d.take.start, 12) && near(d.take.duration, 3) && near(d.take.sourceOffset, 0))

        // ── The window starts before 0 / the file's origin is before 0 ─────────────────────────────────────
        let n = plan(-4, 6, origin: -10, length: 30)
        check("negative times: cropped like any other", near(n.take.start, -4) && near(n.take.duration, 10)
              && near(n.take.sourceOffset, 6))

        // ── Lanes and muting ───────────────────────────────────────────────────────────────────────────────
        let t1 = UUID(), t2 = UUID(), gone = UUID(), before = UUID(), after = UUID()
        let kids = [child(10, 20, lane: 0, id: t1),
                    child(10, 20, lane: 1, id: t2),
                    child(10, 20, lane: 2, muted: true, id: gone),
                    child(0, 10, lane: 3, id: before),          // ends exactly where the window starts
                    child(20, 30, lane: 4, id: after)]           // starts exactly where it ends
        let e = plan(10, 20, kids, origin: 8, length: 20)
        check("lane: below the lowest child (older on top)", e.take.lane == 5)
        check("mute: the unmuted children crossing the window, in order", e.mutedIDs == [t1, t2])
        check("mute: an already muted one is left alone", !e.mutedIDs.contains(gone))
        check("mute: touching the window is not crossing it",
              !e.mutedIDs.contains(before) && !e.mutedIDs.contains(after))
        let partial = plan(10, 20, [child(15, 40, lane: 0, id: t1)], origin: 0, length: 100)
        check("mute: a child that only overlaps the window counts", partial.mutedIDs == [t1])

        // ── Outside the window: an object over the whole capture, nothing muted ────────────────────────────
        let out1 = plan(10, 20, [child(10, 20, lane: 0, id: t1)], origin: 25, length: 5)   // after
        check("after the zone: whole capture", near(out1.take.start, 25) && near(out1.take.duration, 5)
              && near(out1.take.sourceOffset, 0))
        check("after the zone: flagged outside", out1.take.outsideWindow)
        check("after the zone: previous takes NOT muted", out1.mutedIDs.isEmpty)
        check("after the zone: still below the others", out1.take.lane == 1)
        let out2 = plan(10, 20, origin: 0, length: 10)                                       // ends where the zone begins
        check("before the zone (touching): outside, whole", out2.take.outsideWindow && near(out2.take.duration, 10))
        let out3 = plan(10, 20, origin: 20, length: 4)                                       // begins where the zone ends
        check("after the zone (touching): outside", out3.take.outsideWindow)

        // ── Odd inputs ─────────────────────────────────────────────────────────────────────────────────────
        let z = plan(10, 20, origin: 12, length: 0)
        check("an empty capture does not cross anything", z.take.outsideWindow && z.mutedIDs.isEmpty)
        check("no children: lane 0", plan(0, 5, origin: 0, length: 5).take.lane == 0)
        let neg = plan(0, 5, [child(0, 5, lane: -2, id: t1)], origin: 0, length: 5)
        check("a child on a negative lane: the take goes just below it", neg.take.lane == -1)

        print(fails.isEmpty ? "ALL PASS (\(total))" : "\(fails.count) FAILED of \(total)")
        exit(fails.isEmpty ? 0 : 1)
    }
}
