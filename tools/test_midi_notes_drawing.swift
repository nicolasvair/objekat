// The MIDI clip's note preview — the geometry, asserted with no screen.
//
// `MidiNotesDrawing` is what the rich `MidiNotesPreview` and the timeline's batched Canvas both
// draw from. The expected values below are the rich view's own arithmetic, written out by hand
// (pitch range over the notes the block plays, ±1 semitone, 8 semitones at least, 10 % margins,
// loop folding from the block's left edge), plus what the Canvas adds: a range measured over the
// WHOLE clip and a drawing bounded to a window.
//
//     swiftc -parse-as-library \
//         ../objekat/Timeline/MidiNotesDrawing.swift test_midi_notes_drawing.swift \
//         -o /tmp/mnd && /tmp/mnd
//
// Exit: 0 if every assertion passes, 1 otherwise.

import SwiftUI

// Stand-in for the model's note (the real one lives in SoundObject.swift).
struct MidiNote {
    var pitch: Int
    var startBeat: Double
    var lengthBeats: Double
    var velocity: Int = 100
}

var fails: [String] = []
var total = 0

func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    total += 1
    if ok { print("ok    " + label) }
    else { fails.append(label); print("FAIL  \(label)  \(detail)") }
}

func near(_ a: Double, _ b: Double, _ eps: Double = 1e-9) -> Bool { abs(a - b) < eps }

func rects(_ notes: [MidiNote], spb: Double = 0.5, pps: Double = 100, xOffset: Double = 0,
           size: CGSize, loop: (start: Double, end: Double)? = nil,
           visible: ClosedRange<Double>? = nil) -> [(CGRect, Int)] {
    var out: [(CGRect, Int)] = []
    MidiNotesDrawing.forEachNote(notes: notes, secPerBeat: spb, pixelsPerSecond: pps, xOffset: xOffset,
                                 size: size, loopRange: loop, visibleX: visible) { out.append(($0, $1)) }
    return out
}

@main
enum MidiNotesDrawingTest {
  static func main() {
    let size = CGSize(width: 400, height: 100)

    // MARK: - Layout, no loop
    // Three notes at pitches 60, 64, 67 → lo 59, hi 68 → span 9 (> minSpan 8), top 68.
    let three = [MidiNote(pitch: 60, startBeat: 0, lengthBeats: 1),
                 MidiNote(pitch: 64, startBeat: 1, lengthBeats: 1, velocity: 127),
                 MidiNote(pitch: 67, startBeat: 2, lengthBeats: 2, velocity: 20)]
    let lay = MidiNotesDrawing.layout(notes: three, secPerBeat: 0.5, pixelsPerSecond: 100, size: size)
    check("range 59...68 → span 9", lay?.span == 9 && lay?.top == 68, "\(String(describing: lay))")
    check("margin is 10 % of the height", near(lay?.marginY ?? 0, 10))
    check("rowH = 80 / (span+1)", near(lay?.rowH ?? 0, 8))
    check("note height = rowH - 1", near(lay?.noteH ?? 0, 7))

    let r = rects(three, size: size)
    check("three rectangles", r.count == 3)
    // 0.5 s per beat × 100 px/s = 50 px per beat
    check("first note at x 0, width 50", near(r[0].0.minX, 0) && near(r[0].0.width, 50))
    check("second note at x 50", near(r[1].0.minX, 50))
    check("third note: x 100, width 100", near(r[2].0.minX, 100) && near(r[2].0.width, 100))
    check("pitch 67 sits on row 1: y = 10 + 1 × 8", near(r[2].0.minY, 18))
    check("pitch 60 sits on row 8: y = 10 + 8 × 8", near(r[0].0.minY, 74))
    check("velocities travel", r[0].1 == 100 && r[1].1 == 127 && r[2].1 == 20)

    // MARK: - A narrow range is widened to 8 semitones and re-centred
    let two = [MidiNote(pitch: 60, startBeat: 0, lengthBeats: 1), MidiNote(pitch: 62, startBeat: 1, lengthBeats: 1)]
    let l2 = MidiNotesDrawing.layout(notes: two, secPerBeat: 0.5, pixelsPerSecond: 100, size: size)
    // lo 59, hi 63 → span max(8, 4) = 8; top = 63 + (8 - 4) / 2 = 65
    check("narrow range: span 8, top 65", l2?.span == 8 && l2?.top == 65, "\(String(describing: l2))")

    // MARK: - What the block does not play weighs nothing
    let beyond = three + [MidiNote(pitch: 100, startBeat: 100, lengthBeats: 1)]   // x = 5000 > 400
    let lb = MidiNotesDrawing.layout(notes: beyond, secPerBeat: 0.5, pixelsPerSecond: 100, size: size)
    check("a note past the right edge does not stretch the range", lb == lay)
    check("…and is not drawn", rects(beyond, size: size).count == 3)
    let before = three + [MidiNote(pitch: 10, startBeat: -3, lengthBeats: 1)]     // x = -150 < 0
    check("a note before the left edge is not drawn", rects(before, size: size).count == 3)
    check("a note shifted into view by the trim offset is", rects(before, xOffset: 200, size: size).count == 4)

    // MARK: - The window bounds the drawing, not the range
    let wide = CGSize(width: 4000, height: 100)
    let many = (0..<40).map { MidiNote(pitch: 60 + ($0 == 39 ? 20 : 0), startBeat: Double($0), lengthBeats: 1) }
    let layAll = MidiNotesDrawing.layout(notes: many, secPerBeat: 0.5, pixelsPerSecond: 100, size: wide)
    let inWin = rects(many, size: wide, visible: 0...120)
    check("only the notes in the window are emitted", inWin.count == 3, "\(inWin.count)")
    check("the range still counts the note out of the window", layAll?.top == 81, "\(String(describing: layAll))")
    check("the rows are those of the whole clip (pitch 60 at the same y with or without a window)",
          near(inWin[0].0.minY, rects(many, size: wide)[0].0.minY))
    // A note starting before the window but reaching into it is drawn.
    let long = [MidiNote(pitch: 60, startBeat: 0, lengthBeats: 4)]   // x 0...200
    check("a note straddling the window's left edge is drawn", rects(long, size: wide, visible: 150...300).count == 1)
    check("one ending before it is not", rects(long, size: wide, visible: 250...300).count == 0)

    // MARK: - Clamped to the block's right edge
    let edge = [MidiNote(pitch: 60, startBeat: 7, lengthBeats: 4)]    // x 350, width 200 → 50 left
    let re = rects(edge, size: size)
    check("a note spilling past the block is cut at its edge", re.count == 1 && near(re[0].0.maxX, 400))
    let tiny = [MidiNote(pitch: 60, startBeat: 0, lengthBeats: 0.001)]
    check("a tiny note keeps its 1.5 px", near(rects(tiny, size: size)[0].0.width, 1.5))

    // MARK: - Loop: the [IN, OUT] slice repeats from the left edge
    // IN 0 s, OUT 1 s (100 px period). A note at beat 0 repeats every 100 px: 0, 100, 200, 300.
    let loopNote = [MidiNote(pitch: 60, startBeat: 0, lengthBeats: 0.5)]
    let rl = rects(loopNote, size: size, loop: (0, 1))
    check("a looped note repeats over the window", rl.count == 4, "\(rl.count)")
    check("the repeats are one period apart", near(rl[1].0.minX - rl[0].0.minX, 100))
    // IN at 0.5 s: the slice starts at 50 px of the pattern, so a note at beat 1 (x 50) lands on 0.
    let shifted = [MidiNote(pitch: 60, startBeat: 1, lengthBeats: 0.5)]
    let rs = rects(shifted, size: size, loop: (0.5, 1.5))
    check("the IN point is the block's left edge", rs.first.map { near($0.0.minX, 0) } ?? false, "\(rs.map { $0.0.minX })")
    // A note before the IN point only plays on the repeats that bring it into the block.
    let early = [MidiNote(pitch: 60, startBeat: 0, lengthBeats: 0.5)]
    let re2 = rects(early, size: size, loop: (0.5, 1.5))
    check("a note before IN first shows on the second repeat", re2.first.map { near($0.0.minX, 50) } ?? false, "\(re2.map { $0.0.minX })")
    // The window picks the same repeats the full pass would.
    let full = rects(loopNote, size: wide, loop: (0, 1))
    let win = rects(loopNote, size: wide, loop: (0, 1), visible: 1000...1250)
    let expected = full.filter { $0.0.maxX >= 1000 && $0.0.minX <= 1250 }
    check("a window over a loop = the full pass filtered", win.count == expected.count && win.count > 0,
          "\(win.count) vs \(expected.count)")
    check("…and the same x's", zip(win, expected).allSatisfy { near($0.0.minX, $1.0.minX) })
    // A period under half a pixel is not folded.
    let rp = rects(loopNote, size: size, loop: (0, 0.004))
    check("a sub-pixel period does not explode the repeats", rp.count <= 1)
    // The repeats are capped.
    let capped = rects(loopNote, spb: 0.5, pps: 100, size: CGSize(width: 1_000_000, height: 100), loop: (0, 0.01))
    check("repeats are capped at maxLoopRepeats + 1", capped.count <= MidiNotesDrawing.maxLoopRepeats + 1, "\(capped.count)")

    // MARK: - Degenerate inputs
    check("no notes → no layout", MidiNotesDrawing.layout(notes: [MidiNote](), secPerBeat: 0.5, pixelsPerSecond: 100, size: size) == nil)
    check("a zero tempo draws nothing", rects(three, spb: 0, size: size).isEmpty)
    check("a zero-width block draws nothing", rects(three, size: CGSize(width: 0, height: 100)).isEmpty)

    // MARK: - Opacity (the rich view's formula)
    check("opacity: 0.55 + 0.40 v", near(MidiNotesDrawing.opacity(velocity: 127, muted: false), 0.95))
    check("opacity muted: 0.30 + 0.40 v", near(MidiNotesDrawing.opacity(velocity: 0, muted: true), 0.30))

    // MARK: - Batching
    var batches: [MidiNotesDrawing.FillKey: Path] = [:]
    MidiNotesDrawing.append(to: &batches, origin: CGPoint(x: 1000, y: 200), notes: three, secPerBeat: 0.5,
                            pixelsPerSecond: 100, size: size, color: .red, muted: false, dim: false)
    check("one Path per velocity", batches.count == 3)
    let union = batches.values.reduce(CGRect.null) { $0.union($1.boundingRect) }
    check("the paths are translated by the origin", near(union.minX, 1000) && near(union.minY, 200 + 18))

    print("")
    if fails.isEmpty {
        print("\(total) assertions, all pass")
        exit(0)
    } else {
        print("\(fails.count) FAILED: \(fails.joined(separator: " · "))")
        exit(1)
    }
  }
}
