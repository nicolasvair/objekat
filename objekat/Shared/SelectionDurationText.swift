import Foundation

// The length shown by the selection info band (time selection, or the span of the selected
// objects) — pure formatting, no model, no `L()`: the one localised word (the minute) is passed
// in already formatted, so the whole thing compiles and is asserted alone:
//
//     swiftc -parse-as-library ../objekat/Shared/SelectionDurationText.swift \
//         test_selection_duration_text.swift -o /tmp/sdt && /tmp/sdt
//
// The format reads as two whole units, never a decimal: `24s 500ms`, not `24,5s`. `s` and `ms`
// are SI symbols, identical in every language; only the minute word is localised.
//
//   < 100 ms      → `5,3 ms`           (ONE decimal with a comma, always shown: `1,0 ms`,
//                   `47,2 ms`; the one place a decimal is read, because a whole ms hides what a
//                   cut at the sample level does)
//   100 ms ..< 1 s → `500ms`           (whole milliseconds, unpadded)
//   1 s ..< 60 s  → `24s 500ms`        (ms padded to 3 digits so the band does not jitter;
//                   `24s` when ms == 0)
//   ≥ 60 s        → `1 mn 04s 500ms`   (same minute logic as before: localised prefix + seconds
//                   on 2 digits; `1 mn 04s` when ms == 0)
//
// Rounding is done ONCE on the total in milliseconds before splitting, so the band can never
// read `59s 1000ms` or `1 mn 60s`. Under 100 ms the rounding is to the tenth of a millisecond;
// a value that rounds UP to 100,0 ms leaves the decimal branch and reads `100ms` (99.96 ms →
// `100ms`, never `100,0 ms`).
enum SelectionDurationText {
    /// `minutes` formats the minute count with its localised unit (`"%d mn"` in French).
    static func string(_ d: Double, minutes: (Int) -> String) -> String {
        guard d.isFinite, d > 0 else { return "0ms" }
        // Under 100 ms: one decimal, comma, always shown. Decided on the rounded tenth so that
        // 99.96 ms (→ 100,0) takes the whole-millisecond path below and reads `100ms`.
        let tenthsOfMs = Int((d * 10_000).rounded())
        if tenthsOfMs < 1000 {
            return "\(tenthsOfMs / 10),\(tenthsOfMs % 10) ms"
        }
        let totalMs = Int((d * 1000).rounded())
        let ms = totalMs % 1000
        let totalS = totalMs / 1000
        if totalS == 0 { return "\(ms)ms" }
        let msPart = ms == 0 ? "" : " " + String(format: "%03dms", ms)
        if totalS < 60 { return "\(totalS)s" + msPart }
        return minutes(totalS / 60) + " " + String(format: "%02ds", totalS % 60) + msPart
    }
}
