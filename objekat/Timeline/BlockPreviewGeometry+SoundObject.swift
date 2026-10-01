import Foundation

extension BlockPreviewGeometry {

    /// The geometry of `object`, from its stored values and the gesture's. `absStart` is the
    /// block's ABSOLUTE start (a child of an open group is stored relative to its parent).
    /// `kind` follows the object: a group is a group, anything else a clip.
    init(object: SoundObject, absStart: Double? = nil, pixelsPerSecond: Double,
         previewOffset: (dx: Double, dy: Double)? = nil,
         resizeDX: Double = 0, trimDX: Double = 0,
         previewFadeIn: Double? = nil, previewFadeOut: Double? = nil,
         previewFadeInCurve: FadeCurve? = nil, previewFadeOutCurve: FadeCurve? = nil,
         previewLoopRange: (start: Double, end: Double)? = nil) {
        self.init(kind: object.isGroup ? .group : .clip,
                  startTime: absStart ?? object.startTime, duration: object.duration,
                  sourceOffset: object.sourceOffset, speedRatio: object.speedRatio,
                  isReversed: object.isReversed,
                  fadeIn: object.fadeIn, fadeOut: object.fadeOut,
                  fadeInCurve: object.fadeInCurve, fadeOutCurve: object.fadeOutCurve,
                  pixelsPerSecond: pixelsPerSecond,
                  offsetDX: previewOffset?.dx ?? 0, offsetDY: previewOffset?.dy ?? 0,
                  resizeDX: resizeDX, trimDX: trimDX,
                  previewFadeIn: previewFadeIn, previewFadeOut: previewFadeOut,
                  previewFadeInCurve: previewFadeInCurve, previewFadeOutCurve: previewFadeOutCurve,
                  previewLoopRange: previewLoopRange)
    }
}
