// What ⌘R renames: the decision table of `RenameShortcutRoute` (`Shared/RenameShortcutRoute.swift`), asserted
// with no screen. The file has nothing but Foundation behind it.
//
//     swiftc -parse-as-library \
//         ../objekat/Shared/RenameShortcutRoute.swift test_rename_shortcut_route.swift \
//         -o /tmp/renameroute && /tmp/renameroute
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

typealias Route = RenameShortcutRoute
typealias S = RenameShortcutRoute.Situation<Int>
typealias T = RenameShortcutRoute.Target<Int>

@main
enum RenameShortcutRouteTest {
  static func main() {
    let bin = UUID(), host = UUID(), stem = UUID(), main = UUID(), obj = UUID(), mark = UUID()

    func go(_ s: S) -> T { Route.route(s) }

    // Nothing at all
    check("nothing selected: none", go(S()) == .none)

    // 5 / 4: the timeline's own
    check("one object: object", go(S(selectedObject: obj)) == .object(obj))
    check("one annotation: annotation", go(S(annotation: mark)) == .annotation(mark))
    check("an object beats an annotation", go(S(selectedObject: obj, annotation: mark)) == .object(obj))

    // 1: the bin
    check("bin designated, no popover: fxLink", go(S(fxLink: bin, fxLinkHost: host)) == .fxLink(bin))
    check("bin beats the object", go(S(fxLink: bin, fxLinkHost: host, selectedObject: obj)) == .fxLink(bin))
    check("bin beats the Inputs list",
          go(S(fxLink: bin, fxLinkHost: host, inputsHoldKeyboard: true, selectedInputs: [1])) == .fxLink(bin))
    check("popover open, bin of THAT stem: fxLink",
          go(S(fxLink: bin, fxLinkHost: stem, openStem: stem, mainStem: main)) == .fxLink(bin))
    check("popover of the Main open, bin of the Main: fxLink",
          go(S(fxLink: bin, fxLinkHost: main, openStem: main, mainStem: main)) == .fxLink(bin))
    check("popover open, bin of ANOTHER host: the stem",
          go(S(fxLink: bin, fxLinkHost: host, openStem: stem, mainStem: main)) == .stem(stem))
    check("popover of the Main open, bin of another host: none",
          go(S(fxLink: bin, fxLinkHost: host, openStem: main, mainStem: main)) == .none)

    // 2: the stem's popover
    check("popover of a stem: stem", go(S(openStem: stem, mainStem: main)) == .stem(stem))
    check("popover of the Main: none", go(S(openStem: main, mainStem: main)) == .none)
    check("popover of a stem beats the object, the Inputs and the annotation",
          go(S(openStem: stem, mainStem: main, inputsHoldKeyboard: true, selectedInputs: [1],
               selectedObject: obj, annotation: mark)) == .stem(stem))
    check("popover of the Main: no fall-back on the object",
          go(S(openStem: main, mainStem: main, selectedObject: obj)) == .none)
    check("no plugin selection, popover open: the stem (no bin to prefer)",
          go(S(fxLink: nil, fxLinkHost: nil, openStem: stem, mainStem: main)) == .stem(stem))

    // 3: the Inputs list
    check("Inputs hold the keyboard, ONE row: input",
          go(S(inputsHoldKeyboard: true, selectedInputs: [4])) == .input(4))
    check("Inputs hold the keyboard, one row AND an object: input",
          go(S(inputsHoldKeyboard: true, selectedInputs: [4], selectedObject: obj)) == .input(4))
    check("Inputs hold the keyboard, no row: none",
          go(S(inputsHoldKeyboard: true, selectedInputs: [])) == .none)
    check("Inputs hold the keyboard, no row, one object: none (the object is left alone)",
          go(S(inputsHoldKeyboard: true, selectedInputs: [], selectedObject: obj)) == .none)
    check("Inputs hold the keyboard, two rows, one object: none (the object is left alone)",
          go(S(inputsHoldKeyboard: true, selectedInputs: [1, 2], selectedObject: obj)) == .none)
    check("Inputs hold the keyboard, two rows, one annotation: none",
          go(S(inputsHoldKeyboard: true, selectedInputs: [1, 2], annotation: mark)) == .none)
    check("Inputs do NOT hold the keyboard, one row, one object: object",
          go(S(inputsHoldKeyboard: false, selectedInputs: [4], selectedObject: obj)) == .object(obj))
    check("Inputs do NOT hold the keyboard, one row, nothing else: none",
          go(S(inputsHoldKeyboard: false, selectedInputs: [4])) == .none)

    // 3b: an input's popup
    check("audio input popup open: that input, whatever the selection",
          go(S(inputPopupOpen: true, openInput: 7, selectedInputs: [4], selectedObject: obj)) == .input(7))
    check("MIDI input popup open: none (no name of its own), the object is left alone",
          go(S(inputPopupOpen: true, openInput: nil, selectedObject: obj)) == .none)
    check("stem popover beats an input popup", go(S(openStem: stem, mainStem: main, inputPopupOpen: true, openInput: 7)) == .stem(stem))
    check("a bin of the open popup's chain beats the input",
          go(S(fxLink: bin, fxLinkHost: host, inputPopupOpen: true, openInput: 7, openInputHost: host)) == .fxLink(bin))
    check("a bin left in another chain, behind the input popup: the input",
          go(S(fxLink: bin, fxLinkHost: obj, inputPopupOpen: true, openInput: 7, openInputHost: host)) == .input(7))
    check("popup closed, rectangle selected, list holds the keyboard: the selected input",
          go(S(inputPopupOpen: false, inputsHoldKeyboard: true, selectedInputs: [4])) == .input(4))

    // Sanity: a bin without a host does not make the Main's popover rename it
    check("popover open, bin with no known host: the stem",
          go(S(fxLink: bin, fxLinkHost: nil, openStem: stem, mainStem: main)) == .stem(stem))

    print("\n\(total - fails.count)/\(total) passed")
    exit(fails.isEmpty ? 0 : 1)
  }
}
