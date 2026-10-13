import Foundation

// MARK: - The pills of the folded 'audio file' zone (docs/plan_synoptic_rework.md §B.7), pure
//
// The folded zone hides the clip's options (speed, semitones, tempo, channels). When one of them is not
// neutral a pill says so on the folded row: `−3 st`, `×1.07`, `→ 120`, `L`. This file only FORMATS what
// `SynopticAudioFile.hiddenNonNeutralSettings` decides; it knows no view, so it can be compiled and
// asserted alone (tools/test_synoptic_zone_pills.swift).

enum SynopticZonePills {
    /// The semitone figure is shown (rather than the ratio) when the speed is within this of a whole,
    /// non-zero number of semitones: a deliberate transposition reads as `+2 st`, not as `×1.12`.
    static let wholeSemitoneTolerance = 0.05

    /// A speed change as a pill: `−3 st` when it is (nearly) a whole number of semitones, else `×1.07`.
    /// The ratio gets a third decimal when two would round it back onto `×1.00`.
    static func pitchText(semitones: Double, ratio: Double) -> String {
        let r = semitones.rounded()
        if r != 0, abs(semitones - r) < wholeSemitoneTolerance {
            let sign = r < 0 ? "\u{2212}" : "+"      // a true minus, like the pill's neighbours
            return "\(sign)\(Int(abs(r))) st"
        }
        let decimals = abs(ratio - 1) < 0.005 ? 3 : 2
        return "\u{00D7}" + String(format: "%.\(decimals)f", ratio)
    }

    /// A stretch to a tempo as a pill: `→ 120` (up to four decimals, only when needed, like the tempo box).
    static func tempoText(targetBPM: Double) -> String {
        "\u{2192} " + TempoText.display(TempoText.rounded(targetBPM))
    }

    /// The ratio as the tooltips quote it.
    static func ratioText(_ ratio: Double) -> String { String(format: "%.3f", ratio) }
}
