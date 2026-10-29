// What a finished recording becomes in a zone — `RecordTakePlanner`, asserted with no screen and no engine
// (the unit depends on Foundation only). Pinned down: the take is the file cropped to the zone's window
// (handles = the matter around it, reachable through `sourceOffset`), the TOP lane of the zone's takes (the
// newest on top; every existing child goes down by one lane, `shiftIDs`), the previous unmuted takes
// crossing the window muted whole in the default "mute" mode and NOTHING muted in the "add" mode
// (`mutesPrevious` false), and a capture outside the window (an object over the whole capture in the grey
// area, nothing muted). And the mute AT THE START of the recording (`mutesAtStart`, then
// `plan(... mutedAtStart:)` which reads those children as they were and gives back the ones the capture
// turns out not to replace).
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
        check("lane: the top lane of the takes (the newest on top)", e.take.lane == 0)
        check("lane: every existing child goes down by one", e.shiftIDs == [t1, t2, gone, before, after])
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
        check("after the zone: still on top of the others, which go down", out1.take.lane == 0 && out1.shiftIDs == [t1])
        let out2 = plan(10, 20, origin: 0, length: 10)                                       // ends where the zone begins
        check("before the zone (touching): outside, whole", out2.take.outsideWindow && near(out2.take.duration, 10))
        let out3 = plan(10, 20, origin: 20, length: 4)                                       // begins where the zone ends
        check("after the zone (touching): outside", out3.take.outsideWindow)

        // ── Odd inputs ─────────────────────────────────────────────────────────────────────────────────────
        let z = plan(10, 20, origin: 12, length: 0)
        check("an empty capture does not cross anything", z.take.outsideWindow && z.mutedIDs.isEmpty)
        check("no children: lane 0", plan(0, 5, origin: 0, length: 5).take.lane == 0)
        let neg = plan(0, 5, [child(0, 5, lane: -2, id: t1)], origin: 0, length: 5)
        check("a child on a negative lane: the take takes its lane, the child goes down", neg.take.lane == -2
              && neg.shiftIDs == [t1])
        let gap = plan(0, 5, [child(0, 5, lane: 3, id: t1), child(0, 5, lane: 5, id: t2)], origin: 0, length: 5)
        check("takes starting on lane 3: the new one takes lane 3, both go down", gap.take.lane == 3 && gap.shiftIDs == [t1, t2])
        check("no children: nothing to shift", plan(0, 5, origin: 0, length: 5).shiftIDs.isEmpty)

        // ── Muting at the START of the recording ───────────────────────────────────────────────────────────
        let o1 = UUID(), o2 = UUID(), o3 = UUID(), om = UUID()
        let prev = [child(10, 20, lane: 0, id: o1), child(12, 18, lane: 1, id: o2), child(30, 40, lane: 2, id: o3),
                    child(10, 20, lane: 3, muted: true, id: om)]
        let m0 = P.mutesAtStart(windowStart: 10, windowEnd: 20, children: prev, startPosition: 0)
        check("start: the unmuted children crossing the window, in order", m0 == [o1, o2])
        check("start: an already muted one and one outside are left alone", !m0.contains(om) && !m0.contains(o3))
        check("start inside the window: still muted", P.mutesAtStart(windowStart: 10, windowEnd: 20, children: prev, startPosition: 15) == [o1, o2])
        check("start at the window's end: nothing (the capture cannot cross it)",
              P.mutesAtStart(windowStart: 10, windowEnd: 20, children: prev, startPosition: 20).isEmpty)
        check("start beyond the window: nothing", P.mutesAtStart(windowStart: 10, windowEnd: 20, children: prev, startPosition: 99).isEmpty)
        check("no previous take: nothing", P.mutesAtStart(windowStart: 10, windowEnd: 20, children: [], startPosition: 0).isEmpty)

        // At the stop the children are already muted: the plan reads them as they were.
        let nowMuted = prev.map { c in [o1, o2].contains(c.id) ? child(c.start, c.end, lane: c.lane, muted: true, id: c.id) : c }
        let s1 = P.plan(windowStart: 10, windowEnd: 20, children: nowMuted, capture: .init(origin: 5, length: 30),
                        mutedAtStart: [o1, o2])
        check("stop after a mute at the start: the plan still lists them as muted", s1.mutedIDs == [o1, o2])
        check("... nothing to give back", s1.unmuteIDs.isEmpty)
        check("... the take goes on the top lane (lane 0), the four children go down", s1.take.lane == 0
              && s1.shiftIDs == [o1, o2, o3, om])
        let s2 = P.plan(windowStart: 10, windowEnd: 20, children: nowMuted, capture: .init(origin: 25, length: 4),
                        mutedAtStart: [o1, o2])
        check("capture outside the window: nothing muted, the early mutes are given back",
              s2.take.outsideWindow && s2.mutedIDs.isEmpty && s2.unmuteIDs == [o1, o2])
        let s3 = P.plan(windowStart: 10, windowEnd: 20, children: prev, capture: .init(origin: 5, length: 30))
        check("without mutedAtStart the plan is what it was (mutes at the stop)", s3.mutedIDs == [o1, o2] && s3.unmuteIDs.isEmpty)
        check("takeLane = the plan's lane (the top one)", P.takeLane(children: prev) == 0 && P.takeLane(children: []) == 0)

        // ── The "add" mode: nothing is muted, nothing given back ─────────────────────────────────────────────
        check("add: no mute at the start", P.mutesAtStart(windowStart: 10, windowEnd: 20, children: prev, startPosition: 0,
                                                          mutesPrevious: false).isEmpty)
        check("add (explicit true): the default mode still mutes", P.mutesAtStart(windowStart: 10, windowEnd: 20, children: prev,
                                                                                  startPosition: 0, mutesPrevious: true) == [o1, o2])
        let ad = P.plan(windowStart: 10, windowEnd: 20, children: prev, capture: .init(origin: 5, length: 30), mutesPrevious: false)
        check("add: the plan mutes nothing", ad.mutedIDs.isEmpty && ad.unmuteIDs.isEmpty)
        check("add: the take is still cropped and on the top lane, the children down",
              near(ad.take.start, 10) && near(ad.take.duration, 10) && ad.take.lane == 0 && ad.shiftIDs == [o1, o2, o3, om])
        let adOut = P.plan(windowStart: 10, windowEnd: 20, children: prev, capture: .init(origin: 25, length: 4), mutesPrevious: false)
        check("add, outside the window: flagged outside, nothing muted or given back",
              adOut.take.outsideWindow && adOut.mutedIDs.isEmpty && adOut.unmuteIDs.isEmpty && adOut.shiftIDs.count == 4)

        // ── The order after several takes: the newest on top, the older ones below, in either mode ──────────
        func record(_ kids: [P.Child], mutesPrevious: Bool, _ id: UUID) -> [P.Child] {
            let p = P.plan(windowStart: 10, windowEnd: 20, children: kids, capture: .init(origin: 5, length: 30),
                           mutesPrevious: mutesPrevious)
            let moved = kids.map { k in
                P.Child(id: k.id, start: k.start, end: k.end, lane: p.shiftIDs.contains(k.id) ? k.lane + 1 : k.lane,
                        isMuted: k.isMuted || p.mutedIDs.contains(k.id))
            }
            return moved + [P.Child(id: id, start: p.take.start, end: p.take.start + p.take.duration, lane: p.take.lane, isMuted: false)]
        }
        let a1 = UUID(), a2 = UUID(), a3 = UUID()
        for mode in [true, false] {
            var z = record([], mutesPrevious: mode, a1)
            z = record(z, mutesPrevious: mode, a2)
            z = record(z, mutesPrevious: mode, a3)
            let order = z.sorted { $0.lane < $1.lane }.map(\.id)
            check("\(mode ? "mute" : "add"): after three takes the lanes read newest, middle, oldest", order == [a3, a2, a1]
                  && z.map(\.lane).sorted() == [0, 1, 2])
            let audible = z.filter { !$0.isMuted }.map(\.id)
            check("\(mode ? "mute" : "add"): audible = \(mode ? "the newest only" : "all three")",
                  Set(audible) == (mode ? [a3] : [a1, a2, a3]))
        }

        print(fails.isEmpty ? "ALL PASS (\(total))" : "\(fails.count) FAILED of \(total)")
        exit(fails.isEmpty ? 0 : 1)
    }
}
