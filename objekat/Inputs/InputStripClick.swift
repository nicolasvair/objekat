import Foundation

// What a click on an input's rectangle does (docs/plan_groupes_midi.md), decided from the modifiers and the popup alone —
// out of the view so that the table can be compiled and asserted with no screen:
//
//     swiftc -parse-as-library objekat/Inputs/InputStripClick.swift tools/test_input_strip_click.swift \
//         -o /tmp/inputstripclick && /tmp/inputstripclick
//
// A plain click SELECTS the input alone and OPENS its popup (the synoptic: the instrument and the effects), or closes it when
// it is already the open one. ⌘ and ⇧ are the list's selection gestures (add / remove, extend a range): they select and
// leave the popup as it is — a popup does not follow a multiple selection.

nonisolated enum InputStripClick {

    enum PopupAction: Equatable { case leave, toggle }

    /// What the click does to the popup. The selection itself is `ListClickSelection`'s, whatever the modifiers.
    static func popupAction(shift: Bool, command: Bool) -> PopupAction {
        shift || command ? .leave : .toggle
    }

    /// The open popup after the click: `open` is the strip whose popup is open now (nil = none), `clicked` the strip hit.
    static func popupAfter<ID: Equatable>(open: ID?, clicked: ID, action: PopupAction) -> ID? {
        switch action {
        case .leave:  return open
        case .toggle: return open == clicked ? nil : clicked
        }
    }
}
