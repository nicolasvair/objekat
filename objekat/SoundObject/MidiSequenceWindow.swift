import Foundation

// MARK: - A MIDI sequence shared by the takes of a recording through a loop — the pure rules
//
// (docs/plan_enregistrement_audio.md, "Rec en boucle"; session format 37.)
//
// An audio recording through a loop is ONE file and each take points at it with its own `sourceOffset`: the
// takes only differ by the WINDOW they look through. MIDI gets the same shape. What the keyboard played during
// the whole capture is stored ONCE, as an immutable `MidiSequence` (notes in beats from the capture's origin,
// on the recording clock, so a pass that wraps the loop is one more stretch of the same line), and a take is a
// perfectly ordinary `.midiClip` that carries a `MidiSequenceRef { id, offsetBeats }` beside its notes:
//
//   - the clip's notes hold ONLY its window — the notes that BEGIN in `[offsetBeats, offsetBeats + length)` of
//     the sequence, rebased on the clip (the clip's beat x is the sequence's beat x + offsetBeats). A note that
//     began before the window, or begins after it, is not in the clip: it is the part of the capture the other
//     takes (or nobody) look at;
//   - the window RESOLVES again only when the clip's edges move (`applyTrim`, `updateDuration`): pulling an
//     edge out reveals what the sequence holds there, and pushing it back hides it again, as the matter of an
//     audio clip does. Nothing resolves in between;
//   - the first edit of the clip's notes DETACHES it into a classic clip (the notes it holds become its own, the
//     reference is dropped) — copy on first edit, never propagated to the sequence nor to the other takes;
//   - a clip's reference is valid only while the notes the clip holds ARE the notes it was resolved to: a
//     `signature` taken when it was resolved says so (it is not written — it is recomputed when the file is
//     read). Any site that rebuilds a clip's notes without knowing about sequences therefore degrades to a
//     classic clip by itself, at the next door that looks.
//
// A plain Foundation unit with no model behind it, compiled and asserted alone
// (tools/test_midi_sequence_window.swift).

/// What was played during a whole capture: notes in beats from the capture's origin. IMMUTABLE once recorded
/// (a take that is edited detaches, it never writes here).
struct MidiSequence: Codable, Equatable, Identifiable {
    var id: UUID
    var notes: [MidiNote]
}

/// A take's window on a `MidiSequence`.
struct MidiSequenceRef: Codable, Equatable {
    var id: UUID
    /// Where the clip's beat 0 is on the sequence.
    var offsetBeats: Double
    /// What the clip's notes were when this reference was last resolved (@see `MidiSequenceWindow.signature`).
    /// TRANSIENT: never written, recomputed at the load from the notes the file holds.
    var signature: UInt64 = 0

    enum CodingKeys: String, CodingKey { case id, offsetBeats }

    init(id: UUID, offsetBeats: Double, signature: UInt64 = 0) {
        self.id = id
        self.offsetBeats = offsetBeats
        self.signature = signature
    }

    /// True while the clip still holds exactly the notes this reference resolved to.
    func matches(_ notes: [MidiNote]) -> Bool { signature == MidiSequenceWindow.signature(notes) }

    /// The same window, certified for `notes` (what the clip holds now).
    func signed(_ notes: [MidiNote]) -> MidiSequenceRef {
        var r = self
        r.signature = MidiSequenceWindow.signature(notes)
        return r
    }

    /// The window moved on the sequence by `beats` (the clip's start edge moved by as much).
    func shifted(by beats: Double) -> MidiSequenceRef {
        var r = self
        r.offsetBeats += beats
        return r
    }
}

enum MidiSequenceWindow {

    /// A tolerance on the window's edges, beats: a note a hair before its window's start is still in it.
    static let epsilon = 1e-9

    /// The notes of the window `[offsetBeats, offsetBeats + lengthBeats)` of a sequence, rebased on the clip, in
    /// the sequence's own order (by start, then pitch). A note is in the window when it BEGINS in it. Their ids
    /// are DETERMINISTIC from the clip and the sequence's note (`noteID`): a resolve does not renew them, and two
    /// takes of one sequence never share one.
    static func notes(of sequence: [MidiNote], offsetBeats: Double, lengthBeats: Double, clipID: UUID) -> [MidiNote] {
        guard lengthBeats > 0 else { return [] }
        let lo = offsetBeats - epsilon
        let hi = offsetBeats + lengthBeats - epsilon
        var out: [MidiNote] = []
        for n in sequence where n.startBeat >= lo && n.startBeat < hi {
            out.append(MidiNote(id: noteID(clip: clipID, note: n.id), pitch: n.pitch,
                                startBeat: max(0, n.startBeat - offsetBeats),
                                lengthBeats: n.lengthBeats, velocity: n.velocity))
        }
        return out.sorted { a, b in a.startBeat != b.startBeat ? a.startBeat < b.startBeat : a.pitch < b.pitch }
    }

    /// The id of a clip's note taken from a sequence's: the two ids XORed, so it is stable, unique to the clip,
    /// and needs no table.
    static func noteID(clip: UUID, note: UUID) -> UUID {
        let a = withUnsafeBytes(of: clip.uuid) { Array($0) }
        let b = withUnsafeBytes(of: note.uuid) { Array($0) }
        var out = UUID().uuid
        withUnsafeMutableBytes(of: &out) { buf in
            for i in 0..<16 { buf[i] = a[i] ^ b[i] }
        }
        return UUID(uuid: out)
    }

    /// A fingerprint of what a clip holds: the notes' pitch, start, length and velocity, in order, ids left out.
    /// FNV-1a over the bit patterns — deterministic from one process to the next (`Hasher` is not).
    static func signature(_ notes: [MidiNote]) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        @inline(__always) func mix(_ v: UInt64) {
            var x = v
            for _ in 0..<8 {
                h = (h ^ (x & 0xff)) &* 0x100000001b3
                x >>= 8
            }
        }
        mix(UInt64(notes.count))
        for n in notes {
            mix(UInt64(bitPattern: Int64(n.pitch)))
            mix(n.startBeat.bitPattern)
            mix(n.lengthBeats.bitPattern)
            mix(UInt64(bitPattern: Int64(n.velocity)))
        }
        return h
    }

    /// What a take becomes when its edges move: the window `[offsetBeats, offsetBeats + lengthBeats)` resolved
    /// again, and the reference certified for it. nil when the reference no longer holds (the clip was edited, or
    /// its sequence is gone): the caller then treats the clip as a classic one.
    static func resolved(ref: MidiSequenceRef, current: [MidiNote], sequence: MidiSequence?,
                         shiftedByBeats shift: Double, lengthBeats: Double,
                         clipID: UUID) -> (notes: [MidiNote], ref: MidiSequenceRef)? {
        guard let sequence, sequence.id == ref.id, ref.matches(current) else { return nil }
        let moved = ref.shifted(by: shift)
        let notes = notes(of: sequence.notes, offsetBeats: moved.offsetBeats, lengthBeats: lengthBeats, clipID: clipID)
        return (notes, moved.signed(notes))
    }

    /// The references of the two halves of a take cut at `splitBeat` (clip beats), given the notes each half got
    /// (`left` keeps the notes that begin before the cut, `right` the others, rebased).
    ///
    ///   - the RIGHT half looks through the same sequence from `offsetBeats + splitBeat` on: always valid;
    ///   - the LEFT half keeps the offset, and stays valid only if the cut did not shorten a note (a note
    ///     straddling the cut is truncated on the left, which the sequence does not know): then it is a classic
    ///     clip.
    /// nil on both when `ref` no longer holds for `original`.
    static func split(ref: MidiSequenceRef, original: [MidiNote], left: [MidiNote], right: [MidiNote],
                      atBeat splitBeat: Double) -> (left: MidiSequenceRef?, right: MidiSequenceRef?) {
        guard ref.matches(original) else { return (nil, nil) }
        let wholeLeft = original.filter { $0.startBeat < splitBeat }
        let leftRef: MidiSequenceRef? = signature(left) == signature(wholeLeft) ? ref.signed(left) : nil
        return (leftRef, ref.shifted(by: splitBeat).signed(right))
    }
}
