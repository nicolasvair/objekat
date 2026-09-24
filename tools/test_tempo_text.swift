// Decimal BPM — the arithmetic behind it, asserted with no screen. `TempoText`
// (`objekat/Shared/TempoText.swift`) has no model behind it at all, which is why it can be
// compiled and run alone, exactly like `CutSelection` / `SendColumns` before it.
//
//     swiftc -parse-as-library \
//         ../objekat/Shared/TempoText.swift test_tempo_text.swift \
//         -o /tmp/tempotext && /tmp/tempotext
//
// Exit: 0 if every assertion passes, 1 otherwise.

import Foundation

var fails: [String] = []
var total = 0

func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    total += 1
    if ok { print("ok    " + label) }
    else { fails.append(label); print("FAIL  \(label)  \(detail)") }
}

@main
enum TempoTextTest {
  static func main() {

    // MARK: - display

    check("display: whole number", TempoText.display(127) == "127", TempoText.display(127))
    check("display: two decimals kept, trailing zero dropped",
          TempoText.display(127.020) == "127.02", TempoText.display(127.020))
    check("display: rounds to 4 decimals",
          TempoText.display(127.12345) == "127.1235", TempoText.display(127.12345))
    check("display: dot separator always",
          !TempoText.display(127.5).contains(","), TempoText.display(127.5))

    // MARK: - parse

    check("parse: comma separator", TempoText.parse("127,5") == 127.5)
    check("parse: trailing dot", TempoText.parse("127.") == 127)
    check("parse: leading comma", TempoText.parse(",5") == 0.5)
    check("parse: letters rejected", TempoText.parse("abc") == nil)
    check("parse: scientific notation rejected", TempoText.parse("1e2") == nil)
    check("parse: surrounding whitespace trimmed", TempoText.parse(" 127 ") == 127)
    check("parse: empty string rejected", TempoText.parse("") == nil)
    check("parse: double separator rejected", TempoText.parse("12.3.4") == nil)
    check("parse: plain dot separator", TempoText.parse("120.5") == 120.5)

    // MARK: - rounded

    let bumped = TempoText.rounded(127.02 + 0.1)
    check("rounded: 127.02 + 0.1 == 127.12", bumped == 127.12, "\(bumped)")

    // MARK: - Summary

    print("\n\(total - fails.count)/\(total) passed")
    if !fails.isEmpty {
        print("FAILURES:")
        for f in fails { print(" - \(f)") }
        exit(1)
    }
    exit(0)
  }
}
