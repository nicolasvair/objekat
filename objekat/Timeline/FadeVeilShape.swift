import SwiftUI

/// The dark veil a block wears over its fade: it covers what the envelope takes AWAY, so its
/// lower edge IS the fade curve. A straight fade therefore still draws the triangle it always
/// drew — the same path, read through `FadeCurve.linear` — and a shaped one bends that edge.
///
/// Sharing ONE definition between the two block views (a clip and a group wear the same veil) is
/// not tidiness: the veil's edge and what one hears both come from `FadeCurve.gain`, so a curve
/// cannot be drawn one way and played another.
struct FadeVeilShape: Shape {
    let curve: FadeCurve
    /// The fade's width in px, already clamped to the block by the caller.
    let widthPx: Double
    let side: FadeSide

    func path(in rect: CGRect) -> Path {
        Self.path(curve: curve, widthPx: widthPx, side: side, in: rect)
    }

    /// The same veil, drawable OUTSIDE a `Shape` — the timeline's batched Canvas draws the blocks
    /// it does not give a SwiftUI view to, and it drew a straight triangle there whatever the
    /// curve said. One definition, so a fade is not shaped when a block is selected and straight
    /// when it is not.
    static func path(curve: FadeCurve, widthPx: Double, side: FadeSide, in rect: CGRect) -> Path {
        var p = Path()
        let w = min(widthPx, rect.width)
        let h = rect.height
        guard w > 0, h > 0 else { return p }
        let n = max(2, min(Int(widthPx.rounded()), 512))

        switch side {
        case .in:
            // Along the top from the block's edge to the end of the fade, then back down the
            // curve: at x = 0 the gain is nil (the veil reaches the floor), at x = w it is full.
            p.move(to: .zero)
            p.addLine(to: CGPoint(x: w, y: 0))
            for i in stride(from: n, through: 0, by: -1) {
                let a = Double(i) / Double(n)
                p.addLine(to: CGPoint(x: a * w, y: h * (1 - curve.gain(a))))
            }
        case .out:
            let x0 = rect.width - w
            p.move(to: CGPoint(x: x0, y: 0))
            p.addLine(to: CGPoint(x: rect.width, y: 0))
            // `alpha` is the fade's PROGRESS and not the elapsed time, on this edge as on the
            // other (@see FadeCurve): the outgoing edge reads the time it has LEFT, which is why
            // a shape means the same thing on both sides.
            for i in stride(from: 0, through: n, by: 1) {
                let a = Double(i) / Double(n)
                p.addLine(to: CGPoint(x: rect.width - a * w, y: h * (1 - curve.gain(a))))
            }
        }
        p.closeSubpath()
        return p
    }
}
