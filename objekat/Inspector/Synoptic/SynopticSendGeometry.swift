import SwiftUI

// MARK: - The sends' wires, handles and "+" intents (PURE: no view, no model)
//
// Signal view rework, lot L7 (docs/plan_synoptic_rework.md §B.6, request 12). A send is a BOX stacked below
// the stems; the line that shows where it is taken from leaves the TRUNK at the send's tap, runs out to the
// LEFT of the object's frame, down its own gutter, and into the box (@see SynopticLayout.SendCardPlacement.wire,
// whose points the layout guarantees never cross). This file holds what the VIEWS need of that and nothing
// else: how the polyline is rounded and stroked, where the handle that moves the send sits, and what a
// gesture on a send's "+" means. Compiled alone by `tools/test_synoptic_send_wire.swift`.
//
// Who calls it: the wires are drawn in the canvas' `Canvas` (`SendWire.draw(_:cards:)`), the handle is a
// view of `SynopticSendViews.swift` (`SendTapDotView`) laid in the canvas' ZStack. The canvas (lot L4) owns
// the drawing pass; L8 puts the two calls in (the old curve in `SynopticView.draw` goes).

enum SendWire {

    // MARK: Shape

    /// The radius of a wire's corners (clamped to half of the shorter leg it turns between).
    static let cornerRadius: CGFloat = 6
    /// The arrowhead where the wire enters the box: it points RIGHT (the wire arrives from the gutter).
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

    /// The send's wire: tap → left to the gutter → down the gutter → right into the box.
    static func path(of c: SynopticLayout.SendCardPlacement) -> Path { roundedPath(c.wire) }

    /// The arrowhead whose tip is `tip`, pointing right.
    static func arrowHead(at tip: CGPoint) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: tip.x - arrowLength, y: tip.y - arrowHalfWidth))
        p.addLine(to: tip)
        p.addLine(to: CGPoint(x: tip.x - arrowLength, y: tip.y + arrowHalfWidth))
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

    /// Strokes every send's wire into the canvas' context, dashed (it is a TAP, not the flow), with the
    /// arrow where it enters the box. The handles are views, laid over this.
    static func draw(_ ctx: GraphicsContext, cards: [SynopticLayout.SendCardPlacement]) {
        for c in cards {
            let state = state(of: c.send)
            let color = (state == .live ? Color.accentColor : Color.secondary).opacity(opacity(state))
            ctx.stroke(path(of: c), with: .color(color),
                       style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round, dash: dash))
            ctx.stroke(arrowHead(at: c.entry), with: .color(color),
                       style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        }
    }
}

// MARK: - The "+" of a send's mini-chain

/// What a gesture on the "+" of a send's box asks of the view-model: the layout's command
/// (@see SynopticLayout.SendCardPlacement.command(for:)) translated to the closure it goes to.
enum SendPlusIntent: Equatable {
    /// Nothing (a drag the "+" does not offer).
    case none
    /// A click: the plugin picker aimed at this send.
    case openBrowser(aux: UUID)
    /// A gain stage dragged out of the "+" (`onSendPlusGesture`): `result` is `.gain` or `.gainPanMute`.
    case gainStage(aux: UUID, index: Int, result: PlusGestureResult)

    init(_ command: SynopticPlusCommand) {
        switch command {
        case .openBrowser(.sendChain(let aux, _)):
            self = .openBrowser(aux: aux)
        case .insertGainStage(.sendChain(let aux, let index), let face):
            self = .gainStage(aux: aux, index: index, result: face == .gain ? .gain : .gainPanMute)
        default:
            self = .none
        }
    }
}

/// The ghost the "+" shows under the hand while it is dragged (§B.2): what letting go would put there, or
/// that this "+" does not offer what the hand is asking for.
enum SendPlusGhost: Equatable {
    /// Under the click threshold: no ghost, the gesture is still a click.
    case hidden
    /// A gain stage of that face.
    case stage(SynopticGainStageFace)
    /// A direction this "+" does not offer: "not here".
    case refused

    static func of(command: SynopticPlusCommand, translation: CGSize) -> SendPlusGhost {
        if SynopticPlusGesture.isClick(translation) { return .hidden }
        switch command {
        case .insertGainStage(_, let face): return .stage(face)
        default:                            return .refused
        }
    }
}
