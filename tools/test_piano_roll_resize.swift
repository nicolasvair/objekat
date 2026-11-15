// Resizing SEVERAL selected notes of a piano roll (`Timeline/PianoRollResize.swift`), asserted with no
// screen.
//
//     swiftc -parse-as-library ../objekat/Timeline/PianoRollResize.swift test_piano_roll_resize.swift \
//         -o /tmp/pianorollresize && /tmp/pianorollresize
//
// Beats, numbers EXACT in binary (multiples of 1/8). Exit: 0 if every assertion passes, 1 otherwise.

import Foundation

var fails: [String] = []
var total = 0
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    total += 1
    if ok { print("ok    " + label) } else { fails.append(label); print("FAIL  \(label)  \(detail)") }
}
func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }

typealias R = PianoRollResize
typealias S = PianoRollResize.Span
let a = UUID(), b = UUID(), c = UUID()

func span(_ r: [UUID: S], _ id: UUID) -> String {
    guard let s = r[id] else { return "nil" }
    return "[\(s.start) +\(s.length)]"
}
func is_(_ r: [UUID: S], _ id: UUID, _ start: Double, _ len: Double) -> Bool {
    guard let s = r[id] else { return false }
    return near(s.start, start) && near(s.length, len)
}

@main struct Runner { static func main() {
    let three: [UUID: S] = [a: S(start: 1, length: 2), b: S(start: 4, length: 1), c: S(start: 6, length: 0.5)]

    // ── RIGHT edge ─────────────────────────────────────────────────────────────────────────
    let r0 = R.resizeEnd(three, grabbed: a, deltaBeats: 0, minLen: 0.25)
    check("end, delta 0: nothing changes", r0 == three)

    let r1 = R.resizeEnd(three, grabbed: a, deltaBeats: 1, minLen: 0.25)
    check("end +1 on 3 notes: grabbed 2 -> 3", is_(r1, a, 1, 3), span(r1, a))
    check("end +1: the second 1 -> 2", is_(r1, b, 4, 2), span(r1, b))
    check("end +1: the third 0.5 -> 1.5", is_(r1, c, 6, 1.5), span(r1, c))
    check("end: the starts never move", near(r1[a]!.start, 1) && near(r1[b]!.start, 4) && near(r1[c]!.start, 6))

    // shortening: each note stops at ITS OWN minimum
    let r2 = R.resizeEnd(three, grabbed: a, deltaBeats: -1.5, minLen: 0.25)
    check("end -1.5: the grabbed 2 -> 0.5", is_(r2, a, 1, 0.5), span(r2, a))
    check("end -1.5: the second 1 stops at the minimum 0.25", is_(r2, b, 4, 0.25), span(r2, b))
    check("end -1.5: the third (0.5) stops at the minimum 0.25", is_(r2, c, 6, 0.25), span(r2, c))
    let r3 = R.resizeEnd(three, grabbed: a, deltaBeats: -5, minLen: 0.25)
    check("end -5: the grabbed note stops at the minimum", is_(r3, a, 1, 0.25), span(r3, a))
    check("end -5: the others too, individually", is_(r3, b, 4, 0.25) && is_(r3, c, 6, 0.25))

    // a note SHORTER than the minimum is not inflated by a gesture that is not about it
    let short: [UUID: S] = [a: S(start: 0, length: 2), b: S(start: 3, length: 0.125)]
    let r4 = R.resizeEnd(short, grabbed: a, deltaBeats: -1, minLen: 0.25)
    check("a note shorter than the minimum is not grown (0.125 stays)", is_(r4, b, 3, 0.125), span(r4, b))
    check("... and the grabbed one shortens normally", is_(r4, a, 0, 1), span(r4, a))
    let r5 = R.resizeEnd(short, grabbed: a, deltaBeats: 1, minLen: 0.25)
    check("a short note grows with a positive delta like any other (0.125 -> 1.125)", is_(r5, b, 3, 1.125), span(r5, b))

    // one note = the former formula: max(minLen, o.len + delta)
    let one: [UUID: S] = [a: S(start: 2, length: 1)]
    check("1 note, end: the former formula (grows)", is_(R.resizeEnd(one, grabbed: a, deltaBeats: 0.5, minLen: 0.25), a, 2, 1.5))
    check("1 note, end: the former formula (minimum)", is_(R.resizeEnd(one, grabbed: a, deltaBeats: -3, minLen: 0.25), a, 2, 0.25))
    let tiny: [UUID: S] = [a: S(start: 2, length: 0.125)]
    check("1 note shorter than the minimum, grabbed: the former formula lifts it to the minimum",
          is_(R.resizeEnd(tiny, grabbed: a, deltaBeats: 0, minLen: 0.25), a, 2, 0.25))

    // ── LEFT edge ──────────────────────────────────────────────────────────────────────────
    let l0 = R.resizeStart(three, grabbed: a, deltaBeats: 0, minLen: 0.25)
    check("start, delta 0: nothing changes", l0 == three)

    let l1 = R.resizeStart(three, grabbed: a, deltaBeats: -0.5, minLen: 0.25)
    check("start -0.5: the grabbed 1 -> 0.5, end fixed (len 2.5)", is_(l1, a, 0.5, 2.5), span(l1, a))
    check("start -0.5: the second 4 -> 3.5, end fixed (len 1.5)", is_(l1, b, 3.5, 1.5), span(l1, b))
    check("start -0.5: the third 6 -> 5.5, end fixed (len 1)", is_(l1, c, 5.5, 1), span(l1, c))
    check("start: every END stays", near(l1[a]!.end, 3) && near(l1[b]!.end, 5) && near(l1[c]!.end, 6.5))

    // never below 0
    let l2 = R.resizeStart(three, grabbed: a, deltaBeats: -3, minLen: 0.25)
    check("start -3: the grabbed stops at 0 (end 3 fixed)", is_(l2, a, 0, 3), span(l2, a))
    check("start -3: the second goes to 1 (4 - 3), still above 0", is_(l2, b, 1, 4), span(l2, b))
    check("start -3: the third goes to 3", is_(l2, c, 3, 3.5), span(l2, c))
    let l3 = R.resizeStart(three, grabbed: a, deltaBeats: -6, minLen: 0.25)
    check("start -6: the grabbed stops at 0", is_(l3, a, 0, 3), span(l3, a))
    check("start -6: the second stops at 0 too (the floor is per note)", is_(l3, b, 0, 5), span(l3, b))
    check("start -6: the third reaches 0 exactly", is_(l3, c, 0, 6.5), span(l3, c))

    // shortening from the left: the end is the wall, each at its own minimum
    let l4 = R.resizeStart(three, grabbed: a, deltaBeats: 1.5, minLen: 0.25)
    check("start +1.5: the grabbed 1 -> 2.5 (len 0.5)", is_(l4, a, 2.5, 0.5), span(l4, a))
    check("start +1.5: the second (len 1) stops at end - 0.25 = 4.75", is_(l4, b, 4.75, 0.25), span(l4, b))
    check("start +1.5: the third (len 0.5) stops at end - 0.25 = 6.25", is_(l4, c, 6.25, 0.25), span(l4, c))
    let l5 = R.resizeStart(short, grabbed: a, deltaBeats: 5, minLen: 0.25)
    check("a note shorter than the minimum is not moved past its own start by a shortening",
          is_(l5, b, 3.0, 0.125), span(l5, b))
    check("... and the grabbed one stops at end - minimum", is_(l5, a, 1.75, 0.25), span(l5, a))

    // a note that starts BEFORE 0 (masked by a left trim) is not pulled onto 0
    let neg: [UUID: S] = [a: S(start: 2, length: 2), b: S(start: -1, length: 3)]
    let n1 = R.resizeStart(neg, grabbed: a, deltaBeats: -3, minLen: 0.25)
    check("negative note, start -3: NOT moved (its own start is its floor)", is_(n1, b, -1, 3), span(n1, b))
    check("... the grabbed stops at 0", is_(n1, a, 0, 4), span(n1, a))
    let n2 = R.resizeStart(neg, grabbed: a, deltaBeats: 1, minLen: 0.25)
    check("negative note, start +1: it follows to 0 (-1 + 1), end fixed", is_(n2, b, 0, 2), span(n2, b))

    // one note = the former formula
    let o = R.resizeStart(one, grabbed: a, deltaBeats: -5, minLen: 0.25)
    check("1 note, start: the former formula (floor 0, end 3 fixed)", is_(o, a, 0, 3), span(o, a))
    let o2 = R.resizeStart(one, grabbed: a, deltaBeats: 9, minLen: 0.25)
    check("1 note, start: the former formula (minimum length)", is_(o2, a, 2.75, 0.25), span(o2, a))

    print("\n\(total - fails.count)/\(total) ok")
    exit(fails.isEmpty ? 0 : 1)
} }
