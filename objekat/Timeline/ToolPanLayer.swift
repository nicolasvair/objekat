import SwiftUI

struct ToolPanLayer: View {
    let object: SoundObject
    // The display is driven by the parent (toolHoveredID / isSelected). The cursor is handled by
    // updateCursor at canvas level — the block no longer detects the hover itself.
    var alwaysShowOverlay: Bool = false
    /// The block's visible sub-window (in LOCAL coordinates) on which to lay the pan panel, so that
    /// it stays reachable when the block overflows the viewport. nil = the whole block.
    var span: (x: Double, width: Double)? = nil

    private var panString: String {
        let p = object.pan
        if abs(p) < 0.01 { return "C" }
        return p < 0 ? "L \(Int(-p * 100))%" : "R \(Int(p * 100))%"
    }

    /// The knob's diameter: bounded by the block's visible width and by its height (less the room
    /// for the label), so as to stay readable from a tiny clip to a full-screen one.
    private func knobSize(_ visibleWidth: Double, _ height: Double) -> Double {
        max(14, min(34, min(visibleWidth - 8, height - 18)))
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
                                .fill(.black.opacity(0.80))
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
struct PanKnob: View {
    let pan: Float

    /// Half the angular travel (in degrees) on either side of the centre.
    private static let sweep: Double = 135

    var body: some View {
        Canvas { ctx, size in
            let r = min(size.width, size.height) / 2
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let ringR = r - 1.5
            let value = Double(max(-1, min(1, pan)))

            // The full travel (the track)
            // The reference: 0° = 3 o'clock, −90° = 12 o'clock (y downwards); the travel runs from
            // −90−135 to −90+135, an arc opening downwards, like a console knob.
            var track = Path()
            track.addArc(center: c, radius: ringR,
                         startAngle: .degrees(-90 - Self.sweep),
                         endAngle: .degrees(-90 + Self.sweep),
                         clockwise: false)
            ctx.stroke(track, with: .color(.white.opacity(0.22)),
                       style: StrokeStyle(lineWidth: 2.5, lineCap: .round))

            // The portion covered from the centre (12 o'clock) → the L/R offset reads at once
            if abs(value) > 0.005 {
                let end = -90 + value * Self.sweep
                var arc = Path()
                arc.addArc(center: c, radius: ringR,
                           startAngle: .degrees(-90), endAngle: .degrees(end),
                           clockwise: value < 0)
                ctx.stroke(arc, with: .color(.white.opacity(0.85)),
                           style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            }

            // The centre mark
            var center = Path()
            center.move(to: CGPoint(x: c.x, y: c.y - ringR - 0.5))
            center.addLine(to: CGPoint(x: c.x, y: c.y - ringR + 3))
            ctx.stroke(center, with: .color(.white.opacity(0.35)), lineWidth: 1)

            // The index
            let a = (-90 + value * Self.sweep) * .pi / 180
            var needle = Path()
            needle.move(to: CGPoint(x: c.x + cos(a) * (ringR - 6.5), y: c.y + sin(a) * (ringR - 6.5)))
            needle.addLine(to: CGPoint(x: c.x + cos(a) * (ringR - 1.5), y: c.y + sin(a) * (ringR - 1.5)))
            ctx.stroke(needle, with: .color(.white),
                       style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }
    }
}
