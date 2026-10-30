// Where an input dropped on the timeline goes — `RecordZonePlanner`, asserted with no screen and no
// engine (the unit depends on Foundation only). Pinned down: the 40 % of the view, the stop at the next
// object of the lane, the floor max(1 s, 24 px), the refusal on a clip, the time selection's exact in/out,
// an existing group that takes the input, a sub-lane of an open group (the zone is a sub-group), and the
// groups that cannot record (infinite, looping, consolidated). And `planMany`, for several inputs dragged
// at once: one lane per input downwards, each with its OWN end (40 % of the view or the next object of its
// lane), a group on a lane takes its input, the refusal of one lane refuses the lot. Dropped on a time
// selection: EVERY lane takes its in/out (the lanes outside the selection's included), and only a lane
// whose object starts before the selection's end is shorter, up to that object.
//
//     swiftc -parse-as-library \
//         ../objekat/SoundObject/RecordZonePlanner.swift test_record_zone_planner.swift \
//         -o /tmp/trzp && /tmp/trzp
//
// Exit: 0 if every assertion passes, 1 otherwise.

import Foundation

var fails: [String] = []
var total = 0

func check(_ name: String, _ ok: Bool) {
    total += 1
    if !ok { fails.append(name); print("FAIL  \(name)") }
}

typealias P = RecordZonePlanner
let gid = UUID(), cid = UUID(), pid = UUID()

func clip(_ s: Double, _ e: Double, id: UUID = UUID()) -> P.LaneObject { .init(id: id, start: s, end: e, kind: .other) }
func group(_ s: Double, _ e: Double, ok: Bool = true, id: UUID = UUID()) -> P.LaneObject {
    .init(id: id, start: s, end: e, kind: .group(recordable: ok))
}

func plan(_ t: Double, lane: Int = 2, span: Double = 100, pps: Double = 10, objs: [P.LaneObject] = [],
          sel: P.Selection? = nil, parent: P.Parent? = nil) -> P.Plan {
    P.plan(time: t, displayLane: lane, visibleSpanSecs: span, pixelsPerSecond: pps,
           laneObjects: objs, selection: sel, parent: parent)
}

func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }

func isCreate(_ p: P.Plan, _ s: Double, _ e: Double, parent: UUID? = nil) -> Bool {
    if case .create(let a, let b, let par) = p { return near(a, s) && near(b, e) && par == parent }
    return false
}

@main
enum Run {
    static func main() {
        // ── Empty lane: 40 % of the view ───────────────────────────────────────────────────────────────────
        check("empty lane: from the point, 40 % of the view wide", isCreate(plan(10), 10, 50))
        check("empty lane: a different view width", isCreate(plan(0, span: 20), 0, 8))
        check("a negative time is brought to 0", isCreate(plan(-5), 0, 40))

        // ── The next object of the lane is closer ──────────────────────────────────────────────────────────
        check("stops at the next object", isCreate(plan(10, objs: [clip(30, 40)]), 10, 30))
        check("an object farther than 40 % does not matter", isCreate(plan(10, objs: [clip(80, 90)]), 10, 50))
        check("an object BEFORE the point does not matter", isCreate(plan(50, objs: [clip(0, 20)]), 50, 90))
        check("the nearest of several objects wins", isCreate(plan(10, objs: [clip(40, 45), clip(25, 30)]), 10, 25))
        check("a group counts as an object for the stop", isCreate(plan(10, objs: [group(20, 60)]), 10, 20))
        check("an object starting exactly at the point leaves no room", plan(10, objs: [clip(10.0001, 12)]) == .refuse(.tooShort))

        // ── The floor: max(1 s, 24 px) ─────────────────────────────────────────────────────────────────────
        check("at 10 px/s the pixel floor (2.4 s) beats the second: 1 s of room is refused",
              plan(10, objs: [clip(11, 20)]) == .refuse(.tooShort))
        check("room of 2.4 s at 10 px/s is enough", isCreate(plan(10, objs: [clip(12.4, 20)]), 10, 12.4))
        check("room of 2.39 s at 10 px/s is refused", plan(10, objs: [clip(12.39, 20)]) == .refuse(.tooShort))
        check("zoomed in (200 px/s) the second is the floor: 1 s is enough", isCreate(plan(10, pps: 200, objs: [clip(11, 20)]), 10, 11))
        check("zoomed in: 0.99 s is refused", plan(10, pps: 200, objs: [clip(10.99, 20)]) == .refuse(.tooShort))
        check("a tiny view cannot give a zone under the floor", plan(0, span: 2, pps: 10) == .refuse(.tooShort))

        // ── Objects under the point ────────────────────────────────────────────────────────────────────────
        check("on a clip: refused", plan(15, objs: [clip(10, 20)]) == .refuse(.onObject))
        check("on the first instant of a clip: refused", plan(10, objs: [clip(10, 20)]) == .refuse(.onObject))
        check("on the clip's end: free (the end is exclusive)", isCreate(plan(20, objs: [clip(10, 20)]), 20, 60))
        check("on a group that records: it takes the input", plan(15, objs: [group(10, 20, id: gid)]) == .assign(group: gid))
        check("on a group that cannot (infinite / loop / consolidated): refused",
              plan(15, objs: [group(10, 20, ok: false)]) == .refuse(.notRecordable))
        check("an infinite bus covers the whole lane",
              plan(500, objs: [.init(id: UUID(), start: 0, end: .infinity, kind: .group(recordable: false))]) == .refuse(.notRecordable))
        check("a clip wins nothing over a selection: the point on a clip is refused even inside a selection",
              plan(15, objs: [clip(10, 20)], sel: .init(start: 5, end: 30, lanes: [2])) == .refuse(.onObject))

        // ── The time selection ─────────────────────────────────────────────────────────────────────────────
        let sel = P.Selection(start: 12, end: 18, lanes: [1, 2])
        check("on a selection: exactly its in/out", isCreate(plan(14, sel: sel), 12, 18))
        check("... at its edges too", isCreate(plan(12, sel: sel), 12, 18) && isCreate(plan(18, sel: sel), 12, 18))
        check("... even under the floor (the selection decides)", isCreate(plan(10.1, sel: .init(start: 10, end: 10.2, lanes: [2])), 10, 10.2))
        check("outside the selection: the ordinary rule", isCreate(plan(30, sel: sel), 30, 70))
        check("on another lane than the selection's: the ordinary rule", isCreate(plan(14, lane: 5, sel: sel), 14, 54))
        check("an object starting inside the selection stops the zone at its start (the object behind)",
              isCreate(plan(14, objs: [clip(16, 25)], sel: sel), 12, 16))
        check("... the nearest of several objects behind wins", isCreate(plan(14, objs: [clip(17, 20), clip(15, 16)], sel: sel), 12, 15))
        check("... a group behind stops it too", isCreate(plan(14, objs: [group(16, 25)], sel: sel), 12, 16))
        check("... an object before the selection does not matter", isCreate(plan(14, objs: [clip(2, 12)], sel: sel), 12, 18))
        check("... too little room before the object behind (under the floor) is refused",
              plan(12.5, objs: [clip(13, 25)], sel: sel) == .refuse(.tooShort))
        check("... room of 2.4 s at 10 px/s is enough", isCreate(plan(14, objs: [clip(14.4, 25)], sel: sel), 12, 14.4))
        check("an object covering the selection's start refuses it (overlap)", plan(14, objs: [clip(5, 13)], sel: sel) == .refuse(.overlap))
        check("an object starting exactly at the selection's start refuses it (overlap)", plan(14, objs: [clip(12, 13)], sel: sel) == .refuse(.overlap))
        check("an object ending exactly at the selection's start is fine", isCreate(plan(14, objs: [clip(5, 12)], sel: sel), 12, 18))
        check("a selection beside an object is fine", isCreate(plan(14, objs: [clip(18, 25)], sel: sel), 12, 18))
        check("a selection starting before 0 starts at 0", isCreate(plan(1, sel: .init(start: -3, end: 4, lanes: [2])), 0, 4))

        // ── An open group's sub-lane ───────────────────────────────────────────────────────────────────────
        let open = P.Parent(id: pid, allowed: true)
        check("in an open group: a sub-group", isCreate(plan(10, parent: open), 10, 50, parent: pid))
        check("in an open group: a selection gives a sub-group too", isCreate(plan(14, sel: sel, parent: open), 12, 18, parent: pid))
        check("in an open group, on a child group: assigned", plan(15, objs: [group(10, 20, id: gid)], parent: open) == .assign(group: gid))
        check("in an open group, on a child clip: refused", plan(15, objs: [clip(10, 20)], parent: open) == .refuse(.onObject))
        check("in a looping / consolidated group: refused", plan(10, parent: .init(id: pid, allowed: false)) == .refuse(.parentNotRecordable))

        // ── Odd inputs ─────────────────────────────────────────────────────────────────────────────────────
        check("pps = 0 does not divide by zero (the second is the floor)", isCreate(plan(0, pps: 0), 0, 40))
        check("an empty selection span is refused", plan(5, sel: .init(start: 5, end: 5, lanes: [2])) == .refuse(.tooShort))

        // ── Several inputs at once (planMany) ──────────────────────────────────────────────────────────────
        func many(_ t: Double, lane: Int = 2, n: Int, span: Double = 100, pps: Double = 10,
                  lanes: [Int: P.LaneContext] = [:], sel: P.Selection? = nil, parent: P.Parent? = nil) -> [P.Plan] {
            P.planMany(time: t, firstLane: lane, count: n, visibleSpanSecs: span, pixelsPerSecond: pps) { l in
                if let c = lanes[l] { return c }
                return P.LaneContext(objects: [], selection: sel, parent: parent)
            }
        }
        func ctx(_ objs: [P.LaneObject]) -> P.LaneContext { .init(objects: objs, selection: nil, parent: nil) }

        let three = many(10, n: 3)
        check("three inputs on an empty room: three plans", three.count == 3)
        check("... the same start and the same end on three free lanes",
              three.allSatisfy { isCreate($0, 10, 50) })
        check("one input = the single plan", many(10, n: 1) == [plan(10)])
        check("no input = no plan", many(10, n: 0).isEmpty)

        let ends = many(10, n: 3, lanes: [3: ctx([clip(30, 40)]), 4: ctx([clip(20, 25)])])
        check("each lane has its OWN end: 50 / 30 / 20", isCreate(ends[0], 10, 50) && isCreate(ends[1], 10, 30) && isCreate(ends[2], 10, 20))
        check("... and nothing is refused", !P.isRefused(ends))

        let mixed = many(15, n: 3, lanes: [3: ctx([group(10, 20, id: gid)])])
        check("a group on the second lane takes its input; the others make zones",
              isCreate(mixed[0], 15, 55) && mixed[1] == .assign(group: gid) && isCreate(mixed[2], 15, 55))

        let onClip = many(15, n: 3, lanes: [4: ctx([clip(10, 20)])])
        check("a clip on the third lane refuses that lane", onClip[2] == .refuse(.onObject))
        check("... the other plans are what they would be alone, but the lot is refused", isCreate(onClip[0], 15, 55) && P.isRefused(onClip))
        let tight = many(10, n: 2, lanes: [2: ctx([clip(10.5, 20)])])
        check("too little room on the first lane refuses the lot", tight[0] == .refuse(.tooShort) && P.isRefused(tight))
        check("a lane that is not a row of the timeline (nil) refuses",
              P.planMany(time: 10, firstLane: 2, count: 3, visibleSpanSecs: 100, pixelsPerSecond: 10) { $0 == 3 ? nil : ctx([]) }[1] == .refuse(.onObject))

        let tsel = P.Selection(start: 12, end: 18, lanes: [2, 3, 4])
        let onSel = many(14, n: 3, sel: tsel)
        check("on a time selection covering the three lanes: its in/out for each", onSel.allSatisfy { isCreate($0, 12, 18) })
        let partial = many(14, n: 3, sel: P.Selection(start: 12, end: 18, lanes: [2, 3]))
        check("a lane outside the selection's lanes takes the selection's in/out too (all the same length)",
              partial.allSatisfy { isCreate($0, 12, 18) })
        // The hand above the selection's lanes: the lanes below are in it, so the lot follows the selection.
        let handAbove = many(14, lane: 1, n: 3, sel: P.Selection(start: 12, end: 18, lanes: [2, 3]))
        check("hand on a lane outside the selection, one of the next lanes inside it: the selection rules all three",
              handAbove.allSatisfy { isCreate($0, 12, 18) })
        let noLane = many(14, lane: 6, n: 3, sel: P.Selection(start: 12, end: 18, lanes: [2, 3]))
        check("no lane of the drop in the selection: the ordinary rule everywhere", noLane.allSatisfy { isCreate($0, 14, 54) })
        let outTime = many(30, n: 3, sel: tsel)
        check("the point outside the selection's time: the ordinary rule everywhere", outTime.allSatisfy { isCreate($0, 30, 70) })

        func selCtx(_ objs: [P.LaneObject], sel: P.Selection) -> P.LaneContext { .init(objects: objs, selection: sel, parent: nil) }
        let behind = many(14, n: 3, lanes: [3: selCtx([clip(16, 25)], sel: tsel)], sel: tsel)
        check("an object behind shortens THAT lane only: 12-18 / 12-16 / 12-18",
              isCreate(behind[0], 12, 18) && isCreate(behind[1], 12, 16) && isCreate(behind[2], 12, 18) && !P.isRefused(behind))
        let behindOut = many(14, n: 3, lanes: [4: selCtx([clip(15, 25)], sel: P.Selection(start: 12, end: 18, lanes: [2, 3]))],
                             sel: P.Selection(start: 12, end: 18, lanes: [2, 3]))
        check("... also on a lane outside the selection's lanes: 12-18 / 12-18 / 12-15",
              isCreate(behindOut[0], 12, 18) && isCreate(behindOut[1], 12, 18) && isCreate(behindOut[2], 12, 15))
        let covered = many(14, n: 3, lanes: [3: selCtx([clip(5, 13)], sel: tsel)], sel: tsel)
        check("an object covering the selection's start on one lane refuses the lot",
              covered[1] == .refuse(.overlap) && P.isRefused(covered))
        let tightBehind = many(12.5, n: 3, lanes: [4: selCtx([clip(13, 25)], sel: tsel)], sel: tsel)
        check("an object behind leaving too little room refuses the lot", tightBehind[2] == .refuse(.tooShort) && P.isRefused(tightBehind))
        let grp = many(14, n: 3, lanes: [3: selCtx([group(10, 20, id: gid)], sel: tsel)], sel: tsel)
        check("a group under the point on a lane still takes the input; the others follow the selection",
              isCreate(grp[0], 12, 18) && grp[1] == .assign(group: gid) && isCreate(grp[2], 12, 18))
        let clipUnder = many(14, n: 2, lanes: [3: selCtx([clip(10, 20)], sel: tsel)], sel: tsel)
        check("a clip under the point on a lane still refuses the lot", clipUnder[1] == .refuse(.onObject) && P.isRefused(clipUnder))
        let one = many(14, n: 1, sel: tsel)
        check("a single input on a selection: its in/out", one == [plan(14, sel: tsel)] && isCreate(one[0], 12, 18))

        let inGroup = many(10, n: 2, parent: open)
        check("in an open group: sub-groups, one per lane", inGroup.allSatisfy { isCreate($0, 10, 50, parent: pid) })
        check("in a container that cannot record: refused", P.isRefused(many(10, n: 2, parent: .init(id: pid, allowed: false))))

        print(fails.isEmpty ? "ALL PASS (\(total))" : "\(fails.count) FAILED of \(total)")
        exit(fails.isEmpty ? 0 : 1)
    }
}
