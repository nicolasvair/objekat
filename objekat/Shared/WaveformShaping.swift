import Foundation

// Tools that shape the waveform at RENDER time (never in the `.wfc` cache, which stays
// the source's RAW peaks). Applied by TimelineWaveformView (clips) and GroupWaveformView
// (groups, nested ones included).
enum WaveformShaping {

    /// Linear gain from dB. -96 dB (or less) = silence (0).
    static func linearGain(dB: Float) -> Double {
        dB <= -96 ? 0 : pow(10.0, Double(dB) / 20.0)
    }

    /// Fade envelope (0…1) at a local time `t` (s) inside an object of length `dur`.
    /// fadeIn: 0→1 over [0, fi]; fadeOut: 1→0 over [dur-fo, dur].
    static func fadeEnvelope(localTime t: Double, duration dur: Double,
                             fadeIn fi: Double, fadeOut fo: Double) -> Double {
        var g = 1.0
        if fi > 0, t < fi            { g *= max(0, min(1, t / fi)) }
        if fo > 0, t > dur - fo      { g *= max(0, min(1, (dur - t) / fo)) }
        return max(0, g)
    }

    /// Source time (s) for a local timeline time (s), with speed and reverse.
    /// reverse: the source is read from the end of the clip's range.
    static func sourceTime(localTime t: Double, sourceOffset: Double, duration: Double,
                           speedRatio: Double, isReversed: Bool) -> Double {
        let mapped = isReversed ? (duration - t) : t
        return sourceOffset + mapped * speedRatio
    }

    /// The new source offset of a clip whose WINDOW changes (trimming, resizing, cutting) and
    /// whose CONTENT must not move: what you hear at a given timeline instant stays the same
    /// material.
    ///
    /// `sourceOffset` always names the START of the source range, in seconds of the original
    /// file. Played forwards, that range is anchored on the LEFT edge of the window: moving that
    /// edge by δ advances the range by δ×speed, moving the right edge leaves it alone. In reverse
    /// the playback runs back up the range (@see sourceTime): the RIGHT edge is what governs.
    /// So the two edges swap roles — without that mirror, trimming the head of a reversed clip
    /// made its content slide under the window instead of leaving it in place.
    static func retrimmedSourceOffset(_ sourceOffset: Double,
                                      oldStart: Double, oldDuration: Double,
                                      newStart: Double, newDuration: Double,
                                      speedRatio: Double, isReversed: Bool) -> Double {
        let delta = isReversed
            ? (oldStart + oldDuration) - (newStart + newDuration)   // RIGHT edge
            : newStart - oldStart                                   // LEFT edge
        return max(0, sourceOffset + delta * speedRatio)
    }

    /// An object's amplitude modifier (gain × fade), in ABSOLUTE timeline time. Composes as a
    /// chain for nested groups (a product).
    /// MUTE is NOT here: it is handled at render time (greying out on the block itself, leaving
    /// it out as a group's descendant).
    struct Modifier {
        let absStart: Double
        let duration: Double
        let fadeIn: Double
        let fadeOut: Double
        let gain: Double       // = linearGain(volume), precomputed

        func multiplier(atAbsTime t: Double) -> Double {
            gain * fadeEnvelope(localTime: t - absStart, duration: duration,
                                fadeIn: fadeIn, fadeOut: fadeOut)
        }
    }

    /// The product of a chain's multipliers (clip + ancestor groups).
    static func combinedMultiplier(_ mods: [Modifier], atAbsTime t: Double) -> Double {
        var m = 1.0
        for mod in mods {
            m *= mod.multiplier(atAbsTime: t)
            if m == 0 { break }
        }
        return m
    }
}
