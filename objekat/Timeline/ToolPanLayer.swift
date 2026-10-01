import SwiftUI

struct ToolPanLayer: View {
    let object: SoundObject
    // The display is driven by the parent (toolHoveredID / isSelected). The cursor is handled by
    // updateCursor at canvas level — the block no longer detects the hover itself.
    var alwaysShowOverlay: Bool = false
    /// The block's visible sub-window (in LOCAL coordinates) on which to lay the pan panel, so that
    /// it stays reachable when the block overflows the viewport. nil = the whole block.
    var span: (x: Double, width: Double)? = nil

    private var panString: String { ToolOverlayGeometry.panLabel(pan: object.pan) }

    /// The knob's diameter (@see ToolOverlayGeometry.panKnobSize): bounded by the block's visible
    /// width and by its height, so as to stay readable from a tiny clip to a full-screen one.
    private func knobSize(_ visibleWidth: Double, _ height: Double) -> Double {
        ToolOverlayGeometry.panKnobSize(visibleWidth: visibleWidth, height: height)
    }

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .overlay {
                if alwaysShowOverlay {
                    GeometryReader { geo in
                        let sx = span?.x ?? 0
                        let sw = span?.width ?? geo.size.width
                        ZStack {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(.black.opacity(ToolOverlayGeometry.panVeilOpacity))
                            VStack(spacing: 2) {
                                // The knob: the same display language as the other rotary
                                // controls (aux sends). Everything is VERTICAL like the other
                                // tools — drag, wheel and arrows (up = towards the right).
                                PanKnob(pan: object.pan)
                                    .frame(width: knobSize(sw, geo.size.height),
                                           height: knobSize(sw, geo.size.height))
                                Text(panString)
                                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(.white)
                            }
                        }
                        .frame(width: sw, height: geo.size.height)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .offset(x: sx)
                    }
                    .allowsHitTesting(false)
                }
            }
    }
}

// MARK: - Pan knob

/// The knob: a travel arc (−135°…+135°), the arc covered from the centre (12 o'clock) to the
/// value, an index and a centre mark. Purely graphical — the setting goes through the canvas's drag/scroll.
/// The drawing itself is `drawPanKnob` (ToolOverlayDrawing.swift), which the Canvas blocks share.
struct PanKnob: View {
    let pan: Float

    var body: some View {
        Canvas { ctx, size in
            drawPanKnob(ctx, pan: pan, size: size)
        }
    }
}
