// The live capture of a recording in progress — `RecordLiveCapture` (docs/plan_retours_2026-11-04.md, L11), asserted
// with no screen and no engine (the unit depends on Foundation only). Pinned down: a note-on opens a note dated from
// the head and its age, a note-off closes the LAST open note of that pitch, a second note-on of an open pitch closes
// the first, a pass reset keeps the finished pass (or forgets it) and closes the notes still down, the events of a drain
// that straddles a lap are split around the jump, the peaks are found by binary search, and the caps drop the oldest.
//
//     swiftc -parse-as-library \
//         ../objekat/SoundObject/RecordLiveCapture.swift test_record_live_capture.swift -o /tmp/trlc && /tmp/trlc
//
// Exit: 0 if every assertion passes, 1 otherwise.

import Foundation

var fails: [String] = []
var total = 0

func check(_ name: String, _ ok: Bool) {
    total += 1
    if !ok { fails.append(name); print("FAIL  \(name)") }
}

typealias C = RecordLiveCapture
func ev(_ pitch: Int, _ on: Bool, age: Double, vel: Int = 100) -> C.Event {
    C.Event(pitch: pitch, velocity: vel, on: on, ageSeconds: age)
}

@main
enum Run {
    static func main() {
        // ── Notes: pairing and timing ──────────────────────────────────────────────────────────────────────
        var c = C()
        c.ingest(events: [ev(60, true, age: 0.20), ev(64, true, age: 0.10)], head: 10)
        check("two note-ons open two notes", c.notes.count == 2 && c.notes.allSatisfy { $0.end == nil })
        check("a note-on is dated head - age", abs(c.notes[0].start - 9.80) < 1e-9 && abs(c.notes[1].start - 9.90) < 1e-9)
        check("the velocity is kept", c.notes[0].velocity == 100)
        c.ingest(events: [ev(60, false, age: 0.05)], head: 10.5)
        check("a note-off closes its note", c.notes[0].end != nil && abs(c.notes[0].end! - 10.45) < 1e-9)
        check("... and only that pitch", c.notes[1].end == nil)

        c = C()
        c.ingest(events: [ev(60, true, age: 1.0), ev(60, true, age: 0.5)], head: 5)
        check("a second note-on of an open pitch closes the first at that instant",
              c.notes.count == 2 && c.notes[0].end != nil && abs(c.notes[0].end! - 4.5) < 1e-9 && c.notes[1].end == nil)
        c.ingest(events: [ev(60, false, age: 0.0)], head: 6)
        check("the note-off closes the LAST open note of the pitch", c.notes[1].end == 6 && abs(c.notes[0].end! - 4.5) < 1e-9)
        c.ingest(events: [ev(60, false, age: 0.0)], head: 7)
        check("a stray note-off changes nothing", c.notes.count == 2 && c.notes[1].end == 6)

        c = C()
        c.ingest(events: [ev(60, true, age: 0.1), ev(60, false, age: 0.1)], head: 3)
        check("an on and an off at the same instant: a note of length 0, never negative",
              c.notes.count == 1 && c.notes[0].end == c.notes[0].start)

        // ── Peaks ──────────────────────────────────────────────────────────────────────────────────────────
        c = C()
        // Steps of a quarter of a second: exact in binary, so the bounds below are compared without rounding.
        for i in 0..<10 { c.ingest(peakDb: Float(-60 + i), head: Double(i) * 0.25) }
        check("peaks are dated at the head", c.peaks.count == 10 && c.peaks[3].time == 0.75 && c.peaks[3].db == -57)
        c.ingest(peakDb: -500, head: 3)
        check("the dB floor is -120", c.peaks.last!.db == -120)
        check("peakIndices finds times 0.75 ... 1.25", c.current.peakIndices(in: 0.6...1.3) == 3..<6)
        check("peakIndices: a range before everything is empty", c.current.peakIndices(in: -5 ... -1).isEmpty)
        check("peakIndices: a range after everything is empty", c.current.peakIndices(in: 50...60).isEmpty)
        check("peakIndices: a range holding all", c.current.peakIndices(in: 0...5) == 0..<11)
        check("peakIndices: bounds are inclusive", c.current.peakIndices(in: 0.75...1.25) == 3..<6)
        check("peakIndices: between two peaks, nothing", c.current.peakIndices(in: 0.8...0.9).isEmpty)

        // ── A new pass ─────────────────────────────────────────────────────────────────────────────────────
        c = C()
        c.ingest(events: [ev(60, true, age: 0.5), ev(62, true, age: 0.4), ev(62, false, age: 0.3)], head: 8)
        c.ingest(peakDb: -20, head: 8)
        c.newPass(at: 9)
        check("newPass keeps the finished pass", c.done.count == 1 && c.done[0].notes.count == 2 && c.done[0].peaks.count == 1)
        check("... starts an empty one", c.current.isEmpty)
        check("... closes the notes still down at the given time", c.done[0].notes[0].end == 9)
        check("... and leaves the closed ones alone", abs(c.done[0].notes[1].end! - 7.7) < 1e-9)
        c.ingest(events: [ev(70, true, age: 0)], head: 1)
        c.newPass(keep: false)
        check("keep: false forgets the pass", c.done.count == 1 && c.current.isEmpty)
        c.ingest(events: [ev(72, true, age: 0)], head: 2)
        c.newPass()
        check("no time given: an open note ends at the latest instant seen", c.done.count == 2 && c.done[1].notes[0].end == 2)

        // ── A drain that straddles a lap ───────────────────────────────────────────────────────────────────
        let events = [ev(60, true, age: 0.30), ev(62, true, age: 0.05)]
        let sp = C.split(events: events, sinceJump: 0.10)
        check("split: the older event belongs to the pass that ended", sp.before.count == 1 && sp.before[0].pitch == 60)
        check("... with its age counted from the jump", abs(sp.before[0].ageSeconds - 0.20) < 1e-9)
        check("... the younger one to the new pass, age untouched", sp.after.count == 1 && sp.after[0].pitch == 62 && sp.after[0].ageSeconds == 0.05)
        c = C()
        c.ingest(events: sp.before, head: 20)        // the pass ended at 20 s on the timeline
        check("dated from the END of the pass: 19.8", abs(c.notes[0].start - 19.8) < 1e-9)
        check("split with nothing older: everything stays", C.split(events: events, sinceJump: 5).before.isEmpty)
        check("split with the jump just now: everything is before", C.split(events: events, sinceJump: 0).after.isEmpty)

        // ── Caps ───────────────────────────────────────────────────────────────────────────────────────────
        c = C()
        var batch: [C.Event] = []
        for i in 0..<(C.maxNotes + 50) { batch.append(ev(i % 100, true, age: 0)); batch.append(ev(i % 100, false, age: 0)) }
        c.ingest(events: batch, head: 1)
        check("the notes are capped", c.notes.count == C.maxNotes)
        check("... the oldest were dropped (the last pitch is the last one played)", c.notes.last!.pitch == (C.maxNotes + 49) % 100)
        c = C()
        for i in 0..<(C.maxPeaks + 10) { c.ingest(peakDb: -30, head: Double(i)) }
        check("the peaks are capped", c.peaks.count == C.maxPeaks)
        check("... the oldest were dropped", c.peaks.first!.time == 10)

        // ── Pitch range ────────────────────────────────────────────────────────────────────────────────────
        c = C()
        check("no notes, no pitch range", c.current.pitchRange == nil)
        c.ingest(events: [ev(48, true, age: 0), ev(72, true, age: 0), ev(60, true, age: 0)], head: 1)
        check("pitch range", c.current.pitchRange == 48...72)

        print(fails.isEmpty ? "ALL PASS (\(total))" : "\(fails.count) FAILED of \(total)")
        exit(fails.isEmpty ? 0 : 1)
    }
}
