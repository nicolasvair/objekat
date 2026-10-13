import Foundation

// Standalone test of the folded 'audio file' zone's pills (docs/plan_synoptic_rework.md §B.7): how a hidden,
// non-neutral setting is written on the folded row.
//
//     swiftc -parse-as-library -o /tmp/t_pills \
//         ../objekat/Shared/TempoText.swift \
//         ../objekat/Inspector/Synoptic/SynopticZonePills.swift test_synoptic_zone_pills.swift \
//         && /tmp/t_pills

var failures = 0
var total = 0
func check(_ ok: Bool, _ what: String) {
    total += 1
    if !ok { failures += 1; print("FAIL: \(what)") }
}
func eq(_ got: String, _ want: String, _ what: String) {
    total += 1
    if got != want { failures += 1; print("FAIL: \(what): got \"\(got)\", wanted \"\(want)\"") }
}
func semis(_ ratio: Double) -> Double { 12 * log2(ratio) }

@main
struct Main {
    static func main() {
        // A whole number of semitones reads as semitones, with a true minus.
        for st in [-12.0, -7.0, -3.0, -1.0, 1.0, 2.0, 5.0, 12.0] {
            let ratio = pow(2.0, st / 12)
            let want = (st < 0 ? "\u{2212}" : "+") + "\(Int(abs(st))) st"
            eq(SynopticZonePills.pitchText(semitones: semis(ratio), ratio: ratio), want, "\(st) st")
        }
        // Within the tolerance of a whole semitone still counts (a hand-dragged -3 st is never exact).
        let near = pow(2.0, -3.04 / 12)
        eq(SynopticZonePills.pitchText(semitones: semis(near), ratio: near), "\u{2212}3 st", "-3.04 st is -3 st")
        let farther = pow(2.0, -3.2 / 12)
        eq(SynopticZonePills.pitchText(semitones: semis(farther), ratio: farther),
           "\u{00D7}" + String(format: "%.2f", farther), "-3.2 st is a ratio")

        // Anything else is a ratio.
        eq(SynopticZonePills.pitchText(semitones: semis(1.07), ratio: 1.07), "\u{00D7}1.07", "x1.07")
        eq(SynopticZonePills.pitchText(semitones: semis(0.5), ratio: 0.5), "\u{2212}12 st", "half speed is -12 st")
        eq(SynopticZonePills.pitchText(semitones: semis(1.4), ratio: 1.4), "\u{00D7}1.40", "x1.40")
        eq(SynopticZonePills.pitchText(semitones: semis(1.5), ratio: 1.5), "+7 st", "x1.5 is +7.02 st, so +7 st")

        // A speed that is not 1 but would round to 1.00 gets a third decimal; and a speed that is only
        // within the tolerance of ZERO semitones is never "+0 st".
        let tiny = 1.0003
        eq(SynopticZonePills.pitchText(semitones: semis(tiny), ratio: tiny), "\u{00D7}1.000", "x1.000")
        let wobble = 1.01
        eq(SynopticZonePills.pitchText(semitones: semis(wobble), ratio: wobble), "\u{00D7}1.01", "x1.01, not +0 st")
        check(!SynopticZonePills.pitchText(semitones: semis(1.001), ratio: 1.001).contains("+0"), "never +0 st")
        check(!SynopticZonePills.pitchText(semitones: semis(0.999), ratio: 0.999).contains("0 st"), "never -0 st")

        // The tempo.
        eq(SynopticZonePills.tempoText(targetBPM: 120), "\u{2192} 120", "-> 120")
        eq(SynopticZonePills.tempoText(targetBPM: 127.02), "\u{2192} 127.02", "-> 127.02")
        eq(SynopticZonePills.tempoText(targetBPM: 119.99999999), "\u{2192} 120", "rounded onto 120")
        eq(SynopticZonePills.tempoText(targetBPM: 90.12345678), "\u{2192} 90.1235", "four decimals at most")

        eq(SynopticZonePills.ratioText(1.07), "1.070", "ratio quoted with three decimals")

        print("\(total - failures)/\(total) assertions passed")
        exit(failures == 0 ? 0 : 1)
    }
}
