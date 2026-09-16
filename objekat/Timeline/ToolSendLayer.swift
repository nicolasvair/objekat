import SwiftUI

// The columns' geometry — `sendColWidth`, `sendToggleZoneHeight`, `sendColumnIndex` — lives in
// SendColumns.swift, where it depends on nothing and can be asserted with no screen.

/// The Send tool's overlay: one send knob per aux overlapping the clip, in columns side by
/// side (left → right, in lane order). Inside each column, the content is aligned to the
/// BOTTOM (the knob, the name plus the level, then on/off right at the bottom) for better
/// readability. Purely visual (no hit-testing) — the gestures are handled at canvas level.
///
/// The columns set off from the block's left edge EXCEPT where a crossfade holds it: a zone is
/// the span two objects SHARE (@see EditViewModel+Crossfade), so the knobs of the right-hand one
/// were drawn over pixels its neighbour occupies too — one saw them, and the click landed on
/// whichever of the pair the hit-test reached first. They start after the shared span instead,
/// which is the first pixel that belongs to this object alone.
struct ToolSendLayer: View {
    let rows: [SendRow]
    let blockWidth: Double
    let blockHeight: Double
    /// The block's leading span shared with a crossfaded neighbour, in px (0 = no crossfade
    /// there). The SAME value the hit-testing offsets by (@see sendRowHit): two readings of one
    /// geometry, so a knob one can see is a knob one can turn.
    var leadingInset: Double = 0

    /// What is left of the block once the shared span is taken off it. The columns are laid out
    /// in there, so a heavily crossfaded edge makes them thinner rather than pushing them out.
    private var usableWidth: Double { max(0, blockWidth - leadingInset) }
    private var colW: Double { sendColWidth(blockWidth: usableWidth, count: rows.count) }

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .overlay(alignment: .topLeading) {
                if !rows.isEmpty {
                    HStack(spacing: 0) {
                        ForEach(rows) { row in
                            sendColView(row)
                                .frame(width: colW)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, leadingInset)
                    .allowsHitTesting(false)
                }
            }
    }

    @ViewBuilder
    private func sendColView(_ row: SendRow) -> some View {
        let routed = row.enabled && row.level > sendMinDb
        let accent: Color = routed ? .red : .white.opacity(0.35)
        let showText = colW >= 34 && blockHeight >= 48
        let knobD = max(11, min(colW - 12, blockHeight - sendToggleZoneHeight - (showText ? 32 : 6), 26))

        ZStack {
            // The column's background: emphasised if focused.
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.black.opacity(row.focused ? 0.82 : 0.66))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.red.opacity(row.focused ? 0.9 : 0), lineWidth: 1.5)
                )
                .padding(1)

            // The content aligned to the bottom (better readability).
            VStack(spacing: 2) {
                Spacer(minLength: 0)

                // The knob. A level driven by a CURVE is shown faded and carries the automation
                // glyph: it still SAYS what the send is doing — the value it shows is the static
                // one the curve has taken over from — but it no longer answers the hand
                // (@see EditViewModel.selectedSendersWithFreeLevel). The same reading as the signal
                // view's `automationLocked`, on the other surface one reaches a send from.
                ZStack {
                    knob(level: row.level, enabled: routed, focused: row.focused)
                        .opacity(row.automated ? 0.35 : 1)
                    // The glyph stays BRIGHT over the faded knob: the fading says 'this does not
                    // answer', the glyph says why, and a reason as dim as the thing it explains
                    // explains nothing.
                    if row.automated {
                        Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
                            .font(.system(size: max(7, knobD * 0.5), weight: .bold))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                }
                .frame(width: knobD, height: knobD)

                // The name plus the level.
                if showText {
                    Text(row.label)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                        .padding(.horizontal, 2)
                    Text(levelString(row.level))
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(routed ? Color.red.opacity(0.95) : .white.opacity(0.6))
                        .opacity(row.automated ? 0.35 : 1)
                }

                // The on/off button (right at the bottom — its clickable area goes through the canvas).
                ZStack {
                    Circle().stroke(accent.opacity(0.8), lineWidth: 2)
                    if routed { Circle().fill(Color.red).padding(3) }
                }
                .frame(width: 16, height: 16)
                .frame(height: sendToggleZoneHeight)
            }
            .padding(.vertical, 2)
        }
    }

    /// A rotary knob: a background arc plus a value arc (red), and a pointer. A 270° sweep.
    private func knob(level: Float, enabled: Bool, focused: Bool) -> some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let r = min(size.width, size.height) / 2 - 2
            let startA = Angle.degrees(135)
            let sweep  = 270.0
            let frac   = Double((level.clamped(to: sendMinDb...sendMaxDb) - sendMinDb)
                                 / (sendMaxDb - sendMinDb))
            let valA   = Angle.degrees(135 + sweep * frac)

            // The background arc
            var bg = Path()
            bg.addArc(center: c, radius: r, startAngle: startA,
                      endAngle: .degrees(135 + sweep), clockwise: false)
            ctx.stroke(bg, with: .color(.white.opacity(0.22)),
                       style: StrokeStyle(lineWidth: 2.5, lineCap: .round))

            // The value arc
            if frac > 0.001 {
                var val = Path()
                val.addArc(center: c, radius: r, startAngle: startA,
                           endAngle: valA, clockwise: false)
                let col: Color = enabled ? .red : .white.opacity(0.4)
                if focused && enabled {
                    ctx.stroke(val, with: .color(.red.opacity(0.35)),
                               style: StrokeStyle(lineWidth: 6, lineCap: .round))
                }
                ctx.stroke(val, with: .color(col),
                           style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            }

            // The pointer
            let px = c.x + cos(valA.radians) * r
            let py = c.y + sin(valA.radians) * r
            ctx.fill(Path(ellipseIn: CGRect(x: px - 2.2, y: py - 2.2, width: 4.4, height: 4.4)),
                     with: .color(enabled ? .red : .white.opacity(0.6)))
        }
    }

    private func levelString(_ db: Float) -> String {
        db <= sendMinDb ? "-∞" : String(format: "%.0f", db)
    }
}
