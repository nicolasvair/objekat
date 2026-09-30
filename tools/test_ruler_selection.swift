// The arithmetic of a drag in the time ruler (`Shared/RulerSelection.swift`), asserted with no
// screen.
//
//     swiftc -parse-as-library \
//         ../objekat/Shared/RulerSelection.swift test_ruler_selection.swift \
//         -o /tmp/rulersel && /tmp/rulersel
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
enum RulerSelectionTest {
  static func main() {
    // Left to right, and right to left, give the same range.
    check("forward", RulerSelection.range(anchor: 1, current: 3, extending: nil) == 1...3)
    check("backward", RulerSelection.range(anchor: 3, current: 1, extending: nil) == 1...3)
    // A drag that snapped back onto its start traced nothing.
    check("zero span", RulerSelection.range(anchor: 2, current: 2, extending: nil) == nil)
    // ⇧ grows the held range, from either side, and never shortens it.
    check("extend right", RulerSelection.range(anchor: 5, current: 6, extending: 1...3) == 1...6)
    check("extend left", RulerSelection.range(anchor: 0.5, current: 0.75, extending: 1...3) == 0.5...3)
    check("extend inside keeps", RulerSelection.range(anchor: 1.5, current: 2, extending: 1...3) == 1...3)
    // A zero-length drag with a held range still answers that range.
    check("zero span extending", RulerSelection.range(anchor: 2, current: 2, extending: 1...3) == 1...3)
    // Never before zero.
    check("clamped at 0", RulerSelection.range(anchor: -1, current: 2, extending: nil) == 0...2)

    // Lanes: 0...lastRow, minus the automation rows.
    check("all lanes", RulerSelection.objectLanes(lastRow: 3, automationLanes: []) == [0, 1, 2, 3])
    check("automation left out",
          RulerSelection.objectLanes(lastRow: 4, automationLanes: [2, 3]) == [0, 1, 4])
    check("negative last row", RulerSelection.objectLanes(lastRow: -2, automationLanes: []) == [0])

    print("\(total - fails.count)/\(total) passed")
    exit(fails.isEmpty ? 0 : 1)
  }
}
