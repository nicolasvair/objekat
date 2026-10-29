// Where an input dropped on the timeline goes — `RecordZonePlanner`, asserted with no screen and no
// engine (the unit depends on Foundation only). Pinned down: the 40 % of the view, the stop at the next
// object of the lane, the floor max(1 s, 24 px), the refusal on a clip, the time selection's exact in/out,
// an existing group that takes the input, a sub-lane of an open group (the zone is a sub-group), and the
// groups that cannot record (infinite, looping, consolidated).
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
        check("a selection over an object of the lane is refused", plan(14, objs: [clip(16, 25)], sel: sel) == .refuse(.overlap))
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

        print(fails.isEmpty ? "ALL PASS (\(total))" : "\(fails.count) FAILED of \(total)")
        exit(fails.isEmpty ? 0 : 1)
    }
}
