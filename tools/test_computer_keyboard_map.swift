// ComputerKeyboardMap — the table and the routing decision of the « Computer Keyboard » MIDI input, asserted
// with no screen and no engine. Pinned down: the 17 note keys by PHYSICAL keyCode, base 60 = "C4", the
// octave range 0…108, ⌘⌃⌥⇧ turning the capture off for a key (caps lock / fn do not), a repeat swallowed,
// a key already down not re-triggered, the note-off read from the table filled at the press (an octave
// change in between does not hang a note), keys outside the table untouched.
//
//     swiftc -parse-as-library ../objekat/Shared/ComputerKeyboardMap.swift test_computer_keyboard_map.swift \
//         -o /tmp/tckm && /tmp/tckm
//
// Exit: 0 if every assertion passes, 1 otherwise.

import AppKit

var fails: [String] = []
var total = 0

func check(_ name: String, _ ok: Bool) {
    total += 1
    if !ok { fails.append(name); print("FAIL  \(name)") }
}

typealias M = ComputerKeyboardMap

func route(_ code: UInt16, _ flags: NSEvent.ModifierFlags = [], repeat r: Bool = false, on: Bool = true,
           held: [UInt16: Int] = [:], octave: Int = 60) -> M.Decision {
    M.route(keyCode: code, flags: flags, isRepeat: r, modeOn: on, held: held, octave: octave)
}

@main
struct Runner {
    static func main() {
        // MARK: The table

        // key, keyCode, offset — the plan's mapping, one by one.
        let table: [(String, UInt16, Int)] = [
            ("q", 0, 0), ("z", 13, 1), ("s", 1, 2), ("e", 14, 3), ("d", 2, 4), ("f", 3, 5), ("t", 17, 6),
            ("g", 5, 7), ("y", 16, 8), ("h", 4, 9), ("u", 32, 10), ("j", 38, 11), ("k", 40, 12),
            ("o", 31, 13), ("l", 37, 14), ("p", 35, 15), ("m", 41, 16),
        ]
        check("17 note keys", M.noteOffsets.count == 17)
        for (name, code, offset) in table {
            check("\(name) (\(code)) -> +\(offset) -> \(60 + offset)", route(code) == .noteOn(keyCode: code, note: 60 + offset))
        }
        check("the offsets are 0…16, each once", Set(M.noteOffsets.values) == Set(0...16))

        // MARK: Octaves

        check("start = 60", M.defaultOctave == 60)
        check("60 is named C4 (as the piano roll)", M.octaveName(60) == "C4")
        check("0 is C-1", M.octaveName(0) == "C-1")
        check("108 is C8", M.octaveName(108) == "C8")
        check("x goes up an octave", route(7) == .octave(72))
        check("w goes down an octave", route(6) == .octave(48))
        check("x at 108 is swallowed (limit)", route(7, octave: 108) == .swallow)
        check("w at 0 is swallowed (limit)", route(6, octave: 0) == .swallow)
        check("w at 12 reaches 0", route(6, octave: 12) == .octave(0))
        check("x at 96 reaches 108", route(7, octave: 96) == .octave(108))
        check("the notes follow the octave", route(0, octave: 36) == .noteOn(keyCode: 0, note: 36))
        check("the highest key at the highest base stays a MIDI note", route(41, octave: 108) == .noteOn(keyCode: 41, note: 124))
        check("every key of every octave is 0…127",
              stride(from: 0, through: 108, by: 12).allSatisfy { base in
                  M.noteOffsets.keys.allSatisfy { code in
                      if case .noteOn(_, let n) = route(code, octave: base) { return (0...127).contains(n) }
                      return false
                  }
              })
        check("a repeat of w / x is swallowed", route(6, repeat: true) == .swallow && route(7, repeat: true) == .swallow)

        // MARK: When it is NOT ours

        check("mode off: a note key passes", route(0, on: false) == .passThrough)
        check("mode off: w passes", route(6, on: false) == .passThrough)
        for (name, flag) in [("⌘", NSEvent.ModifierFlags.command), ("⌃", .control), ("⌥", .option), ("⇧", .shift)] {
            check("\(name) held: a note key passes", route(0, [flag]) == .passThrough)
            check("\(name) held: x passes", route(7, [flag]) == .passThrough)
        }
        check("⌘⇧ held: passes", route(1, [.command, .shift]) == .passThrough)
        check("caps lock is not a modifier", route(0, [.capsLock]) == .noteOn(keyCode: 0, note: 60))
        check("fn / numeric pad stamp is not a modifier", route(0, [.function, .numericPad]) == .noteOn(keyCode: 0, note: 60))
        // The keys the plan leaves alone: ù (39), a (12), r (15), i (34), c (8), v (9), space, return, arrows.
        for code: UInt16 in [39, 12, 15, 34, 8, 9, 49, 36, 123, 126, 51, 53] {
            check("keyCode \(code) is not ours", route(code) == .passThrough)
        }
        check("the digit row is not ours", [18, 19, 20, 21, 23, 22, 26, 28, 25, 29].allSatisfy { route($0) == .passThrough })

        // MARK: Repeat and re-press

        check("a repeat is swallowed", route(0, repeat: true) == .swallow)
        check("a repeat with the note held is swallowed", route(0, repeat: true, held: [0: 60]) == .swallow)
        check("a key already down is not re-triggered", route(0, held: [0: 60]) == .swallow)
        check("another key while one is down plays", route(2, held: [0: 60]) == .noteOn(keyCode: 2, note: 64))

        // MARK: Release

        check("release reads the table", M.noteToRelease(keyCode: 0, held: [0: 60]) == 60)
        check("release of a key not down is nil", M.noteToRelease(keyCode: 0, held: [2: 64]) == nil)
        // The whole scenario of the table: press q at 60, go up an octave, release q — the NOTE-OFF is 60, not 72.
        var held: [UInt16: Int] = [:]
        var octave = 60
        if case .noteOn(let code, let note) = route(0, held: held, octave: octave) { held[code] = note }
        if case .octave(let next) = route(7, held: held, octave: octave) { octave = next }
        check("octave moved while q is down", octave == 72)
        check("q released after the octave change turns off 60", M.noteToRelease(keyCode: 0, held: held) == 60)
        check("a press after the change plays at 72", route(0, held: [:], octave: octave) == .noteOn(keyCode: 0, note: 72))

        print(fails.isEmpty ? "ALL PASS (\(total))" : "\(fails.count) FAILED of \(total)")
        exit(fails.isEmpty ? 0 : 1)
    }
}
