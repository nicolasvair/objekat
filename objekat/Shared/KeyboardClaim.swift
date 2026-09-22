import AppKit
import SwiftUI

// MARK: - WHO OWNS THE KEYBOARD, project-wide.
//
// `TimelineKeyHandler` reads the keyboard through an AppKit LOCAL monitor, which runs inside
// `NSApp.sendEvent` — AHEAD of the responder chain, hence ahead of any `.onKeyPress` in a
// focused SwiftUI view. A panel or a control that wants a key cannot simply take SwiftUI focus
// and wait for it: the monitor has to be told, explicitly, to let that key through before it
// ever reaches AppKit's normal dispatch. That is the whole reason this type exists.
//
// WHY THE QUESTION IS NARROW (`owns(_:)` answers for a few keys, never "does this claimant want
// the keyboard at all"): the monitor still has to run the transport, the tools, and every
// shortcut for whoever does NOT currently hold a claim. Space must still start/stop playback,
// ⌘Z must still undo, and the digit-row tools must still fire — none of that keyboard is this
// claimant's to take. Widening the question to "is someone focused" would silently kill all of
// it the moment any field or list took focus. So each claimant is asked about only the keys it
// is known to need: the four arrows for a list, the arrows/⌫/digits/punctuation for a value box.
//
// WHY IDENTITY MATTERS (`release(_:)` checks the caller IS the current owner before clearing):
// when focus moves from box A to box B, SwiftUI fires A's `.onChange(of: isFocused)` (going
// false) and B's (going true) in an order this code does not control. If A's release ran
// unconditionally AFTER B's claim, the owner would be wiped out from under B and the flag would
// die right when it is needed. Checking identity first makes a late, stale release a no-op.
@MainActor
@Observable
final class KeyboardClaim {
    static let shared = KeyboardClaim()

    enum Claimant: Equatable {
        case explorer
        case soundList
        case valueField(UUID)
    }

    private(set) var owner: Claimant?
    /// Incremented ONLY by `revoke()`. A value box observes it to know the timeline just took
    /// the keyboard back (a click on the canvas, Escape…) even though nothing ever called this
    /// box's own `release`.
    private(set) var revocation: Int = 0

    private init() {}

    func claim(_ c: Claimant) {
        owner = c
    }

    func release(_ c: Claimant) {
        // Anti-race guard — see the header comment: only the CURRENT owner may clear itself.
        if owner == c { owner = nil }
    }

    func revoke() {
        guard owner != nil else { return }
        owner = nil
        revocation &+= 1
    }

    /// The ONE question the monitor asks. Placement in `TimelineKeyHandler` is unchanged: right
    /// after the text-input bail-out, before the cheatsheet is armed.
    func owns(_ event: NSEvent) -> Bool {
        switch owner {
        case .explorer, .soundList:
            // Mot pour mot l'ancien test (TimelineKeyHandler): les 4 flèches, peu importe les
            // modificateurs — ne rien changer à ces deux revendicateurs.
            return [123, 124, 125, 126].contains(event.keyCode)

        case .valueField:
            // `heldModifiers` lives on `TimelineView` (the type `TimelineKeyHandler.swift`
            // extends — there is no standalone `TimelineKeyHandler` type).
            let flags = event.modifierFlags.intersection(TimelineView.heldModifiers)
            if event.keyCode == 125 || event.keyCode == 126 {   // ↓ / ↑
                // JAMAIS `flags.isEmpty` : une flèche porte toujours .function + .numericPad.
                return flags.isEmpty
            }
            if event.keyCode == 51 || event.keyCode == 117 {    // ⌫ / Suppr avant
                return flags.isEmpty
            }
            // Le CARACTÈRE, pas le keyCode — exactement ce que teste DragValueBox.onKeyPress,
            // ce qui rend le clavier AZERTY cohérent : ⇧2 = "2" (va à la case), 2 nu = "é" (reste
            // à l'outil d'affectation de stem). ⇧ est donc AUTORISÉ ; ⌘ ⌃ ⌥ ne le sont pas.
            guard !event.modifierFlags.contains(.command),
                  !event.modifierFlags.contains(.control),
                  !event.modifierFlags.contains(.option),
                  let ch = event.characters?.first else { return false }
            return ch.isNumber || ch == "-" || ch == "." || ch == ","

        case nil:
            return false
        }
    }
}
