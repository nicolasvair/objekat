// "The caret as a snap target" (`Shared/CaretSnap.swift`), asserted with no screen.
//
//     swiftc -parse-as-library ../objekat/Shared/CaretSnap.swift test_caret_snap.swift \
//         -o /tmp/caretsnap && /tmp/caretsnap
//
// Exit: 0 if every assertion passes, 1 otherwise.

import Foundation

var fails: [String] = []
var total = 0
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    total += 1
    if ok { print("ok    " + label) } else { fails.append(label); print("FAIL  \(label)  \(detail)") }
}

@main struct Runner { static func main() {
    typealias C = CaretSnap
    check("a caret on a lane offers its instant", C.target(cursor: 4.27, caretLane: 2, hasTimeSelection: false) == 4.27)
    check("the lane is of no importance (lane 0)", C.target(cursor: 4.27, caretLane: 0, hasTimeSelection: false) == 4.27)
    check("the lane is of no importance (lane 40)", C.target(cursor: 4.27, caretLane: 40, hasTimeSelection: false) == 4.27)
    check("no caret: nothing", C.target(cursor: 4.27, caretLane: nil, hasTimeSelection: false) == nil)
    check("a time selection is up (caret hidden): nothing", C.target(cursor: 4.27, caretLane: 2, hasTimeSelection: true) == nil)
    check("no caret AND a time selection: nothing", C.target(cursor: 4.27, caretLane: nil, hasTimeSelection: true) == nil)
    check("caret at 0 is a target", C.target(cursor: 0, caretLane: 1, hasTimeSelection: false) == 0)
    check("caret before 0 is not (nothing drawn there)", C.target(cursor: -0.5, caretLane: 1, hasTimeSelection: false) == nil)

    print("\n\(total - fails.count)/\(total) ok")
    exit(fails.isEmpty ? 0 : 1)
} }
