import AppKit
import Observation

// MARK: - The band at the bottom of the timeline while a plugin card is being dragged
//
// The object move has its band (DÉPLACEMENT / COPIE, the ⌥ and ⌘ chips lit as they are held);
// a plugin drag had nothing but the cursor's '+' and the maillon. This is the same band for the
// plugin gesture: nothing = move, ⌥ = an independent copy (⌘ means nothing here).
//
// A plugin drag is a SYSTEM drag session: there is no gesture of ours to read it from, only the
// drop targets it hovers. So every door that takes a plugin — a timeline object, a bus's strip,
// a card or a cable of the synoptic — says "I am hovered" / "no longer", under its own key.
// The band shows while at least one key is present. Keys and not a flag: two neighbouring
// targets get the new one's `dropEntered` BEFORE the old one's `dropExited`, and a single flag
// would be cleared by the late exit while the hand is over the new target.
//
// Shared (not on the view-model): the synoptic's drop targets have no view-model at hand.

@MainActor @Observable
final class PluginDropHint {
    static let shared = PluginDropHint()

    /// Where the card would land, which decides what the band says.
    ///  • `.host` — an object or a bus, or a card / a cable of the synoptic: nothing = move,
    ///    ⌥ = an independent copy.
    ///  • `.intoBin` — a place INSIDE an FX link's block: the plugin joins the bin (every object
    ///    sharing it gets one), or ⌥ adds an independent copy of it.
    ///  • `.outOfBin` — an instance of an FX link let go OUTSIDE it: it leaves the bin for every
    ///    object and stays a plain plugin here; ⌥ takes an independent copy and leaves the bin alone.
    ///  • `.blockMove` — a whole FX link block: it moves to the target, which joins the bin (⌥ = the
    ///    source keeps its own, still on the same bin).
    ///  • `.send` — a SEND card is in the hand (not a plugin): the band says where it would be taken, or
    ///    why it cannot (@see SendDrop). No modifier: one send per pair, so no copy.
    ///  • `.sendChain` — a plugin going onto, or coming from, a SEND's box (INC 3): nothing = move,
    ///    ⌥ = copy.
    ///  • `.refusal(key)` — a plugin a send's box refuses, with the catalogue key of the reason
    ///    (@see SendBoxPluginRefusal). The only plugin refusal that speaks: elsewhere the cursor alone does.
    enum Context: Hashable { case host, intoBin, outOfBin, blockMove, sendChain, refusal(String), send(SendDropBanner) }

    struct State: Equatable {
        var context: Context
        var alt: Bool

        /// A copy is what the release makes: ⌥ (the same reading as `acceptPluginDrop` and as the
        /// synoptic's delegate — ⌘ is not read at all).
        var isCopy: Bool { alt }
    }

    private(set) var state: State?

    @ObservationIgnored private var targets: [String: Context] = [:]
    /// Follows ⌥ without the mouse moving: `dropUpdated` only speaks on a movement, and the
    /// expected gesture is to stop, read the band, press a key. Same probe as the file drop's
    /// (@see EditViewModel.fileDropModifierWatch): `Task.sleep` resumes in the drag's tracking
    /// run-loop mode, where a `.default` Timer would not.
    @ObservationIgnored private var watch: Task<Void, Never>?

    func present(_ key: String, context: Context) {
        if targets[key] != context { targets[key] = context }
        refresh()
        armWatch()
    }

    func leave(_ key: String) {
        guard targets.removeValue(forKey: key) != nil else { return }
        refresh()
    }

    private func refresh() {
        // No button down = no drag any more: a session cancelled over a target (Escape, a release
        // outside any window) is not guaranteed to send the `dropExited` that would close the band.
        if targets.isEmpty || NSEvent.pressedMouseButtons == 0 {
            targets.removeAll()
            if state != nil { state = nil }
            watch?.cancel(); watch = nil
            return
        }
        // The most specific place wins: a bin's own contexts, then a plain chain, then a host.
        let present = Set(targets.values)
        // A send in the hand outranks every other reading; between two lines the accepting one wins
        // (a neighbour's late exit must not hide where the card would land).
        var sendLines: [SendDropBanner] = []
        for case .send(let b) in present { sendLines.append(b) }
        var context: Context
        if let line = sendLines.first(where: { !$0.isRefusal }) ?? sendLines.first {
            context = .send(line)
        } else if let place = [Context.blockMove, .intoBin, .outOfBin, .sendChain].first(where: present.contains) {
            context = place
        } else if let refused = present.first(where: { if case .refusal = $0 { return true } else { return false } }) {
            context = refused
        } else {
            context = .host
        }
        // A plugin taken FROM a send's box reads as a send chain's, wherever it lands.
        if PluginDragSession.shared.fromSend, context == .host { context = .sendChain }
        let next = State(context: context, alt: NSEvent.modifierFlags.contains(.option))
        // Reassigned only if it changes: the timeline reads it, and rewriting the same value on
        // every hover update would invalidate it for nothing.
        if state != next { state = next }
    }

    private func armWatch() {
        guard watch == nil else { return }
        watch = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 40_000_000)
                guard let self, !self.targets.isEmpty else { return }
                self.refresh()
            }
        }
    }
}
