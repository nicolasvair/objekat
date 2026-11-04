// What a click on an input's rectangle does: `InputStripClick` (`Inputs/InputStripClick.swift`), asserted with no screen.
//
//     swiftc -parse-as-library ../objekat/Inputs/InputStripClick.swift test_input_strip_click.swift \
//         -o /tmp/inputstripclick && /tmp/inputstripclick
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
enum InputStripClickTest {
    static func main() {
        typealias C = InputStripClick
        check("plain click: toggles the popup", C.popupAction(shift: false, command: false) == .toggle)
        check("⌘ click: selection only", C.popupAction(shift: false, command: true) == .leave)
        check("⇧ click: selection only", C.popupAction(shift: true, command: false) == .leave)
        check("⌘⇧ click: selection only", C.popupAction(shift: true, command: true) == .leave)

        check("toggle on a closed popup: opens it", C.popupAfter(open: nil, clicked: 3, action: .toggle) == 3)
        check("toggle on the open strip: closes it", C.popupAfter(open: 3, clicked: 3, action: .toggle) == nil)
        check("toggle on another strip: the popup moves", C.popupAfter(open: 2, clicked: 3, action: .toggle) == 3)
        check("leave: nothing opens", C.popupAfter(open: nil, clicked: 3, action: .leave) == nil)
        check("leave: the open one stays", C.popupAfter(open: 2, clicked: 3, action: .leave) == 2)

        print("\n\(total - fails.count)/\(total) passed")
        exit(fails.isEmpty ? 0 : 1)
    }
}
