import Foundation

// MARK: - The name of a recorded file — the pure rules
//
// `Name 2026-10-29 04-12-33.wav` in `samples/rec/`: the input's name, then the instant the recording
// began (to the second, with dashes so the name is legal on every volume). One file per input and per
// take; two inputs that carry the same name, or a file already there, take " (2)", " (3)"… before the
// extension. The input's name is a free text the hand typed, so what a file name cannot hold ("/" and
// ":" first of all, and control characters) is replaced, and a name that comes out empty falls back on
// "Input".
//
// A plain Foundation unit, compiled and asserted alone (tools/test_record_file_naming.swift).

enum RecordFileNaming {

    static let fileExtension = "wav"
    static let fallbackName = "Input"

    /// The input's name made safe for a file name.
    static func sanitized(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/:\\").union(.controlCharacters).union(.newlines)
        var out = name.unicodeScalars.map { bad.contains($0) ? "-" : String($0) }.joined()
        out = out.trimmingCharacters(in: .whitespaces)
        while out.hasPrefix(".") { out.removeFirst() }
        return out.isEmpty ? fallbackName : out
    }

    /// `2026-10-29 04-12-33`, in the given zone (the machine's by default), whatever the locale.
    static func stamp(_ date: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return f.string(from: date)
    }

    /// The file name (with its extension) for an input recorded at `date`. `taken` says whether a name is
    /// already spoken for — by another input of the same take, or by a file on the disk.
    static func name(inputName: String, date: Date, timeZone: TimeZone = .current,
                     taken: (String) -> Bool) -> String {
        let base = sanitized(inputName) + " " + stamp(date, timeZone: timeZone)
        var candidate = base + "." + fileExtension
        var n = 2
        while taken(candidate) {
            candidate = base + " (\(n))." + fileExtension
            n += 1
        }
        return candidate
    }
}
