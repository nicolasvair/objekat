import Foundation

// MARK: - Where a piano roll opens — and nothing else
//
// The arithmetic of the framing, and only the arithmetic: no view, no model, no layout. It is a
// unit of its own for the reason `SendColumns` and `SynopticMarquee` are — this is the half of the
// piano roll's opening that has nothing behind it, and put here it can be compiled alone and
// asserted with no screen (@see tools/test_piano_roll_framing.swift).
//
// The rule it holds is one sentence long and took two readings to get right: a roll frames its own
// notes, AND its window starts on a C.

/// The C at or below `pitch`, bounded so that a window of `rows` semitones stays inside 0…127.
///
/// **A piano roll's window always starts on a C.** The framing below puts it wherever the notes
/// are, and the first version of that let the bottom row land on G♯2 or D4 — it showed the notes,
/// and it made everything else unreadable: the octave labels no longer named an octave, the black
/// keys fell in a pattern nobody recognises, and oct +/- carried the offset around for the rest of
/// the session. The reference is worth more than the perfect centring.
///
/// The bound matters as much as the snapping: a window pushed against 127 and clamped by whoever
/// draws it would come back off its C, which is how the octave button used to lose the reference at
/// the top of its travel.
///
/// And the ceiling is the LOWEST C from which the window still reaches 127, not the highest C whose
/// whole window fits underneath. Rounding the other way looks tidier and puts the last semitones of
/// the keyboard out of reach for ever: with a window of 24 rows it stops at C7, so a note written
/// at 127 could be neither seen nor scrolled to. The keyboard ENDS instead — the drawing stops at
/// 127 and the rows above it simply are not there (@see `PianoRollView.normalRowPitches`).
func pianoRollBaseOnC(_ pitch: Int, rows: Int) -> Int {
    let rows = max(1, rows)
    let need = max(0, 127 - rows + 1)               // the lowest start that still shows 127
    let ceiling = min(120, (need + 11) / 12 * 12)   // 120 = C9, the last C there is
    return min(max(0, pitch) / 12 * 12, ceiling)
}

/// The window a roll opens on when nobody has moved it yet.
///
/// The notes are CENTRED when they fit in the height available, and otherwise read from a semitone
/// under the lowest — a span taller than the window has to be read from somewhere, and one reads a
/// keyboard upwards from the bass. That ideal is then snapped onto one of the two C's framing it,
/// and the one showing MORE OF THE NOTES wins, which is the whole reason for framing anything. A
/// tie goes to the lower, for the same reason as the tall span above.
///
/// No notes at all: `fallback`, untouched. There is nothing to frame, and a note about to be drawn
/// will be drawn where the middle of the keyboard is.
func pianoRollAutoBase(pitches: [Int], rows: Int, fallback: Int) -> Int {
    guard let lo = pitches.min(), let hi = pitches.max() else { return fallback }
    let rows = max(1, rows)
    let ideal = hi - lo + 1 <= rows ? (lo + hi) / 2 - (rows - 1) / 2 : lo - 1
    let low  = pianoRollBaseOnC(ideal, rows: rows)
    let high = pianoRollBaseOnC(low + 12, rows: rows)
    guard high != low else { return low }
    func seen(_ base: Int) -> Int {
        pitches.reduce(0) { $0 + (($1 >= base && $1 <= base + rows - 1) ? 1 : 0) }
    }
    return seen(high) > seen(low) ? high : low
}
