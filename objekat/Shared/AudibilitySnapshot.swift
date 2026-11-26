import Foundation

// MARK: - The listening state, frozen into values
//
// The one rule that composes an object's silence (its mute, its stem's mute, a solo that filters it
// out) — @see the header of `EditViewModel+Audibility.swift`, which builds and pushes it. Apart from
// the view-model so that the code that only READS the rule can compile alone: the picture index
// (`VideoObjectIndex+Items.swift`, `tools/test_video_model.swift`) asks it whether a picture would be
// silenced were it a sound.

/// The listening state frozen into values: what does not depend on the object itself (the solo's roots,
/// the audible closure, the muted stems). A value, and not a call to the view model, because the rendering
/// of a `Canvas` is not MainActor-isolated and cannot query it — without this the rule would be
/// rewritten alongside, and that is exactly what is to be avoided.
nonisolated struct AudibilitySnapshot {
    /// The objects DIRECTLY soloed (confirmed ∪ temporary) — not the closure by ancestor.
    var soloRoots: Set<UUID> = []
    /// Is any solo filtering the listening?
    var soloActive: Bool = false
    /// The audible closure under that solo (audible leaves + their ancestor groups).
    var soloAudible: Set<UUID> = []
    /// The stems whose bus is muted (the Main cannot be muted).
    var mutedStemIDs: Set<UUID> = []
    /// The ANCESTOR groups of a direct solo: their fader must stay open even if they are muted,
    /// otherwise the container would multiply by zero the descendant that is meant to be heard.
    var soloRootAncestors: Set<UUID> = []
    /// THE SOLO OF AN AUX (@see EditViewModel.wetListening): the auxes DIRECTLY soloed…
    var wetAuxes: Set<UUID> = []
    /// …the objects heard ONLY through their sends to them (the outermost sender of each path: its
    /// fader stays open, its direct output is cut at the tail of its chain by the engine)…
    var wetOnlySenders: Set<UUID> = []
    /// …and those senders with everything they contain: none of it is silenced by the solo's
    /// filtering (a group's children feed the group that sends), and none of it feeds any aux but a
    /// soloed one.
    var wetZone: Set<UUID> = []

    /// True if the object shows as "muted": a mute — its own or its stem's — that the direct
    /// solo does not lift. The silence due to the solo's FILTERING is not part of it: it has its
    /// own visual language (opacity), @see EditViewModel.isSoloDimmed.
    func isMutedInMix(_ item: SoundObject) -> Bool {
        if soloRoots.contains(item.id) { return false }
        if item.isMuted { return true }
        return item.stemID.map { mutedStemIDs.contains($0) } ?? false
    }

    /// True if the object is reduced to silence, all layers taken together.
    func isSilenced(_ item: SoundObject) -> Bool {
        // The direct solo wins over EVERYTHING: over the mutes (`isMutedInMix` says so again on its own
        // account) as over the filtering on the next line.
        if soloRoots.contains(item.id) { return false }
        // And so does the path leading to it — a muted group must not stifle the soloed descendant that
        // goes through it. Silence only here, not in `isMutedInMix`: the group stays displayed
        // muted, which it still is for all the rest of its content.
        if soloRootAncestors.contains(item.id) { return false }
        if isMutedInMix(item) { return true }
        // Heard through its sends to a soloed aux: not filtered out (its DRY is cut elsewhere — by the
        // engine at the tail of its chain, @see wetOnlySenders — never by its fader, which its sends tap).
        return soloActive && !soloAudible.contains(item.id) && !wetZone.contains(item.id)
    }

    /// `isSilenced` without the solo's FILTERING: the silence an explicit mute (the object's own or its
    /// stem's) imposes, as the direct solo leaves it. What gates a send of the wet zone at an ancestor:
    /// a group above it that is merely filtered out by the solo sits DOWNSTREAM of the tap and cuts
    /// nothing of what is sent, whereas its MUTE does (Q-U1).
    func isSilencedByMute(_ item: SoundObject) -> Bool {
        if soloRoots.contains(item.id) || soloRootAncestors.contains(item.id) { return false }
        return isMutedInMix(item)
    }
}
