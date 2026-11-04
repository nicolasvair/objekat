// MidiSequenceWindow — the shared MIDI sequence of a recording through a loop, asserted with no screen and no
// engine. Pinned down: a take's notes are the notes of the sequence that BEGIN in its window, rebased (a note
// that began before, or begins after, is not in it); the window edges (inclusive start, exclusive end); a resolve
// after an edge moved reveals / hides notes and is reversible; the notes' ids are deterministic and never shared
// by two takes; the signature ignores ids and sees any other change (so a rebuilt clip degrades to a classic one);
// a cut gives the right half the window from `offset + split` on and the left half only when no note was
// shortened; the reference round-trips through JSON WITHOUT its signature.
//
// `MidiNote` is stood in for here (the real one lives in SoundObject.swift, which drags the model along): same
// fields, same initialiser, Codable.
//
//     swiftc -parse-as-library ../objekat/SoundObject/MidiSequenceWindow.swift test_midi_sequence_window.swift \
//         -o /tmp/tmsw && /tmp/tmsw
//
// Exit: 0 if every assertion passes, 1 otherwise.

import Foundation

struct MidiNote: Identifiable, Codable, Equatable {
    var id = UUID()
    var pitch: Int
    var startBeat: Double
    var lengthBeats: Double
    var velocity: Int = 100
    init(id: UUID = UUID(), pitch: Int, startBeat: Double, lengthBeats: Double, velocity: Int = 100) {
        self.id = id; self.pitch = pitch; self.startBeat = startBeat
        self.lengthBeats = lengthBeats; self.velocity = velocity
    }
}

var fails: [String] = []
var total = 0

func check(_ name: String, _ ok: Bool) {
    total += 1
    if !ok { fails.append(name); print("FAIL  \(name)") }
}

func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }

typealias W = MidiSequenceWindow

func note(_ pitch: Int, _ s: Double, _ l: Double = 0.5, _ v: Int = 100) -> MidiNote {
    MidiNote(pitch: pitch, startBeat: s, lengthBeats: l, velocity: v)
}

/// The cut as the view model makes it (EditViewModel.splitMidiNotes), reproduced.
func splitNotes(_ notes: [MidiNote], at b: Double) -> (left: [MidiNote], right: [MidiNote]) {
    var l: [MidiNote] = [], r: [MidiNote] = []
    for n in notes {
        if n.startBeat < b {
            var ln = n
            ln.lengthBeats = min(n.lengthBeats, max(0.01, b - n.startBeat))
            l.append(ln)
        } else {
            r.append(MidiNote(pitch: n.pitch, startBeat: n.startBeat - b, lengthBeats: n.lengthBeats, velocity: n.velocity))
        }
    }
    return (l, r)
}


@main
struct Main {
    static func main() {
        // A sequence of 8 notes, one per beat from 0 to 7, ascending pitch.
        let seqNotes = (0..<8).map { note(60 + $0, Double($0)) }
        let seq = MidiSequence(id: UUID(), notes: seqNotes)
        let clipA = UUID(), clipB = UUID()

        // MARK: the window

        do {
            let w = W.notes(of: seqNotes, offsetBeats: 2, lengthBeats: 3, clipID: clipA)
            check("window [2,5): three notes", w.count == 3)
            check("window [2,5): pitches 62 63 64", w.map(\.pitch) == [62, 63, 64])
            check("window [2,5): rebased on the clip (0, 1, 2)", w.map(\.startBeat) == [0, 1, 2])
            check("window keeps length and velocity", near(w[0].lengthBeats, 0.5) && w[0].velocity == 100)
        }
        do {
            let all = W.notes(of: seqNotes, offsetBeats: 0, lengthBeats: 100, clipID: clipA)
            check("a window over everything gives every note", all.count == 8)
            check("an empty window gives nothing", W.notes(of: seqNotes, offsetBeats: 2, lengthBeats: 0, clipID: clipA).isEmpty)
            check("a window beyond the sequence gives nothing", W.notes(of: seqNotes, offsetBeats: 50, lengthBeats: 4, clipID: clipA).isEmpty)
        }
        do {
            // The start is inclusive, the end exclusive: two adjacent windows PARTITION the sequence.
            let a = W.notes(of: seqNotes, offsetBeats: 0, lengthBeats: 3, clipID: clipA)
            let b = W.notes(of: seqNotes, offsetBeats: 3, lengthBeats: 5, clipID: clipB)
            check("adjacent windows partition: 3 + 5 = 8", a.count == 3 && b.count == 5)
            check("the boundary note (beat 3) goes to the later window", b.first?.pitch == 63 && !a.contains { $0.pitch == 63 })
        }
        do {
            // A note that began before the window and rings into it is NOT in it.
            let held = [note(60, 0.5, 4), note(61, 2.0)]
            let w = W.notes(of: held, offsetBeats: 1, lengthBeats: 3, clipID: clipA)
            check("a note begun before the window is not in it", w.map(\.pitch) == [61])
            // A note that begins in the window keeps its whole length, past the window's end.
            let tail = [note(60, 2.5, 10)]
            let t = W.notes(of: tail, offsetBeats: 0, lengthBeats: 3, clipID: clipA)
            check("a note begun in the window keeps its length past the end", t.count == 1 && near(t[0].lengthBeats, 10))
            // The tolerance: a note a hair before the start is in, never negative.
            let hair = [note(60, 1.0 - 1e-12)]
            let h = W.notes(of: hair, offsetBeats: 1, lengthBeats: 1, clipID: clipA)
            check("a hair before the start is in, clamped to 0", h.count == 1 && h[0].startBeat == 0)
        }
        do {
            // Order: by start then pitch, whatever the sequence's order.
            let messy = [note(64, 1), note(60, 1), note(62, 0)]
            let w = W.notes(of: messy, offsetBeats: 0, lengthBeats: 5, clipID: clipA)
            check("ordered by start then pitch", w.map(\.pitch) == [62, 60, 64])
        }

        // MARK: ids

        do {
            let a1 = W.notes(of: seqNotes, offsetBeats: 0, lengthBeats: 8, clipID: clipA)
            let a2 = W.notes(of: seqNotes, offsetBeats: 0, lengthBeats: 8, clipID: clipA)
            let b1 = W.notes(of: seqNotes, offsetBeats: 0, lengthBeats: 8, clipID: clipB)
            check("ids are deterministic for one clip", a1.map(\.id) == a2.map(\.id))
            check("ids differ between two clips of one sequence", Set(a1.map(\.id)).isDisjoint(with: Set(b1.map(\.id))))
            check("ids are unique inside one clip", Set(a1.map(\.id)).count == 8)
            check("a note's id does not depend on the window", {
                let narrow = W.notes(of: seqNotes, offsetBeats: 4, lengthBeats: 1, clipID: clipA)
                return narrow.first?.id == a1[4].id
            }())
        }

        // MARK: signature

        do {
            let n = W.notes(of: seqNotes, offsetBeats: 0, lengthBeats: 8, clipID: clipA)
            let renewed = n.map { MidiNote(pitch: $0.pitch, startBeat: $0.startBeat, lengthBeats: $0.lengthBeats, velocity: $0.velocity) }
            check("the signature ignores ids", W.signature(n) == W.signature(renewed))
            check("the signature is stable", W.signature(n) == W.signature(n))
            var moved = n; moved[3].startBeat += 0.25
            var longer = n; longer[3].lengthBeats += 0.25
            var louder = n; louder[3].velocity = 90
            var other = n; other[3].pitch += 1
            check("a moved note changes the signature", W.signature(moved) != W.signature(n))
            check("a lengthened note changes the signature", W.signature(longer) != W.signature(n))
            check("a velocity change changes the signature", W.signature(louder) != W.signature(n))
            check("a pitch change changes the signature", W.signature(other) != W.signature(n))
            check("a missing note changes the signature", W.signature(Array(n.dropLast())) != W.signature(n))
            check("an added note changes the signature", W.signature(n + [note(30, 20)]) != W.signature(n))
            check("empty differs from non-empty", W.signature([]) != W.signature(n))
            check("order matters", W.signature(n.reversed()) != W.signature(n))
        }

        // MARK: resolve on an edge move

        do {
            // A take over [2,5): offset 2, three notes.
            let notes0 = W.notes(of: seqNotes, offsetBeats: 2, lengthBeats: 3, clipID: clipA)
            let ref0 = MidiSequenceRef(id: seq.id, offsetBeats: 2).signed(notes0)
            check("a fresh ref matches what it resolved to", ref0.matches(notes0))

            // The END edge pulled out by 2 beats (no shift of the start): notes 5 and 6 appear.
            let out = W.resolved(ref: ref0, current: notes0, sequence: seq, shiftedByBeats: 0, lengthBeats: 5, clipID: clipA)
            check("pulling the end out reveals the notes behind it", out?.notes.map(\.pitch) == [62, 63, 64, 65, 66])
            check("the offset is unchanged by an end move", near(out?.ref.offsetBeats ?? -1, 2))
            check("the new ref matches the new notes", out.map { $0.ref.matches($0.notes) } == true)

            // ... and pushed back: they are hidden again, the take is what it was (ids included).
            let back = W.resolved(ref: out!.ref, current: out!.notes, sequence: seq, shiftedByBeats: 0, lengthBeats: 3, clipID: clipA)
            check("pushing the end back hides them again (reversible)", back?.notes == notes0)

            // The START edge pulled in by 1 beat: the start moves to 3, the window shrinks to [3,5).
            let inn = W.resolved(ref: ref0, current: notes0, sequence: seq, shiftedByBeats: 1, lengthBeats: 2, clipID: clipA)
            check("pulling the start in: offset 3", near(inn?.ref.offsetBeats ?? -1, 3))
            check("pulling the start in: notes 63, 64 rebased on 0", inn?.notes.map(\.pitch) == [63, 64] && inn?.notes.map(\.startBeat) == [0, 1])

            // The START edge pulled OUT by 2 beats (negative shift): the window grows to the left to [0,5).
            let left = W.resolved(ref: ref0, current: notes0, sequence: seq, shiftedByBeats: -2, lengthBeats: 5, clipID: clipA)
            check("pulling the start out reveals the notes before it", left?.notes.map(\.pitch) == [60, 61, 62, 63, 64])
            check("pulling the start out: offset 0, rebased", near(left?.ref.offsetBeats ?? -1, 0) && left?.notes.map(\.startBeat) == [0, 1, 2, 3, 4])

            // An edited clip no longer resolves (nil = a classic clip).
            var edited = notes0; edited[0].pitch += 12
            check("an edited clip does not resolve", W.resolved(ref: ref0, current: edited, sequence: seq, shiftedByBeats: 0, lengthBeats: 5, clipID: clipA) == nil)
            check("a missing sequence does not resolve", W.resolved(ref: ref0, current: notes0, sequence: nil, shiftedByBeats: 0, lengthBeats: 5, clipID: clipA) == nil)
            let stranger = MidiSequence(id: UUID(), notes: seqNotes)
            check("another sequence does not resolve", W.resolved(ref: ref0, current: notes0, sequence: stranger, shiftedByBeats: 0, lengthBeats: 5, clipID: clipA) == nil)
        }

        // MARK: cut

        do {
            // Take over [2,6): notes 62..65 (length 0.5 each), cut at 2 beats (no note straddles).
            let notes0 = W.notes(of: seqNotes, offsetBeats: 2, lengthBeats: 4, clipID: clipA)
            let ref0 = MidiSequenceRef(id: seq.id, offsetBeats: 2).signed(notes0)
            let (l, r) = splitNotes(notes0, at: 2)
            let refs = W.split(ref: ref0, original: notes0, left: l, right: r, atBeat: 2)
            check("cut, nothing straddling: both halves keep a reference", refs.left != nil && refs.right != nil)
            check("cut: the left half keeps the offset", near(refs.left?.offsetBeats ?? -1, 2))
            check("cut: the right half looks from offset + split", near(refs.right?.offsetBeats ?? -1, 4))
            check("cut: each ref matches the notes its half holds", refs.left?.matches(l) == true && refs.right?.matches(r) == true)
            // The right half resolves, afterwards, to what it holds (pulling its end out reveals the following notes).
            let rr = W.resolved(ref: refs.right!, current: r, sequence: seq, shiftedByBeats: 0, lengthBeats: 4, clipID: clipB)
            check("cut: the right half resolves to its own notes and the ones after", rr?.notes.map(\.pitch) == [64, 65, 66, 67])
            // ... and the left half can be pulled out to the right: it reveals what the cut hid.
            let lr = W.resolved(ref: refs.left!, current: l, sequence: seq, shiftedByBeats: 0, lengthBeats: 4, clipID: clipA)
            check("cut: the left half can reveal what the cut hid", lr?.notes.map(\.pitch) == [62, 63, 64, 65])
        }
        do {
            // A long note straddles the cut: the left half's note is shortened -> the left half detaches, the right stays.
            let held = MidiSequence(id: UUID(), notes: [note(60, 0, 3), note(62, 2), note(64, 3)])
            let notes0 = W.notes(of: held.notes, offsetBeats: 0, lengthBeats: 4, clipID: clipA)
            let ref0 = MidiSequenceRef(id: held.id, offsetBeats: 0).signed(notes0)
            let (l, r) = splitNotes(notes0, at: 2.5)
            let refs = W.split(ref: ref0, original: notes0, left: l, right: r, atBeat: 2.5)
            check("cut through a note: the left half detaches", refs.left == nil)
            check("cut through a note: the right half keeps its reference", refs.right != nil && near(refs.right!.offsetBeats, 2.5))
            check("cut through a note: the straddler is not in the right half", !r.contains { $0.pitch == 60 })
        }
        do {
            // A stale ref gives nothing.
            let notes0 = W.notes(of: seqNotes, offsetBeats: 2, lengthBeats: 4, clipID: clipA)
            let ref0 = MidiSequenceRef(id: seq.id, offsetBeats: 2).signed(notes0)
            var edited = notes0; edited.removeFirst()
            let (l, r) = splitNotes(edited, at: 2)
            let refs = W.split(ref: ref0, original: edited, left: l, right: r, atBeat: 2)
            check("cut of an edited clip: no reference on either half", refs.left == nil && refs.right == nil)
        }

        // MARK: coding

        do {
            let ref = MidiSequenceRef(id: seq.id, offsetBeats: 3.25).signed(seqNotes)
            let data = try! JSONEncoder().encode(ref)
            let text = String(data: data, encoding: .utf8)!
            check("the signature is not written", !text.contains("signature"))
            check("id and offsetBeats are written", text.contains("offsetBeats") && text.contains(seq.id.uuidString))
            let back = try! JSONDecoder().decode(MidiSequenceRef.self, from: data)
            check("decoded: same id and offset", back.id == ref.id && near(back.offsetBeats, 3.25))
            check("decoded: the signature is unset until the owner re-signs", back.signature == 0)
            check("re-signed from the notes it holds, it matches again", back.signed(seqNotes).matches(seqNotes))

            let sdata = try! JSONEncoder().encode(seq)
            let sback = try! JSONDecoder().decode(MidiSequence.self, from: sdata)
            check("a sequence round-trips", sback == seq)
            // A resolved clip survives a JSON round trip of its notes: the signature is exact (doubles are exact).
            let notes0 = W.notes(of: seqNotes, offsetBeats: 1.1, lengthBeats: 3.3, clipID: clipA)
            let nd = try! JSONEncoder().encode(notes0)
            let nb = try! JSONDecoder().decode([MidiNote].self, from: nd)
            check("the signature survives a JSON round trip of the notes", W.signature(nb) == W.signature(notes0))
        }

        print(fails.isEmpty ? "ALL PASS (\(total))" : "\(fails.count) FAILED of \(total)")
        exit(fails.isEmpty ? 0 : 1)

    }
}
