import AppKit

/// What the modifier keys say about a FILE DROP over the timeline — the rules, with no model and no
/// view behind them, so they can be compiled and asserted alone:
///
///     swiftc -parse-as-library ../objekat/Shared/FileDropModifiers.swift test_file_drop_modifiers.swift \
///         -o /tmp/filedropmods && /tmp/filedropmods
///
/// A drag session under way (the Finder's or the library's) starves the app's `flagsChanged` monitor:
/// the modifiers have to be read off the keyboard itself (`NSEvent.modifierFlags`) while the hover
/// lasts, and these functions are what is made of what was read.
enum FileDropModifiers {

    /// Whether the drop SNAPS: the project's snap, inverted by ⌘ held — the same convention as every
    /// other gesture (`EditViewModel.effectiveSnapEnabled`).
    static func fileDropSnapOn(snapEnabled: Bool, flags: NSEvent.ModifierFlags) -> Bool {
        snapEnabled != flags.contains(.command)
    }
}
