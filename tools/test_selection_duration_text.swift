// The length read in the selection info band — `SelectionDurationText`
// (`Shared/SelectionDurationText.swift`), pure formatting, asserted with no screen.
//
//     swiftc -parse-as-library \
//         ../objekat/Shared/SelectionDurationText.swift test_selection_duration_text.swift \
//         -o /tmp/sdt && /tmp/sdt
//
// Exit: 0 if every assertion passes, 1 otherwise.

import Foundation

var fails: [String] = []
var total = 0

func check(_ d: Double, _ expected: String) {
    total += 1
    let got = SelectionDurationText.string(d, minutes: { "\($0) mn" })
    if got == expected { print("ok    \(d) -> \(got)") }
    else { fails.append("\(d)"); print("FAIL  \(d) -> \(got)  (expected \(expected))") }
}

@main
enum SelectionDurationTextTest {
  static func main() {
    // Below the second: whole milliseconds only.
    check(0.5,       "500ms")
    check(0.0504,    "50ms")
    check(0.001,     "1ms")
    check(0.0004,    "0ms")
    check(0,         "0ms")
    check(-1,        "0ms")
    check(.nan,      "0ms")
    // Seconds + milliseconds, never a decimal.
    check(24.5,      "24s 500ms")
    check(24.05,     "24s 050ms")
    check(24,        "24s")
    check(1,         "1s")
    check(1.0004,    "1s")
    check(0.9996,    "1s")          // rounds up across the second, never "1000ms"
    check(59.9996,   "1 mn 00s")    // ... and across the minute, never "59s 1000ms"
    // Minutes: localised prefix + seconds on two digits.
    check(60,        "1 mn 00s")
    check(64.5,      "1 mn 04s 500ms")
    check(125.007,   "2 mn 05s 007ms")
    check(3600,      "60 mn 00s")

    print("\n\(total - fails.count)/\(total) passed")
    exit(fails.isEmpty ? 0 : 1)
  }
}
