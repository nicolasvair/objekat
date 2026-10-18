import Foundation

// MARK: - Does the object's sound reach the output? (the mutes of the signal view, pure)
//
// The signal view carries mutes of its own: a gain stage's (the "gain · pan · mute" face) and a
// parallel block's per-BRANCH mute. An object whose sound is cut by them is silent, and the timeline
// greys it exactly as it greys an object muted from its own button (@see EditViewModel.chainSilencedIDs).
//
// The rule, over the object's chain seen as a graph of SERIES and PARALLEL blocks:
//
//  - in SERIES a mute cuts: the sound goes through every element in turn, so one cut element cuts the
//    series — several mutes simply accumulate (a series is cut as soon as ONE element is);
//  - in PARALLEL a block is cut only when EVERY branch is cut — a branch being cut when its own mute
//    is on, or when the series it holds is cut (so the rule is recursive for nested blocks). One audible
//    branch is enough for the sound to reach the output through the sum;
//  - the object is "silent through its chain" iff the root series is cut, i.e. iff EVERY path from the
//    source to the output is cut by at least one mute.
//
// What does NOT cut, on purpose (the most conservative reading: an object is never greyed on a doubt):
//  - an EMPTY branch (the "gain only" path of a parallel block) lets the sound through, and so does a
//    parallel block with no branch at all;
//  - a mute that is not heard: a gain stage whose own `isEnabled` is off, or any stage inside an FX
//    link's block whose common on/off is off (the block is bypassed, the sound goes through it —
//    @see GainStageDisplay, which makes the same two calls for the drawn gain);
//  - a branch pulled to −96 dB without its mute, a fader at −96 dB: not a mute (the object's own mute
//    and its stem's are the existing rule, `AudibilitySnapshot.isMutedInMix`, which this one comes on
//    top of — the two are a disjunction);
//  - an automated mute (a curve on the stage's mute parameter): the model holds the static value, as
//    the drawn waveform does for the gain;
//  - the SENDS (post-fader or not) and the mini-chains hung on them: a send leads to an aux, not to the
//    object's own output. An object whose chain is cut but which still feeds an aux is greyed all the
//    same (@see the open question in the branch's report).
//
// The mute of a stage is the model's STORED value (`gainStageStoredValues`), kept in step with the live
// instance by every write of the hand or the API (@see EditViewModel.mirrorGainStageValues).
//
// This file is compiled alone (with the model) by `tools/test_chain_audibility.swift`.
enum ChainAudibility {

    /// True when no sound gets through `chain`: every path from its input to its output goes through a
    /// mute. `offBins`: the ids of the ATTACHED FX links whose common on/off is off
    /// (@see EditViewModel.offFXLinkIDs). An empty chain is not cut.
    static func isCut(_ chain: [ObjectPlugin], offBins: Set<UUID>) -> Bool {
        // In series, one cut element is enough. (`contains` stops at the first one.)
        chain.contains { entryCuts($0, offBins: offBins) }
    }

    /// Does this single entry of a series cut the sound?
    private static func entryCuts(_ p: ObjectPlugin, offBins: Set<UUID>) -> Bool {
        // A send's marker is the PLACE a send taps the trunk: the sound goes through it.
        if p.isSendMarker { return false }

        // A parallel block: cut only if every branch is — an unmuted branch holding no cut series lets
        // the sound reach the sum. A block with no branch is not a cut.
        if let rack = p.rack {
            guard !rack.voices.isEmpty else { return false }
            let mutes = rack.voiceMutes ?? []
            for (i, voice) in rack.voices.enumerated() {
                let muted = i < mutes.count && mutes[i]
                if !muted && !isCut(voice, offBins: offBins) { return false }
            }
            return true
        }

        // A bin's block: a series of the bin's instances — unless the bin is switched off, in which case
        // the block is bypassed (the bin's common on/off while attached, the block's own while detached).
        if let fb = p.fxBlock {
            let on = fb.isDetached ? (fb.local?.isEnabled ?? true) : !offBins.contains(fb.linkID)
            return on && isCut(fb.plugins, offBins: offBins)
        }

        // A leaf: only a gain stage that is heard and switched to mute cuts. Any other plugin passes
        // the sound (what it does to the level cannot be known without rendering).
        guard p.isEnabled, let values = p.gainStageStoredValues else { return false }
        return values.muted
    }
}

extension SoundObject {
    /// True when the signal view's mutes cut ALL the paths of this object's own chain to its output
    /// (@see ChainAudibility). The object's own mute and its stem's are not part of it.
    func isSilencedByChain(offBins: Set<UUID>) -> Bool {
        // The vast majority of objects have no plugin at all: nothing to walk.
        !plugins.isEmpty && ChainAudibility.isCut(plugins, offBins: offBins)
    }
}
