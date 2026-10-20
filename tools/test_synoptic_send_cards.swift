import SwiftUI

// Standalone geometry test of the SEND BOXES in the signal view layout (signal view rework of October 2026,
// docs/plan_synoptic_rework.md §B.6; it replaces the INC 2 column of docs/plan_sends_rework.md §D.1.A.j).
//
// Every outgoing send is a COLUMN stacked BELOW the stems, left-aligned on the frame; its wire leaves the tap
// dot on the trunk to the LEFT, goes down its own gutter (left of the frame), comes in at the column's top and
// runs DOWN through the send's plugins (real cards) to the send's line at the bottom (request 5, 13 October
// 2026). The send tapped HIGHEST takes the OUTERMOST gutter and the LOWEST column: the wires nest, none crosses.
// A tap is a '+' of the ROOT series (head ≡ input, tail ≡ pre-fader, between ≡ chain(i)) or the '+' on
// the wire mixer → stems (post-fader). Nothing is laid inside a parallel block.
//
//     swiftc -parse-as-library -o /tmp/t_sc \
//         ../objekat/Inspector/Synoptic/SynopticGraph.swift \
//         ../objekat/Inspector/Synoptic/SynopticPlusGesture.swift \
//         ../objekat/Inspector/Synoptic/SynopticPlusShortcuts.swift \
//         ../objekat/Inspector/Synoptic/SynopticWidthFlow.swift \
//         ../objekat/Inspector/Synoptic/SynopticLayout.swift test_synoptic_send_cards.swift \
//         && /tmp/t_sc

func L(_ key: String, _ args: CVarArg...) -> String { key }

var failures = 0
var total = 0
func check(_ ok: Bool, _ what: String) {
    total += 1
    if !ok { failures += 1; print("FAIL: \(what)") }
}

func plug(_ name: String) -> SynopticNode { .plugin(SynopticPlugin(name: name, category: .utility)) }
func send(_ name: String, _ slot: SynopticSendSlot, plugins n: Int = 0) -> SynopticSend {
    var s = SynopticSend(id: UUID(), name: name, enabled: true, levelDb: -6, slot: slot)
    s.plugins = (0..<n).map { SynopticSendPlugin(id: UUID(), name: "p\($0)") }
    return s
}
func layout(_ root: SynopticNode, sends: [SynopticSend] = [], enabled: Bool = true,
            mix: Bool = true, frame: Bool = true) -> SynopticLayout.Diagram {
    SynopticLayout.diagram(for: root, audioFile: true, mix: mix, stems: true,
                           sends: sends, sendsEnabled: enabled, objectFrame: frame)
}
func card(_ d: SynopticLayout.Diagram, _ s: SynopticSend) -> SynopticLayout.SendCardPlacement? {
    d.sendCards.first { $0.send.id == s.id }
}

// MARK: segment geometry

struct Seg { let a: CGPoint; let b: CGPoint; let owner: Int }

func segments(_ c: SynopticLayout.SendCardPlacement, owner: Int) -> [Seg] {
    let w = c.wire
    return zip(w, w.dropFirst()).compactMap { p, q in
        (abs(p.x - q.x) < 1e-9 && abs(p.y - q.y) < 1e-9) ? nil : Seg(a: p, b: q, owner: owner)
    }
}

/// A PROPER crossing of two axis-aligned segments: one horizontal, one vertical, meeting strictly inside
/// both (a T at an end, or two collinear segments sharing a stretch, is not a crossing).
func properlyCross(_ s: Seg, _ t: Seg) -> Bool {
    let sh = abs(s.a.y - s.b.y) < 1e-9, th = abs(t.a.y - t.b.y) < 1e-9
    guard sh != th else { return false }
    let h = sh ? s : t, v = sh ? t : s
    let hx0 = min(h.a.x, h.b.x), hx1 = max(h.a.x, h.b.x), hy = h.a.y
    let vy0 = min(v.a.y, v.b.y), vy1 = max(v.a.y, v.b.y), vx = v.a.x
    let e: CGFloat = 1e-6
    return vx > hx0 + e && vx < hx1 - e && hy > vy0 + e && hy < vy1 - e
}

/// True if the (axis-aligned) segment passes through the interior of `r` (running along an edge or ending
/// on it is allowed).
func segHits(_ s: Seg, _ r: CGRect) -> Bool {
    let e: CGFloat = 0.5
    let x0 = min(s.a.x, s.b.x), x1 = max(s.a.x, s.b.x), y0 = min(s.a.y, s.b.y), y1 = max(s.a.y, s.b.y)
    return x1 > r.minX + e && x0 < r.maxX - e && y1 > r.minY + e && y0 < r.maxY - e
}

/// Every check on the wires of a laid diagram: no two cross, none runs through a card, a zone, another
/// column or the "+ Send to…" button; each gutter is left of the frame and inside the canvas.
func checkWires(_ d: SynopticLayout.Diagram, _ tag: String, quiet: Bool = false) -> Bool {
    var ok = true
    func print(_ s: String) { if !quiet { Swift.print(s) } }
    let segs = d.sendCards.enumerated().flatMap { segments($1, owner: $0) }
    for (i, s) in segs.enumerated() {
        for t in segs[(i + 1)...] where s.owner != t.owner && properlyCross(s, t) {
            ok = false; print("  \(tag): wires \(s.owner) and \(t.owner) cross")
        }
    }
    var obstacles: [CGRect] = d.placement.cards.map(\.frame)
    obstacles += [d.sourcePill, d.outPill]
    if let c = d.clipZone { obstacles.append(c) }
    if let b = d.addSendButton { obstacles.append(b) }
    for (k, c) in d.sendCards.enumerated() {
        let frameLeft = d.objectFrame?.minX ?? c.frame.minX
        if !(c.gutterX < frameLeft && c.gutterX >= 0) { ok = false; print("  \(tag): gutter \(k) not left of the frame") }
        for s in segments(c, owner: k) {
            for r in obstacles where segHits(s, r) { ok = false; print("  \(tag): wire \(k) runs through \(r)") }
            for (j, o) in d.sendCards.enumerated() where j != k && segHits(s, o.frame) {
                ok = false; print("  \(tag): wire \(k) runs through column \(j)")
            }
            // its own column: the last segment runs ALONG its top edge to the axis, never inside
            if segHits(s, c.frame) { ok = false; print("  \(tag): wire \(k) runs into its own column") }
        }
    }
    return ok
}

/// A tiny deterministic generator (the random sweep must be reproducible).
struct LCG { var s: UInt64; mutating func next() -> UInt64 { s = s &* 6364136223846793005 &+ 1442695040888963407; return s >> 33 } }

@main
struct Main {
    static func main() {
        let trunk = SynopticNode.series([plug("A"), plug("B"), plug("C")])
        let rootInserts = { (d: SynopticLayout.Diagram) in d.placement.inserts.filter { $0.seriesID == trunk.id } }

        // 1. A sender with no send: the post-fader '+', the "+ Send to…" button, ONE fixed slot (post-fader).
        let none = layout(trunk)
        check(none.sendCards.isEmpty, "no send, no column")
        check(none.addSendButton != nil, "a sender always has the + Send to... button")
        check(none.postFaderPlus != nil, "a sender has the post-fader '+'")
        check(none.sendSlotDrops.map(\.slot) == [.postFader], "one fixed slot left: post-fader (the others are the trunk's '+')")
        let non = layout(trunk, enabled: false)
        check(non.addSendButton == nil && non.sendSlotDrops.isEmpty && non.sendCards.isEmpty && non.postFaderPlus == nil,
              "an object that does not send: no button, no slot, no post-fader '+'")
        check(none.placement.cards.map(\.frame) == non.placement.cards.map(\.frame), "being a sender does not move the trunk")
        check(none.outPill.minY > non.outPill.minY, "the post-fader '+' lengthens the wire mixer -> stems")

        // 2. Adding sends shifts the content right by the gutters only; nothing moves vertically.
        let all: [SynopticSend] = [send("i", .input), send("c1", .chain(1)), send("c2", .chain(2)),
                                   send("pre", .preFader), send("post", .postFader)]
        let full = layout(trunk, sends: all)
        let shift = SynopticLayout.sendGutterSpace(all.count)
        check(zip(full.placement.cards, none.placement.cards).allSatisfy {
                  abs($0.frame.minY - $1.frame.minY) < 1e-9 && abs($0.frame.minX - $1.frame.minX - shift) < 1e-9 },
              "the trunk's cards move right by the gutters' width, not down")
        check(abs(full.outPill.minY - none.outPill.minY) < 1e-9 && abs(full.clipZone!.minY - none.clipZone!.minY) < 1e-9,
              "clip zone and stems do not move down")
        check(full.sendCards.count == all.count, "a column per send")

        // 3. Each slot's tap: the trunk's '+' and the post-fader '+'.
        let ri = rootInserts(full)
        check(ri.count == 4, "a 3-entry trunk has 4 insert points")
        func at(_ i: Int) -> CGPoint { ri.first { $0.insertIndex == i }!.center }
        check(card(full, all[0])!.anchor == at(0), "input = the trunk's head '+'")
        check(card(full, all[1])!.anchor == at(1), "chain(1) = the '+' before the 2nd entry")
        check(card(full, all[2])!.anchor == at(2), "chain(2) = the '+' before the 3rd entry")
        check(card(full, all[3])!.anchor == at(3), "pre-fader = the trunk's tail '+'")
        check(card(full, all[4])!.anchor == full.postFaderPlus!.center, "post-fader = the '+' on the wire mixer -> stems")
        check(full.postFaderPlus!.center.y > full.clipZone!.maxY && full.postFaderPlus!.center.y < full.outPill.minY,
              "the post-fader '+' lies between the mixer and the stems")
        for c in full.sendCards { check(c.tapDot == c.anchor, "\(c.send.name): the tap dot is the anchor") }
        let beyond = layout(trunk, sends: [send("x", .chain(99))])
        check(beyond.sendCards[0].anchor == rootInserts(beyond).first { $0.insertIndex == 3 }!.center,
              "chain(99) is clamped to the tail")
        let empty = SynopticNode.series([])
        let e = layout(empty, sends: [send("e", .input)])
        check(e.sendCards.count == 1 && e.sendCards[0].anchor == e.placement.inserts.first { $0.seriesID == empty.id }!.center,
              "an empty trunk still has its one tap")

        // 4. The columns: BELOW the stems, left-aligned on the frame, lowest tap first, highest tap outermost.
        let frame = full.objectFrame!
        for c in full.sendCards {
            check(c.frame.minY >= full.outPill.maxY + SynopticLayout.sendsTopGap - 1e-9, "\(c.send.name) is below the stems")
            check(abs(c.frame.minX - frame.minX) < 1e-9, "\(c.send.name) is left-aligned on the frame")
            check(!c.frame.intersects(frame), "\(c.send.name) is outside the frame")
            check(c.frame.maxX <= full.canvasSize.width && c.frame.maxY <= full.canvasSize.height, "\(c.send.name) inside the canvas")
            check(c.wire.count == 4 && c.wire.first == c.anchor && c.wire.last == c.entry, "\(c.send.name): tap -> gutter -> column top")
        }
        let byY = full.sendCards.sorted { $0.frame.minY < $1.frame.minY }
        check(byY.map(\.send.name) == ["post", "pre", "c2", "c1", "i"], "columns read top to bottom from the LOWEST tap")
        for (a, b) in zip(byY, byY.dropFirst()) {
            check(a.frame.maxY + SynopticLayout.sendCardGap <= b.frame.minY + 1e-9, "\(a.send.name) / \(b.send.name) do not overlap")
            check(b.gutterX < a.gutterX, "\(b.send.name) (higher tap) takes an outer gutter")
        }
        if let b = full.addSendButton {
            check(b.minY >= byY.last!.frame.maxY && abs(b.minX - frame.minX) < 1e-9, "'+ Send to...' at the bottom of the stack")
        }
        check(checkWires(full, "five slots"), "five slots: no crossing, nothing run through")

        // 5. Several sends at one tap keep the order given, share the tap, and nest.
        let stack = [send("s1", .chain(1)), send("s2", .chain(1)), send("s3", .chain(1)), send("s4", .postFader)]
        let st = layout(trunk, sends: stack)
        let order = st.sendCards.sorted { $0.frame.minY < $1.frame.minY }.map(\.send.name)
        check(order == ["s4", "s1", "s2", "s3"], "post-fader first, then the shared tap in the order given (\(order))")
        check(Set(stack.dropLast().map { card(st, $0)!.anchor }).count == 1, "the three share one tap")
        check(checkWires(st, "shared tap"), "a shared tap: no crossing")

        // (the detectors must be able to fail)
        check(properlyCross(Seg(a: CGPoint(x: 0, y: 5), b: CGPoint(x: 10, y: 5), owner: 0),
                            Seg(a: CGPoint(x: 5, y: 0), b: CGPoint(x: 5, y: 10), owner: 1)), "(detector) a cross is caught")
        check(!properlyCross(Seg(a: CGPoint(x: 0, y: 5), b: CGPoint(x: 10, y: 5), owner: 0),
                             Seg(a: CGPoint(x: 5, y: 5), b: CGPoint(x: 5, y: 10), owner: 1)), "(detector) a T is not a cross")
        check(segHits(Seg(a: CGPoint(x: 0, y: 5), b: CGPoint(x: 10, y: 5), owner: 0), CGRect(x: 4, y: 0, width: 2, height: 10)),
              "(detector) a wire through a column is caught")
        check(!segHits(Seg(a: CGPoint(x: 0, y: 5), b: CGPoint(x: 4, y: 5), owner: 0), CGRect(x: 4, y: 0, width: 2, height: 10)),
              "(detector) a wire ending on a column's edge is not")
        var swapped = full
        if swapped.sendCards.count >= 2 {
            let g0 = swapped.sendCards[0].gutterX
            swapped.sendCards[0].gutterX = swapped.sendCards[swapped.sendCards.count - 1].gutterX
            swapped.sendCards[swapped.sendCards.count - 1].gutterX = g0
            check(!checkWires(swapped, "(detector, swapped gutters)", quiet: true), "(detector) swapping two gutters makes wires cross")
        }

        // 6. NO TWO WIRES CROSS for 1–6 sends at every slot mix: exhaustive up to 4, a seeded sweep for 5–6.
        let slots: [SynopticSendSlot] = [.input, .chain(1), .chain(2), .preFader, .postFader]
        var mixes = 0, bad = 0
        func trial(_ chosen: [SynopticSendSlot], plugins: [Int], frame: Bool = true) {
            let ss = chosen.enumerated().map { send("s\($0)", $1, plugins: plugins[$0]) }
            let d = layout(trunk, sends: ss, frame: frame)
            mixes += 1
            if !checkWires(d, "\(chosen)") { bad += 1 }
            // nesting order: a column lower in the stack is never tapped lower
            let ys = d.sendCards.sorted { $0.frame.minY < $1.frame.minY }
            if zip(ys, ys.dropFirst()).contains(where: { $0.anchor.y < $1.anchor.y - 1e-9 }) { bad += 1; print("  order broken \(chosen)") }
        }
        func sweep(_ n: Int, _ prefix: [SynopticSendSlot]) {
            if prefix.count == n { trial(prefix, plugins: prefix.indices.map { $0 % 3 }); return }
            for s in slots { sweep(n, prefix + [s]) }
        }
        for n in 1...4 { sweep(n, []) }
        var g = LCG(s: 0x5EED)
        for n in 5...6 {
            for _ in 0..<400 {
                let chosen = (0..<n).map { _ in slots[Int(g.next() % UInt64(slots.count))] }
                trial(chosen, plugins: (0..<n).map { _ in Int(g.next() % 4) }, frame: g.next() % 2 == 0)
            }
        }
        check(bad == 0, "no crossing and nesting kept over \(mixes) slot mixes (\(bad) bad)")

        // 7. Nothing in a branch: with a parallel block in the trunk, taps are the ROOT's '+' only, and the
        //    wire leaving a tap does not run through the parallel.
        let branchA = SynopticNode.series([plug("p1")]), branchB = SynopticNode.series([plug("p2")])
        let par = SynopticNode.parallel([branchA, branchB])
        let withPar = SynopticNode.series([plug("A"), par, plug("C")])
        let sp = layout(withPar, sends: [send("m", .chain(1)), send("n", .chain(2)), send("o", .input)])
        let rootPts = Set(sp.placement.inserts.filter { $0.seriesID == withPar.id }.map { "\($0.center.x),\($0.center.y)" })
        for c in sp.sendCards { check(rootPts.contains("\(c.anchor.x),\(c.anchor.y)"), "\(c.send.name) is tapped on the root series") }
        let parScope = sp.placement.scopes.first!.rect
        for c in sp.sendCards {
            for s in segments(c, owner: 0) { check(!segHits(s, parScope), "\(c.send.name)'s wire avoids the parallel's area") }
        }
        check(checkWires(sp, "parallel"), "parallel: no crossing")

        // 8. The post-fader slot drop: on the wire, previews at its tap.
        for z in full.sendSlotDrops {
            check(z.rect.contains(z.anchor), "slot \(z.slot) detects its own tap")
            check(z.previewFrame.midY == z.anchor.y && z.previewFrame.height == SynopticLayout.cardH, "slot \(z.slot) previews at its tap")
            check(z.rect.minY >= full.clipZone!.maxY && z.rect.maxY <= full.outPill.minY, "slot \(z.slot) lies on the wire mixer -> stems")
        }

        // 9. The post-fader '+' offers the SEND only (D2); the trunk's '+' carry their slot.
        let pf = full.postFaderPlus!
        check(pf.allowedGestures == [.send], "the mixer -> stems '+' allows .send only")
        check(pf.command(for: CGSize(width: 2, height: 2)) == .send(.postFader), "a click on it: the Send to... menu, post-fader")
        check(pf.command(for: CGSize(width: -60, height: 0)) == .send(.postFader), "left: a post-fader send")
        check(pf.command(for: CGSize(width: 60, height: -35)) == .none, "up-right: nothing any more")
        check(pf.command(for: CGSize(width: 60, height: 0)) == .none, "right: no gain there")
        check(pf.command(for: CGSize(width: 120, height: 0)) == .none, "far right: no gain there")
        check(pf.command(for: CGSize(width: 60, height: 35)) == .none, "down-right: no branch there")
        check(full.plusTarget(at: pf.center) == .postFader, "hovering its wire names it")
        check(full.command(for: .postFader, translation: CGSize(width: -50, height: 6)) == .send(.postFader),
              "the diagram dispatches the post-fader key")
        let expectedSlots: [Int: SynopticSendSlot] = [0: .input, 1: .chain(1), 2: .chain(2), 3: .preFader]
        for z in ri {
            check(z.sendSlot == expectedSlots[z.insertIndex], "trunk '+' \(z.insertIndex) carries its slot")
            check(z.command(for: CGSize(width: -60, height: 0)) == .send(expectedSlots[z.insertIndex]!),
                  "trunk '+' \(z.insertIndex): left asks for a send at its slot")
        }

        // 10. A send is drawn LIKE THE OBJECT (request 5 of 13 October 2026): the wire comes in at the column's
        //     top, on its axis, and goes DOWN through the send's plugins — real cards, as on the trunk — to the
        //     send's LINE at the bottom. A plugin-less send: the line under a short stub of wire.
        let H = SynopticLayout.sendCardH
        let plain = send("plain", .chain(1)), two = send("two", .chain(1), plugins: 2)
        let bp = layout(trunk, sends: [plain]), b2 = layout(trunk, sends: [two])
        let cPlain = card(bp, plain)!, c2b = card(b2, two)!
        // the line: one per send, at the BOTTOM of its column, the full width of a send's line
        for (tag, c) in [("plain", cPlain), ("two", c2b)] {
            check(c.lineRect.maxY == c.frame.maxY && c.lineRect.height == H && c.lineRect.width == SynopticLayout.sendCardW,
                  "\(tag): the send's line is at the BOTTOM of its column")
            check(c.frame.contains(c.lineRect), "\(tag): the line inside the column")
            check(c.entry == CGPoint(x: c.axisX, y: c.frame.minY), "\(tag): the wire comes in at the column's top, on its axis")
            check(abs(c.axisX - c.lineRect.midX) < 1e-9, "\(tag): the line is centred on the axis")
        }
        check(cPlain.frame.height == SynopticLayout.sendStubH + H && cPlain.chain.cards.isEmpty,
              "a send without plugin: the line under a stub of wire, no card")
        check(cPlain.chain.inserts.count == 1, "a send without plugin: ONE '+'")
        let zp = cPlain.chain.inserts[0]
        check(zp.center.x == cPlain.axisX && zp.center.y > cPlain.frame.minY && zp.plusRect.maxY <= cPlain.lineRect.minY,
              "its '+' sits on the stub, ABOVE the line")
        check(!zp.alwaysVisible, "its '+' shows on hover only")
        check(zp.hoverRect.contains(CGPoint(x: cPlain.lineRect.midX, y: cPlain.lineRect.midY)),
              "hovering the LINE shows it (a plugin-less send is its line)")
        check(cPlain.chain.cables.count == 1 && cPlain.chain.cables[0].from == cPlain.entry
              && cPlain.chain.cables[0].to == CGPoint(x: cPlain.axisX, y: cPlain.lineRect.minY)
              && cPlain.chain.cables[0].style == .connector, "the stub: from the wire's arrival down into the line, with an arrow")
        // two plugins: two REAL cards, in order, on the axis, above the line
        let cards2 = c2b.chain.cards
        check(cards2.map(\.plugin.id) == two.plugins.map(\.id), "two plugins: two cards, in processing order")
        check(cards2.allSatisfy { $0.frame.height == SynopticLayout.cardH && $0.frame.width == SynopticLayout.cardWidth(for: $0.plugin) },
              "they are real cards (the trunk's size)")
        check(cards2.allSatisfy { abs($0.frame.midX - c2b.axisX) < 1e-9 }, "centred on the column's axis")
        check(cards2[0].frame.maxY < cards2[1].frame.minY && cards2[1].frame.maxY < c2b.lineRect.minY,
              "top to bottom: the first, the second, then the line")
        check(cards2.allSatisfy { c2b.frame.contains($0.frame) }, "no card spills out of its column")
        check(b2.placement.cards.map(\.frame) == bp.placement.cards.map(\.frame) && b2.outPill == bp.outPill,
              "a send's column does not move the trunk")
        // the wire runs down the column without a break: entry → … → the line's top
        let run = c2b.chain.cables
        var pts: [CGPoint] = [c2b.entry]
        let chained = run.allSatisfy { cab in abs(cab.from.x - c2b.axisX) < 1e-9 && abs(cab.to.x - c2b.axisX) < 1e-9 && cab.to.y > cab.from.y }
        check(chained, "every segment of the column is on its axis, going DOWN")
        for cab in run.sorted(by: { $0.from.y < $1.from.y }) { pts.append(cab.to) }
        check(pts.last == CGPoint(x: c2b.axisX, y: c2b.lineRect.minY), "the column's run ends at the line's top")
        check(run.contains { $0.from == c2b.entry }, "the column's first segment leaves from the wire's arrival")
        check(run.contains { $0.to == CGPoint(x: c2b.axisX, y: c2b.lineRect.minY) && $0.style == .connector },
              "the last one arrives at the line, with an arrow")
        for k in cards2 {
            check(run.contains { $0.to == CGPoint(x: k.frame.midX, y: k.frame.minY) && $0.style == .connector },
                  "a segment arrives at card \(k.plugin.name), with an arrow")
        }
        // a '+' on every segment, a send's own keys, hover only
        let ins2 = c2b.chain.inserts.sorted { $0.insertIndex < $1.insertIndex }
        check(ins2.map(\.insertIndex) == [0, 1, 2], "two plugins: three '+' (head, between, tail)")
        check(ins2.allSatisfy { $0.role == .sendChain && $0.key == .sendChain(aux: two.id, index: $0.insertIndex) },
              "they are the send's '+' (role and key)")
        check(ins2.allSatisfy { !$0.alwaysVisible }, "shown on hover only")
        check(ins2.allSatisfy { abs($0.center.x - c2b.axisX) < 1e-9 }, "on the axis")
        check(ins2[0].center.y < cards2[0].frame.minY && ins2[1].center.y > cards2[0].frame.maxY
              && ins2[1].center.y < cards2[1].frame.minY && ins2[2].center.y > cards2[1].frame.maxY
              && ins2[2].plusRect.maxY < c2b.lineRect.minY, "head, between and tail, each on its segment")
        for z in ins2 {
            check(b2.plusTarget(at: z.center) == z.key, "hovering segment \(z.insertIndex) names its '+'")
            check(b2.plusRect(for: z.key) == z.plusRect, "the diagram finds '+' \(z.insertIndex)")
        }
        check(b2.plusTarget(at: CGPoint(x: cards2[0].frame.midX, y: cards2[0].frame.midY)) == nil, "a card's body is no '+' line")
        check(b2.plusRect(for: .sendChain(aux: two.id, index: 7)) == nil && b2.allowedGestures(for: .sendChain(aux: two.id, index: 7)).isEmpty,
              "a '+' that does not exist is not found")
        // insertion slots, counted from the top: the '+' nearest the pointer
        let three = send("three", .postFader, plugins: 3)
        let d3 = layout(trunk, sends: [three])
        let c3 = card(d3, three)!
        let k3c = c3.chain.cards
        let x = c3.axisX
        check(c3.insertIndex(at: CGPoint(x: x, y: c3.frame.minY + 1)) == 0, "the column's top: slot 0")
        check(c3.insertIndex(at: CGPoint(x: x, y: k3c[0].frame.minY + 2)) == 0, "top of the first card: before it")
        check(c3.insertIndex(at: CGPoint(x: x, y: k3c[0].frame.maxY - 2)) == 1, "bottom of the first card: after it")
        check(c3.insertIndex(at: CGPoint(x: x, y: k3c[1].frame.maxY - 1)) == 2, "bottom of the second card: slot 2")
        check(c3.insertIndex(at: CGPoint(x: x, y: k3c[2].frame.maxY - 1)) == 3, "bottom of the last card: slot N")
        check(c3.insertIndex(at: CGPoint(x: x, y: c3.lineRect.midY)) == 3, "on the send's line: the end")
        check(c3.insertIndex(at: CGPoint(x: x, y: c3.frame.maxY + 5)) == nil, "below the column: no slot")
        check(c3.insertIndex(at: CGPoint(x: c3.frame.minX - 5, y: c3.frame.midY)) == nil, "left of the column: no slot")
        check(c3.dropPreview(0).midY == c3.insert(0)!.center.y && c3.dropPreview(9) == c3.dropPreview(3),
              "the drop preview sits on the '+' aimed at, clamped")
        check(cPlain.insertIndex(at: CGPoint(x: cPlain.axisX, y: cPlain.lineRect.midY)) == 0
              && cPlain.insertIndex(at: CGPoint(x: cPlain.axisX, y: zp.center.y)) == 0,
              "a send without plugin: a drop on its line or on its stub is slot 0")
        // a wide plugin name widens the column, never the line; the column stays left-aligned
        var wide = send("wide", .postFader)
        wide.plugins = [SynopticSendPlugin(id: UUID(), name: String(repeating: "W", count: 40))]
        let dw = layout(trunk, sends: [wide])
        let cw = card(dw, wide)!
        check(cw.frame.width >= cw.chain.cards[0].frame.width && cw.lineRect.width == SynopticLayout.sendCardW,
              "a wide card widens its column, not the line")
        check(cw.frame.contains(cw.chain.cards[0].frame) && cw.frame.maxX <= dw.canvasSize.width, "the wide card stays inside")

        // 11. A send's '+': gain gestures only — no branch, no FX link, no send from a send.
        for z in ins2 + [zp] {
            let k = z.key
            check(z.allowedGestures == [.gain, .gainPanMute], "'+' \(z.insertIndex): a gain stage only")
            check(z.command(for: CGSize(width: 3, height: 0)) == .openBrowser(k), "a click: the browser at that '+'")
            check(z.command(for: CGSize(width: 40, height: 0)) == .insertGainStage(k, .gain), "right: a gain stage there")
            check(z.command(for: CGSize(width: 100, height: 5)) == .insertGainStage(k, .gainPanMute), "far right: gain + pan + mute")
            check(z.command(for: CGSize(width: 60, height: 35)) == .none, "down-right: no branch on a send")
            check(z.command(for: CGSize(width: -60, height: 0)) == .none, "left: no send from a send")
        }
        let k3 = SynopticPlusKey.sendChain(aux: three.id, index: 3)
        check(d3.allowedGestures(for: k3) == [.gain, .gainPanMute], "the diagram: a send's '+' offers a gain only")
        check(d3.command(for: k3, translation: CGSize(width: 30, height: 2)) == .insertGainStage(k3, .gain),
              "the diagram dispatches a send's key")
        check(d3.command(for: .sendChain(aux: three.id, index: 1), translation: CGSize(width: 2, height: 1))
              == .openBrowser(.sendChain(aux: three.id, index: 1)), "a click on a middle '+': the browser at THAT index")

        // 12. Without a clip zone, and without a frame, the layout still holds.
        let bus = layout(trunk, sends: [send("b", .postFader), send("c", .input)], mix: false)
        check(bus.sendCards.count == 2 && bus.sendCards.allSatisfy { $0.frame.maxY <= bus.canvasSize.height }, "no mix: still laid")
        check(checkWires(bus, "no mix"), "no mix: no crossing")
        let nf = layout(trunk, sends: [send("b", .postFader), send("c", .input)], frame: false)
        check(nf.objectFrame == nil && checkWires(nf, "no frame"), "no frame: still nested")

        print("\(total - failures)/\(total) send column checks passed (\(mixes) slot mixes swept)")
        exit(failures == 0 ? 0 : 1)
    }
}
