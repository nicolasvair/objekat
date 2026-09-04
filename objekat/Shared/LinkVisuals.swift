import SwiftUI

// MARK: - Semantic colours of the app's "links"
//
// A single convention shared by the whole UI to show that one element is tied to another:
//   • purple = linked sound objects (placements sharing the same definition)
//   • yellow = linked plugins (the same parameters synced between instances)
//   • red    = sends (routing towards an aux)
//
// Every line or dot drawn in the timeline or the inspector takes its colour from here, so that
// one place stays consistent with another.
enum LinkColor {
    static let soundObject = Color.purple
    static let plugin      = Color.yellow
    static let send        = Color.red
}

// MARK: - Reusable link paths
//
/// A timeline block as the link paths see it: its box AND the roundness of its corners.
/// The two travel together because the roundness depends on the NATURE of the block (clip = 4,
/// group/aux = 20, see `SoundObject.blockCornerRadius`): without it, every halo fell back on a
/// clip's radius and spilled out of a group's corners.
struct LinkTarget {
    var rect: CGRect
    var cornerRadius: Double

    init(_ rect: CGRect, cornerRadius: Double) {
        self.rect = rect
        self.cornerRadius = cornerRadius
    }
}

// The link curves (red sends, yellow linked plugins, purple linked sound objects) all shared
// the same S-shaped sweep, copied and pasted. Factored out here: one path, and the colour
// carries the meaning (see LinkColor).
enum LinkOverlay {
    /// Adds to `path` an S-shaped link curve between two points (the sweep every link shares).
    static func appendCurve(_ path: inout Path, from src: CGPoint, to dst: CGPoint) {
        let dy = abs(dst.y - src.y) * 0.4 + 24
        let up = src.y > dst.y
        path.move(to: src)
        path.addCurve(to: dst,
                      control1: CGPoint(x: src.x, y: src.y + (up ? -dy : dy)),
                      control2: CGPoint(x: dst.x, y: dst.y + (up ? dy : -dy)))
    }

    /// Draws a "star" of links: an active halo around `source`, a discreet halo around each
    /// `member`, and a curve from the source to each of them. `member` excludes the source.
    /// Reused for linked plugins (yellow) and linked sound objects (purple).
    static func drawStar(in ctx: GraphicsContext, source: LinkTarget,
                         members: [LinkTarget], color: Color) {
        drawHalo(in: ctx, target: source, color: color, active: true)
        for t in members { drawHalo(in: ctx, target: t, color: color, active: false) }

        let src = CGPoint(x: source.rect.midX, y: source.rect.midY)
        for t in members {
            var path = Path()
            appendCurve(&path, from: src, to: CGPoint(x: t.rect.midX, y: t.rect.midY))
            ctx.stroke(path, with: .color(color.opacity(0.30)), lineWidth: 9)
            ctx.stroke(path, with: .color(color.opacity(0.55)), lineWidth: 2.4)
        }
    }

    /// Draws a CHAIN of links: a single line joining each block to the next (instead of a star
    /// from each to all, which becomes an unreadable mesh in a multiple selection). A halo
    /// around each member (`active` = selected, more pronounced). `nodes` has to be pre-ordered
    /// (typically along the timeline) so that the chain follows a readable path.
    static func drawChain(in ctx: GraphicsContext,
                          nodes: [(target: LinkTarget, active: Bool)], color: Color) {
        for n in nodes { drawHalo(in: ctx, target: n.target, color: color, active: n.active) }
        guard nodes.count > 1 else { return }
        for i in 0..<(nodes.count - 1) {
            var path = Path()
            appendCurve(&path,
                        from: CGPoint(x: nodes[i].target.rect.midX, y: nodes[i].target.rect.midY),
                        to:   CGPoint(x: nodes[i + 1].target.rect.midX, y: nodes[i + 1].target.rect.midY))
            ctx.stroke(path, with: .color(color.opacity(0.30)), lineWidth: 9)
            ctx.stroke(path, with: .color(color.opacity(0.55)), lineWidth: 2.4)
        }
    }

    /// Halo/highlight of a linked block (active = the source we start from, more pronounced).
    /// The roundness comes from the block, it is not constant: a fixed-radius frame laid around a
    /// GROUP (r = 20) cut through its four round corners and read as a square rectangle slapped on
    /// askew. The radii follow the `inset` so as to stay concentric.
    static func drawHalo(in ctx: GraphicsContext, target: LinkTarget, color: Color, active: Bool) {
        let r = target.rect
        let box = Path(roundedRect: r.insetBy(dx: -3, dy: -3),
                       cornerRadius: target.cornerRadius + 3)
        if active {
            let glow = Path(roundedRect: r.insetBy(dx: -6, dy: -6),
                            cornerRadius: target.cornerRadius + 6)
            ctx.stroke(glow, with: .color(color.opacity(0.25)), lineWidth: 6)
            ctx.fill(box, with: .color(color.opacity(0.15)))
            ctx.stroke(box, with: .color(color.opacity(0.95)), lineWidth: 2.5)
        } else {
            ctx.fill(box, with: .color(color.opacity(0.10)))
            ctx.stroke(box, with: .color(color.opacity(0.85)), lineWidth: 2)
        }
    }
}

// MARK: - The "link" badge (dragging a linked plugin)

/// A "link" icon in a round coloured badge, following the cursor while a plugin is dragged with
/// ⌘ (yellow = linked plugin). A small component of its own for that single case (a flying hint).
struct LinkBadge: View {
    var color: Color
    var size: CGFloat = 11

    var body: some View {
        Image(systemName: "link")
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(.black)
            .padding(size * 0.45)
            .background(Circle().fill(color))
    }
}
