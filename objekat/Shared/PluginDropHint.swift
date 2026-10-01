import AppKit
import Observation

// MARK: - The band at the bottom of the timeline while a plugin card is being dragged
//
// The object move has its band (DÉPLACEMENT / COPIE, the ⌥ and ⌘ chips lit as they are held);
// a plugin drag had nothing but the cursor's '+' and the maillon. This is the same band for the
// plugin gesture: nothing = move, ⌥ = an independent copy, ⌘ = a linked copy.
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
    ///  • `.host` — an object or a bus: nothing = move, ⌥ = an independent copy, ⌘ = a linked copy
    ///    (or, for an FX link's plugin, the target joining the bin).
    ///  • `.sameChain` — a card or a cable of the synoptic, moving within a chain: ⌘ does not link
    ///    there (two linked instances in one chain are refused on purpose, @see transferPlugins) —
    ///    the band says so instead of lighting a ⌘ that would do nothing.
    ///  • `.intoBin` — a place INSIDE an FX link's block: the plugin joins the bin (every object
    ///    sharing it gets one), or ⌥ adds an independent copy of it; ⌘ does nothing.
    ///  • `.outOfBin` — an instance of an FX link let go OUTSIDE it: it leaves the bin for every
    ///    object and stays a plain plugin here; ⌥ takes an independent copy and leaves the bin alone.
    ///  • `.blockMove` — a whole FX link block: it moves to the target, which joins the bin (⌥ or ⌘ =
    ///    the source keeps its own, still on the same bin).
    enum Context: Equatable { case host, sameChain, intoBin, outOfBin, blockMove }

    struct State: Equatable {
        var context: Context
        var alt: Bool
        var cmd: Bool

        /// The gesture a release would make NOW — the same reading as `acceptPluginDrop`
        /// (⌘ wins over ⌥) and as the synoptic's delegate (⌥ only, ⌘ = a move). Only a host has a
        /// link to make: every other context says what ⌘ does (or does not) in its own words.
        var isLink: Bool { context == .host && cmd }
        /// A copy is what the release makes: ⌥, except where ⌘ is a copy too (a block's second
        /// gesture — it is never an independent one, the copy stays on the bin).
        var isCopy: Bool { !isLink && (alt || (context == .blockMove && cmd)) }
    }

    private(set) var state: State?

    @ObservationIgnored private var targets: [String: Context] = [:]
    /// Follows ⌥/⌘ without the mouse moving: `dropUpdated` only speaks on a movement, and the
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
        let context: Context = [Context.blockMove, .intoBin, .outOfBin, .sameChain].first(where: present.contains) ?? .host
        let f = NSEvent.modifierFlags
        let next = State(context: context, alt: f.contains(.option), cmd: f.contains(.command))
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
