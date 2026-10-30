import Foundation

// What ⌘R renames, decided from the situation alone — taken out of `EditViewModel.performRenameShortcut` so
// that the decision table can be compiled and asserted with no screen:
//
//     swiftc -parse-as-library ../objekat/Shared/RenameShortcutRoute.swift test_rename_shortcut_route.swift \
//         -o /tmp/renameroute && /tmp/renameroute
//
// ⌘R is CONTEXTUAL: the thing that "has the keyboard" is renamed, and when it has it but cannot be renamed the
// shortcut does NOTHING rather than fall through to something else (a ⌘R aimed at an input that renamed the
// timeline's selected object behind it would be the worst answer). In order:
//
//  1. an FX link bin, when the signal view holds the keyboard on ONE bin. With a stem's popover open, only if
//     that selection lives in THAT stem's chain (the popover is another window: a selection left in an
//     object's chain, behind it, is not what the hand is looking at);
//  2. the stem whose popover is open — the Main has no name of its own, so the answer is « nothing »;
//  3. the Inputs list, when it holds the keyboard (@see KeyboardClaim, `.inputs`): exactly ONE selected row is
//     renamed; none or several: nothing, WITHOUT falling back on the timeline's object;
//  4. the one selected object of the timeline;
//  5. the one selected marker / region / comment.

enum RenameShortcutRoute {

    /// What ⌘R renames. `Input` is the Inputs tab's row type (`InputRef`); generic only so that this file
    /// compiles alone.
    enum Target<Input: Hashable>: Equatable {
        case fxLink(UUID)
        case stem(UUID)
        case input(Input)
        case object(UUID)
        case annotation(UUID)
        case none
    }

    /// Everything the decision reads. Each field is already « resolved » by the caller: `fxLink` is nil unless
    /// the signal view holds the keyboard AND its selection designates one bin.
    struct Situation<Input: Hashable> {
        /// The bin designated by the plugin selection, when the signal view holds the keyboard.
        var fxLink: UUID? = nil
        /// The host of the plugin selection (an object, a stem, the Main).
        var fxLinkHost: UUID? = nil
        /// The stem whose popover is open (the Main included).
        var openStem: UUID? = nil
        /// The Main's id: its popover has nothing to rename.
        var mainStem: UUID? = nil
        /// `KeyboardClaim.owner == .inputs`.
        var inputsHoldKeyboard: Bool = false
        var selectedInputs: [Input] = []
        /// The timeline's selected object, if exactly ONE is selected.
        var selectedObject: UUID? = nil
        /// The one selected marker / region / comment.
        var annotation: UUID? = nil
    }

    static func route<Input: Hashable>(_ s: Situation<Input>) -> Target<Input> {
        if let link = s.fxLink {
            if let stem = s.openStem {
                if s.fxLinkHost == stem { return .fxLink(link) }
                // Another host's selection, behind the popover: not what ⌘R is aimed at; the popover is.
            } else {
                return .fxLink(link)
            }
        }
        if let stem = s.openStem {
            return stem == s.mainStem ? .none : .stem(stem)
        }
        if s.inputsHoldKeyboard {
            return s.selectedInputs.count == 1 ? .input(s.selectedInputs[0]) : .none
        }
        if let object = s.selectedObject { return .object(object) }
        if let mark = s.annotation { return .annotation(mark) }
        return .none
    }
}
