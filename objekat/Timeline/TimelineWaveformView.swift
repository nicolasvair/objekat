import SwiftUI

struct TimelineWaveformView: View {
    var waveformCache: WaveformCache
    let filePath: String
    let sourceOffset: Double
    let pixelsPerSecond: Double
    let scrollOffsetX: CGFloat
    let viewportWidth: CGFloat
    let xPos: Double
    let stemColor: Color
    let isSelected: Bool
    // Shaping at render time (the effective values, a drag preview included).
    let clipDuration: Double
    let speedRatio: Double
    let isReversed: Bool
    let volumeDb: Float
    let fadeIn: Double
    let fadeOut: Double
    let isMuted: Bool
    let waveformDisplayDB: Double
    /// The loop's IN/OUT bounds in seconds LOCAL to the block (`nil` = no loop).
    /// @see SoundObject.loopMarkerLocalRange
    var loopRange: (start: Double, end: Double)? = nil

    var body: some View {
        if let fileDuration = waveformCache.duration(for: filePath), fileDuration > 0 {
            let _ = fileDuration   // an explicit guard: no drawing without a loaded length.
            Canvas { ctx, size in
                WaveformDrawing.draw(
                    into: ctx, size: size,
                    waveformCache: waveformCache, filePath: filePath,
                    sourceOffset: sourceOffset, pixelsPerSecond: pixelsPerSecond,
                    scrollOffsetX: scrollOffsetX, viewportWidth: viewportWidth, xPos: xPos,
                    stemColor: stemColor, isSelected: isSelected,
                    clipDuration: clipDuration, speedRatio: speedRatio, isReversed: isReversed,
                    volumeDb: volumeDb, fadeIn: fadeIn, fadeOut: fadeOut,
                    isMuted: isMuted, waveformDisplayDB: waveformDisplayDB, loopRange: loopRange)
            }
            .allowsHitTesting(false)
        }
    }
}
