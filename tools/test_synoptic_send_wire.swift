import SwiftUI

// Standalone test of the SEND WIRES' pure side (signal view rework of October 2026, lot L7,
// docs/plan_synoptic_rework.md §B.6): how a send's polyline is rounded, where the handle that takes the
// send in the hand sits (it must never cover the '+' it is taken at, nor any other element), how the wire runs
// down a send's column (arrows pointing down), and what a gesture on a send's '+' asks of the view-model.
//
//     swiftc -parse-as-library -o /tmp/t_sw \
//         ../objekat/Inspector/Synoptic/SynopticGraph.swift \
//         ../objekat/Inspector/Synoptic/SynopticPlusGesture.swift \
//         ../objekat/Inspector/Synoptic/SynopticPlusShortcuts.swift \
//         ../objekat/Inspector/Synoptic/SynopticWidthFlow.swift \
//         ../objekat/Inspector/Synoptic/SynopticLayout.swift \
//         ../objekat/Inspector/Synoptic/SynopticSendGeometry.swift test_synoptic_send_wire.swift \
//         && /tmp/t_sw

func L(_ key: String, _ args: CVarArg...) -> String { key }

var failures = 0
var total = 0
func check(_ ok: Bool, _ what: String) {
    total += 1
    if !ok { failures += 1; print("FAIL: \(what)") }
}

func plug(_ name: String) -> SynopticNode { .plugin(SynopticPlugin(name: name, category: .utility)) }
func send(_ name: String, _ slot: SynopticSendSlot, plugins n: Int = 0, enabled: Bool = true,
          refusal: String? = nil) -> SynopticSend {
    var s = SynopticSend(id: UUID(), name: name, enabled: enabled, levelDb: -6, refusal: refusal, slot: slot)
    s.plugins = (0..<n).map { SynopticSendPlugin(id: UUID(), name: "p\($0)") }
    return s
}
func layout(_ root: SynopticNode, sends: [SynopticSend] = [], mix: Bool = true, frame: Bool = true) -> SynopticLayout.Diagram {
    SynopticLayout.diagram(for: root, audioFile: true, mix: mix, stems: true,
                           sends: sends, sendsEnabled: true, objectFrame: frame)
}

struct LCG { var s: UInt64; mutating func next() -> UInt64 { s = s &* 6364136223846793005 &+ 1442695040888963407; return s >> 33 } }

/// The elements of a diagram a handle must not cover.
func obstacles(_ d: SynopticLayout.Diagram) -> [CGRect] {
    var r: [CGRect] = d.placement.cards.map(\.frame)
    r += [d.sourcePill, d.outPill]
    for z in [d.clipZone, d.stemsZone, d.audioZone, d.midiZone, d.araCard, d.busHeadZone, d.addSendButton] {
        if let z { r.append(z) }
    }
    r += d.sendCards.map(\.frame)
    return r
}

/// The elements of a path, flattened to (kind, points).
enum El: Equatable { case move(CGPoint), line(CGPoint), quad(CGPoint, CGPoint), other }
func elements(_ p: Path) -> [El] {
    var out: [El] = []
    p.forEach { e in
        switch e {
        case .move(let a):          out.append(.move(a))
        case .line(let a):          out.append(.line(a))
        case .quadCurve(let a, let c): out.append(.quad(a, c))
        default:                    out.append(.other)
        }
    }
    return out
}
func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

@main
struct Main {
    static func main() {
        // 1. Rounded paths.
        check(SendWire.roundedPath([]).isEmpty, "no point: empty path")
        check(SendWire.roundedPath([CGPoint(x: 1, y: 1)]).isEmpty, "one point: empty path")
        check(SendWire.roundedPath([CGPoint(x: 1, y: 1), CGPoint(x: 1, y: 1)]).isEmpty, "two equal points: empty path")
        let straight = elements(SendWire.roundedPath([CGPoint(x: 0, y: 0), CGPoint(x: 50, y: 0)]))
        check(straight == [.move(CGPoint(x: 0, y: 0)), .line(CGPoint(x: 50, y: 0))], "two points: a plain line")
        let collinear = elements(SendWire.roundedPath([CGPoint(x: 0, y: 0), CGPoint(x: 20, y: 0), CGPoint(x: 50, y: 0)]))
        check(collinear == straight, "a collinear middle is dropped (no corner to round)")
        let dup = SendWire.simplified([CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 30), CGPoint(x: 0, y: 30)])
        check(dup == [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 30)], "repeated points are dropped")
        let uturn = SendWire.simplified([CGPoint(x: 0, y: 0), CGPoint(x: 20, y: 0), CGPoint(x: 5, y: 0)])
        check(uturn.count == 3, "a U-turn is NOT a collinear middle")

        let big: [CGPoint] = [CGPoint(x: 100, y: 10), CGPoint(x: 20, y: 10), CGPoint(x: 20, y: 90), CGPoint(x: 60, y: 90)]
        let eb = elements(SendWire.roundedPath(big))
        // move, line, quad, line, quad, line
        check(eb.count == 6 && eb.first == .move(big[0]), "a 4-point wire: move + 2 rounded corners")
        if case .line(let end) = eb.last! { check(end == big[3], "the path ends on the last point") } else { check(false, "last element is a line") }
        var corners = 0
        if case .quad(_, let c1) = eb[2] { check(c1 == big[1], "first corner: the vertex is the control"); corners += 1 }
        if case .quad(_, let c2) = eb[4] { check(c2 == big[2], "second corner: the vertex is the control"); corners += 1 }
        check(corners == 2, "two quad corners")
        if case .line(let s1) = eb[1] { check(abs(dist(s1, big[1]) - SendWire.cornerRadius) < 1e-9, "corner radius = \(SendWire.cornerRadius) on long legs") }

        // Short legs clamp the radius to half the leg: a staircase of 4 pt legs never overshoots.
        let tight: [CGPoint] = [CGPoint(x: 0, y: 0), CGPoint(x: 4, y: 0), CGPoint(x: 4, y: 4), CGPoint(x: 8, y: 4)]
        let et = elements(SendWire.roundedPath(tight))
        var cur = CGPoint.zero
        var okClamp = true
        var quads = 0
        for e in et {
            switch e {
            case .move(let a), .line(let a): cur = a
            case .quad(let a, let c):
                quads += 1
                if dist(cur, c) > 2 + 1e-9 || dist(a, c) > 2 + 1e-9 { okClamp = false }
                cur = a
            default: okClamp = false
            }
        }
        okClamp = okClamp && quads == 2
        check(okClamp, "4 pt legs: every corner eats at most half of each leg")

        // Random axis-aligned polylines: every quad's tangents stay within the legs.
        var rng = LCG(s: 7)
        var sweepOK = true
        for _ in 0..<400 {
            var pts: [CGPoint] = [CGPoint(x: 100, y: 0)]
            var horizontal = true
            for _ in 0..<(2 + Int(rng.next() % 4)) {
                let len = CGFloat(1 + Int(rng.next() % 90))
                let sign: CGFloat = rng.next() % 2 == 0 ? 1 : -1
                let last = pts.last!
                pts.append(horizontal ? CGPoint(x: last.x + sign * len, y: last.y) : CGPoint(x: last.x, y: last.y + sign * len))
                horizontal.toggle()
            }
            let simple = SendWire.simplified(pts)
            let els = elements(SendWire.roundedPath(pts))
            var c = CGPoint.zero
            var legLimit: [CGFloat] = []
            for i in 1..<max(1, simple.count - 1) {
                legLimit.append(min(SendWire.cornerRadius, dist(simple[i - 1], simple[i]) / 2, dist(simple[i], simple[i + 1]) / 2))
            }
            var k = 0
            for e in els {
                switch e {
                case .move(let a): c = a
                case .line(let a): c = a
                case .quad(let a, let ctrl):
                    let lim = legLimit[k] + 1e-9; k += 1
                    if dist(c, ctrl) > lim || dist(a, ctrl) > lim { sweepOK = false }
                    c = a
                default: sweepOK = false
                }
            }
            if els.first != .move(simple[0]) { sweepOK = false }
            if k != max(0, simple.count - 2) { sweepOK = false }
        }
        check(sweepOK, "400 random polylines: rounded corners never overshoot a leg, one quad per corner")

        // 2. State and opacity.
        check(SendWire.state(of: send("a", .postFader)) == .live, "an enabled send is live")
        check(SendWire.state(of: send("a", .postFader, enabled: false)) == .off, "a switched-off send is off")
        check(SendWire.state(of: send("a", .postFader, refusal: "nope")) == .refused, "a refused send is refused")
        check(SendWire.state(of: send("a", .postFader, enabled: false, refusal: "x")) == .refused, "refusal wins over off")
        check(SendWire.opacity(.live) > SendWire.opacity(.off) && SendWire.opacity(.off) == SendWire.opacity(.refused),
              "a live wire is brighter than a dim one")

        // 3. The handle, over a sweep of layouts.
        let trunk = SynopticNode.series([plug("A"), plug("B"), plug("C")])
        let slots: [SynopticSendSlot] = [.input, .chain(1), .chain(2), .chain(3), .preFader, .postFader]
        var layouts = 0, handles = 0
        var handleOK = true
        var rng2 = LCG(s: 42)
        for _ in 0..<300 {
            let n = 1 + Int(rng2.next() % 5)
            let sends = (0..<n).map { i in send("s\(i)", slots[Int(rng2.next() % UInt64(slots.count))], plugins: Int(rng2.next() % 3)) }
            let d = layout(trunk, sends: sends, mix: rng2.next() % 4 != 0, frame: rng2.next() % 4 != 0)
            layouts += 1
            let obs = obstacles(d)
            var rects: [CGRect] = []
            for c in d.sendCards {
                let r = SendWire.rank(of: c, in: d.sendCards)
                let h = SendWire.handleCenter(of: c, rank: r)
                let hr = SendWire.handleRect(of: c, rank: r)
                handles += 1
                // on the first leg of the wire: same y as the tap, between the gutter and the tap
                if abs(h.y - c.tapDot.y) > 1e-9 || !(h.x > c.gutterX && h.x < c.tapDot.x) {
                    handleOK = false; print("  handle not on the first leg: \(h) tap \(c.tapDot) gutter \(c.gutterX)")
                }
                // never over the '+' ring it is taken at
                if hr.maxX > c.tapDot.x - SynopticLayout.plusW / 2 + 1e-9 {
                    handleOK = false; print("  handle covers its own '+': \(hr) tap \(c.tapDot)")
                }
                for o in obs where o.insetBy(dx: 0.5, dy: 0.5).intersects(hr) {
                    // a handle may sit ON its own wire's rect only where nothing else is: report anything
                    handleOK = false; print("  handle \(hr) over element \(o)")
                }
                rects.append(hr)
            }
            for i in rects.indices { for j in rects.indices where j > i && rects[i].intersects(rects[j]) {
                handleOK = false; print("  two handles overlap: \(rects[i]) \(rects[j])")
            } }
        }
        check(handleOK, "\(handles) handles over \(layouts) layouts: on the wire, left of their '+', over nothing, none over another")

        // Sends at one tap take successive ranks, one handle's width apart.
        let three = [send("a", .postFader), send("b", .postFader), send("c", .postFader)]
        let d3 = layout(trunk, sends: three)
        let ranks = d3.sendCards.map { SendWire.rank(of: $0, in: d3.sendCards) }
        check(ranks == [0, 1, 2], "three sends at one tap: ranks 0, 1, 2 (\(ranks))")
        let xs = d3.sendCards.enumerated().map { SendWire.handleCenter(of: $1, rank: ranks[$0]).x }
        check(abs((xs[0] - xs[1]) - SendWire.handleDiameter) < 1e-9 && abs((xs[1] - xs[2]) - SendWire.handleDiameter) < 1e-9,
              "ranked handles are one handle's width apart")
        let lone = layout(trunk, sends: [send("x", .input), send("y", .preFader)])
        check(lone.sendCards.allSatisfy { SendWire.rank(of: $0, in: lone.sendCards) == 0 }, "sends at different taps are all rank 0")

        // A handle never goes past its own gutter, however many share the tap.
        let many = layout(trunk, sends: (0..<12).map { send("m\($0)", .postFader) })
        check(many.sendCards.allSatisfy { c in
            SendWire.handleCenter(of: c, rank: SendWire.rank(of: c, in: many.sendCards)).x > c.gutterX
        }, "12 sends at one tap: every handle stays right of its gutter")

        // The wire's path starts at the tap and comes in at the column's top, on its axis; it carries on DOWN
        // into the column (its first segment), and every arrow points DOWN at what it arrives at (request 5,
        // 13 October 2026: a send drawn like the object).
        for (tag, dd) in [("no plugin", layout(trunk, sends: [send("e", .postFader)])),
                          ("two plugins", layout(trunk, sends: [send("p", .postFader, plugins: 2)]))] {
            let c = dd.sendCards[0]
            let pts = SendWire.points(of: c)
            check(pts.first == c.tapDot, "\(tag): the wire starts at the tap dot")
            check(pts.contains(c.entry), "\(tag): the wire passes the column's entry")
            let first = c.chain.cables.first { $0.from == c.entry }
            check(first != nil && pts.last == first!.to, "\(tag): the wire carries on into the column's first segment")
            check(SendWire.columnCables(of: c).count == c.chain.cables.count - 1, "\(tag): the merged segment is not drawn twice")
            let els = elements(SendWire.path(of: c))
            check(els.first == .move(c.tapDot), "\(tag): the path starts at the tap dot")
            if case .line(let e) = els.last! { check(e == pts.last!, "\(tag): the path ends where the points end") }
            else { check(false, "\(tag): the path ends with a line") }
            let tips = SendWire.arrowTips(of: c)
            check(tips.contains(CGPoint(x: c.axisX, y: c.lineRect.minY)), "\(tag): an arrow arrives at the send's line")
            check(tips.count == 1 + c.chain.cards.count, "\(tag): one arrow per card, plus the line's")
            for t in tips {
                let tip = elements(SendWire.arrowHead(at: t))
                check(tip.count == 3 && tip[1] == .line(t), "\(tag): the arrow's tip is where it arrives")
                if case .move(let m) = tip[0], case .line(let z) = tip[2] {
                    check(m.y < t.y && z.y < t.y && abs(m.x - t.x) <= SendWire.arrowHalfWidth, "\(tag): the arrow points DOWN")
                }
            }
        }

        // 4. A send's "+": the trunk's own gesture, restricted to a gain stage.
        let boxed = send("b", .postFader, plugins: 2)
        let db = layout(trunk, sends: [boxed])
        let c = db.sendCards[0]
        let tail = SynopticPlusKey.sendChain(aux: boxed.id, index: 2)
        func cmd(_ k: SynopticPlusKey, _ w: CGFloat, _ h: CGFloat) -> SynopticPlusCommand {
            db.command(for: k, translation: CGSize(width: w, height: h))
        }
        check(c.insert(2)?.key == tail, "the tail '+' of a send names the send and the end of its chain")
        check(cmd(tail, 2, 1) == .openBrowser(tail), "a click opens the browser for THIS send, at that '+'")
        check(cmd(tail, 40, 2) == .insertGainStage(tail, .gain), "right: a gain stage at the end of the chain")
        check(cmd(tail, 120, 0) == .insertGainStage(tail, .gainPanMute), "far right: gain + pan + mute")
        let head = SynopticPlusKey.sendChain(aux: boxed.id, index: 0)
        check(cmd(head, 40, 2) == .insertGainStage(head, .gain), "the head '+': a gain stage at the head")
        check(cmd(tail, 60, 35) == .none && cmd(tail, 60, -35) == .none && cmd(tail, -60, 0) == .none,
              "branch / send-up / send-left: nothing on a send")
        check(db.allowedGestures(for: tail) == [.gain, .gainPanMute], "a send's '+' offers the gain gestures only")

        print("\(total - failures)/\(total) send wire checks passed (\(layouts) layouts, \(handles) handles)")
        exit(failures == 0 ? 0 : 1)
    }
}
