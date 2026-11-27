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
    // Below 100 ms: one decimal with a comma, always shown.
    check(0.0053,    "5,3 ms")
    check(0.001,     "1,0 ms")
    check(0.0004,    "0,4 ms")
    check(0.00004,   "0,0 ms")
    check(0.0099,    "9,9 ms")
    check(0.00996,   "10,0 ms")     // 10 ms is no boundary any more: the decimal goes on to 100 ms
    check(0.00995,   "10,0 ms")
    check(0.00994,   "9,9 ms")
    check(0.01,      "10,0 ms")
    check(0.0104,    "10,4 ms")
    check(0.0472,    "47,2 ms")
    check(0.0504,    "50,4 ms")
    check(0.0999,    "99,9 ms")
    check(0.09994,   "99,9 ms")
    check(0.09996,   "100 ms")       // rounds up to 100,0 -> whole-millisecond path, never "100,0 ms"
    // From 100 ms up to the second: whole milliseconds only (unchanged).
    check(0.1,       "100 ms")
    check(0.1004,    "100 ms")
    check(0.5,       "500 ms")
    check(0,         "0 ms")
    check(-1,        "0 ms")
    check(.nan,      "0 ms")
    // Seconds + milliseconds, never a decimal.
    check(24.5,      "24s 500 ms")
    check(24.05,     "24s 050 ms")
    check(24,        "24s")
    check(1,         "1s")
    check(1.0004,    "1s")
    check(0.9996,    "1s")          // rounds up across the second, never "1000 ms"
    check(59.9996,   "1 mn 00s")    // ... and across the minute, never "59s 1000 ms"
    // Minutes: localised prefix + seconds on two digits.
    check(60,        "1 mn 00s")
    check(64.5,      "1 mn 04s 500 ms")
    check(125.007,   "2 mn 05s 007 ms")
    check(3600,      "60 mn 00s")

    print("\n\(total - fails.count)/\(total) passed")
    exit(fails.isEmpty ? 0 : 1)
  }
}
