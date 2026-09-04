import SwiftUI

/// A block's horizontal sub-range (in the canvas's 'content' coordinates), bounded by the
/// visible portion of the viewport. It keeps a tool's controls (volume/pan) reachable when the
/// block overflows the view — a very wide clip, or one scrolled to the point where the edge
/// anchoring the controls is off screen. It returns the block's full range if it fits entirely
/// in the view (so it has no effect in the common case). Used identically by the rendering
/// (SoundBlockView / GroupBlockView) and by the gestures' hit-testing (tap/drag) so that they
func visibleSpan(blockX: Double, blockWidth: Double,
                 scrollOffsetX: CGFloat, viewportWidth: CGFloat) -> (x: Double, width: Double) {
    let x0 = max(blockX, Double(scrollOffsetX))
    let x1 = min(blockX + blockWidth, Double(scrollOffsetX) + Double(viewportWidth))
    guard x1 > x0 else { return (blockX, blockWidth) }
    return (x0, x1 - x0)
}

struct ToolVolumeLayer: View {
    let object: SoundObject
    var showFullOverlay: Bool = true
    // stay aligned.
    // The display is driven by the parent (toolHoveredID through updateToolHover): the block no
    var forceShow: Bool = false
    /// longer detects the hover itself. The cursor is handled by updateCursor at canvas level.
    /// The block's visible sub-window (in coordinates LOCAL to the block) on which to lay the
    var span: (x: Double, width: Double)? = nil

    private var volumeLevelString: String {
        if object.volume <= -96 { return "-∞ dB" }
        return String(format: "%.0f dB", object.volume)
    }

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .overlay {
                if forceShow && showFullOverlay {
                    ZStack(alignment: .topLeading) {
                        // A full-block veil: it signals volume mode over the whole clip.
                        Color.black.opacity(0.80)
                        // The controls (mute / ± / level) bounded by the block's visible portion.
                        GeometryReader { geo in
                            let sx = span?.x ?? 0
                            let sw = span?.width ?? geo.size.width
                            ZStack(alignment: .topLeading) {
                                if object.isMuted {
                                    Color.red.opacity(0.22).frame(width: sw * 0.4)
                                }
                                HStack(spacing: 0) {
                                    // — Mute (40%) —
                                    ZStack {
                                        VStack(spacing: 1) {
                                            Image(systemName: object.isMuted ? "speaker.slash.fill" : "speaker.wave.2")
                                                .font(.system(size: 9))
                                            Text(object.isMuted ? L("common.muteBadge") : "M")
                                                .font(.system(size: 8, weight: .bold))
                                        }
                                        .foregroundStyle(object.isMuted ? Color.red : Color.white.opacity(0.6))
                                    }
                                    .frame(width: sw * 0.4)

                                    Rectangle().fill(Color.white.opacity(0.2)).frame(width: 1)

                                    // — +/− (20%) —
                                    VStack(spacing: 0) {
                                        Text(verbatim: "+")
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundStyle(.white)
                                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                                        Rectangle().fill(Color.white.opacity(0.2)).frame(height: 1)
                                        Text(verbatim: "−")
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundStyle(.white)
                                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    }
                                    .frame(width: sw * 0.2 - 2)

                                    Rectangle().fill(Color.white.opacity(0.2)).frame(width: 1)

                                    // — Drag (40%) —
                                    ZStack {
                                        VStack(spacing: 2) {
                                            Text(volumeLevelString)
                                                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                                .foregroundStyle(object.isMuted ? Color.red.opacity(0.8) : Color.white)
                                            Image(systemName: "arrow.up.arrow.down")
                                                .font(.system(size: 7))
                                                .foregroundStyle(Color.white.opacity(0.4))
                                        }
                                    }
                                    .frame(width: sw * 0.4 - 2)
                                }
                                .frame(width: sw)
                            }
                            .frame(width: sw, height: geo.size.height, alignment: .topLeading)
                            .offset(x: sx)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .allowsHitTesting(false)
                }
            }
    }
}

// MARK: - Minimal overlay (selected clips not hovered, or clips < 50px wide)

struct ToolVolumeLayerMinimal: View {
    let object: SoundObject

    private var volumeLevelString: String {
        if object.volume <= -96 { return "-∞" }
        return String(format: "%.0f dB", object.volume)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.65)
            if object.isMuted { Color.red.opacity(0.20) }
            Text(volumeLevelString)
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .foregroundStyle(object.isMuted ? Color.red.opacity(0.85) : Color.white.opacity(0.9))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .padding(.horizontal, 2)
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .allowsHitTesting(false)
    }
}
