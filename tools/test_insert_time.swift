// The arithmetic of "insert time" (the ruler's menu entry), asserted with no screen: the time
// remapping `EditViewModel.rippleInsertMap`'s rule, the marks, the curves and the timeline's
// comments, and the round trip with the ripple's own splicing (insert then remove = identity).
//
//     swiftc -parse-as-library \
//         ../objekat/SoundObject/Marker.swift \
//         ../objekat/SoundObject/Automation.swift \
//         ../objekat/SoundObject/AutomationCurveMath.swift \
//         ../objekat/SoundObject/AutomationCurveShape.swift \
//         test_insert_time.swift -o /tmp/instime && /tmp/instime
//
// `rippleInsertMap` lives in an EditViewModel extension (which drags the whole app in), so the
// rule is restated here as `insertMap` — one line, and the build keeps the two honest through the
// API scenario (`scenario_insert_time.py`).
//
// Exit: 0 if every assertion passes, 1 otherwise.

import Foundation

// The two constants Automation.swift reads from SoundObject.swift.
let sendMinDb: Float = -60.0
let sendMaxDb: Float = 6.0

var fails: [String] = []
var total = 0

func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    total += 1
    if ok { print("ok    " + label) }
    else { fails.append(label); print("FAIL  \(label)  \(detail)") }
}

func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }

/// The rule of `EditViewModel.rippleInsertMap`.
func insertMap(_ x: Double, at: Double, length: Double) -> Double { x >= at ? x + length : x }

@main
enum InsertTimeTest {
  static func main() {
    // MARK: the time map
    check("map before", near(insertMap(1, at: 2, length: 3), 1))
    check("map at", near(insertMap(2, at: 2, length: 3), 5))
    check("map after", near(insertMap(4, at: 2, length: 3), 7))

    // MARK: markers
    let mk = [Marker(time: 1, name: "before"),
              Marker(time: 2, name: "at"),
              Marker(time: 5, name: "after"),
              Marker(time: 0, duration: 1, name: "region ends before"),
              Marker(time: 0, duration: 2, name: "region ends at"),
              Marker(time: 1, duration: 3, name: "region contains"),
              Marker(time: 2, duration: 1, name: "region starts at"),
              Marker(time: 4, duration: 1, name: "region after")]
    let out = mk.insertingTime(at: 2, length: 10)
    func byName(_ n: String) -> Marker { out.first { $0.name == n }! }
    check("marker before stays", near(byName("before").time, 1))
    check("marker at slides", near(byName("at").time, 12))
    check("marker after slides", near(byName("after").time, 15))
    check("region ending before stays", near(byName("region ends before").time, 0)
          && near(byName("region ends before").duration, 1))
    check("region ending at lo stays whole", near(byName("region ends at").duration, 2))
    check("region containing lo is lengthened, start kept",
          near(byName("region contains").time, 1) && near(byName("region contains").duration, 13))
    check("region starting at lo slides whole",
          near(byName("region starts at").time, 12) && near(byName("region starts at").duration, 1))
    check("region after slides whole",
          near(byName("region after").time, 14) && near(byName("region after").duration, 1))
    check("ids kept", out.map(\.id) == mk.map(\.id))
    check("nothing dropped", out.count == mk.count)
    check("zero length is the identity", mk.insertingTime(at: 2, length: 0) == mk)

    // Insert then remove the same span: the identity, for the marks that keep their length.
    let rt = mk.insertingTime(at: 2, length: 10).splicedInTime(removing: 2, to: 12)
    check("marker round trip (insert then splice)", rt == mk,
          "\(rt.map { "\($0.name):\($0.time)+\($0.duration)" })")

    // MARK: a span (the playback loop)
    check("span before stays", (0.0...1.0).insertingTime(at: 2, length: 10) == 0...1)
    check("span ending at lo stays", (0.0...2.0).insertingTime(at: 2, length: 10) == 0...2)
    check("span containing lo is lengthened", (1.0...4.0).insertingTime(at: 2, length: 10) == 1...14)
    check("span starting at lo slides whole", (2.0...4.0).insertingTime(at: 2, length: 10) == 12...14)
    check("span after slides whole", (3.0...4.0).insertingTime(at: 2, length: 10) == 13...14)
    check("span: zero length is the identity", (1.0...4.0).insertingTime(at: 2, length: 0) == 1...4)

    // MARK: automation
    func lane(_ pts: [(Double, Float)]) -> AutomationLane {
        AutomationLane(param: .volume, points: pts.map { AutomationPoint(t: $0.0, v: $0.1) })
    }
    // A curve entirely after `at`: it slides whole.
    let after = [lane([(3, 1), (5, 2)])].insertingTime(at: 2, length: 10)
    check("curve after slides", after.count == 1 && near(after[0].points[0].t, 13)
          && near(after[0].points[1].t, 15))
    // A curve entirely before `at`: untouched (its last value is held by the engine).
    let before = [lane([(0, 1), (1, 2)])].insertingTime(at: 2, length: 10)
    check("curve before untouched", before == [lane([(0, 1), (1, 2)])])
    // A curve crossing `at`: a flat blank, then the same shape.
    let cross = [lane([(0, 0), (4, 4)])].insertingTime(at: 2, length: 10)[0].points
    check("crossing: 4 points", cross.count == 4, "\(cross)")
    if cross.count == 4 {
        check("crossing: before the blank", near(cross[0].t, 0) && cross[0].v == 0)
        check("crossing: blank starts at lo with the value there",
              near(cross[1].t, 2) && abs(cross[1].v - 2) < 1e-4)
        check("crossing: blank ends at lo+length with the SAME value",
              near(cross[2].t, 12) && abs(cross[2].v - 2) < 1e-4)
        check("crossing: tail slid", near(cross[3].t, 14) && cross[3].v == 4)
        check("crossing: the blank is a straight (flat) segment", cross[1].c == 0)
    }
    // A point exactly at `at` slides with what follows (the left side keeps the one before).
    let onEdge = [lane([(0, 0), (2, 1), (4, 0)])].insertingTime(at: 2, length: 10)[0].points
    check("point at lo: plateau keeps its value",
          onEdge.contains { near($0.t, 2) && abs($0.v - 1) < 1e-4 }
          && onEdge.contains { near($0.t, 12) && abs($0.v - 1) < 1e-4 }, "\(onEdge)")
    check("empty curve dropped", [AutomationLane(param: .volume)].insertingTime(at: 1, length: 1).isEmpty)
    check("zero length is the identity",
          [lane([(0, 0), (4, 4)])].insertingTime(at: 2, length: 0) == [lane([(0, 0), (4, 4)])])
    // The tail after the blank is exactly the tail that was there, shifted.
    let orig = lane([(0, 0), (4, 4), (8, 1)])
    let ins = [orig].insertingTime(at: 2, length: 10)[0]
    check("tail shape preserved",
          ins.points.filter { $0.t > 12 + 1e-9 }.map { ($0.t - 10, $0.v) }
            .elementsEqual(orig.points.filter { $0.t > 2 }.map { ($0.t, $0.v) }, by: { near($0.0, $1.0) && $0.1 == $1.1 }))

    // MARK: comments
    let c1 = TimelineComment(startTime: 1, duration: 4, lane: 0, text: "before, straddles")
    let c2 = TimelineComment(startTime: 2, duration: 1, lane: 0, text: "at")
    let c3 = TimelineComment(startTime: 6, duration: 1, lane: 0, text: "after")
    var c4 = TimelineComment(startTime: 6, duration: 1, lane: 0, text: "in a group")
    c4.parentID = UUID()
    let cs = [c1, c2, c3, c4].insertingTime(at: 2, length: 10)
    check("comment before stays (and is not lengthened)",
          near(cs[0].startTime, 1) && near(cs[0].duration, 4))
    check("comment at lo slides", near(cs[1].startTime, 12))
    check("comment after slides", near(cs[2].startTime, 16))
    check("comment in a group is left alone", near(cs[3].startTime, 6))
    // The ripple's own splice (the fix of ⌥⌫): after slides back, inside goes, before stays.
    let sp = [c1, c2, c3, c4].splicedInTime(removing: 1.5, to: 3)
    check("splice: before stays", sp.contains { $0.text == "before, straddles" && near($0.startTime, 1) })
    check("splice: inside goes", !sp.contains { $0.text == "at" })
    check("splice: after slides back", sp.contains { $0.text == "after" && near($0.startTime, 4.5) })
    check("splice: group comment untouched", sp.contains { $0.text == "in a group" && near($0.startTime, 6) })
    let rtc = [c1, c3].insertingTime(at: 2, length: 10).splicedInTime(removing: 2, to: 12)
    check("comment round trip", rtc == [c1, c3])

    print("\(total - fails.count)/\(total) passed")
    exit(fails.isEmpty ? 0 : 1)
  }
}
