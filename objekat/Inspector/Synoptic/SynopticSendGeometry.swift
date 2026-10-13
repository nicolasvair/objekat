import SwiftUI

// MARK: - The sends' wires, handles and "+" intents (PURE: no view, no model)
//
// Signal view rework, lot L7 (docs/plan_synoptic_rework.md §B.6, request 12), reworked on 13 October 2026
// (request 5: a send drawn like the object). A send is a COLUMN stacked below the stems; the line that shows
// where it is taken from leaves the TRUNK at the send's tap, runs out to the LEFT of the object's frame, down
// its own gutter, in at the column's top, and then DOWN the column through the send's plugins to its line
// (@see SynopticLayout.SendCardPlacement.wire / .chain, whose points the layout guarantees never cross). This
// file holds what the VIEWS need of that and nothing else: how the polyline is rounded and stroked, and where
// the handle that moves the send sits. Compiled alone by `tools/test_synoptic_send_wire.swift`.
//
// Who calls it: the wires are drawn in the canvas' `Canvas` (`SendWire.draw(_:cards:)`), the handle is a
// view of `SynopticSendViews.swift` (`SendTapDotView`) laid in the canvas' ZStack. The canvas (lot L4) owns
// the drawing pass; L8 puts the two calls in (the old curve in `SynopticView.draw` goes).

enum SendWire {

    // MARK: Shape

    /// The radius of a wire's corners (clamped to half of the shorter leg it turns between).
    static let cornerRadius: CGFloat = 6
    /// The arrowheads of the wire's run down the column (into each card, into the line): they point DOWN,
    /// the signal's way, as the trunk's do.
    static let arrowLength: CGFloat = 6
    static let arrowHalfWidth: CGFloat = 4
    /// The visible dot of the handle, and the square the hand can take it by.
    static let dotDiameter: CGFloat = 6
    static let handleDiameter: CGFloat = 14
    static let lineWidth: CGFloat = 1.2
    static let dash: [CGFloat] = [4, 3]

    /// How a send's wire reads: lit when the send carries signal, dim when the hand switched it off or the
    /// bridge refuses it (a refused send stays in the model, silent: the card says why).
    enum State: Equatable { case live, off, refused }

    static func state(of send: SynopticSend) -> State {
        if send.refusal != nil { return .refused }
        return send.enabled ? .live : .off
    }

    /// The stroke's opacity: the accent colour at 0.75 when live, the secondary colour at 0.4 otherwise.
    static func opacity(_ state: State) -> Double { state == .live ? 0.75 : 0.4 }

    // MARK: Handle

    /// The centre of the HANDLE that takes the send in the hand. The layout's `tapDot` is the point of the
    /// trunk the send is taken at — the centre of its '+', which the hand also uses (a click, a drag right).
    /// A handle on that very point would swallow the '+', so it sits on the wire just LEFT of the '+' ring
    /// instead (the two rects never touch): the wire runs through it, the ring never covers it.
    ///
    /// Sends taken at ONE tap share the same point and the same first leg, hence the same handle spot:
    /// `rank` (their order among those, @see `rank(of:in:)`) steps each further one a handle's width to the
    /// left, never past its own gutter, so that every send keeps a handle the hand can reach.
    static func handleCenter(of c: SynopticLayout.SendCardPlacement, rank: Int = 0) -> CGPoint {
        let x = c.tapDot.x - SynopticLayout.plusW / 2 - handleDiameter / 2 - 1 - CGFloat(max(0, rank)) * handleDiameter
        let leftmost = c.gutterX + handleDiameter / 2 + 2
        return CGPoint(x: max(x, min(leftmost, c.tapDot.x)), y: c.tapDot.y)
    }

    /// The square the hand takes the handle by.
    static func handleRect(of c: SynopticLayout.SendCardPlacement, rank: Int = 0) -> CGRect {
        let h = handleCenter(of: c, rank: rank)
        return CGRect(x: h.x - handleDiameter / 2, y: h.y - handleDiameter / 2,
                      width: handleDiameter, height: handleDiameter)
    }

    /// The rank of `card` among the cards taken at the SAME point (0 = the first of them, in the order of
    /// `cards`, which is the stack's order).
    static func rank(of card: SynopticLayout.SendCardPlacement, in cards: [SynopticLayout.SendCardPlacement]) -> Int {
        var n = 0
        for other in cards {
            if other.id == card.id { return n }
            if abs(other.tapDot.x - card.tapDot.x) < 1e-6 && abs(other.tapDot.y - card.tapDot.y) < 1e-6 { n += 1 }
        }
        return n
    }

    // MARK: Paths

    /// `points` joined by straight legs whose corners are rounded by `radius` (clamped to half of each
    /// adjacent leg, so two corners never eat the same leg twice). Repeated points and collinear middles
    /// are dropped first; fewer than two distinct points give an empty path.
    static func roundedPath(_ points: [CGPoint], radius: CGFloat = cornerRadius) -> Path {
        let pts = simplified(points)
        var path = Path()
        guard pts.count >= 2 else { return path }
        path.move(to: pts[0])
        guard pts.count > 2 else { path.addLine(to: pts[1]); return path }
        for i in 1..<(pts.count - 1) {
            let prev = pts[i - 1], corner = pts[i], next = pts[i + 1]
            let inLen = hypot(corner.x - prev.x, corner.y - prev.y)
            let outLen = hypot(next.x - corner.x, next.y - corner.y)
            let r = max(0, min(radius, inLen / 2, outLen / 2))
            let start = CGPoint(x: corner.x + (prev.x - corner.x) / inLen * r,
                                y: corner.y + (prev.y - corner.y) / inLen * r)
            let end = CGPoint(x: corner.x + (next.x - corner.x) / outLen * r,
                              y: corner.y + (next.y - corner.y) / outLen * r)
            path.addLine(to: start)
            path.addQuadCurve(to: end, control: corner)
        }
        path.addLine(to: pts[pts.count - 1])
        return path
    }

    /// The send's wire as ONE polyline: tap → left to the gutter → down the gutter → right to the column's
    /// axis → down into the column's first element (its first card, or the line of a plugin-less send). The
    /// turn down is part of it, so that corner is rounded like the others.
    static func points(of c: SynopticLayout.SendCardPlacement) -> [CGPoint] {
        var p = c.wire
        if let first = c.chain.cables.first, startsAtEntry(first, c) { p.append(first.to) }
        return p
    }

    static func path(of c: SynopticLayout.SendCardPlacement) -> Path { roundedPath(points(of: c)) }

    /// The column's first segment leaves from where the wire arrives (always, as laid; checked to the
    /// sub-pixel so a rounding never draws one segment twice).
    private static func startsAtEntry(_ cable: SynopticLayout.Cable, _ c: SynopticLayout.SendCardPlacement) -> Bool {
        abs(cable.from.x - c.entry.x) < 1e-6 && abs(cable.from.y - c.entry.y) < 1e-6
    }

    /// The rest of the run down the column (every segment after the one `points(of:)` already holds).
    static func columnCables(of c: SynopticLayout.SendCardPlacement) -> [SynopticLayout.Cable] {
        guard let first = c.chain.cables.first, startsAtEntry(first, c) else { return c.chain.cables }
        return Array(c.chain.cables.dropFirst())
    }

    /// The arrowheads of the column: one where each segment ARRIVES at an element (a card, the line) — the
    /// trunk's own rule (the arrow belongs to the segment that arrives; a `.plain` one carries none).
    static func arrowTips(of c: SynopticLayout.SendCardPlacement) -> [CGPoint] {
        c.chain.cables.filter { $0.style == .connector }.map(\.to)
    }

    /// The arrowhead whose tip is `tip`, pointing DOWN.
    static func arrowHead(at tip: CGPoint) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: tip.x - arrowHalfWidth, y: tip.y - arrowLength))
        p.addLine(to: tip)
        p.addLine(to: CGPoint(x: tip.x + arrowHalfWidth, y: tip.y - arrowLength))
        return p
    }

    /// Drops repeated points and the middles of straight runs (a collinear point has no corner to round).
    static func simplified(_ points: [CGPoint]) -> [CGPoint] {
        var out: [CGPoint] = []
        for p in points {
            if let last = out.last, abs(last.x - p.x) < 1e-9, abs(last.y - p.y) < 1e-9 { continue }
            out.append(p)
        }
        var i = 1
        while i < out.count - 1 {
            let a = out[i - 1], b = out[i], c = out[i + 1]
            let cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
            let dot = (b.x - a.x) * (c.x - b.x) + (b.y - a.y) * (c.y - b.y)
            if abs(cross) < 1e-9 && dot > 0 { out.remove(at: i) } else { i += 1 }
        }
        return out
    }

    // MARK: Drawing

    /// Strokes every send's wire into the canvas' context, dashed (it is a TAP, not the flow): from the trunk
    /// to the column, then on down the column through the send's cards to its line — ONE wire, in one style,
    /// with an arrow into each card and into the line. The handles and the '+' are views, laid over this.
    static func draw(_ ctx: GraphicsContext, cards: [SynopticLayout.SendCardPlacement]) {
        for c in cards {
            let state = state(of: c.send)
            let color = (state == .live ? Color.accentColor : Color.secondary).opacity(opacity(state))
            let dashed = StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round, dash: dash)
            ctx.stroke(path(of: c), with: .color(color), style: dashed)
            for cable in columnCables(of: c) {
                var p = Path()
                p.move(to: cable.from)
                p.addLine(to: cable.to)
                ctx.stroke(p, with: .color(color), style: dashed)
            }
            let solid = StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
            for tip in arrowTips(of: c) { ctx.stroke(arrowHead(at: tip), with: .color(color), style: solid) }
        }
    }
}
