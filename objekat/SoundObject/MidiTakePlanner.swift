import Foundation

// MARK: - What a MIDI recording becomes in a zone — the pure rules
//
// The engine hands over what the keyboard played as NOTES in absolute seconds on the timeline (a note still
// held at the stop is closed there by Tracktion) and the sustain pedal (CC 64) as it moved. What a take
// stores is decided HERE from those and nothing else:
//
//   - a note's timing is in BEATS relative to the take's start, at the project's tempo (`MidiNote`'s unit); a
//     note that begins BEFORE the take (the take is cropped to the zone's window, the capture is longer) has a
//     negative `startBeat` — a HANDLE, kept in the model and not played until the edge is pulled out;
//   - the sustain pedal is FOLDED into the notes: a note released while the pedal is down lasts until the pedal
//     comes up (or the capture ends), but never past the next attack of the same pitch. The pedal itself is
//     not kept, and no other controller (CC, pitch bend) is: they are ignored;
//   - `shift` moves everything in time (a fixed correction, seconds; the engine already applies the output
//     latency, so the planner's own is 0);
//   - a recording with no note gives NO take (nil).
//
// A plain Foundation unit with no model behind it (tools/test_midi_take_planner.swift).

enum MidiTakePlanner {

    /// A note as the engine reports it: seconds on the timeline.
    struct RawNote: Equatable {
        var pitch: Int
        var start: Double
        var end: Double
        var velocity: Int
    }

    /// A movement of the sustain pedal (CC 64) at `time`, seconds on the timeline: down when the value is >= 64.
    struct Pedal: Equatable {
        var time: Double
        var down: Bool
    }

    /// The notes of the take, in beats relative to `takeStart`, ordered by start (then pitch); nil when the
    /// recording holds no note.
    /// - Parameters:
    ///   - captureEnd: where the capture stopped, seconds — the limit of a pedal still down.
    ///   - bpm: the project's tempo.
    static func notes(_ raw: [RawNote], pedal: [Pedal] = [], takeStart: Double, captureEnd: Double,
                      bpm: Double, shift: Double = 0) -> [MidiNote]? {
        let valid = raw.filter { (0...127).contains($0.pitch) && $0.end >= $0.start }
        guard !valid.isEmpty, bpm > 0 else { return nil }

        let folded = foldSustain(valid, pedal: pedal.sorted { $0.time < $1.time }, captureEnd: captureEnd)
        let perSecond = bpm / 60
        let out = folded.map { n -> MidiNote in
            MidiNote(pitch: n.pitch,
                     startBeat: (n.start + shift - takeStart) * perSecond,
                     lengthBeats: max(0.01, (n.end - n.start) * perSecond),
                     velocity: min(127, max(1, n.velocity)))
        }
        return out.sorted { a, b in a.startBeat != b.startBeat ? a.startBeat < b.startBeat : a.pitch < b.pitch }
    }

    /// Notes released while the pedal is down last until it comes up (or `captureEnd`), without crossing
    /// the next attack of their own pitch.
    static func foldSustain(_ notes: [RawNote], pedal: [Pedal], captureEnd: Double) -> [RawNote] {
        guard !pedal.isEmpty else { return notes }
        func isDown(at t: Double) -> Bool {
            var down = false
            for p in pedal where p.time <= t { down = p.down }
            return down
        }
        func nextUp(after t: Double) -> Double {
            pedal.first { $0.time > t && !$0.down }?.time ?? captureEnd
        }
        var byPitch: [Int: [Double]] = [:]
        for n in notes { byPitch[n.pitch, default: []].append(n.start) }
        return notes.map { n in
            guard isDown(at: n.end) else { return n }
            var end = max(n.end, nextUp(after: n.end))
            if let nextAttack = byPitch[n.pitch]?.filter({ $0 > n.start }).min() { end = min(end, nextAttack) }
            var m = n
            m.end = max(n.end, end)
            return m
        }
    }
}
