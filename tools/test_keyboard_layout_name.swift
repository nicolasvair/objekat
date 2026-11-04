// KeyboardLayoutName — what the keys at the Q W E R T Y positions spell, and what the « Computer Keyboard »
// input is therefore called, asserted with no Carbon, no screen and no engine. Pinned down: the three families,
// case not mattering, any other arrangement (Dvorak, Colemak, partial or empty rows) giving nil, the titles as
// proper names, and `displayName` preferring the family, then the layout's own localised name, then nothing.
//
//     swiftc -parse-as-library ../objekat/Shared/KeyboardLayoutName.swift test_keyboard_layout_name.swift \
//         -o /tmp/tkln && /tmp/tkln
//
// Exit: 0 if every assertion passes, 1 otherwise.

import Foundation

var fails: [String] = []
var total = 0

func check(_ name: String, _ ok: Bool) {
    total += 1
    if !ok { fails.append(name); print("FAIL  \(name)") }
}

@main struct Main {
    static func main() {
        // the six physical keys the family test reads, in reading order
        check("the top row is the keyCodes of Q W E R T Y", KeyboardLayoutName.topRowKeyCodes == [12, 13, 14, 15, 17, 16])

        // the three families
        check("azerty", KeyboardLayoutName.family(topRow: "azerty") == .azerty)
        check("qwerty", KeyboardLayoutName.family(topRow: "qwerty") == .qwerty)
        check("qwertz", KeyboardLayoutName.family(topRow: "qwertz") == .qwertz)

        // case does not matter
        check("mixed case", KeyboardLayoutName.family(topRow: "AzErTy") == .azerty)
        check("upper case", KeyboardLayoutName.family(topRow: "QWERTZ") == .qwertz)

        // anything else is nil
        check("Dvorak row", KeyboardLayoutName.family(topRow: "',.pyf") == nil)
        check("Colemak row", KeyboardLayoutName.family(topRow: "qwfpgj") == nil)
        check("empty row (the layout could not be read)", KeyboardLayoutName.family(topRow: "") == nil)
        check("a partial row", KeyboardLayoutName.family(topRow: "qwert") == nil)
        check("a longer row", KeyboardLayoutName.family(topRow: "qwertyu") == nil)
        check("spaces are not ignored", KeyboardLayoutName.family(topRow: " qwerty") == nil)
        check("a non-Latin row", KeyboardLayoutName.family(topRow: "йцукен") == nil)

        // titles: proper names
        check("titles", KeyboardLayoutFamily.azerty.title == "AZERTY" && KeyboardLayoutFamily.qwerty.title == "QWERTY"
              && KeyboardLayoutFamily.qwertz.title == "QWERTZ")

        // displayName: family, else the layout's localised name, else nil
        check("family wins over the localised name",
              KeyboardLayoutName.displayName(family: .azerty, localizedLayoutName: "French") == "AZERTY")
        check("family alone", KeyboardLayoutName.displayName(family: .qwertz, localizedLayoutName: nil) == "QWERTZ")
        check("no family: the layout's own name",
              KeyboardLayoutName.displayName(family: nil, localizedLayoutName: "Dvorak") == "Dvorak")
        check("the layout's name is trimmed",
              KeyboardLayoutName.displayName(family: nil, localizedLayoutName: "  Colemak \n") == "Colemak")
        check("an empty name is no name", KeyboardLayoutName.displayName(family: nil, localizedLayoutName: "") == nil)
        check("a blank name is no name", KeyboardLayoutName.displayName(family: nil, localizedLayoutName: "   ") == nil)
        check("nothing at all", KeyboardLayoutName.displayName(family: nil, localizedLayoutName: nil) == nil)

        print("\n\(total - fails.count)/\(total) assertions passed")
        exit(fails.isEmpty ? 0 : 1)
    }
}
