// "What a right click on the lanes means" — the decision behind the menu, asserted with no screen.
// `ContextMenuPlan` (`Shared/ContextMenuPlan.swift`) has no view and no model behind it, which is
// why it can be compiled and run alone, like `CrossfadeGrab` / `CutSelection` before it. The AppKit
// monitor that builds the menu cannot be driven headless; WHAT IT DECIDES can.
//
//     swiftc -parse-as-library \
//         ../objekat/Shared/ContextMenuPlan.swift test_context_menu_plan.swift \
//         -o /tmp/ctxplan && /tmp/ctxplan
//
// Five questions: which half of a block the point is on, whether it lies inside the time selection,
// whether a time selection exists at all (it decides an empty lane: a range ANYWHERE gives the
// range's menu there, none gives no menu), which menu the combination builds (and which annotation
// items it offers), and whether the click selects the object first.
//
// Exit: 0 if every assertion passes, 1 otherwise.

import Foundation

var fails: [String] = []
var total = 0

func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    total += 1
    if ok { print("ok    " + label) }
    else { fails.append(label); print("FAIL  \(label)  \(detail)") }
}

@main
enum ContextMenuPlanTest {
  static func main() {
    typealias P = ContextMenuPlan
    typealias Z = ContextMenuPlan.BlockZone

    // MARK: - The 50 % line: the left click's own

    check("top of the block is time", Z.zone(localY: 0, blockHeight: 100) == .time)
    check("just above the middle is time", Z.zone(localY: 49.9, blockHeight: 100) == .time)
    check("exactly the middle is the body (the left click's `<`)",
          Z.zone(localY: 50, blockHeight: 100) == .body)
    check("bottom of the block is the body", Z.zone(localY: 100, blockHeight: 100) == .body)

    // MARK: - Inside the time selection

    check("a point inside: lane and span",
          P.contains(lane: 2, time: 5, lanes: [1, 2, 3], range: 3...8))
    check("the span's bounds are inside (closed range)",
          P.contains(lane: 1, time: 3, lanes: [1, 2], range: 3...8)
            && P.contains(lane: 1, time: 8, lanes: [1, 2], range: 3...8))
    check("the right time on another lane is outside",
          !P.contains(lane: 4, time: 5, lanes: [1, 2, 3], range: 3...8))
    check("the right lane at another time is outside",
          !P.contains(lane: 2, time: 8.001, lanes: [1, 2, 3], range: 3...8)
            && !P.contains(lane: 2, time: 2.999, lanes: [1, 2, 3], range: 3...8))

    // MARK: - In the range: today's menu, whatever the object

    for zone in [Z.time, Z.body, nil] {
        for already in [true, false] {
            let d = P.decide(pointInTimeSelection: true, hasTimeSelection: true, zone: zone,
                             objectAlreadySelected: already)
            let tag = "in range, zone \(String(describing: zone)), selected \(already)"
            check(tag + ": the range's menu", d.layout == .rangeMenu)
            check(tag + ": nothing is selected", !d.selectsObject)
            check(tag + ": the comment is offered", d.offersComment)
            check(tag + ": the object marker only with an object under the point",
                  d.offersObjectMarker == (zone != nil))
        }
    }

    // MARK: - Upper half, no range: time

    do {
        let d = P.decide(pointInTimeSelection: false, hasTimeSelection: false, zone: .time,
                         objectAlreadySelected: false)
        check("upper half: the time menu", d.layout == .objectTimeMenu)
        check("upper half: the object marker is offered", d.offersObjectMarker)
        check("upper half: no comment (no range under the hand)", !d.offersComment)
        check("upper half: nothing is selected, the cursor stays", !d.selectsObject)
        let s = P.decide(pointInTimeSelection: false, hasTimeSelection: false, zone: .time,
                         objectAlreadySelected: true)
        check("upper half on a selected object: still nothing selected, same menu",
              s.layout == .objectTimeMenu && !s.selectsObject
                && s.offersObjectMarker && !s.offersComment)
        let e = P.decide(pointInTimeSelection: false, hasTimeSelection: true, zone: .time,
                         objectAlreadySelected: false)
        check("upper half with a range lying elsewhere: the same time menu, no comment",
              e.layout == .objectTimeMenu && !e.selectsObject
                && e.offersObjectMarker && !e.offersComment)
    }

    // MARK: - Lower half, no range: the object

    do {
        let d = P.decide(pointInTimeSelection: false, hasTimeSelection: false, zone: .body,
                         objectAlreadySelected: false)
        check("lower half: the object's menu", d.layout == .objectBodyMenu)
        check("lower half, not selected: the click selects it first", d.selectsObject)
        check("lower half: no object marker (it lives in the upper half)", !d.offersObjectMarker)
        check("lower half: no comment", !d.offersComment)
        let k = P.decide(pointInTimeSelection: false, hasTimeSelection: false, zone: .body,
                         objectAlreadySelected: true)
        check("lower half, already selected: the selection is kept whole (nothing selected)",
              k.layout == .objectBodyMenu && !k.selectsObject)
        let e = P.decide(pointInTimeSelection: false, hasTimeSelection: true, zone: .body,
                         objectAlreadySelected: false)
        check("lower half with a range lying elsewhere: the object's menu, which selects it",
              e.layout == .objectBodyMenu && e.selectsObject
                && !e.offersObjectMarker && !e.offersComment)
    }

    // MARK: - Nothing under the hand (an empty lane)

    do {
        let d = P.decide(pointInTimeSelection: false, hasTimeSelection: false, zone: nil,
                         objectAlreadySelected: false)
        check("no object, no range: no menu", d.layout == .nothing)
        check("no object, no range: nothing selected, nothing offered",
              !d.selectsObject && !d.offersObjectMarker && !d.offersComment)
    }

    // A range lying ELSEWHERE still gives the range's menu on an empty lane: nothing changed there.
    do {
        let d = P.decide(pointInTimeSelection: false, hasTimeSelection: true, zone: nil,
                         objectAlreadySelected: false)
        check("no object, a range lying elsewhere: the range's menu", d.layout == .rangeMenu)
        check("no object, a range lying elsewhere: the comment is offered", d.offersComment)
        check("no object, a range lying elsewhere: no object marker, nothing selected",
              !d.offersObjectMarker && !d.selectsObject)
        let i = P.decide(pointInTimeSelection: true, hasTimeSelection: true, zone: nil,
                         objectAlreadySelected: false)
        check("no object, a point inside the range: the very same decision", i == d)
    }

    // MARK: - A sweep: the invariants that hold for every combination

    for (inRange, hasRange) in [(true, true), (false, true), (false, false)] {
        for zone in [Z.time, Z.body, nil] {
            for already in [true, false] {
                let d = P.decide(pointInTimeSelection: inRange, hasTimeSelection: hasRange,
                                 zone: zone, objectAlreadySelected: already)
                let tag = "range \(inRange)/\(hasRange), zone \(String(describing: zone)), selected \(already)"
                check(tag + ": selecting implies the body, outside the range, unselected",
                      !d.selectsObject || (!inRange && zone == .body && !already))
                check(tag + ": a comment only with a time selection", !d.offersComment || hasRange)
                check(tag + ": an object marker only with an object", !d.offersObjectMarker || zone != nil)
                check(tag + ": a nothing-menu offers nothing",
                      d.layout != .nothing || (!d.offersObjectMarker && !d.offersComment && !d.selectsObject))
                check(tag + ": no object, the menu follows the existence of a range",
                      zone != nil || (d.layout == .rangeMenu) == hasRange)
                check(tag + ": a range lying elsewhere never drives an object's menu",
                      zone == nil || inRange || (d.layout != .rangeMenu && !d.offersComment))
            }
        }
    }

    print("\n\(total - fails.count)/\(total) assertions passed")
    if !fails.isEmpty {
        print("FAILED: " + fails.joined(separator: ", "))
        exit(1)
    }
  }
}
