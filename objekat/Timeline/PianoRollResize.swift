import Foundation

/// The arithmetic of resizing SEVERAL selected notes of a piano roll at once — pure, in beats, with no
/// view and no model (compiled and run alone by `tools/test_piano_roll_resize.swift`).
///
/// The hand grabs ONE edge of ONE note; the travel of that edge (snapped, as before) is a `deltaBeats`
/// measured on the grabbed note, and every selected note takes the SAME delta on its own edge — the
/// way the move already works (one delta computed on the grabbed note, applied to the selection).
/// The bounds are then applied NOTE BY NOTE, so that a short note stopping at its minimum does not
/// hold the others back:
/// - the grabbed note keeps exactly the formula it always had (a single selected note behaves as it
///   did before this existed): its length never goes below `minLen`, its start never below 0;
/// - the OTHER notes are never GROWN by the minimum: a note already shorter than `minLen` (a note
///   written before the grid was made coarser) keeps its length at worst, it is not inflated by a
///   gesture that was not about it; and a note that starts before 0 (masked by a left trim of its
///   clip, a legitimate state) is not pulled onto 0 by the gesture — its own start is its floor.
enum PianoRollResize {

    /// A note's extent in beats. `end` is derived, so that the right edge and the left edge stay
    /// consistent whichever of the two moves.
    struct Span: Equatable {
        var start: Double
        var length: Double
        var end: Double { start + length }
        init(start: Double, length: Double) { self.start = start; self.length = length }
    }

    /// The RIGHT edge moves by `deltaBeats`: the start stays, the length follows.
    static func resizeEnd(_ origs: [UUID: Span], grabbed: UUID,
                          deltaBeats: Double, minLen: Double) -> [UUID: Span] {
        var out: [UUID: Span] = [:]
        for (id, o) in origs {
            if id == grabbed {
                out[id] = Span(start: o.start, length: max(minLen, o.length + deltaBeats))
            } else {
                out[id] = Span(start: o.start,
                               length: max(o.length + deltaBeats, min(minLen, o.length)))
            }
        }
        return out
    }

    /// The LEFT edge moves by `deltaBeats`: the end stays, the start and the length follow.
    static func resizeStart(_ origs: [UUID: Span], grabbed: UUID,
                            deltaBeats: Double, minLen: Double) -> [UUID: Span] {
        var out: [UUID: Span] = [:]
        for (id, o) in origs {
            let start: Double
            if id == grabbed {
                start = max(0, min(o.start + deltaBeats, o.end - minLen))
                out[id] = Span(start: start, length: max(minLen, o.end - start))
            } else {
                let lower = min(0, o.start)
                let upper = o.end - min(minLen, o.length)
                start = max(lower, min(o.start + deltaBeats, upper))
                out[id] = Span(start: start, length: o.end - start)
            }
        }
        return out
    }
}
