// The gain-reduction reading of the expert bar, alone: which read-only parameter a plugin's bar
// starts on, and what its text is worth in dB (no engine, no model, no settings written).
//
//   swiftc -parse-as-library objekat/App/LaunchArguments.swift objekat/Shared/GainReductionReading.swift \
//          tools/test_gain_reduction_reading.swift -o /tmp/tgr && /tmp/tgr
import Foundation

@main
struct TestGainReductionReading {
    static var failures = 0, total = 0
    static func check(_ label: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        total += 1
        if ok { print("ok    " + label) } else { failures += 1; print("FAIL  " + label + "   " + detail()) }
    }

    static func main() {
        let d = GainReductionReading.defaultIndex
        // Real names, as AU / VST3 compressors and limiters publish them.
        check("Pro-C 2 style", d(["Input Level", "Output Level", "Gain Reduction"]) == 2)
        check("a bare GR", d(["Level", "GR"]) == 1)
        check("GR with a channel", d(["Out L", "GR L", "GR R"]) == 1)
        check("'gr' inside a word is not GR", d(["Grit", "Program", "Agro"]) == nil)
        check("G.R.", d(["Meter", "G.R."]) == 1)
        check("'Gain Reduction' beats a mere 'Reduction'", d(["Noise Reduction Amount", "Gain Reduction"]) == 1)
        check("a reduction when nothing says gain", d(["Input", "Reduction"]) == 1)
        check("an attenuation", d(["Input", "Attenuation Meter"]) == 1)
        check("comp + meter last", d(["Input", "Comp Meter"]) == 1)
        check("case and accents folded", d(["RÉDUCTION DE GAIN"]) == 0)
        check("'gainreduction' glued", d(["GainReduction"]) == 0)
        check("nothing qualifies", d(["Input Meter", "Output Meter"]) == nil)
        check("an empty list", d([]) == nil)
        check("first of a tier wins", d(["GR 1", "GR 2"]) == 0)

        let w = GainReductionReading.matchesWord
        check("word at start", w("gr", "gr meter"))
        check("word after a digit", w("gr", "1gr"))
        check("not inside a word", !w("gr", "agro"))
        check("second occurrence alone", w("gr", "grit gr"))

        let db = GainReductionReading.decibels(fromText:)
        check("-3.2 dB", db("-3.2 dB") == 3.2)
        check("3.2 (no unit)", db("3.2") == 3.2)
        check("typographic minus, decimal comma", db("\u{2212}4,5 dB") == 4.5)
        check("a leading label", db("GR: -6.0 dB") == 6.0)
        check("+0.0", db("+0.0") == 0.0)
        check("no number", db("off") == nil)
        check("-inf", db("-inf") == nil)
        check("an integer", db("12 dB") == 12)
        check("a magnitude, never negative", (db("-0.5") ?? -1) >= 0)

        print("\n\(total - failures)/\(total) OK")
        exit(failures == 0 ? 0 : 1)
    }
}
