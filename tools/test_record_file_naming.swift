// The name of a recorded file — `RecordFileNaming`, asserted with no screen and no engine (Foundation
// only). Pinned down: `Name AAAA-MM-JJ HH-MM-SS.wav`, the characters a file name cannot hold, the empty
// name, and the " (2)" suffix when a name is taken (two inputs with the same name, or a file already there).
//
//     swiftc -parse-as-library \
//         ../objekat/SoundObject/RecordFileNaming.swift test_record_file_naming.swift \
//         -o /tmp/trfn && /tmp/trfn
//
// Exit: 0 if every assertion passes, 1 otherwise.

import Foundation

var fails: [String] = []
var total = 0

func check(_ name: String, _ ok: Bool) {
    total += 1
    if !ok { fails.append(name); print("FAIL  \(name)") }
}

typealias N = RecordFileNaming

@main
enum Run {
    static func main() {
        let utc = TimeZone(identifier: "UTC")!
        let paris = TimeZone(identifier: "Europe/Paris")!
        var comps = DateComponents()
        comps.year = 2026; comps.month = 10; comps.day = 29; comps.hour = 4; comps.minute = 12; comps.second = 33
        comps.timeZone = utc
        let date = Calendar(identifier: .gregorian).date(from: comps)!

        check("stamp: dashes, no colon", N.stamp(date, timeZone: utc) == "2026-10-29 04-12-33")
        check("stamp: the time zone given", N.stamp(date, timeZone: paris) == "2026-10-29 05-12-33")
        check("name: input, stamp, wav",
              N.name(inputName: "Mic 1", date: date, timeZone: utc, taken: { _ in false }) == "Mic 1 2026-10-29 04-12-33.wav")
        check("name: a taken name gets (2)",
              N.name(inputName: "Mic 1", date: date, timeZone: utc,
                     taken: { $0 == "Mic 1 2026-10-29 04-12-33.wav" }) == "Mic 1 2026-10-29 04-12-33 (2).wav")
        check("name: (2) taken too, then (3)",
              N.name(inputName: "Mic 1", date: date, timeZone: utc,
                     taken: { $0.hasSuffix("33.wav") || $0.hasSuffix("(2).wav") }) == "Mic 1 2026-10-29 04-12-33 (3).wav")
        var used = Set<String>()
        var names: [String] = []
        for _ in 0..<3 {
            let n = N.name(inputName: "Guitar", date: date, timeZone: utc, taken: { used.contains($0) })
            used.insert(n); names.append(n)
        }
        check("three inputs, one name: three distinct files", Set(names).count == 3)

        check("sanitize: slash and colon", N.sanitized("a/b:c") == "a-b-c")
        check("sanitize: backslash", N.sanitized("a\\b") == "a-b")
        check("sanitize: control characters", N.sanitized("a\nb\tc") == "a-b-c")
        check("sanitize: edges trimmed", N.sanitized("  Voice  ") == "Voice")
        check("sanitize: no hidden file", N.sanitized("..secret") == "secret")
        check("sanitize: empty falls back", N.sanitized("") == N.fallbackName && N.sanitized("   ") == N.fallbackName)
        check("sanitize: accents and symbols are kept", N.sanitized("Voix été 1+2") == "Voix été 1+2")
        check("name: an empty input name", N.name(inputName: "", date: date, timeZone: utc, taken: { _ in false })
              == "Input 2026-10-29 04-12-33.wav")

        print(fails.isEmpty ? "ALL PASS (\(total))" : "\(fails.count) FAILED of \(total)")
        exit(fails.isEmpty ? 0 : 1)
    }
}
