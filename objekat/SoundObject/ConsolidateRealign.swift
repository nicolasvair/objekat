import Foundation

// RE-ALIGNING an instance onto a new wave.
//
// When the content of a consolidated object changes — its root was trimmed, moved, extended, a child
// was added — the wave every instance reads is a different file, possibly of a different length and
// with its position 0 at another instant of the content. Each instance keeps showing the SAME material
// where it was (the user arranged them against the sound, not against file offsets), so its source
// offset moves with the content, and its window is brought back inside what the new wave holds.
//
// The one rule, for every instance (the edited one, built from its stage, and all the others):
//
//     δ  = the instant of the new wave's position 0, minus the old one's (edit time)
//     so' = so − δ                                   the material stays opposite the same place
//     the window never GROWS (Q1 of the plan): it is only cut where the wave has no more material —
//     at the head when so' < 0 (the start moves later by as much, in timeline seconds), at the tail
//     when the range runs past the end. A reversed instance plays its range backwards, so the two
//     ends swap their roles.
//     the fades are bounded by the new length (their sum never exceeds it); the instance's automation
//     and markers, relative to its start, follow it when the start moves.
//
// A window left with NO material at all (Q2) keeps its place, its length and its fades, and reads
// silence: its source offset is the end of the wave, and `isOutsideConsolidateContent` says so.
//
// Pure model code, unit-tested on its own: @see tools/test_consolidate_realign.swift

extension SoundObject {

    /// `inst` (a closed instance: a `.clip`) re-aimed at the wave `wavePath` of length `waveLength`,
    /// whose position 0 is `delta` seconds LATER (edit time) than the position 0 of the wave `inst`
    /// was aligned on. Anything that is not a clip comes back unchanged.
    func realignedInstance(delta: Double, wavePath: String, waveLength: Double) -> SoundObject {
        guard case .clip(_, let so, _, let spd0, let rev) = kind else { return self }
        let spd = max(spd0, 0.0001)
        let eps = 1e-6

        // The range of wave the window reads, against the NEW wave.
        let r0 = so - delta
        let r1 = r0 + duration * spd
        var lowCut  = max(0, -r0)                       // wave seconds below position 0
        var highCut = max(0, r1 - waveLength)           // wave seconds past the end
        if lowCut < eps { lowCut = 0 }
        if highCut < eps { highCut = 0 }
        // Forwards, the low end of the range is the head of the window; reversed, its tail.
        let headCut = (rev ? highCut : lowCut) / spd
        let tailCut = (rev ? lowCut : highCut) / spd
        let newDuration = duration - headCut - tailCut

        var o = self
        if newDuration <= eps {
            // Q2: nothing of the content is left under this window. Place and length stay; the
            // window reads past the end of the wave.
            o.kind = .clip(filePath: wavePath, sourceOffset: waveLength, fileDuration: waveLength,
                           speedRatio: spd0, isReversed: rev)
            return o
        }

        o.kind = .clip(filePath: wavePath, sourceOffset: max(0, r0), fileDuration: waveLength,
                       speedRatio: spd0, isReversed: rev)
        o.startTime = startTime + headCut
        o.duration  = newDuration
        // Fades: bounded, in order — the head one first. The sum never exceeds the window.
        o.fadeIn  = min(fadeIn, newDuration)
        o.fadeOut = min(fadeOut, max(0, newDuration - o.fadeIn))
        // What is relative to the start follows it when the start moves later.
        if headCut != 0 {
            o.automation = automation.shiftedInTime(by: -headCut)
            o.markers    = markers.shiftedInTime(by: -headCut)
            o.loopRangeStart = loopRangeStart.map { $0 - headCut }
            o.loopRangeEnd   = loopRangeEnd.map   { $0 - headCut }
        }
        return o
    }
}
