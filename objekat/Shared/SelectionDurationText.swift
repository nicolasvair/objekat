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
//   < 1 s         → `500ms`            (whole milliseconds, unpadded)
//   1 s ..< 60 s  → `24s 500ms`        (ms padded to 3 digits so the band does not jitter;
//                   `24s` when ms == 0)
//   ≥ 60 s        → `1 mn 04s 500ms`   (same minute logic as before: localised prefix + seconds
//                   on 2 digits; `1 mn 04s` when ms == 0)
//
// Rounding is done ONCE on the total in milliseconds before splitting, so the band can never
// read `59s 1000ms` or `1 mn 60s`.
enum SelectionDurationText {
    /// `minutes` formats the minute count with its localised unit (`"%d mn"` in French).
    static func string(_ d: Double, minutes: (Int) -> String) -> String {
        guard d.isFinite, d > 0 else { return "0ms" }
        let totalMs = Int((d * 1000).rounded())
        let ms = totalMs % 1000
        let totalS = totalMs / 1000
        if totalS == 0 { return "\(ms)ms" }
        let msPart = ms == 0 ? "" : " " + String(format: "%03dms", ms)
        if totalS < 60 { return "\(totalS)s" + msPart }
        return minutes(totalS / 60) + " " + String(format: "%02ds", totalS % 60) + msPart
    }
}
