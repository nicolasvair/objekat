import Foundation
import Observation

// MARK: - The signal view's session memory (docs/plan_synoptic_rework.md §B.7, §B.9)
//
// What the hand folded or unfolded in the signal view, remembered for the whole session and for every
// object at once: not saved with the project, not in the undo stack (folding is not an edit). One
// app-wide object, `SynopticUIState.shared`.
//
// - The 'audio file' zone's options are FOLDED by default (loop and reverse stay visible on its row; a
//   pill names a hidden setting that is not neutral): `clipOptionsExpanded`.
// - An FX link's block is UNFOLDED by default: `collapsedFXLinks` holds the bins the hand folded, keyed by
//   the BIN's id (`SynopticFXLink.stateKey`), so a bin folded on one object is folded on every host.
// - `renamingFXLinkID`: the bin whose header shows the inline rename field (⌘R, the header's menu).

@MainActor @Observable
final class SynopticUIState {
    static let shared = SynopticUIState()

    /// The 'audio file' zone shows all its options (false = one row, the default).
    var clipOptionsExpanded: Bool = false
    /// The FX link bins the hand folded (by bin id; unfolded by default).
    var collapsedFXLinks: Set<UUID> = []
    /// The bin being renamed inline (nil = none).
    var renamingFXLinkID: UUID? = nil

    init() {}

    func toggleClipOptions() { clipOptionsExpanded.toggle() }

    func isFXFolded(_ key: UUID) -> Bool { collapsedFXLinks.contains(key) }

    func toggleFXFold(_ key: UUID) { setFXFolded(key, !isFXFolded(key)) }

    func setFXFolded(_ key: UUID, _ folded: Bool) {
        if folded { collapsedFXLinks.insert(key) } else { collapsedFXLinks.remove(key) }
    }
}
