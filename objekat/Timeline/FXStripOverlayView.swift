import AppKit
import SwiftUI

/// The FX tool's hover: WHICH object shows its mini signal view, in which part of its block, and
/// what the hand is on. A store of its own, written by the canvas's hover handler and read by the
/// overlay alone — so a hover under the FX tool redraws one small Canvas, never the timeline
/// (@see TimelineHoverStore for the same reasoning).
@MainActor @Observable
final class FXStripHoverStore {
    struct Shown: Equatable {
        let objectID: UUID
        /// The part of the block the drawing is laid in, content coordinates: the block's visible
        /// span, under its name (@see TimelineView.fxStripArea).
        var area: CGRect
        /// The box under the pointer, if any.
        var hover: FXStripLayout.Hit?
    }
    private(set) var shown: Shown?

    func set(_ s: Shown?) { if shown != s { shown = s } }
}

/// The mini signal view, drawn INSIDE the hovered block (@see FXStripLayout): the content veiled,
/// then wires, boxes (or pastilles with the plugin's initials), the FX link frames. Pure drawing — the canvas resolves the hover and the
/// clicks on the same `FXStripLayout.layout` (@see TimelineView+TapHandler, `handleFXTap`).
struct FXStripOverlayView: View {
    let viewModel: EditViewModel
    let store: FXStripHoverStore

    /// The block's content shows through at about a quarter.
    static let veilOpacity: Double = 0.75

    var body: some View {
        if viewModel.activeTool == .toolFX, let s = store.shown, s.area.width > 0, s.area.height > 0 {
            let model = viewModel.fxStripModel(objectID: s.objectID)
            let area = s.area
            Canvas { ctx, _ in
                ctx.translateBy(x: -area.minX, y: -area.minY)
                Self.draw(&ctx, model: model, area: area, hover: s.hover)
            }
            .frame(width: area.width, height: area.height)
            .offset(x: area.minX, y: area.minY)
            .allowsHitTesting(false)
        }
    }

    static func draw(_ ctx: inout GraphicsContext, model: FXStripModel, area: CGRect,
                     hover: FXStripLayout.Hit?) {
        ctx.fill(Path(roundedRect: area, cornerRadius: 3), with: .color(.black.opacity(veilOpacity)))
        let lay = FXStripLayout.layout(model, in: area)
        let ink = Color.white

        switch lay.detail {
        case .none:
            return
        case .empty, .count:
            guard let r = lay.textRect else { return }
            let s = lay.detail == .empty ? L("fx.tool.noPlugins") : "\(model.plugInCount) FX"
            drawFitted(&ctx, s, in: r, size: 10, color: ink.opacity(lay.detail == .empty ? 0.55 : 0.85),
                       centred: true)
            return
        case .labeled, .dots, .foldedDots:
            break
        }

        // Wires.
        var wires = Path()
        for w in lay.wires {
            guard let first = w.first else { continue }
            wires.move(to: first)
            for p in w.dropFirst() { wires.addLine(to: p) }
        }
        ctx.stroke(wires, with: .color(ink.opacity(0.55)), lineWidth: 1)

        // FX link frames.
        for f in lay.bins where f.bin < model.bins.count {
            let detached = model.bins[f.bin].isDetached
            ctx.stroke(Path(roundedRect: f.rect, cornerRadius: 3), with: .color(.accentColor.opacity(0.85)),
                       style: StrokeStyle(lineWidth: 1, dash: detached ? [3, 2] : []))
        }

        // Boxes.
        for b in lay.boxes {
            let e = model.entries[b.entry]
            let hovered = hover?.entry == b.entry
            let off = !e.isEnabled && (e.kind == .plugin || e.kind == .instrument)
            let rect = b.rect
            if lay.detail == .labeled {
                let shape = Path(roundedRect: rect, cornerRadius: 3)
                ctx.fill(shape, with: .color(Color(white: off ? 0.16 : 0.24).opacity(0.95)))
                ctx.stroke(shape, with: .color(ink.opacity(hovered ? 0.7 : 0.28)), lineWidth: 1)
                var textX = rect.minX + 4
                if e.kind == .gainStage {
                    let gs = min(rect.height - 4, 10)
                    var glyph = ctx.resolve(Image(systemName: "dial.low"))
                    glyph.shading = .color(ink.opacity(0.6))
                    ctx.draw(glyph, in: CGRect(x: rect.minX + 3, y: rect.midY - gs / 2, width: gs, height: gs))
                    textX = rect.minX + 4 + gs
                }
                let label = b.folded ? "∥ \(e.detail.count)" : e.name
                let tr = CGRect(x: textX, y: rect.minY, width: max(0, rect.maxX - 3 - textX), height: rect.height)
                drawFitted(&ctx, label, in: tr, size: 9.5,
                           color: ink.opacity(off ? 0.4 : 0.9), centred: false)
            } else {
                // A pastille: a rounded rectangle like the signal view's cards (not a capsule), the
                // plugin's INITIALS inside. A parallel block folded into one wears a doubled outline.
                let radius = min(rect.height * 0.3, 4)
                let shape = Path(roundedRect: rect, cornerRadius: radius)
                ctx.fill(shape, with: .color(Color(white: off ? 0.12 : 0.24).opacity(0.95)))
                ctx.stroke(shape, with: .color(ink.opacity(off ? 0.35 : 0.6)), lineWidth: 1)
                if b.folded {
                    let inner = rect.insetBy(dx: 1.75, dy: 1.75)
                    if inner.width > 1, inner.height > 1 {
                        ctx.stroke(Path(roundedRect: inner, cornerRadius: max(1, radius - 1.5)),
                                   with: .color(ink.opacity(0.4)), lineWidth: 0.75)
                    }
                }
                let label = b.folded ? "∥" : (e.kind == .gainStage ? "dB" : FXStripLayout.initials(e.name))
                drawFitted(&ctx, label, in: rect.insetBy(dx: 1, dy: 0), size: max(6, rect.height * 0.55),
                           color: ink.opacity(off ? 0.4 : 0.95), centred: true)
                if hovered {
                    ctx.stroke(Path(roundedRect: rect.insetBy(dx: -1.5, dy: -1.5), cornerRadius: radius + 1.5),
                               with: .color(.accentColor), lineWidth: 1)
                }
            }
        }
    }

    /// `s` on one line inside `r`, cut with an ellipsis to fit (measured, not guessed).
    private static func drawFitted(_ ctx: inout GraphicsContext, _ s: String, in r: CGRect,
                                   size: CGFloat, color: Color, centred: Bool) {
        guard r.width > 4, r.height > 6, !s.isEmpty else { return }
        func resolved(_ t: String) -> GraphicsContext.ResolvedText {
            ctx.resolve(Text(verbatim: t).font(.system(size: size, weight: .medium)).foregroundColor(color))
        }
        let unbounded = CGSize(width: CGFloat.greatestFiniteMagnitude, height: r.height)
        var text = resolved(s)
        if text.measure(in: unbounded).width > r.width {
            let chars = Array(s)
            var lo = 0, hi = chars.count
            while lo < hi {
                let mid = (lo + hi + 1) / 2
                if resolved(String(chars[0..<mid]) + "…").measure(in: unbounded).width <= r.width { lo = mid } else { hi = mid - 1 }
            }
            guard lo > 0 else { return }
            text = resolved(String(chars[0..<lo]) + "…")
        }
        var c = ctx
        c.clip(to: Path(r))
        if centred {
            c.draw(text, at: CGPoint(x: r.midX, y: r.midY), anchor: .center)
        } else {
            c.draw(text, at: CGPoint(x: r.minX, y: r.midY), anchor: .leading)
        }
    }
}
