import Foundation

// MARK: - The name of the keyboard layout in use (PURE: no Carbon, no view)

/// The families the « Computer Keyboard » input is named after. The platform half
/// (`KeyboardLayoutWatcher`) reads what the keys at the Q W E R T Y positions TYPE; this file only decides what
/// that spells, so the decision can be compiled and asserted alone (`tools/test_keyboard_layout_name.swift`).
enum KeyboardLayoutFamily: String, Equatable {
    case azerty, qwerty, qwertz

    /// The family's name as it is written: proper names, never translated.
    var title: String {
        switch self {
        case .azerty: return "AZERTY"
        case .qwerty: return "QWERTY"
        case .qwertz: return "QWERTZ"
        }
    }
}

enum KeyboardLayoutName {
    /// The PHYSICAL keyCodes of the Q W E R T Y positions, in reading order. The layout is read through keys
    /// and not through its name because a layout's name says little (« French », « ABC », « Swiss German »)
    /// where the letters on these six keys are what the hand calls AZERTY or QWERTY.
    static let topRowKeyCodes: [UInt16] = [12, 13, 14, 15, 17, 16]

    /// The family `topRow` spells — the lowercased characters typed by `topRowKeyCodes` — or nil for any other
    /// arrangement (Dvorak, Colemak, a non-Latin layout…). Case does not matter.
    static func family(topRow: String) -> KeyboardLayoutFamily? {
        KeyboardLayoutFamily(rawValue: topRow.lowercased())
    }

    /// What to call the keyboard: the family's title, else the layout's own localised name, else nil.
    static func displayName(family: KeyboardLayoutFamily?, localizedLayoutName: String?) -> String? {
        if let family { return family.title }
        let name = localizedLayoutName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? nil : name
    }
}
