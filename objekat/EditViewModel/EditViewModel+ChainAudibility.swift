import Foundation

// MARK: - Greying an object whose chain's mutes cut its whole sound, read cheaply
//
// The rule lives in `ChainAudibility` (pure); this is only where the drawing reads it and how it is
// kept cheap: ONE memo, `chainSilencedIDs`, dropped by every write to `items` (the same `didSet` as
// the other derived caches) and rebuilt on the next read by ONE walk of the project — objects with no
// plugin are skipped at once. Never per block, never per frame: between two model changes every reader
// pays a set lookup. The `Canvas` takes the whole set as a VALUE once per pass (its nested drawing
// functions are not MainActor-isolated).
//
// Two things the memo depends on besides `items`: the FX links switched off (`offFXLinkIDs`, read at
// every access — an observed read, so a bin's on/off redraws the readers, and compared with the one
// the memo was built for), and nothing else: a stage's mute is the model's mirror of the live instance
// (@see mirrorGainStageValues), a branch's mute is `rack.voiceMutes`, both inside `items`.
//
// This is a DISPLAY rule only. It is not part of `AudibilitySnapshot` on purpose: that one also drives
// the engine (-96 dB on the fader, the sends' gates), and a mute of the signal view already cuts the
// sound by itself — pushing a second silence on the fader would also silence the sends, which the
// signal view's mutes do not (@see ChainAudibility).
extension EditViewModel {

    /// The ids of the objects (at any depth) whose chain's mutes cut ALL the paths to the output.
    var chainSilencedIDs: Set<UUID> {
        let offBins = offFXLinkIDs
        if let c = chainSilencedCache, c.offBins == offBins { return c.ids }
        var ids: Set<UUID> = []
        func walk(_ objects: [SoundObject]) {
            for o in objects {
                if o.isSilencedByChain(offBins: offBins) { ids.insert(o.id) }
                if case .group(let children, _) = o.kind { walk(children) }
            }
        }
        walk(items)
        chainSilencedCache = (offBins, ids)
        return ids
    }

    /// True if `item` shows as muted in the timeline: a mute that is its own or its stem's (not lifted
    /// by a direct solo — @see isMutedInMix), OR a chain whose mutes cut every path to the output. The
    /// second part is not lifted by a solo: a solo opens the object's fader, not the signal view's mutes.
    /// For the drawing only; what the engine hears is `isSilenced`.
    func isShownMuted(_ item: SoundObject) -> Bool {
        audibility.isMutedInMix(item) || chainSilencedIDs.contains(item.id)
    }
}
