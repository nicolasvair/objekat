import Foundation

/// Where a LOOPING audio clip's window and loop bounds go when its LEFT edge moves — the pure
/// arithmetic, Foundation only, compiled alone by `tools/test_loop_retrim.swift`.
///
/// The model. A loop's IN/OUT bounds (`loopRangeStart` / `loopRangeEnd`) are LOCAL seconds (0 = the
/// block's left edge) and the file is read at `sourceOffset + local × speed`
/// (@see EditViewModel.clipLoopFileBounds). So a bound is a place in the FILE seen through the
/// window: when the window's left edge moves by δ, `sourceOffset` advances by δ×speed (the
/// ordinary trim, @see WaveformShaping.retrimmedSourceOffset) but the bounds, being local, stay
/// where they were — they now name another place in the file. The pattern slid inside the file,
/// shortened against the file's end, then fell silent (the bounds crossed).
///
/// What an Ableton-style loop wants is the opposite: the pattern is ANCHORED, in the file AND on the
/// timeline. The repeats keep their grid (`g + k·P`, `g` = where a repeat starts), the left edge
/// only moves the WINDOW over that grid, and what is heard at an instant that stays inside the
/// window does not change. Going out and back is the identity.
///
/// The window is therefore re-expressed on the grid: at the new left edge the pattern is at phase
/// `φ = (newStart − g) mod P`, so the clip enters its file `φ×speed` after the IN point
/// (`sourceOffset' = fileIN + φ·speed`), the IN bound lands `φ` BEFORE the edge (local `−φ`) and
/// OUT `P − φ` after it. That is the canonical form: IN in `]−P, 0]`.
///
/// `g` follows the engine and the drawing: the left edge plays the IN point when IN lies INSIDE the
/// block (`a > 0`: the matter before IN is never heard — the existing convention), and otherwise
/// the repeat that started at `a ≤ 0` is already running at the edge (`g = startTime + a`).
enum LoopRetrim {

    /// The window's new state: the source offset (seconds of the FILE) and the IN / OUT bounds
    /// (seconds LOCAL to the new left edge).
    struct Window: Equatable {
        var sourceOffset: Double
        var loopStart: Double
        var loopEnd: Double
    }

    /// `x` modulo `p`, in `[0, p)`; a value within `1e-9` of a whole number of periods is snapped
    /// to 0 so that a round trip (+δ then −δ) returns EXACTLY the initial phase instead of `P − ε`.
    static func phase(_ x: Double, period p: Double) -> Double {
        guard p > 0 else { return 0 }
        let k = (x / p).rounded()
        if abs(x - k * p) < 1e-9 { return 0 }
        let r = x - (x / p).rounded(.down) * p
        return r >= p ? 0 : max(0, r)
    }

    /// The new window of a looping clip whose left edge goes from `startTime` to `newStart`.
    ///
    /// - `sourceOffset`: the clip's, SECONDS OF THE FILE (the point read at the left edge).
    /// - `speedRatio`: > 0 (the model's, 0.0625…16).
    /// - `fileLoopIn` / `fileLoopOut`: the IN / OUT bounds IN THE FILE, seconds of the file
    ///   (@see EditViewModel.clipLoopFileBounds — already clamped to `[0, fileDuration]`).
    ///
    /// `nil` when the loop has no usable period (OUT ≤ IN): the caller then keeps the ordinary
    /// trim. Forwards only — a reversed clip cannot loop (@see SoundObject.canLoop).
    static func anchored(startTime: Double, sourceOffset: Double, speedRatio: Double,
                         fileLoopIn: Double, fileLoopOut: Double, newStart: Double) -> Window? {
        let v = max(speedRatio, 0.0001)
        let period = (fileLoopOut - fileLoopIn) / v           // P, TIMELINE seconds
        guard period > 1e-6 else { return nil }
        let a = (fileLoopIn - sourceOffset) / v               // IN, local to the current edge
        let origin = startTime + min(0, a)                     // g: where a repeat starts
        let phi = phase(newStart - origin, period: period)
        let loopStart = phi == 0 ? 0 : -phi                     // never −0.0
        return Window(sourceOffset: fileLoopIn + phi * v,
                      loopStart: loopStart,
                      loopEnd: loopStart + period)
    }
    // MARK: - Where the bounds are SHOWN

    /// How far the IN/OUT markers are drawn (and grabbed) from where they are STORED, in seconds
    /// local to the block: `k·P` with `k` the smallest whole number of periods that brings IN onto
    /// the block's left edge or after it (`IN + k·P ≥ 0`), 0 when IN is already there.
    ///
    /// Why. After a left trim the anchored retrim (@see `anchored`) leaves IN in `]−P, 0]`: BEFORE the
    /// left edge, where nothing is drawn and nothing can be grabbed — the bounds seemed lost the
    /// moment the edge crossed them. The cycle that follows is the same pattern one period later,
    /// so it is that one that is shown: IN at `IN + k·P`, OUT at `OUT + k·P`, the FIRST cycle that
    /// starts inside the block. Storage and engine are untouched; this is a reading, and the one
    /// function the drawing, the hit test, the hover and the drag preview all call.
    ///
    /// Dragging the marker shown by `d` moves the stored bound by the same `d` (the offset is
    /// carried through the gesture, @see `LoopRangeDragState.shift`).
    ///
    /// A range with no period (OUT ≤ IN) is shown where it is. A block shorter than the distance to
    /// the shown IN has no marker to draw (the caller only draws what falls inside the block):
    /// opening the block again brings them back.
    nonisolated static func displayShift(start: Double, end: Double) -> Double {
        let period = end - start
        guard period > 1e-6, start < -1e-9 else { return 0 }
        // A hair of tolerance so that an IN that lies one whole period before the edge (to the bit)
        // is shown ON the edge instead of one period further.
        let k = max(0, (-start / period - 1e-9).rounded(.up))
        return k * period
    }

    /// `(start, end)` shifted by `displayShift` — the bounds as they are shown — and the shift itself.
    nonisolated static func displayed(start: Double, end: Double) -> (start: Double, end: Double, shift: Double) {
        let shift = displayShift(start: start, end: end)
        return (start + shift, end + shift, shift)
    }

    /// Where the markers stand for a block `duration` seconds long: the shift that brings them onto
    /// the cycle to show, and whether they are PINNED onto the block's edges.
    ///
    /// The cycle shown is the first one that starts at or after the left edge (`displayShift`). When
    /// the block is shorter than the distance to that IN — a crop leaves no cycle boundary inside
    /// it — there is nothing to grab, and the bounds would be lost. Then the cycle shown is the one
    /// that CROSSES the block (the one holding its left edge: IN ≤ 0 < OUT), and since both of its
    /// bounds lie outside the block (IN before the left edge, OUT after the right one) they are
    /// PINNED onto the two edges, where the upper half of an edge stays grabbable
    /// (@see ClipEditZone.resolve). Dragging a pinned marker moves the STORED bound by the hand's
    /// travel, from where it really is. The same function draws, hit-tests, hovers and previews.
    struct MarkerFrame: Equatable {
        var shift: Double
        var pinned: Bool
    }

    nonisolated static func markerFrame(start: Double, end: Double, duration: Double) -> MarkerFrame {
        let period = end - start
        guard period > 1e-6 else { return MarkerFrame(shift: 0, pinned: false) }
        var shift = displayShift(start: start, end: end)
        guard start + shift > duration + 1e-9 else { return MarkerFrame(shift: shift, pinned: false) }
        // No cycle starts inside the block: take the cycle that holds its left edge (one period back
        // when IN had to be pushed; an IN stored past the right edge stays where it is).
        if shift > 0 { shift -= period }
        return MarkerFrame(shift: shift, pinned: true)
    }

    /// The markers' positions (seconds local to the block): the stored bounds + `shift`, onto the
    /// block's edges when `pinned`. For a pinned frame the TRUE positions (unclamped) are the stored
    /// bounds + `shift`; these are the ones that are drawn and hit-tested.
    nonisolated static func markerPositions(start: Double, end: Double, frame: MarkerFrame,
                                            duration: Double) -> (start: Double, end: Double) {
        let a = start + frame.shift, b = end + frame.shift
        guard frame.pinned else { return (a, b) }
        let hi = max(0, duration)
        return (min(max(a, 0), hi), min(max(b, 0), hi))
    }

    // MARK: - The left edge of a LOOPING group

    /// A looping group's new frame: the content's shift and the bounds local to the new edge.
    struct Porthole: Equatable {
        var shift: Double
        var loopStart: Double
        var loopEnd: Double
    }

    /// What keeps the phase of a looping GROUP whose left edge comes to lie at `time`: how far its
    /// content must move (`shift`, the group's own children being what the loop repeats) and its
    /// IN/OUT bounds local to the new edge. The group counterpart of `anchored`: a group has no
    /// file to read at an offset, so the pattern is anchored by laying its content on the repeat
    /// that starts at or before the edge (the bounds come out ≤ 0, like the right half of a cut).
    ///
    /// The grid starts at `min(startTime, IN)`, not at IN: a group whose IN lies inside it plays IN
    /// on its LEFT EDGE.
    ///
    /// `allowEarlier`: false = a cut or a deletion (the edge only ever moves INTO the group, so the
    /// repeat is never before the grid's origin); true = a trim, whose edge may also go OUT beyond
    /// the origin, where the grid carries on backwards — the pattern gains cycles. Then the content
    /// moves by whole periods, and `time` within `1e-9` periods of a repeat counts as ON it, so that
    /// going out and back is the identity.
    ///
    /// `nil` when the loop has no period (OUT − IN ≤ 1 ms).
    nonisolated static func porthole(startTime: Double, loopStart a: Double, loopEnd b: Double,
                         at time: Double, allowEarlier: Bool) -> Porthole? {
        let period = b - a
        guard period > 0.001 else { return nil }
        let inAbs  = startTime + a                      // the IN point, in timeline time
        let origin = min(startTime, inAbs)              // where the engine's repeats start
        let x = (time - origin) / period
        var k: Double
        if allowEarlier {
            let r = x.rounded()
            k = abs(x - r) < 1e-9 ? r : x.rounded(.down)
        } else {
            k = max(0, x.rounded(.down))
        }
        if k == 0 { k = 0 }                             // never −0.0
        let newInAbs = origin + k * period
        let loopStart = newInAbs - time
        return Porthole(shift: newInAbs - inAbs,
                        loopStart: loopStart == 0 ? 0 : loopStart,
                        loopEnd: loopStart + period)
    }
}
