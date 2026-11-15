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
}
