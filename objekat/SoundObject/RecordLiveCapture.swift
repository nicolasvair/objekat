import Foundation

// What a recording shows of itself while it runs (docs/plan_retours_2026-11-04.md, L11): the notes played on a MIDI
// zone's input, and the loudness of an audio zone's input over time. It is a SIMPLIFIED picture, made at the UI's rate
// from what the engine hands over (note events with their age, the peak of each tick), never the file being written:
// nothing here can touch the recording, and a missed tick costs a pixel of drawing.
//
// Pure — Foundation only, no view, no model, no engine — so it can be compiled and asserted alone
// (`tools/test_record_live_capture.swift`). The times are the TIMELINE's, in seconds: the caller says where the head is
// (`head`) and the capture dates what it is handed from there (`head - age` for an event, `head` for a peak).
//
// One capture per zone. A recording through a loop makes several PASSES: `newPass` closes the one that ended and starts
// an empty one, and keeps the finished pass (`done`) when the zone shows a ghost for it — the ghost then draws what the
// pass drew while it was current.

/// A note as played: its attack, its velocity, and its end (nil while the key is still down).
struct LiveNote: Equatable {
    var pitch: Int
    var velocity: Int
    var start: Double
    var end: Double?
}

/// The loudness of the input at one tick: the peak since the previous one, in dB (floor -120).
struct LivePeak: Equatable {
    var time: Double
    var db: Float
}

struct RecordLiveCapture: Equatable {
    /// Beyond these the OLDEST are dropped (20 000 notes, 60 000 peaks: 33 minutes at 30 Hz).
    static let maxNotes = 20_000
    static let maxPeaks = 60_000
    /// How far back a note-off looks for its note-on: the keys held are recent, and a stray note-off (its note-on
    /// dropped by the engine's ring) must not walk the whole list.
    static let noteOffLookback = 512

    /// A note event as the engine reports it: `ageSeconds` is how long ago it happened, at the moment of the drain.
    struct Event: Equatable {
        var pitch: Int
        var velocity: Int
        var on: Bool
        var ageSeconds: Double
    }

    /// What one pass drew.
    struct Pass: Equatable {
        var notes: [LiveNote] = []
        var peaks: [LivePeak] = []

        var isEmpty: Bool { notes.isEmpty && peaks.isEmpty }

        /// The distinct pitch range of the notes, nil without notes.
        var pitchRange: ClosedRange<Int>? {
            guard let lo = notes.map(\.pitch).min(), let hi = notes.map(\.pitch).max() else { return nil }
            return lo...hi
        }

        /// The peaks whose time lies in `range` (a binary search: the times only grow within a pass).
        func peakIndices(in range: ClosedRange<Double>) -> Range<Int> {
            var lo = 0, hi = peaks.count
            while lo < hi {                       // first index with time >= range.lowerBound
                let mid = (lo + hi) / 2
                if peaks[mid].time < range.lowerBound { lo = mid + 1 } else { hi = mid }
            }
            let first = lo
            hi = peaks.count
            while lo < hi {                       // first index with time > range.upperBound
                let mid = (lo + hi) / 2
                if peaks[mid].time <= range.upperBound { lo = mid + 1 } else { hi = mid }
            }
            return first..<lo
        }
    }

    /// The pass in progress.
    var current = Pass()
    /// The finished passes the zone shows a ghost for, in order (`done[i]` is the ghost of pass i).
    var done: [Pass] = []
    /// The time of the latest thing ingested: where an open note ends when the pass is closed without a better date.
    private(set) var lastTime: Double = 0

    var notes: [LiveNote] { current.notes }
    var peaks: [LivePeak] { current.peaks }

    /// Note events, dated from `head`. A note-on opens a note; a note-off closes the LAST open note of its pitch (a
    /// second note-on of a pitch still open closes the first at that instant, so notes of one pitch never stack).
    mutating func ingest(events: [Event], head: Double) {
        // In the order they happened (the engine's ring is filled in arrival order).
        for e in events {
            let t = head - e.ageSeconds
            lastTime = max(lastTime, t)
            if e.on {
                if let open = lastOpenIndex(pitch: e.pitch) { current.notes[open].end = t }
                current.notes.append(LiveNote(pitch: e.pitch, velocity: e.velocity, start: t, end: nil))
            } else if let open = lastOpenIndex(pitch: e.pitch) {
                current.notes[open].end = max(t, current.notes[open].start)
            }
        }
        if current.notes.count > Self.maxNotes { current.notes.removeFirst(current.notes.count - Self.maxNotes) }
    }

    /// One tick's peak, at the head.
    mutating func ingest(peakDb: Float, head: Double) {
        lastTime = max(lastTime, head)
        current.peaks.append(LivePeak(time: head, db: max(-120, peakDb)))
        if current.peaks.count > Self.maxPeaks { current.peaks.removeFirst(current.peaks.count - Self.maxPeaks) }
    }

    /// The pass ended: the notes still down end at `time` (default: the latest instant seen), then the pass goes to
    /// `done` when `keep` (the zone shows a ghost for it) or is forgotten, and the next one starts empty.
    mutating func newPass(at time: Double? = nil, keep: Bool = true) {
        let end = time ?? lastTime
        for i in current.notes.indices where current.notes[i].end == nil { current.notes[i].end = max(end, current.notes[i].start) }
        if keep { done.append(current) }
        current = Pass()
        lastTime = 0          // dates the pass that starts now, not the one that ended
    }

    /// Splits the events of one drain around a jump of the head (a lap): `sinceJump` is how long ago the head jumped.
    /// The events older than that happened in the pass that ended — returned with their ages counted from the jump, so
    /// that `ingest(events:head:)` with the END of that pass dates them right — and the others belong to the new one.
    static func split(events: [Event], sinceJump: Double) -> (before: [Event], after: [Event]) {
        var before: [Event] = [], after: [Event] = []
        for e in events {
            if e.ageSeconds > sinceJump {
                var b = e
                b.ageSeconds = e.ageSeconds - max(0, sinceJump)
                before.append(b)
            } else {
                after.append(e)
            }
        }
        return (before, after)
    }

    private func lastOpenIndex(pitch: Int) -> Int? {
        let lowest = max(0, current.notes.count - Self.noteOffLookback)
        var i = current.notes.count - 1
        while i >= lowest {
            if current.notes[i].pitch == pitch && current.notes[i].end == nil { return i }
            i -= 1
        }
        return nil
    }
}
