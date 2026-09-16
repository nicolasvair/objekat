// Where a piano roll opens — asserted with no screen.
//
// `PianoRollFraming` depends on nothing at all, which is the whole reason it is a unit of its own:
// it is the half of the roll's opening that has no model and no layout behind it. Two things are
// being held to at once, and they pull against each other — FRAME THE NOTES (a roll that opens on
// an empty stretch of keyboard looks empty, and one then hunts for one's own material with
// oct +/-) and START ON A C (a bottom row on G♯2 puts the octave labels where no octave begins).
// The second wins, and what the assertions below pin down is the price: which of the two C's
// framing the ideal window is taken, and what happens at the two ends of the keyboard.
//
//     swiftc -parse-as-library \
//         ../objekat/Timeline/PianoRollFraming.swift test_piano_roll_framing.swift \
//         -o /tmp/pianoframing && /tmp/pianoframing
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
enum PianoRollFramingTest {
  static func main() {

    // MARK: - Snapping onto a C

    check("a C stays where it is", pianoRollBaseOnC(48, rows: 24) == 48)
    check("anything else comes DOWN to the C under it",
          pianoRollBaseOnC(55, rows: 24) == 48, "\(pianoRollBaseOnC(55, rows: 24))")
    check("one semitone under a C falls a whole octave",
          pianoRollBaseOnC(47, rows: 24) == 36, "\(pianoRollBaseOnC(47, rows: 24))")
    check("the floor is C-1 and not a negative pitch",
          pianoRollBaseOnC(-30, rows: 24) == 0, "\(pianoRollBaseOnC(-30, rows: 24))")

    // The ceiling is the point of `rows`, and it rounds UPWARDS: 127 - 23 = 104 is a G♯, and the
    // C above it (108) is the last window that still reaches the top of the keyboard. Taking the
    // C BELOW instead (96) looks tidier and puts the last eight semitones out of reach for ever.
    check("the ceiling is itself a C", pianoRollBaseOnC(127, rows: 24) == 108,
          "\(pianoRollBaseOnC(127, rows: 24))")
    check("and the ceiling still reaches 127", 108 + 24 - 1 >= 127)
    check("it follows the window's height", pianoRollBaseOnC(127, rows: 12) == 120,
          "\(pianoRollBaseOnC(127, rows: 12))")
    check("and never goes past the last C there is",
          pianoRollBaseOnC(127, rows: 2) == 120, "\(pianoRollBaseOnC(127, rows: 2))")
    check("a window taller than the keyboard still starts at 0",
          pianoRollBaseOnC(60, rows: 200) == 0, "\(pianoRollBaseOnC(60, rows: 200))")

    // MARK: - Framing the notes

    check("no note at all leaves the fallback alone",
          pianoRollAutoBase(pitches: [], rows: 24, fallback: 48) == 48)

    // A handful of notes around C5. Centring alone would give (72+79)/2 - 11 = 64 (E4); the two
    // C's framing that are 60 and 72, and 60 shows every note where 72 cuts the lowest off.
    let chord = [72, 74, 76, 79]
    check("the notes are framed, and the bottom row is a C",
          pianoRollAutoBase(pitches: chord, rows: 24, fallback: 48) == 60,
          "\(pianoRollAutoBase(pitches: chord, rows: 24, fallback: 48))")
    check("every note of it is inside the window",
          chord.allSatisfy { $0 >= 60 && $0 <= 60 + 23 })

    // THE REASON THE CHOICE IS MADE BY COUNTING. Here the lower C would cut the top of the chord
    // off: rows = 12, ideal centring 70, the two C's are 60 (shows nothing above 71) and 72.
    let high = [72, 74, 76, 79]
    check("the C that shows MORE of the notes wins",
          pianoRollAutoBase(pitches: high, rows: 12, fallback: 48) == 72,
          "\(pianoRollAutoBase(pitches: high, rows: 12, fallback: 48))")

    // A span TALLER than the window is read from the bass — and from a C. The lowest note is 25,
    // so the window one would want starts at 24 (C1), which is already a C.
    let spread = [25, 40, 55, 70, 85, 100]
    let wide = pianoRollAutoBase(pitches: spread, rows: 24, fallback: 48)
    check("a span taller than the window starts on a C", wide % 12 == 0, "\(wide)")
    check("and it is read upwards from the bass", wide == 24, "\(wide)")

    // The complaint this whole thing answers: a roll written two octaves up used to open on C3 and
    // look EMPTY. Whatever else it does, the framing must show something.
    let twoUp = [84, 86, 88]
    let base = pianoRollAutoBase(pitches: twoUp, rows: 24, fallback: 48)
    check("a roll written high does not open on an empty keyboard",
          twoUp.contains { $0 >= base && $0 <= base + 23 }, "\(base)")
    check("and it is still a C", base % 12 == 0, "\(base)")

    // Notes at the very top: the ceiling has the last word, and it is a C.
    let top = [120, 124, 127]
    let ceil24 = pianoRollAutoBase(pitches: top, rows: 24, fallback: 48)
    check("against the ceiling the window is a C", ceil24 % 12 == 0, "\(ceil24)")
    // It is ALLOWED to sit against the end of the keyboard — what the drawing does with the rows
    // that fall past 127 is clamp them away (@see PianoRollView.normalRowPitches). Reaching the
    // last notes is worth a short window; losing the C is not.
    check("it may sit against the end of the keyboard", ceil24 + 23 >= 127, "\(ceil24)")
    check("and the drawing still has rows to show", min(127, ceil24 + 23) - ceil24 + 1 >= 12,
          "\(min(127, ceil24 + 23) - ceil24 + 1)")
    check("with the notes still inside it",
          top.allSatisfy { $0 >= ceil24 && $0 <= ceil24 + 23 }, "\(ceil24)")

    // A single note, alone: it has to be visible, and the reference kept.
    for p in [0, 1, 11, 12, 60, 61, 100, 127] {
        let b = pianoRollAutoBase(pitches: [p], rows: 24, fallback: 48)
        check("a lone note at \(p) is visible, on a C",
              b % 12 == 0 && p >= b && p <= b + 23, "base \(b)")
    }

    // And oct +/- keeps the reference, since it adds a whole octave to something already on a C.
    var walk = pianoRollAutoBase(pitches: [60], rows: 24, fallback: 48)
    for _ in 0..<12 { walk = pianoRollBaseOnC(walk + 12, rows: 24) }
    check("twelve presses of oct + land on a C all the same", walk % 12 == 0, "\(walk)")
    check("and stop at the ceiling rather than past it", walk == 108, "\(walk)")

    print(fails.isEmpty ? "\nALL PASS (\(total))"
                        : "\n\(fails.count) FAILURE(S) of \(total): \(fails.joined(separator: ", "))")
    exit(fails.isEmpty ? 0 : 1)
  }
}
