import SwiftUI

// Standalone geometry test of an FX link's block in the signal view layout.
//
// A block is THREE nested rectangles: the header card straddling the top edge of the body, the body
// (what is filled and outlined), and the mix box (pan · volume · mute) nested at the body's foot. The
// wire stops at the header and at the mix box and starts again on the other side — the regression
// this file guards is the old arrow that ran straight through the header AND the footer.
//
//     swiftc -parse-as-library -o /tmp/t_fxblock \
//         ../objekat/Inspector/Synoptic/SynopticGraph.swift \
//         ../objekat/Inspector/Synoptic/SynopticLayout.swift test_synoptic_fxblock.swift \
//         && /tmp/t_fxblock

func L(_ key: String, _ args: CVarArg...) -> String { key }

var failures = 0
var total = 0
func check(_ ok: Bool, _ what: String) {
    total += 1
    if !ok { failures += 1; print("FAIL: \(what)") }
}

/// Points along a cable, as the view draws it: a straight line for a connector / plain wire, the
/// vertical-control cubic for a fork / merge.
func samples(_ c: SynopticLayout.Cable, n: Int = 200) -> [CGPoint] {
    (0...n).map { i in
        let t = CGFloat(i) / CGFloat(n)
        switch c.style {
        case .connector, .plain, .ghost:
            return CGPoint(x: c.from.x + (c.to.x - c.from.x) * t, y: c.from.y + (c.to.y - c.from.y) * t)
        case .fork, .merge:
            let midY = (c.from.y + c.to.y) / 2
            let p0 = c.from, p1 = CGPoint(x: c.from.x, y: midY), p2 = CGPoint(x: c.to.x, y: midY), p3 = c.to
            let u = 1 - t
            let x = u*u*u*p0.x + 3*u*u*t*p1.x + 3*u*t*t*p2.x + t*t*t*p3.x
            let y = u*u*u*p0.y + 3*u*u*t*p1.y + 3*u*t*t*p2.y + t*t*t*p3.y
            return CGPoint(x: x, y: y)
        }
    }
}

/// True if some cable of `pl` passes through the INTERIOR of `rect` (touching its edge is allowed:
/// that is where a wire stops or starts).
func anyCableCrosses(_ pl: SynopticLayout.Placement, _ rect: CGRect) -> Bool {
    let inside = rect.insetBy(dx: 0.5, dy: 0.5)
    for c in pl.cables where samples(c).contains(where: { inside.contains($0) }) { return true }
    return false
}

func card(_ n: String) -> SynopticNode {
    SynopticNode(id: UUID(), kind: .plugin(SynopticPlugin(name: n, category: .eq)))
}

func fxLink(_ name: String, detached: Bool = false) -> SynopticFXLink {
    SynopticFXLink(blockID: UUID(), name: name, color: .red, isDetached: detached,
                   isEnabled: true, gainDb: 0, pan: 0, muted: false, memberCount: 2)
}

func block(_ kids: [SynopticNode], name: String = "Bin", detached: Bool = false) -> SynopticNode {
    let fx = fxLink(name, detached: detached)
    var b = SynopticNode(id: fx.blockID, kind: .series(kids))
    b.fxLink = fx
    return b
}

/// What every block must satisfy, whatever it holds and wherever it sits.
func checkBlock(_ f: SynopticLayout.FXBlockPlacement, in pl: SynopticLayout.Placement, _ tag: String) {
    // nested rectangles
    check(f.bodyRect.minY > f.headerRect.minY && f.bodyRect.minY < f.headerRect.maxY,
          "\(tag): the body starts INSIDE the header card's height (it straddles the top edge)")
    check(abs(f.bodyRect.minY - (f.headerRect.maxY - SynopticLayout.fxHeaderOverlap)) < 0.001,
          "\(tag): the overlap is the one constant")
    check(f.bodyRect.contains(f.mixRect), "\(tag): the mix box is inside the body")
    check(f.bodyRect.minX <= f.headerRect.minX + 0.001 && f.headerRect.maxX <= f.bodyRect.maxX + 0.001,
          "\(tag): the header card is no wider than the body")
    // the top and the bottom rectangles are EXACTLY as wide as the body round them, edge for edge
    check(abs(f.headerRect.minX - f.bodyRect.minX) < 0.001 && abs(f.headerRect.width - f.bodyRect.width) < 0.001,
          "\(tag): the header card has the body's width and left edge")
    check(abs(f.mixRect.minX - f.bodyRect.minX) < 0.001 && abs(f.mixRect.width - f.bodyRect.width) < 0.001,
          "\(tag): the mix box has the body's width and left edge")
    check(abs(f.headerRect.width - f.rect.width) < 0.001 && abs(f.mixRect.width - f.rect.width) < 0.001,
          "\(tag): header card, mix box and the block's extent share one width")
    check(f.rect.contains(f.headerRect) && f.rect.contains(f.bodyRect), "\(tag): the extent holds both")
    check(abs(f.rect.minY - f.headerRect.minY) < 0.001 && abs(f.rect.maxY - f.bodyRect.maxY) < 0.001,
          "\(tag): the extent runs from the card's top to the body's bottom")
    check(abs(f.headerRect.midX - f.bodyRect.midX) < 0.001 && abs(f.mixRect.midX - f.bodyRect.midX) < 0.001,
          "\(tag): header card and mix box are centred on the wire")
    // the mix box's slots: left → right pan < volume < mute, inside the box
    check(f.panSlot.maxX <= f.volumeSlot.minX + 0.001 && f.volumeSlot.maxX <= f.muteSlot.minX + 0.001,
          "\(tag): pan < volume < mute, left to right, without overlap")
    check(f.panSlot.minX < f.volumeSlot.minX && f.volumeSlot.minX < f.muteSlot.minX, "\(tag): slot order")
    for (n, s) in [("pan", f.panSlot), ("volume", f.volumeSlot), ("mute", f.muteSlot)] {
        check(f.mixRect.contains(s), "\(tag): the \(n) slot is inside the mix box")
    }
    // the series sits between the header card and the mix box
    for c in pl.cards where f.bodyRect.contains(c.frame) {
        check(c.frame.minY >= f.headerRect.maxY - 0.001, "\(tag): \(c.plugin.name) is under the header card")
        check(c.frame.maxY <= f.mixRect.minY + 0.001, "\(tag): \(c.plugin.name) is above the mix box")
    }
    // THE ARROW BUG: no wire across the header card, none across the mix box
    check(!anyCableCrosses(pl, f.headerRect), "\(tag): no wire crosses the header card")
    check(!anyCableCrosses(pl, f.mixRect), "\(tag): no wire crosses the mix box")
    // the wire stops, then starts again
    let cx = f.bodyRect.midX
    check(pl.cables.contains { $0.style == .connector && abs($0.from.x - cx) < 0.001
                               && abs($0.from.y - f.headerRect.maxY) < 0.001 },
          "\(tag): a wire (with its arrow) leaves the header card's foot")
    check(pl.cables.contains { $0.style == .connector && abs($0.to.x - cx) < 0.001
                               && abs($0.to.y - f.mixRect.minY) < 0.001 },
          "\(tag): the wire STOPS at the mix box's head, with an arrow")
    check(pl.cables.contains { $0.style == .plain && abs($0.from.y - f.mixRect.maxY) < 0.001
                               && abs($0.to.y - f.bodyRect.maxY) < 0.001 },
          "\(tag): the wire starts AGAIN at the mix box's foot, with no arrowhead")
    check(!pl.cables.contains { $0.style == .connector && abs($0.from.x - cx) < 0.001
                                && abs($0.from.y - f.mixRect.maxY) < 0.001 },
          "\(tag): no arrowhead on the wire that leaves the mix box")
}

@main struct T {
    static func main() {
        let a = card("EQ"), b = card("Compressor")
        let bin = block([a, b])
        let before = card("Before"), after = card("After")
        let root = SynopticNode(id: UUID(), kind: .series([before, bin, after]))

        // MARK: measure / place agree
        let size = SynopticLayout.measure(bin)
        var bare = bin; bare.fxLink = nil
        let inner = SynopticLayout.measure(bare)
        let expectedH = SynopticLayout.fxHeaderCardH + SynopticLayout.fxHeaderGap + inner.height
                      + SynopticLayout.fxMixGap + SynopticLayout.fxMixH + SynopticLayout.fxPad
        check(abs(size.height - expectedH) < 0.001, "block height = card + gap + series + gap + mix + pad")
        check(size.width >= SynopticLayout.fxMinW, "block at least fxMinW wide")
        check(size.width >= inner.width + 2 * SynopticLayout.fxPad - 0.001, "block wider than its series by the padding")
        check(size.width >= SynopticLayout.fxMixW + 2 * SynopticLayout.fxPad - 0.001, "block holds the mix box and its margins")

        let pl = SynopticLayout.place(root, at: .zero)
        check(pl.fxBlocks.count == 1, "one block laid")
        guard let f = pl.fxBlocks.first else { print("failures: \(failures)"); exit(1) }
        check(abs(f.rect.width - size.width) < 0.001 && abs(f.rect.height - size.height) < 0.001, "extent = measured size")
        check(f.pluginCount == 2, "the block knows how many entries it holds")
        for c in pl.cards where c.plugin.name == "EQ" || c.plugin.name == "Compressor" {
            check(f.bodyRect.contains(c.frame), "\(c.plugin.name) inside the body")
        }
        for c in pl.cards where c.plugin.name == "Before" || c.plugin.name == "After" {
            check(!f.rect.intersects(c.frame), "\(c.plugin.name) outside the block")
        }
        check(pl.cards.count == 4, "four cards")
        check(pl.size.height >= f.rect.maxY - 0.001, "the diagram holds the block")
        checkBlock(f, in: pl, "series")

        // The detector itself must be able to fail: the OLD layout's wire ran from the block's top to the
        // series, straight through the header — exactly what this builds.
        var bad = pl
        bad.cables.append(SynopticLayout.Cable(from: CGPoint(x: f.bodyRect.midX, y: f.headerRect.minY),
                                               to: CGPoint(x: f.bodyRect.midX, y: f.mixRect.minY), style: .connector))
        check(anyCableCrosses(bad, f.headerRect), "(detector) a wire straight through the header is caught")
        check(anyCableCrosses(bad, f.mixRect) == false, "(detector) one that stops at the mix box's head is not")

        // The entry of the block is the TOP of its header card (the previous element's wire lands there).
        let blockPl = SynopticLayout.place(bin, at: CGPoint(x: 40, y: 100))
        check(abs(blockPl.entry.y - blockPl.fxBlocks[0].headerRect.minY) < 0.001, "entry = the header card's top")
        check(abs(blockPl.exit.y - blockPl.fxBlocks[0].bodyRect.maxY) < 0.001, "exit = the body's bottom")

        // MARK: widths
        let longName = block([a], name: String(repeating: "Very long bin name ", count: 4))
        let lw = SynopticLayout.measure(longName).width
        check(lw >= SynopticLayout.fxHeaderW(name: String(repeating: "Very long bin name ", count: 4)) - 0.001,
              "a long name widens the block up to the header's cap")
        check(SynopticLayout.fxHeaderW(name: String(repeating: "x", count: 400)) <= SynopticLayout.audioZoneW + 0.001,
              "the header card never exceeds the audio zone's width")
        check(SynopticLayout.fxHeaderW(name: "A") >= SynopticLayout.cardW - 0.001, "a short name keeps the card width")
        let longPl = SynopticLayout.place(longName, at: .zero)
        checkBlock(longPl.fxBlocks[0], in: longPl, "long name")
        let wide = block([card(String(repeating: "W", count: 60))], name: "A")
        let widePl = SynopticLayout.place(wide, at: .zero)
        check(widePl.fxBlocks[0].bodyRect.width >= SynopticLayout.cardWidth(for: SynopticPlugin(name: String(repeating: "W", count: 60), category: .eq)) + 2 * SynopticLayout.fxPad - 0.001,
              "a wide card widens the body")
        checkBlock(widePl.fxBlocks[0], in: widePl, "wide card")

        // MARK: an empty block still holds its '+', and the geometry holds
        let empty = block([])
        let es = SynopticLayout.measure(empty)
        check(es.height > SynopticLayout.fxHeaderCardH + SynopticLayout.fxMixH, "an empty block still holds its '+'")
        let epl = SynopticLayout.place(SynopticNode(id: UUID(), kind: .series([card("x"), empty])), at: .zero)
        check(epl.fxBlocks.count == 1 && epl.fxBlocks[0].pluginCount == 0, "an empty block is laid, with no entry")
        checkBlock(epl.fxBlocks[0], in: epl, "empty")

        // MARK: detached = the same geometry
        let det = block([a, b], detached: true)
        let dpl = SynopticLayout.place(SynopticNode(id: UUID(), kind: .series([det])), at: .zero)
        checkBlock(dpl.fxBlocks[0], in: dpl, "detached")
        check(abs(SynopticLayout.measure(det).height - size.height) < 0.001, "detached block: same size")

        // MARK: in a parallel branch
        let par = SynopticNode(id: UUID(), kind: .parallel([
            SynopticNode(id: UUID(), kind: .series([block([card("P1"), card("P2")], name: "Branch bin")])),
            SynopticNode(id: UUID(), kind: .series([card("Other")])),
        ]))
        let ppl = SynopticLayout.place(SynopticNode(id: UUID(), kind: .series([par])), at: .zero)
        check(ppl.fxBlocks.count == 1, "a block in a parallel branch is laid")
        checkBlock(ppl.fxBlocks[0], in: ppl, "parallel branch")
        check(ppl.scopes.contains { $0.rect.contains(ppl.fxBlocks[0].rect) }, "the branch's backing area holds the block")

        // MARK: two blocks in a row, and a block right after the head, do not crowd each other
        let two = SynopticNode(id: UUID(), kind: .series([block([a], name: "One"), block([b], name: "Two")]))
        let tpl = SynopticLayout.place(two, at: .zero)
        check(tpl.fxBlocks.count == 2, "two blocks")
        for fb in tpl.fxBlocks { checkBlock(fb, in: tpl, "two blocks (\(fb.link.name))") }
        check(!tpl.fxBlocks[0].rect.intersects(tpl.fxBlocks[1].rect), "two consecutive blocks do not overlap")

        print(failures == 0 ? "ALL PASS (\(total) assertions)" : "failures: \(failures) of \(total)")
        exit(failures == 0 ? 0 : 1)
    }
}
