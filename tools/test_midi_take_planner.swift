// MidiTakePlanner — what a MIDI recording becomes in a zone, asserted with no screen and no engine.
// Pinned down: seconds -> beats relative to the take (at the tempo), a note before the take = a negative start
// (a HANDLE), ordering, no note = no take, the sustain pedal folded into the durations (not past the next
// attack of the same pitch, not past the capture), velocities clamped, invalid notes dropped.
//
// `MidiNote` is stood in for here (the real one lives in SoundObject.swift, which drags the model along): same
// fields, same initialiser.
//
//     swiftc -parse-as-library ../objekat/SoundObject/MidiTakePlanner.swift test_midi_take_planner.swift \
//         -o /tmp/tmtp && /tmp/tmtp
//
// Exit: 0 if every assertion passes, 1 otherwise.

import Foundation

struct MidiNote: Equatable {
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

func near(_ a: Double, _ b: Double, _ tol: Double = 1e-9) -> Bool { abs(a - b) < tol }

typealias P = MidiTakePlanner
func raw(_ pitch: Int, _ s: Double, _ e: Double, _ v: Int = 100) -> P.RawNote { .init(pitch: pitch, start: s, end: e, velocity: v) }

@main
struct Main {
    static func main() {
        // MARK: Seconds -> beats

        let a = P.notes([raw(60, 10.5, 11.0, 90)], takeStart: 10, captureEnd: 20, bpm: 120)
        check("one note comes out", a?.count == 1)
        check("0.5 s after the take at 120 BPM = 1 beat", near(a![0].startBeat, 1.0))
        check("0.5 s long at 120 BPM = 1 beat", near(a![0].lengthBeats, 1.0))
        check("pitch and velocity are kept", a![0].pitch == 60 && a![0].velocity == 90)
        let b = P.notes([raw(60, 10.5, 11.0)], takeStart: 10, captureEnd: 20, bpm: 60)
        check("at 60 BPM a second is a beat", near(b![0].startBeat, 0.5) && near(b![0].lengthBeats, 0.5))
        let c = P.notes([raw(60, 10.5, 11.0)], takeStart: 10, captureEnd: 20, bpm: 90)
        check("at 90 BPM", near(c![0].startBeat, 0.75))

        // MARK: A handle: the note begins before the take

        let h = P.notes([raw(64, 9.0, 9.5), raw(65, 10.0, 10.5)], takeStart: 10, captureEnd: 20, bpm: 120)
        check("a note before the take is KEPT, with a negative start (a handle)",
              h?.count == 2 && near(h![0].startBeat, -2.0) && h![0].pitch == 64)
        check("... and the one at the take's start is at 0", near(h![1].startBeat, 0))

        // MARK: Order

        let o = P.notes([raw(72, 11, 11.2), raw(60, 10, 10.2), raw(67, 10, 10.2)], takeStart: 10, captureEnd: 20, bpm: 120)
        check("ordered by start, then pitch", o!.map(\.pitch) == [60, 67, 72])

        // MARK: Nothing

        check("no note: no take", P.notes([], takeStart: 0, captureEnd: 5, bpm: 120) == nil)
        check("only invalid notes (pitch 200, end before start): no take",
              P.notes([raw(200, 0, 1), raw(60, 2, 1)], takeStart: 0, captureEnd: 5, bpm: 120) == nil)
        check("a null tempo gives no take rather than a division", P.notes([raw(60, 0, 1)], takeStart: 0, captureEnd: 5, bpm: 0) == nil)
        let v = P.notes([raw(60, 0, 1, 0), raw(61, 1, 2, 300)], takeStart: 0, captureEnd: 5, bpm: 120)
        check("velocity is clamped to 1...127", v![0].velocity == 1 && v![1].velocity == 127)
        let z = P.notes([raw(60, 1, 1)], takeStart: 0, captureEnd: 5, bpm: 120)
        check("a zero-length note gets a minimal length, not zero", z![0].lengthBeats > 0)

        // MARK: Sustain pedal

        let pedal = [P.Pedal(time: 0.5, down: true), P.Pedal(time: 3.0, down: false)]
        let s1 = P.notes([raw(60, 1.0, 1.5)], pedal: pedal, takeStart: 0, captureEnd: 10, bpm: 120)
        check("pedal down at the release: the note lasts until the pedal comes up (1.0 -> 3.0 = 4 beats)",
              near(s1![0].lengthBeats, 4.0))
        let s2 = P.notes([raw(60, 1.0, 1.5), raw(60, 2.0, 2.2)], pedal: pedal, takeStart: 0, captureEnd: 10, bpm: 120)
        check("... but never past the next attack of the same pitch (1.0 -> 2.0 = 2 beats)", near(s2![0].lengthBeats, 2.0))
        check("... the second one (released at 2.2, pedal down) lasts until 3.0 (2.0 -> 3.0 = 2 beats)", near(s2![1].lengthBeats, 2.0))
        let s3 = P.notes([raw(60, 1.0, 1.5), raw(62, 1.0, 1.5)], pedal: pedal, takeStart: 0, captureEnd: 10, bpm: 120)
        check("another pitch is not in the way", near(s3![0].lengthBeats, 4.0) && near(s3![1].lengthBeats, 4.0))
        let s4 = P.notes([raw(60, 4.0, 4.5)], pedal: pedal, takeStart: 0, captureEnd: 10, bpm: 120)
        check("a note released with the pedal UP is not extended", near(s4![0].lengthBeats, 1.0))
        let s5 = P.notes([raw(60, 1.0, 1.5)], pedal: [P.Pedal(time: 0.5, down: true)], takeStart: 0, captureEnd: 6, bpm: 120)
        check("a pedal never released stops at the capture's end (1.0 -> 6.0 = 10 beats)", near(s5![0].lengthBeats, 10.0))
        let s6 = P.notes([raw(60, 1.0, 1.5)], pedal: [P.Pedal(time: 3.0, down: false), P.Pedal(time: 0.5, down: true)],
                         takeStart: 0, captureEnd: 10, bpm: 120)
        check("the pedal events may come in any order", near(s6![0].lengthBeats, 4.0))
        let s7 = P.notes([raw(60, 1.0, 1.5)], pedal: [], takeStart: 0, captureEnd: 10, bpm: 120)
        check("no pedal at all: the note is as played", near(s7![0].lengthBeats, 1.0))

        // MARK: Shift

        let sh = P.notes([raw(60, 10.5, 11.0)], takeStart: 10, captureEnd: 20, bpm: 120, shift: 0.25)
        check("a shift moves the notes in time (0.25 s = 0.5 beat)", near(sh![0].startBeat, 1.5))

        print(fails.isEmpty ? "ALL PASS (\(total))" : "\(fails.count) FAILED of \(total)")
        exit(fails.isEmpty ? 0 : 1)
    }
}
