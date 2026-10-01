import SwiftUI

// The MIDI clip's note preview (a mini piano roll inside the block), as ONE definition that two
// drawers share: `MidiNotesPreview` (the rich view's own Canvas, block-local) and the batched
// Canvas of the timeline (`TimelineView.plainBlocksCanvas`, canvas coordinates, bounded to the
// viewport). The geometry is the rich view's, to the digit.
//
// WHAT IT DOES:
//  - the pitch range adjusts itself to the notes the clip PLAYS (a note, or a loop repeat, whose
//    attack falls outside the block's edges is not pushed to the engine and must neither show nor
//    weigh on the vertical scale), plus one semitone of margin at each end, at least `minSpan`
//    semitones, re-centred if the span was widened;
//  - the notes are drawn in the central 80 % of the height, one row per semitone;
//  - looping: the [IN, OUT] slice repeats from the block's LEFT edge, as the waveform and the
//    engine fold it.
//
// WHAT THE CANVAS ADDS (and the rich view does not need):
//  - the range is measured over the WHOLE clip, never over what is on screen — a note scrolled out
//    of the viewport still decides the scale, or the notes would breathe as one scrolls;
//  - the drawing is bounded to a horizontal window (`visibleX`, in the block's own coordinates);
//  - the fills are BATCHED: one Path per (colour, velocity, dim) instead of one fill per note;
//  - a note's width is clamped to the block's right edge, which is what `clipShape` did for the
//    rich view (and the rich view keeps it, so the two agree).
//
// No view, no model: pure geometry over anything shaped like a note (`MidiNoteLike`), hence
// assertable alone (`tools/test_midi_notes_drawing.swift`).

/// What the drawing reads of a note. `MidiNote` conforms; the test brings its own.
protocol MidiNoteLike {
    var pitch: Int { get }
    var startBeat: Double { get }
    var lengthBeats: Double { get }
    var velocity: Int { get }
}

extension MidiNote: MidiNoteLike {}

enum MidiNotesDrawing {
    /// The minimum span of semitones shown (it avoids giant bars when there are 1-2 pitches).
    static let minSpan = 8
    /// A ceiling on drawn repeats: a very short pattern looped over a very long window at high
    /// zoom must not generate an unreasonable number of iterations.
    static let maxLoopRepeats = 2000

    /// What two notes must share to be filled by the same operation: the colour, the velocity (the
    /// opacity is `(muted ? 0.30 : 0.55) + 0.40 × velocity / 127`) and the dimming of the block.
    struct FillKey: Hashable {
        let color: Color
        let velocity: Int
        let muted: Bool
        let dim: Bool
    }

    /// The vertical layout every note of a block shares.
    struct Layout: Equatable {
        let top: Int
        let span: Int
        let marginY: Double
        let rowH: Double
        var noteH: Double { max(1.5, rowH - 1) }
    }

    /// Where a block's notes come from, in px: `note.startBeat * pxPerBeat + xOffset`, minus the
    /// loop's IN point when the pattern repeats.
    private struct Frame {
        let pxPerBeat: Double
        let xOffset: Double
        let width: Double
        /// nil = the clip does not loop.
        let periodPx: Double?
        let loopShiftPx: Double
        let maxK: Int

        init(secPerBeat: Double, pixelsPerSecond: Double, xOffset: Double, width: Double,
             loopRange: (start: Double, end: Double)?) {
            pxPerBeat = secPerBeat * pixelsPerSecond
            self.xOffset = xOffset
            self.width = width
            let period = loopRange.map { $0.end - $0.start }
            let p = (period.map { $0 > 0.001 } ?? false) ? period! * pixelsPerSecond : nil
            // A period under half a pixel is not drawn folded (the original's own threshold).
            periodPx = (p ?? 0) > 0.5 ? p : nil
            // The pattern's offset: the block's left edge plays the part of the IN point.
            loopShiftPx = (p != nil ? (loopRange?.start ?? 0) : 0) * pixelsPerSecond
            if let periodPx {
                maxK = min(MidiNotesDrawing.maxLoopRepeats, Int((width / periodPx).rounded(.up)) + 1)
            } else {
                maxK = 0
            }
        }

        /// The x of a note's first attack (k = 0).
        func baseX(_ startBeat: Double) -> Double {
            if periodPx != nil { return startBeat * pxPerBeat + xOffset - loopShiftPx }
            return startBeat * pxPerBeat + xOffset
        }

        /// Whether any attack of a note whose first one falls at `base` lands inside the block.
        func plays(base: Double) -> Bool {
            guard let periodPx else { return base >= 0 && base < width }
            let k0 = base >= 0 ? 0 : Int((-base / periodPx).rounded(.up))
            return k0 <= maxK && base + Double(k0) * periodPx < width
        }
    }

    /// The layout of a block, or nil if it plays no note at all (nothing to draw).
    static func layout<N: MidiNoteLike>(notes: [N], secPerBeat: Double, pixelsPerSecond: Double,
                                        xOffset: Double = 0, size: CGSize,
                                        loopRange: (start: Double, end: Double)? = nil) -> Layout? {
        guard secPerBeat > 0, size.width > 0, !notes.isEmpty else { return nil }
        let f = Frame(secPerBeat: secPerBeat, pixelsPerSecond: pixelsPerSecond,
                      xOffset: xOffset, width: size.width, loopRange: loopRange)
        var minPitch = Int.max, maxPitch = Int.min
        for n in notes where f.plays(base: f.baseX(n.startBeat)) {
            if n.pitch < minPitch { minPitch = n.pitch }
            if n.pitch > maxPitch { maxPitch = n.pitch }
        }
        guard minPitch <= maxPitch else { return nil }
        // A self-adjusting pitch range plus a 1 semitone margin at the top and at the bottom.
        let lo = minPitch - 1
        let hi = maxPitch + 1
        let span = max(minSpan, hi - lo)
        let top = hi + (span - (hi - lo)) / 2          // re-centres if the span was widened
        // The vertical margin = 10% of the clip's height at the top AND at the bottom; the notes
        // are drawn in the central band that is left.
        let marginY = size.height * 0.10
        let usableH = max(1, size.height - 2 * marginY)
        return Layout(top: top, span: span, marginY: marginY, rowH: usableH / Double(span + 1))
    }

    /// Calls `emit(rect, velocity)` for every note rectangle of the block, in the block's own
    /// coordinates, bounded to `visibleX` (nil = no bound). A note is skipped when the whole of it
    /// lies outside the window; the window is judged on the note's CLAMPED extent.
    static func forEachNote<N: MidiNoteLike>(notes: [N], secPerBeat: Double, pixelsPerSecond: Double,
                                             xOffset: Double = 0, size: CGSize,
                                             loopRange: (start: Double, end: Double)? = nil,
                                             visibleX: ClosedRange<Double>? = nil,
                                             _ emit: (CGRect, Int) -> Void) {
        guard let lay = layout(notes: notes, secPerBeat: secPerBeat, pixelsPerSecond: pixelsPerSecond,
                               xOffset: xOffset, size: size, loopRange: loopRange) else { return }
        let f = Frame(secPerBeat: secPerBeat, pixelsPerSecond: pixelsPerSecond,
                      xOffset: xOffset, width: size.width, loopRange: loopRange)
        let h = lay.noteH
        for n in notes {
            let base = f.baseX(n.startBeat)
            guard f.plays(base: base) else { continue }
            let w = max(1.5, n.lengthBeats * f.pxPerBeat)
            let y = lay.marginY + Double(lay.top - n.pitch) * lay.rowH

            func put(_ x: Double) {
                guard x >= 0, x < size.width else { return }
                let cw = min(w, size.width - x)
                if let v = visibleX, x + cw < v.lowerBound || x > v.upperBound { return }
                emit(CGRect(x: x, y: y, width: cw, height: h), n.velocity)
            }
            guard let periodPx = f.periodPx else { put(base); continue }
            // The repeats that can reach the window: x_k = base + k·P, wanted in [lower − w, upper].
            var k0 = 0, k1 = f.maxK
            if let v = visibleX {
                k0 = max(0, Int(((v.lowerBound - w - base) / periodPx).rounded(.down)))
                k1 = min(f.maxK, Int(((v.upperBound - base) / periodPx).rounded(.up)))
            }
            guard k0 <= k1 else { continue }
            for k in k0...k1 { put(base + Double(k) * periodPx) }
        }
    }

    /// The opacity of a note: the rich view's own formula.
    static func opacity(velocity: Int, muted: Bool) -> Double {
        (muted ? 0.30 : 0.55) + 0.40 * (Double(velocity) / 127.0)
    }

    /// Lays one block's notes into `batches`, translated by `origin` (the block's top-left corner in
    /// the destination's coordinates).
    static func append<N: MidiNoteLike>(to batches: inout [FillKey: Path], origin: CGPoint,
                                        notes: [N], secPerBeat: Double, pixelsPerSecond: Double,
                                        xOffset: Double = 0, size: CGSize,
                                        loopRange: (start: Double, end: Double)? = nil,
                                        visibleX: ClosedRange<Double>? = nil,
                                        color: Color, muted: Bool, dim: Bool) {
        // The corner radius is the rich view's: min(2, h / 2).
        var local: [Int: Path] = [:]
        forEachNote(notes: notes, secPerBeat: secPerBeat, pixelsPerSecond: pixelsPerSecond,
                    xOffset: xOffset, size: size, loopRange: loopRange, visibleX: visibleX) { rect, velocity in
            let r = rect.offsetBy(dx: origin.x, dy: origin.y)
            local[velocity, default: Path()].addRoundedRect(
                in: r, cornerSize: CGSize(width: min(2, r.height / 2), height: min(2, r.height / 2)))
        }
        for (velocity, path) in local {
            batches[FillKey(color: color, velocity: velocity, muted: muted, dim: dim), default: Path()]
                .addPath(path)
        }
    }

    /// Fills the batches: the dimmed ones at 0.25, as the Canvas dims every element it draws.
    static func fill(_ batches: [FillKey: Path], into ctx: GraphicsContext) {
        guard !batches.isEmpty else { return }
        var dimmed = ctx
        dimmed.opacity = 0.25
        for (key, path) in batches {
            let shading = GraphicsContext.Shading.color(
                key.color.opacity(opacity(velocity: key.velocity, muted: key.muted)))
            if key.dim { dimmed.fill(path, with: shading) } else { ctx.fill(path, with: shading) }
        }
    }
}
