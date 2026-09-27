import Foundation

// The audio device line shown in the window's title bar and answered by `audio.status` — pure
// formatting, no model, no `L()` (the localised words are passed in as parameters). It is the
// half of the feature with nothing behind it, hence compilable and assertable alone:
//
//     swiftc -parse-as-library ../objekat/Shared/AudioStatusText.swift \
//         test_audio_status_text.swift -o /tmp/ast && /tmp/ast
//
// The separator ` — ` is a glyph, like the em dash AppKit itself draws between a window's title
// and its subtitle — it needs no translation.
enum AudioStatusText {
    /// A sample rate in kHz, compact: `44100` → `"44.1k"`, `48000` → `"48k"`, `22050` →
    /// `"22.05k"`. Up to two decimals, trailing zeros dropped, the decimal point ALWAYS `.`
    /// (POSIX — `String(format:)` with no locale — never the user's own, since this is a unit,
    /// like `"dB"`, and not prose). `0`, a negative value or NaN answer `""`: there is nothing to
    /// show, and an empty string is what `line(...)` below already knows to omit.
    static func shortRate(_ hz: Double) -> String {
        guard hz.isFinite, hz > 0 else { return "" }
        let k = hz / 1000
        var s = String(format: "%.2f", k)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s + "k"
    }

    /// The whole line: `"MOTU M2 — 48k — 512"`. `name == nil` answers `none` exactly (no
    /// dashes trailing it — there is nothing after "no device" to separate). A rate of 0 or a
    /// buffer of 0 is OMITTED rather than printed as `"0"` (the two traps `audioDeviceSnapshot`
    /// already closes: `--no-audio`, a device open but not playing — but a caller reading a
    /// half-formed snapshot some other way must not show a lie either). `running == false`
    /// appends `" — \(stopped)"` at the very end. A device name that itself contains `" — "` is
    /// kept verbatim — it is data, not a delimiter we invented.
    static func line(name: String?, sampleRate: Double, bufferSize: Int,
                      running: Bool, none: String, stopped: String) -> String {
        guard let name, !name.isEmpty else { return none }
        var parts = [name]
        let rate = shortRate(sampleRate)
        if !rate.isEmpty { parts.append(rate) }
        if bufferSize > 0 { parts.append("\(bufferSize)") }
        if !running { parts.append(stopped) }
        return parts.joined(separator: " — ")
    }
}
