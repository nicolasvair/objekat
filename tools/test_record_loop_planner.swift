// A recording made THROUGH a loop — `RecordLoopPlanner`, asserted with no screen and no engine (Foundation only).
// Pinned down: one take per pass that crosses the zone's window, cropped to it, all pointing at the one file with
// their own `sourceOffset`; the newest on the top lane and the older ones one lane each below it (every existing
// child goes down by as many lanes as there are takes); "mute" mode = only the LAST crossing pass audible (even
// partial) and the previous takes crossing the window muted, "add" mode = everything audible and nothing muted;
// a partial pass at the stop kept, a pass of no length dropped; a zone no pass crosses = ONE object over the last
// pass, outside the window, nothing muted, the mutes made at the press given back; with ONE pass the plan is
// exactly `RecordTakePlanner.plan`; and the mute at the press aware of the loop (`reachableRange`).
//
//     swiftc -parse-as-library \
//         ../objekat/SoundObject/RecordTakePlanner.swift ../objekat/SoundObject/RecordLoopPlanner.swift \
//         test_record_loop_planner.swift -o /tmp/trlp && /tmp/trlp
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

typealias L = RecordLoopPlanner
typealias S = RecordLoopPlanner.Segment

func child(_ s: Double, _ e: Double, lane: Int, muted: Bool = false, id: UUID = UUID()) -> L.Child {
    .init(id: id, start: s, end: e, lane: lane, isMuted: muted)
}

/// The passes of a recording from `p` through the loop [ls, le], `n` full laps after the first stretch, then a
/// partial last pass of `tail` seconds (0 = none). The file is continuous: each pass starts where the previous ended.
func passes(from p: Double, loop ls: Double, _ le: Double, laps n: Int, tail: Double) -> [S] {
    var out: [S] = []
    var file = 0.0
    let first = le - p
    out.append(S(fileStart: file, length: first, timelineStart: p))
    file += first
    for _ in 0..<n {
        out.append(S(fileStart: file, length: le - ls, timelineStart: ls))
        file += le - ls
    }
    if tail > 0 { out.append(S(fileStart: file, length: tail, timelineStart: ls)) }
    return out
}

@main
enum Run {
    static func main() {
        // ── One pass = the linear plan, to the digit ───────────────────────────────────────────────────────
        do {
            let kids = [child(8, 14, lane: 0), child(12, 30, lane: 1, muted: true), child(25, 30, lane: 2)]
            for (origin, length) in [(5.0, 30.0), (14.0, 30.0), (0.0, 17.0), (0.0, 5.0), (30.0, 4.0)] {
                for mode in [true, false] {
                    let a = RecordTakePlanner.plan(windowStart: 10, windowEnd: 20, children: kids,
                                                   capture: .init(origin: origin, length: length), mutesPrevious: mode)
                    let b = L.plan(windowStart: 10, windowEnd: 20, children: kids,
                                   segments: [S(fileStart: 0, length: length, timelineStart: origin)], mutesPrevious: mode)
                    let tag = "one pass (\(origin), \(length), \(mode ? "mute" : "add"))"
                    check("\(tag): one take", b.takes.count == 1)
                    guard let t = b.takes.first else { continue }
                    check("\(tag): same start/duration/offset/lane/outside",
                          near(t.start, a.take.start) && near(t.duration, a.take.duration) && near(t.sourceOffset, a.take.sourceOffset)
                          && t.lane == a.take.lane && t.outsideWindow == a.take.outsideWindow)
                    check("\(tag): audible", t.audible)
                    check("\(tag): same mutes, unmutes, shift", b.mutedIDs == a.mutedIDs && b.unmuteIDs == a.unmuteIDs
                          && b.shiftIDs == a.shiftIDs && b.shiftBy == 1)
                }
            }
        }

        // ── Four passes of a loop [12, 15] over a zone [10, 20] pressed at 11 ───────────────────────────────
        // pass 0: 11..15 (file 0..4), 1: 12..15 (file 4..7), 2: 12..15 (file 7..10), 3 (partial): 12..13.5 (file 10..11.5)
        do {
            let segs = passes(from: 11, loop: 12, 15, laps: 2, tail: 1.5)
            let p = L.plan(windowStart: 10, windowEnd: 20, children: [], segments: segs)
            check("loop in the zone: one take per pass (4)", p.takes.count == 4)
            check("takes follow the passes", p.takes.map(\.pass) == [0, 1, 2, 3])
            check("pass 0 cropped to nothing (inside the window): 11..15, offset 0",
                  near(p.takes[0].start, 11) && near(p.takes[0].duration, 4) && near(p.takes[0].sourceOffset, 0))
            check("pass 1: 12..15, offset 4", near(p.takes[1].start, 12) && near(p.takes[1].duration, 3) && near(p.takes[1].sourceOffset, 4))
            check("pass 2: 12..15, offset 7", near(p.takes[2].start, 12) && near(p.takes[2].sourceOffset, 7))
            check("the partial pass is kept: 12..13.5, offset 10", near(p.takes[3].start, 12) && near(p.takes[3].duration, 1.5)
                  && near(p.takes[3].sourceOffset, 10))
            check("the newest on the top lane (0), the older ones below", p.takes.map(\.lane) == [3, 2, 1, 0])
            check("\"mute\": only the last pass is audible (even partial)", p.takes.map(\.audible) == [false, false, false, true])
            check("no take outside the window", p.takes.allSatisfy { !$0.outsideWindow })
            check("every take's file range lies in one continuous file (offsets chain)",
                  zip(p.takes, p.takes.dropFirst()).allSatisfy { near($0.sourceOffset + $0.duration, $1.sourceOffset) })
        }

        // ── "add" mode: everything audible, nothing muted ──────────────────────────────────────────────────
        do {
            let kids = [child(10, 20, lane: 0)]
            let segs = passes(from: 11, loop: 12, 15, laps: 1, tail: 0)
            let p = L.plan(windowStart: 10, windowEnd: 20, children: kids, segments: segs, mutesPrevious: false)
            check("add: two takes, both audible", p.takes.count == 2 && p.takes.allSatisfy(\.audible))
            check("add: nothing muted", p.mutedIDs.isEmpty)
            check("add: the existing child goes down by 2 lanes", p.shiftBy == 2 && p.shiftIDs == kids.map(\.id))
            check("add: lanes 1 (older) and 0 (newest)", p.takes.map(\.lane) == [1, 0])
        }

        // ── "mute" mode: the previous takes crossing the window are muted whole ────────────────────────────
        do {
            let a = child(10, 20, lane: 0), b = child(0, 5, lane: 1), c = child(10, 20, lane: 2, muted: true)
            let segs = passes(from: 11, loop: 12, 15, laps: 1, tail: 0)
            let p = L.plan(windowStart: 10, windowEnd: 20, children: [a, b, c], segments: segs)
            check("mute: the unmuted child crossing the window is muted, not the one outside, not the muted one",
                  p.mutedIDs == [a.id])
            check("mute: the lane taken is the highest child's", p.takes.map(\.lane) == [1, 0])
        }

        // ── A partial pass at the stop: never dropped, unless it has no length ─────────────────────────────
        do {
            let segs = passes(from: 11, loop: 12, 15, laps: 1, tail: 0) + [S(fileStart: 7, length: 0, timelineStart: 12)]
            let p = L.plan(windowStart: 10, windowEnd: 20, children: [], segments: segs)
            check("a pass of 0 sample is dropped", p.takes.count == 2)
            let tiny = passes(from: 11, loop: 12, 15, laps: 1, tail: 0.001)
            check("a pass of 1 ms is kept", L.plan(windowStart: 10, windowEnd: 20, children: [], segments: tiny).takes.count == 3)
        }

        // ── Loop and zone are independent: only the passes crossing the window make takes ──────────────────
        do {
            // zone [12, 14]; the loop [10, 16] crosses it every lap, the first stretch starts at 9 (before the zone)
            let segs = passes(from: 9, loop: 10, 16, laps: 1, tail: 0)       // 9..16, 10..16
            let p = L.plan(windowStart: 12, windowEnd: 14, children: [], segments: segs)
            check("window narrower than the loop: 2 takes of 2 s", p.takes.count == 2 && p.takes.allSatisfy { near($0.duration, 2) })
            check("pass 0 enters the file 3 s in (12 - 9)", near(p.takes[0].sourceOffset, 3))
            check("pass 1 enters at 7 + 2", near(p.takes[1].sourceOffset, 7 + 2))
            // zone [20, 30]: the loop never reaches it
            let q = L.plan(windowStart: 20, windowEnd: 30, children: [child(20, 30, lane: 0)], segments: segs)
            check("a zone the loop never crosses: ONE take, outside the window", q.takes.count == 1 && q.takes[0].outsideWindow)
            check("... over the LAST pass, at its real place and file position",
                  near(q.takes[0].start, 10) && near(q.takes[0].duration, 6) && near(q.takes[0].sourceOffset, 7))
            check("... mutes nothing", q.mutedIDs.isEmpty)
            check("... on the lane of the zone's takes, the children going down by one", q.takes[0].lane == 0 && q.shiftBy == 1)
            // part of the passes crosses, part does not: only those that cross give takes
            let r = L.plan(windowStart: 9, windowEnd: 10.5, children: [], segments: segs)
            check("only the passes that cross the window give takes (the first stretch 9..16 does; so does 10..16)", r.takes.count == 2)
            let r2 = L.plan(windowStart: 8, windowEnd: 9.5, children: [], segments: segs)
            check("only the first stretch crosses [8, 9.5]: one take, audible", r2.takes.count == 1 && r2.takes[0].audible
                  && near(r2.takes[0].start, 9) && near(r2.takes[0].duration, 0.5))
        }

        // ── The mutes made at the press, given back when no pass crosses ───────────────────────────────────
        do {
            let k = child(20, 30, lane: 0, muted: true)                      // muted at the press
            let segs = passes(from: 9, loop: 10, 16, laps: 1, tail: 0)
            let p = L.plan(windowStart: 20, windowEnd: 30, children: [k], segments: segs, mutedAtStart: [k.id])
            check("given back when nothing crosses the window", p.unmuteIDs == [k.id] && p.mutedIDs.isEmpty)
            let ok = child(10, 20, lane: 0, muted: true)
            let q = L.plan(windowStart: 12, windowEnd: 14, children: [ok], segments: segs, mutedAtStart: [ok.id])
            check("kept muted when a pass crosses (replaced)", q.mutedIDs == [ok.id] && q.unmuteIDs.isEmpty)
        }

        // ── No segment at all ───────────────────────────────────────────────────────────────────────────────
        do {
            let k = child(10, 20, lane: 0, muted: true)
            let p = L.plan(windowStart: 10, windowEnd: 20, children: [k], segments: [], mutedAtStart: [k.id])
            check("no segment: no take, the mutes given back", p.takes.isEmpty && p.unmuteIDs == [k.id] && p.shiftBy == 0)
        }

        // ── The mute at the press, aware of the loop ───────────────────────────────────────────────────────
        do {
            let a = child(10, 20, lane: 0), m = child(10, 20, lane: 1, muted: true)
            func at(_ press: Double, _ loop: ClosedRange<Double>?, ws: Double = 10, we: Double = 20, mode: Bool = true) -> [UUID] {
                L.mutesAtStart(windowStart: ws, windowEnd: we, children: [a, m], startPosition: press, loop: loop, mutesPrevious: mode)
            }
            check("no loop, press before the end: muted (as before)", at(5, nil) == [a.id])
            check("no loop, press at the end: nothing", at(20, nil).isEmpty)
            check("no loop, press beyond: nothing", at(25, nil).isEmpty)
            check("press beyond the window, loop behind the head: nothing", at(25, 12...15).isEmpty)
            check("press before the loop, loop crossing the window: muted", at(0, 12...15) == [a.id])
            check("press inside the loop, window inside the loop: muted", at(13, 12...15) == [a.id])
            check("loop beyond the window, press before it: muted (the head walks through the window to reach the loop)",
                  at(0, 30...40) == [a.id])
            check("press beyond the window, loop further on: nothing (the head never comes back)", at(25, 30...40).isEmpty)
            check("loop shorter than 250 ms counts for none", at(25, 12...12.1).isEmpty && at(5, 12...12.1) == [a.id])
            check("\"add\": never", at(5, nil, mode: false).isEmpty)
            let r = L.reachableRange(startPosition: 13, loop: 12...15)
            check("reachable from inside the loop = the loop", near(r.lowerBound, 12) && near(r.upperBound, 15))
            let r2 = L.reachableRange(startPosition: 5, loop: 12...15)
            check("reachable from before the loop = press to loop end", near(r2.lowerBound, 5) && near(r2.upperBound, 15))
        }

        // ── The journal -> the passes of a file ─────────────────────────────────────────────────────────────
        do {
            typealias J = L.JournalPoint
            let lin = L.segments(journal: [], origin: 4, length: 10)
            check("no journal: one linear pass", lin == [S(fileStart: 0, length: 10, timelineStart: 4)])
            check("a single point (an anchor) = a linear pass at the file's own origin",
                  L.segments(journal: [J(clock: 4, timeline: 4)], origin: 4, length: 10) == lin)
            check("a file that starts before the anchor: the first stretch is extended back",
                  L.segments(journal: [J(clock: 4.5, timeline: 4.5)], origin: 4, length: 10) == lin)
            // press at 1 (clock 1 = timeline 1), loop [3,5]: wraps at clock 5, 7, 9 ; the file starts at 0.98
            let j = [J(clock: 1, timeline: 1), J(clock: 5, timeline: 3), J(clock: 7, timeline: 3), J(clock: 9, timeline: 3)]
            let s = L.segments(journal: j, origin: 0.98, length: 8.5)       // file 0.98 .. 9.48 on the clock
            check("four passes", s.count == 4)
            check("pass 0 starts with the file, 0.02 s before the anchor",
                  near(s[0].fileStart, 0) && near(s[0].timelineStart, 0.98) && near(s[0].length, 4.02))
            check("pass 1: file 4.02 s in, timeline 3, 2 s", near(s[1].fileStart, 4.02) && near(s[1].timelineStart, 3) && near(s[1].length, 2))
            check("the last pass runs to the file's end (the tail)", near(s[3].fileStart, 8.02) && near(s[3].length, 0.48))
            check("the passes chain in the file", zip(s, s.dropFirst()).allSatisfy { near($0.fileStart + $0.length, $1.fileStart) })
            check("a file that ends before a point drops the later passes", L.segments(journal: j, origin: 1, length: 3).count == 1)
            check("a file that begins after the first points drops them", L.segments(journal: j, origin: 7.5, length: 1).count == 1
                  && near(L.segments(journal: j, origin: 7.5, length: 1)[0].timelineStart, 3.5))
            check("timeline(forClock:) — inside a pass", near(L.timeline(forClock: 6, journal: j), 4))
            check("timeline(forClock:) — on a wrap, the new pass", near(L.timeline(forClock: 7, journal: j), 3))
            check("timeline(forClock:) — before the anchor, extrapolated back", near(L.timeline(forClock: 0.5, journal: j), 0.5))
            check("timeline(forClock:) — no journal", near(L.timeline(forClock: 2.5, journal: []), 2.5))
        }

        // ── One undo step per pass ───────────────────────────────────────────────────────────────────────────
        do {
            check("steps: no pass, no step", L.passSteps(passes: []).isEmpty)
            check("steps: one pass = one step", L.passSteps(passes: [0]) == [[0]])
            check("steps: three passes = three steps", L.passSteps(passes: [0, 1, 2]) == [[0], [1], [2]])
            check("steps: unsorted and repeated indices are sorted and deduplicated",
                  L.passSteps(passes: [2, 0, 1, 1, 2]) == [[0], [1], [2]])
            check("steps: a pass index that skipped (a zone the loop did not reach) keeps its own step",
                  L.passSteps(passes: [1, 3]) == [[1], [3]])
            let twenty = L.passSteps(passes: Array(0..<20))
            check("steps: twenty passes cap at sixteen steps", twenty.count == 16)
            check("steps: the earliest five merge into the first step", twenty[0] == [0, 1, 2, 3, 4])
            check("steps: the others stay single", twenty.dropFirst().enumerated().allSatisfy { $0.element == [5 + $0.offset] })
            check("steps: every pass is in exactly one step", twenty.flatMap { $0 } == Array(0..<20))
            check("steps: exactly the cap stays single", L.passSteps(passes: Array(0..<16)).count == 16
                  && L.passSteps(passes: Array(0..<16)).allSatisfy { $0.count == 1 })
            check("steps: one over the cap merges two", L.passSteps(passes: Array(0..<17))[0] == [0, 1]
                  && L.passSteps(passes: Array(0..<17)).count == 16)
            check("steps: a custom cap", L.passSteps(passes: Array(0..<5), cap: 2) == [[0, 1, 2, 3], [4]])

            check("layout: no take", L.prefixLayout(takeCount: 0, baseLane: 3, mutesPrevious: true).isEmpty)
            // The prefix of k crossing passes is what `plan` makes of the first k segments, in both modes.
            let kids = [child(8, 14, lane: 2), child(12, 30, lane: 3)]
            let segs = passes(from: 5, loop: 10, 20, laps: 3, tail: 4)        // 5 passes, all crossing [10, 20]
            for mode in [true, false] {
                for k in 1...segs.count {
                    let plan = L.plan(windowStart: 10, windowEnd: 20, children: kids, segments: Array(segs.prefix(k)),
                                      mutesPrevious: mode)
                    let layout = L.prefixLayout(takeCount: k, baseLane: RecordTakePlanner.takeLane(children: kids),
                                                mutesPrevious: mode)
                    check("layout k=\(k) mutes=\(mode): as many takes as the plan", plan.takes.count == layout.count)
                    check("layout k=\(k) mutes=\(mode): the plan's lanes",
                          zip(plan.takes, layout).allSatisfy { $0.lane == $1.lane })
                    check("layout k=\(k) mutes=\(mode): the plan's audibility",
                          zip(plan.takes, layout).allSatisfy { $0.audible == $1.audible })
                    check("layout k=\(k) mutes=\(mode): the existing children go down by k", plan.shiftBy == k)
                }
            }
            let two = L.prefixLayout(takeCount: 3, baseLane: 0, mutesPrevious: true)
            check("layout: the newest on the base lane, the oldest lowest", two.map(\.lane) == [2, 1, 0])
            check("layout: \"mute\" leaves the last one audible", two.map(\.audible) == [false, false, true])
            check("layout: \"add\" leaves all audible",
                  L.prefixLayout(takeCount: 3, baseLane: 0, mutesPrevious: false).allSatisfy(\.audible))
        }

        print(fails.isEmpty ? "ALL PASS (\(total))" : "\(fails.count) FAILED of \(total)")
        exit(fails.isEmpty ? 0 : 1)
    }
}
