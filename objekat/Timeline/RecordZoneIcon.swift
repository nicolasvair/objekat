import SwiftUI
import AppKit

// MARK: - The [ o ] of a recording zone
//
// A group that has an input carries a record button, centred on its block: a ring and a dot. ONE
// definition of where it stands and what it looks like, read by the three places that need it —
// the batched Canvas (`GroupBlocksCanvas.drawOverlays`, the resting look), the canvas's hit-test
// (`TimelineView.recordIconHit`: the canvas resolves the click, the block is pure drawing) and the
// armed overlay (`ArmedRecordZonesLayer`, the blinking look) — so the three cannot drift apart.
//
//   idle    a ring, a small dot: click to arm
//   absent  the same, pale: the input is not on the card (or the inputs are closed) — no click
//   armed   red, dot filled — drawn by the overlay (it blinks), never by the Canvas

enum RecordZoneIcon {

    enum State: Equatable { case idle, absent, armed }

    static let red = Color(red: 0.92, green: 0.12, blue: 0.14)

    /// The icon's square, centred on the block; nil when the block is too small to carry one.
    static func rect(in block: CGRect) -> CGRect? {
        let d = min(30, (block.height * 0.55).rounded())
        guard d >= 12, block.width >= d + 12 else { return nil }
        return CGRect(x: block.midX - d / 2, y: block.midY - d / 2, width: d, height: d)
    }

    /// What a click can hit: the icon with a little air around it.
    static func hitRect(in block: CGRect) -> CGRect? { rect(in: block)?.insetBy(dx: -4, dy: -4) }

    /// The ring (stroke centre line) and the dot, inside the icon's square.
    static func shapes(in r: CGRect) -> (ring: CGRect, dot: CGRect, lineWidth: CGFloat) {
        let lw = max(1.5, r.width * 0.09)
        let dotD = r.width * 0.42
        return (r.insetBy(dx: lw / 2, dy: lw / 2),
                CGRect(x: r.midX - dotD / 2, y: r.midY - dotD / 2, width: dotD, height: dotD), lw)
    }

    /// The resting look, in the Canvas. `.armed` draws nothing here: the overlay owns it.
    static func draw(into ctx: GraphicsContext, rect: CGRect, state: State) {
        guard state != .armed else { return }
        let s = shapes(in: rect)
        let ink = Color.black.opacity(state == .idle ? 0.55 : 0.2)
        // A pale disc behind it, so that the ring reads over any tint and over a waveform.
        ctx.fill(Path(ellipseIn: rect), with: .color(.white.opacity(state == .idle ? 0.55 : 0.3)))
        ctx.stroke(Path(ellipseIn: s.ring), with: .color(ink), lineWidth: s.lineWidth)
        ctx.fill(Path(ellipseIn: s.dot), with: .color(state == .idle ? red.opacity(0.75) : ink))
    }
}
