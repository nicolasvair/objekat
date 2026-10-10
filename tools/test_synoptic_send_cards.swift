import SwiftUI

// Standalone geometry test of the SEND CARDS in the signal view layout (INC 2, step 2.9,
// docs/plan_sends_rework.md §D.1.A.j).
//
// A send is a card in a column BESIDE the trunk, wired to the trunk at its anchor: the input wire, one
// of the ROOT series' own insert points (a position inside the chain), the wire between the OUT gain and
// the clip zone (pre-fader), the wire under the clip zone (post-fader, the default). Nothing is laid
// inside a parallel block, and the trunk's own geometry does not move when sends are added.
//
//     swiftc -parse-as-library -o /tmp/t_sendcards \
//         ../objekat/Inspector/Synoptic/SynopticGraph.swift \
//         ../objekat/Inspector/Synoptic/SynopticLayout.swift test_synoptic_send_cards.swift \
//         && /tmp/t_sendcards

func L(_ key: String, _ args: CVarArg...) -> String { key }

var failures = 0
var total = 0
func check(_ ok: Bool, _ what: String) {
    total += 1
    if !ok { failures += 1; print("FAIL: \(what)") }
}

func plug(_ name: String) -> SynopticNode { .plugin(SynopticPlugin(name: name, category: .utility)) }
func send(_ name: String, _ slot: SynopticSendSlot) -> SynopticSend {
    SynopticSend(id: UUID(), name: name, enabled: true, levelDb: -6, slot: slot)
}
func layout(_ root: SynopticNode, sends: [SynopticSend] = [], enabled: Bool = true,
            mix: Bool = true) -> SynopticLayout.Diagram {
    SynopticLayout.diagram(for: root, audioFile: true, mix: mix, stems: true,
                           sends: sends, sendsEnabled: enabled)
}
func card(_ d: SynopticLayout.Diagram, _ s: SynopticSend) -> SynopticLayout.SendCardPlacement? {
    d.sendCards.first { $0.send.id == s.id }
}

@main
struct Main {
    static func main() {
        let trunk = SynopticNode.series([plug("A"), plug("B"), plug("C")])

        // 1. No sends and a sender: only the "+ Send to…" button; its absence for a non-sender.
        let none = layout(trunk)
        check(none.sendCards.isEmpty, "no send, no card")
        check(none.addSendButton != nil, "a sender always has the + Send to... button")
        check(none.sendSlotDrops.map(\.slot) == [.input, .preFader, .postFader], "three fixed slots, in signal order")
        let non = layout(trunk, enabled: false)
        check(non.addSendButton == nil && non.sendSlotDrops.isEmpty && non.sendCards.isEmpty,
              "an object that does not send has no column, no button, no slot")

        // 2. The trunk does not move when sends appear; only the canvas widens (and may grow in height).
        let all: [SynopticSend] = [send("i", .input), send("c0", .chain(0)), send("c2", .chain(2)),
                                   send("pre", .preFader), send("post", .postFader)]
        let full = layout(trunk, sends: all)
        check(full.outPill == none.outPill && full.sourcePill == none.sourcePill && full.clipZone == none.clipZone,
              "head, clip zone and foot do not move with sends")
        check(full.placement.cards.map(\.frame) == none.placement.cards.map(\.frame), "the plugin cards do not move")
        check(full.canvasSize.width > non.canvasSize.width, "the canvas widens by the column")
        check(non.canvasSize == layout(trunk, enabled: false).canvasSize, "no send, no sender: canvas as before")
        check(full.sendCards.count == all.count, "a card per send")

        // 3. Slot per position.
        let ci = card(full, all[0])!, c0 = card(full, all[1])!, c2 = card(full, all[2])!
        let cp = card(full, all[3])!, cq = card(full, all[4])!
        let inGainY = full.chainInGain!.center.y, outGainY = full.chainOutGain!.center.y
        check(ci.anchor.y > full.sourcePill.maxY && ci.anchor.y < inGainY, "input: between the head and the IN gain")
        let inserts = full.placement.inserts.filter { !$0.seriesID.uuidString.isEmpty }
        let rootID: UUID = { if case .series = trunk.kind { return trunk.id }; return trunk.id }()
        let rootInserts = inserts.filter { $0.seriesID == rootID }
        check(rootInserts.count == 4, "a 3-entry trunk has 4 insert points")
        check(c0.anchor == rootInserts.first { $0.insertIndex == 0 }!.center, "chain(0) = the trunk's head insert point")
        check(c2.anchor == rootInserts.first { $0.insertIndex == 2 }!.center, "chain(2) = the insert point before the 3rd entry")
        check(c0.anchor.y > inGainY && c2.anchor.y < outGainY, "chain anchors lie between the IN and the OUT gain")
        check(cp.anchor.y > outGainY && cp.anchor.y < full.clipZone!.minY, "pre-fader: between the OUT gain and the clip zone")
        check(cq.anchor.y > full.clipZone!.maxY && cq.anchor.y < full.outPill.minY, "post-fader: under the clip zone, above the stems")
        let beyond = layout(trunk, sends: [send("x", .chain(99))])
        check(beyond.sendCards[0].anchor == beyond.placement.inserts.filter { $0.seriesID == rootID }
                .first { $0.insertIndex == 3 }!.center, "chain(99) is clamped to the end of the trunk")
        let empty = SynopticNode.series([])
        let e = layout(empty, sends: [send("e", .chain(0))])
        check(e.sendCards.count == 1 && e.sendCards[0].anchor == e.placement.inserts.first { $0.seriesID == empty.id }!.center,
              "an empty trunk still has its one insert point")

        // 4. Geometry of the column: right of everything, inside the canvas, no overlap, order kept.
        let rightOfTrunk = full.placement.cards.map(\.frame.maxX).max() ?? 0
        for c in full.sendCards {
            check(c.frame.minX > rightOfTrunk, "card \(c.send.name) is right of the trunk's cards")
            check(c.frame.maxX <= full.canvasSize.width && c.frame.maxY <= full.canvasSize.height, "card \(c.send.name) inside the canvas")
            check(c.frame.minX > full.clipZone!.maxX && c.frame.minX > full.stemsZone!.maxX, "card \(c.send.name) clear of the clip and stems zones")
        }
        let byY = full.sendCards.sorted { $0.frame.minY < $1.frame.minY }
        for (a, b) in zip(byY, byY.dropFirst()) { check(a.frame.maxY <= b.frame.minY, "\(a.send.name) / \(b.send.name) do not overlap") }
        check(byY.map(\.send.name) == ["i", "c0", "c2", "pre", "post"], "cards read top to bottom in signal order")
        if let b = full.addSendButton {
            check(b.minY >= cq.frame.maxY && b.maxY <= full.canvasSize.height, "the + Send to... button comes after the post-fader cards")
        }

        // 5. Several sends at one point stack in the order of `sends`, without overlap, and keep their anchor.
        let stack = [send("s1", .chain(1)), send("s2", .chain(1)), send("s3", .chain(1)), send("s4", .postFader)]
        let st = layout(trunk, sends: stack)
        let ys = stack.map { card(st, $0)!.frame.minY }
        check(ys == ys.sorted() && Set(ys).count == 4, "stacked in the order given")
        for (a, b) in zip(stack, stack.dropFirst()) { check(card(st, a)!.frame.maxY <= card(st, b)!.frame.minY, "\(a.name)/\(b.name) disjoint") }
        check(Set(stack.dropLast().map { card(st, $0)!.anchor }).count == 1, "the three share one anchor")
        check(card(st, stack[3])!.frame.minY >= card(st, stack[2])!.frame.maxY, "a post-fader card is pushed below the stack when they collide")

        // 6. Nothing in a branch: with a parallel block in the trunk, anchors are the ROOT's insert points only.
        let branchA = SynopticNode.series([plug("p1")]), branchB = SynopticNode.series([plug("p2")])
        let par = SynopticNode.parallel([branchA, branchB])
        let withPar = SynopticNode.series([plug("A"), par, plug("C")])
        let sp = layout(withPar, sends: [send("m", .chain(1)), send("n", .chain(2))])
        let rootPts = Set(sp.placement.inserts.filter { $0.seriesID == withPar.id }.map { "\($0.center.x),\($0.center.y)" })
        let branchPts = sp.placement.inserts.filter { $0.seriesID == branchA.id || $0.seriesID == branchB.id }
        for c in sp.sendCards { check(rootPts.contains("\(c.anchor.x),\(c.anchor.y)"), "\(c.send.name) hangs on the root series") }
        for c in sp.sendCards { for b in branchPts { check(c.anchor != b.center, "no card anchored in a branch") } }
        let parScope = sp.placement.scopes.first!.rect
        for c in sp.sendCards { check(!parScope.contains(CGPoint(x: c.frame.minX, y: c.frame.midY)), "\(c.send.name) is outside the parallel's backing area") }

        // 7. Slot drop zones contain their anchor and do not overlap one another.
        for z in full.sendSlotDrops {
            check(z.rect.contains(z.anchor), "slot \(z.slot) detects its own anchor")
            check(z.previewFrame.midY == z.anchor.y, "slot \(z.slot) previews at its anchor")
        }
        for (a, b) in zip(full.sendSlotDrops, full.sendSlotDrops.dropFirst()) {
            check(!a.rect.intersects(b.rect), "slots \(a.slot) / \(b.slot) are disjoint")
        }

        // 8. Wires: a card's anchor is on the trunk's axis (or at an insert point), left of the card.
        for c in full.sendCards { check(c.anchor.x < c.frame.minX, "wire of \(c.send.name) leaves the trunk towards the right") }

        // 9. Without a clip zone (a bus) the layout still holds.
        let bus = layout(trunk, sends: [send("b", .postFader)], mix: false)
        check(bus.sendCards.count == 1 && bus.sendCards[0].frame.maxY <= bus.canvasSize.height, "no mix: still laid")

        // 10. INC 3 — the BOX of a send that carries plugins (Q-U19: plugins on top, the line at the bottom).
        func fx(_ name: String) -> SynopticSendPlugin { SynopticSendPlugin(id: UUID(), name: name) }
        func boxed(_ name: String, _ slot: SynopticSendSlot, _ n: Int) -> SynopticSend {
            var s = send(name, slot); s.plugins = (0..<n).map { fx("p\($0)") }; return s
        }
        let H = SynopticLayout.sendCardH, R = SynopticLayout.sendPluginRowH, P = SynopticLayout.sendPlusRowH
        check(SynopticLayout.sendBoxHeight(plugins: 0) == H, "no plugin: the box IS today's card")
        check(SynopticLayout.sendBoxHeight(plugins: 3) == 3 * R + P + H, "3 plugins: 3 rows + the '+' row + the line")
        let plain = send("plain", .chain(1)), two = boxed("two", .chain(1), 2)
        let bp = layout(trunk, sends: [plain]), b2 = layout(trunk, sends: [two])
        let cPlain = card(bp, plain)!, c2b = card(b2, two)!
        check(cPlain.frame.height == H && cPlain.headerRect == cPlain.frame && cPlain.pluginRows.isEmpty,
              "a send without plugin: frame = line, no row")
        check(cPlain.entry == CGPoint(x: cPlain.frame.minX, y: cPlain.frame.midY) && cPlain.entry.y == cPlain.anchor.y,
              "no plugin: the wire arrives at the line's centre, level with the anchor (as in INC 2)")
        check(cPlain.plusRect.maxY == cPlain.frame.minY, "no plugin: the hover '+' sits just above the line")
        check(c2b.frame.height == 2 * R + P + H, "two plugins: the box's height")
        check(c2b.headerRect.maxY == c2b.frame.maxY && c2b.headerRect.height == H, "the send's line is at the BOTTOM")
        check(c2b.pluginRows.count == 2 && c2b.pluginRows[0].minY == c2b.frame.minY
              && c2b.pluginRows[1].minY == c2b.pluginRows[0].maxY, "rows on top, in order, contiguous")
        check(c2b.plusRect.minY == c2b.pluginRows[1].maxY && c2b.plusRect.maxY == c2b.headerRect.minY,
              "the '+' row: after the last plugin, just above the line")
        check(c2b.entry.y == c2b.pluginRows[0].midY && c2b.entry.y == c2b.anchor.y && c2b.entry.x == c2b.frame.minX,
              "the wire arrives at the TOP of the box: its first row, level with the anchor")
        check(b2.placement.cards.map(\.frame) == bp.placement.cards.map(\.frame) && b2.outPill == bp.outPill,
              "a box does not move the trunk")
        check(b2.canvasSize.width == bp.canvasSize.width, "the column's width does not change")
        // Stacking: two boxes at neighbouring slots never overlap, and the canvas grows to hold them.
        let big = [boxed("b1", .chain(0), 4), boxed("b2", .chain(1), 3), send("b3", .chain(1)), boxed("b4", .postFader, 2)]
        let bs = layout(trunk, sends: big)
        let boxes = big.map { card(bs, $0)! }
        for (a, b) in zip(boxes, boxes.dropFirst()) {
            check(a.frame.maxY + SynopticLayout.sendCardGap <= b.frame.minY + 0.001, "\(a.send.name)/\(b.send.name): stacked without overlap")
        }
        check(boxes[0].entry.y == boxes[0].anchor.y, "the first box hangs level with its anchor")
        check(boxes[1].entry.y > boxes[1].anchor.y, "a box pushed down by the one above: its entry is below its anchor")
        for b in boxes { check(b.frame.maxY <= bs.canvasSize.height, "\(b.send.name) inside the canvas") }
        if let btn = bs.addSendButton { check(btn.minY >= boxes[3].frame.maxY, "'+ Send to...' after the last box") }
        // Insertion slots, counted from the top.
        let three = boxed("three", .postFader, 3)
        let c3 = card(layout(trunk, sends: [three]), three)!
        let x = c3.frame.midX
        check(c3.insertIndex(at: CGPoint(x: x, y: c3.frame.minY + 1)) == 0, "top of the first row: slot 0")
        check(c3.insertIndex(at: CGPoint(x: x, y: c3.pluginRows[0].maxY - 1)) == 1, "bottom of the first row: slot 1")
        check(c3.insertIndex(at: CGPoint(x: x, y: c3.pluginRows[1].midY + 2)) == 2, "lower half of the second row: slot 2")
        check(c3.insertIndex(at: CGPoint(x: x, y: c3.pluginRows[2].maxY - 1)) == 3, "bottom of the last row: slot N")
        check(c3.insertIndex(at: CGPoint(x: x, y: c3.plusRect.midY)) == 3, "on the '+' row: the end")
        check(c3.insertIndex(at: CGPoint(x: x, y: c3.headerRect.midY)) == 3, "on the send's line: the end")
        check(c3.insertIndex(at: CGPoint(x: x, y: c3.frame.maxY + 5)) == nil, "outside the box: no slot")
        check(c3.insertIndex(at: CGPoint(x: c3.frame.minX - 5, y: c3.frame.midY)) == nil, "left of the box: no slot")
        check(c3.insertLineY(0) == c3.frame.minY && c3.insertLineY(3) == c3.pluginRows[2].maxY && c3.insertLineY(9) == c3.insertLineY(3),
              "the insertion line: above the first row … under the last, clamped")
        check(cPlain.insertIndex(at: CGPoint(x: cPlain.frame.midX, y: cPlain.frame.midY)) == 0
              && cPlain.insertIndex(at: CGPoint(x: cPlain.frame.midX, y: cPlain.plusRect.midY)) == 0,
              "a send without plugin: a drop on its line or on its hover '+' is slot 0")
        // The fixed slots keep their card-sized preview (a dragged send, not a box).
        check(bs.sendSlotDrops.allSatisfy { $0.previewFrame.height == H }, "slot previews stay one line high")

        print("\(total - failures)/\(total) send card checks passed")
        exit(failures == 0 ? 0 : 1)
    }
}
