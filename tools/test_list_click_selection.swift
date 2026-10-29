// The selection rule of a list of rows (click, ⌘, ⇧, arrows, ⌘A), asserted with no screen.
// `ListClickSelection` (`Shared/ListClickSelection.swift`) has nothing but the standard library behind it.
//
//     swiftc -parse-as-library \
//         ../objekat/Shared/ListClickSelection.swift test_list_click_selection.swift \
//         -o /tmp/listclick && /tmp/listclick
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
enum ListClickSelectionTest {
  static func main() {
    let rows = [1, 2, 3, 4, 5, 6]
    func click(_ cur: Set<Int>, _ id: Int, shift: Bool = false, command: Bool = false) -> Set<Int> {
        ListClickSelection.apply(current: cur, clicked: id, ordered: rows, shift: shift, command: command)
    }
    func move(_ cur: Set<Int>, _ d: Int, extend: Bool = false, in o: [Int]? = nil) -> Set<Int> {
        ListClickSelection.move(current: cur, delta: d, ordered: o ?? rows, extend: extend)
    }

    // MARK: click
    check("a bare click selects the row alone", click([], 3) == [3])
    check("a bare click replaces a selection", click([1, 2, 5], 4) == [4])
    check("a bare click on a selected row keeps only that row", click([1, 2, 3], 2) == [2])
    check("⌘ adds a row", click([2], 4, command: true) == [2, 4])
    check("⌘ removes a row already there", click([2, 4], 4, command: true) == [2])
    check("⌘ can empty the selection", click([2], 2, command: true) == [])
    check("⇧ with nothing selected acts as a bare click", click([], 4, shift: true) == [4])
    check("⇧ extends downwards from the selection", click([2], 5, shift: true) == [2, 3, 4, 5])
    check("⇧ extends upwards from the selection", click([4], 1, shift: true) == [1, 2, 3, 4])
    check("⇧ takes the ENDS of a scattered selection", click([2, 5], 3, shift: true) == [2, 3, 4, 5])
    check("⇧ inside the span keeps the span", click([2, 5], 4, shift: true) == [2, 3, 4, 5])
    check("⇧ on the only selected row keeps it alone", click([3], 3, shift: true) == [3])
    check("⇧ wins over ⌘ when both are held", click([2], 4, shift: true, command: true) == [2, 3, 4])
    check("⇧ on a row that is not shown changes nothing", click([2], 99, shift: true) == [2])
    check("a selection made only of rows not shown is not an anchor", click([77], 3, shift: true) == [3])
    check("⌘ leaves rows not shown alone", click([77], 3, command: true) == [77, 3])
    check("a bare click drops rows not shown", click([77], 3) == [3])

    // MARK: arrows
    check("↓ with nothing selected takes the first row", move([], 1) == [1])
    check("↑ with nothing selected takes the last row", move([], -1) == [6])
    check("↓ moves by one row", move([3], 1) == [4])
    check("↑ moves by one row", move([3], -1) == [2])
    check("↓ stops at the last row", move([6], 1) == [6])
    check("↑ stops at the first row", move([1], -1) == [1])
    check("↓ from a range goes under its lowest row", move([2, 3, 4], 1) == [5])
    check("↑ from a range goes above its highest row", move([2, 3, 4], -1) == [1])
    check("↓ from a scattered selection goes under its lowest row", move([1, 4], 1) == [5])
    check("↓ from a range touching the end collapses on the last row", move([4, 5, 6], 1) == [6])
    check("⇧↓ with nothing selected takes the first row", move([], 1, extend: true) == [1])
    check("⇧↑ with nothing selected takes the last row", move([], -1, extend: true) == [6])
    check("⇧↓ adds the row under the selection", move([2, 3], 1, extend: true) == [2, 3, 4])
    check("⇧↑ adds the row above the selection", move([2, 3], -1, extend: true) == [1, 2, 3])
    check("⇧↓ fills the gaps of a scattered selection", move([1, 3], 1, extend: true) == [1, 2, 3, 4])
    check("⇧↓ at the last row changes nothing", move([5, 6], 1, extend: true) == [5, 6])
    check("⇧↑ at the first row changes nothing", move([1, 2], -1, extend: true) == [1, 2])
    check("an arrow on an empty list changes nothing", move([], 1, in: []) == [])
    check("a zero delta changes nothing", move([3], 0) == [3])
    check("a selection not shown counts as no selection", move([77], 1) == [1])

    // MARK: ⌘A and the row an arrow reached
    check("⌘A selects every row shown", ListClickSelection.all(ordered: rows) == Set(rows))
    check("⌘A on an empty list is empty", ListClickSelection.all(ordered: [Int]()) == [])
    check("edge after ↓ is the lowest end", ListClickSelection.edge(of: [2, 3, 4], delta: 1, ordered: rows) == 3)
    check("edge after ↑ is the highest end", ListClickSelection.edge(of: [2, 3, 4], delta: -1, ordered: rows) == 1)
    check("edge of nothing is nil", ListClickSelection.edge(of: Set<Int>(), delta: 1, ordered: rows) == nil)

    // A non-integer id, as the panel uses (a struct): the rule is generic.
    struct R: Hashable { var a: Int }
    let rr = [R(a: 0), R(a: 1), R(a: 2)]
    check("works on any hashable id",
          ListClickSelection.apply(current: [R(a: 0)], clicked: R(a: 2), ordered: rr, shift: true, command: false)
            == Set(rr))

    print("\n\(total - fails.count)/\(total) assertions pass")
    exit(fails.isEmpty ? 0 : 1)
  }
}
