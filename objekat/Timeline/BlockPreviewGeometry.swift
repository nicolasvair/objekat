import Foundation

/// WHERE and HOW a block is drawn while a gesture is under way on it: the one definition the
/// rich views (`SoundBlockView`, `GroupBlockView`) and the batched Canvas read, so that a block
/// that changes regime — or the same block drawn by the two — can never disagree with itself.
///
/// It takes the block's MODEL values (what is stored) and the GESTURE's values (what the hand is
/// about to make of it: the move's offset, a trim / resize in whole pixels, a fade being pulled,
/// the loop bounds being dragged) and answers what is on screen: the effective duration, fades and
/// curves, the pixel rect, the source offset the waveform is read from, the composite's start.
/// Nothing here writes the model — a preview is a READING of the gesture's state, never an edit.
///
/// Foundation only, on purpose: it is compiled alone by `tools/test_block_preview_geometry.swift`
/// against a verbatim copy of the formulas it replaced. With NO gesture on the block (`isNeutral`)
/// every answer is the stored value, to the bit — which is what lets a block leave the Canvas for
/// a view, or the other way round, with nothing shifting on the screen.
///
/// The clip and the group differ in four places, and `kind` is only for them: a clip COMPRESSES its
/// fades against a shrinking length (the same rule as `updateTrim` / `updateDuration`), a group
/// does not; a clip's width floors at 1 px under a resize and 2 otherwise, a group's at 2; a clip
/// pins its right edge when a left trim squeezes it under 2 px; and only a clip has a source offset.
nonisolated struct BlockPreviewGeometry {

    enum Kind { case clip, group }

    // MARK: Model
    var kind: Kind
    var startTime: Double
    var duration: Double
    var sourceOffset: Double = 0
    var speedRatio: Double = 1
    var isReversed: Bool = false
    var fadeIn: Double
    var fadeOut: Double
    var fadeInCurve: FadeCurve
    var fadeOutCurve: FadeCurve

    // MARK: Gesture
    var pixelsPerSecond: Double
    /// The move's travel in px (0 = not moving).
    var offsetDX: Double = 0
    var offsetDY: Double = 0
    /// Right edge travel in px (resize, a spilling fade-out) and left edge travel in WHOLE px (trim,
    /// a spilling fade-in) — @see `TimelineView.previewResizeDX` / `previewTrimDX`.
    var resizeDX: Double = 0
    var trimDX: Double = 0
    var previewFadeIn: Double? = nil
    var previewFadeOut: Double? = nil
    var previewFadeInCurve: FadeCurve? = nil
    var previewFadeOutCurve: FadeCurve? = nil
    /// The loop bounds being dragged (or the stored ones), seconds local to the block. nil = no loop.
    var previewLoopRange: (start: Double, end: Double)? = nil

    /// True when nothing is under way: every answer below is then the stored value.
    var isNeutral: Bool {
        offsetDX == 0 && offsetDY == 0 && resizeDX == 0 && trimDX == 0
            && previewFadeIn == nil && previewFadeOut == nil
            && previewFadeInCurve == nil && previewFadeOutCurve == nil
    }

    // MARK: Length

    var effectiveDuration: Double {
        max(0.01, duration + (resizeDX - trimDX) / pixelsPerSecond)
    }

    // MARK: Fades

    /// The fades on screen, in seconds: the dragged fade first, then — for a clip — the same
    /// compression logic as `updateTrim` / `updateDuration`, so the preview reflects the crop in
    /// real time. A group shows them as they are.
    var effectiveFades: (fi: Double, fo: Double) {
        var fi = previewFadeIn ?? fadeIn
        var fo = previewFadeOut ?? fadeOut
        guard kind == .clip else { return (fi, fo) }
        let D = effectiveDuration
        if trimDX != 0 {
            // crop in, left
            if D < fo { fo = D; fi = 0 }
            else if D < fi + fo { fi = D - fo }
        } else if resizeDX != 0 {
            // crop out, right
            if D < fi { fi = D; fo = 0 }
            else if D < fi + fo { fo = D - fi }
        } else {
            // no trim/resize: the dragged fade takes priority, the other gives way
            if fi + fo > D {
                if previewFadeIn != nil { fo = max(0, D - fi) }
                else if previewFadeOut != nil { fi = max(0, D - fo) }
                else { fi = min(fi, D * 0.5); fo = min(fo, D * 0.5) }
            }
        }
        return (fi, fo)
    }
    var effectiveFadeIn: Double { effectiveFades.fi }
    var effectiveFadeOut: Double { effectiveFades.fo }
    var fadeInPx: Double { effectiveFadeIn * pixelsPerSecond }
    var fadeOutPx: Double { effectiveFadeOut * pixelsPerSecond }
    /// The shape being dragged takes priority over the stored one, exactly as the length does.
    var effectiveFadeInCurve: FadeCurve { previewFadeInCurve ?? fadeInCurve }
    var effectiveFadeOutCurve: FadeCurve { previewFadeOutCurve ?? fadeOutCurve }

    // MARK: Loop

    /// The loop's IN / OUT bounds in px local to the block. nil = does not loop.
    var loopMarkerPx: (start: Double, end: Double)? {
        guard let r = previewLoopRange else { return nil }
        return (r.start * pixelsPerSecond, r.end * pixelsPerSecond)
    }

    // MARK: Place

    private var naturalWidth: Double {
        duration * pixelsPerSecond + resizeDX - trimDX
    }

    var blockWidth: Double {
        switch kind {
        case .clip:
            if resizeDX != 0 { return max(naturalWidth, 1) }
            return max(naturalWidth, 2)
        case .group:
            return max(naturalWidth, 2)
        }
    }

    /// The block's left edge in canvas px. `startTime` is the ABSOLUTE start (a child of an open
    /// group passes its absolute one).
    var xPos: Double {
        switch kind {
        case .clip:
            // Anchoring on the right edge (a minimum width of 2 px) is reserved for a left trim
            // under way: the right edge is the fixed anchor while the left one follows the mouse.
            if naturalWidth < 2 && trimDX != 0 {
                return startTime * pixelsPerSecond + duration * pixelsPerSecond - 2 + offsetDX
            }
            return startTime * pixelsPerSecond + trimDX + offsetDX
        case .group:
            return startTime * pixelsPerSecond + trimDX + offsetDX
        }
    }

    func yPos(rulerHeight: Double, displayLane: Int, laneStep: Double) -> Double {
        rulerHeight + Double(displayLane) * laneStep + offsetDY
    }

    // MARK: Content

    /// The source offset the waveform is read from. OUTSIDE a trim under way it is EXACTLY the
    /// stored one (a block moving between the Canvas and a view must not jump). During a trim it
    /// follows the edge to the pixel; in reverse it is the RIGHT edge that governs the source range
    /// (@see `WaveformShaping.retrimmedSourceOffset`).
    var effectiveSourceOffset: Double {
        let moving = isReversed ? resizeDX : trimDX
        guard moving != 0, pixelsPerSecond > 0 else { return sourceOffset }
        let dStart = trimDX / pixelsPerSecond
        let dEnd = resizeDX / pixelsPerSecond
        return WaveformShaping.retrimmedSourceOffset(
            sourceOffset,
            oldStart: startTime, oldDuration: duration,
            newStart: startTime + dStart,
            newDuration: duration - dStart + dEnd,
            speedRatio: speedRatio, isReversed: isReversed)
    }

    /// A group's effective start during a left trim under way: the edge follows the hand but the
    /// children do NOT move (their start is absolute) — it is the window that moves over them. The
    /// composite is aligned on this, not on the stored start.
    var effectiveStartTime: Double {
        guard trimDX != 0, pixelsPerSecond > 0 else { return startTime }
        return startTime + trimDX / pixelsPerSecond
    }
}
