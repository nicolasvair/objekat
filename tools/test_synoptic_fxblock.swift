import SwiftUI

// Standalone geometry test of an FX link's block in the signal view layout (rework of October 2026,
// docs/plan_synoptic_rework.md §B.7, §B.8).
//
// A block is TWO nested rectangles: the header card straddling the top edge of the body, and the body
// (what is filled and outlined). There is NO mix box any more (a gain on a bin is a gain stage of its
// series): the body ends `fxPad` under the series' tail '+'. The wire never runs across the header card.
// FOLDED, the block is the header card and a one-line body the wire runs straight through, the series
// not being laid at all.
//
//     swiftc -parse-as-library -o /tmp/t_fx \
//         ../objekat/Inspector/Synoptic/SynopticGraph.swift \
//         ../objekat/Inspector/Synoptic/SynopticPlusGesture.swift \
//         ../objekat/Inspector/Synoptic/SynopticPlusShortcuts.swift \
//         ../objekat/Inspector/Synoptic/SynopticLayout.swift test_synoptic_fxblock.swift \
//         && /tmp/t_fx

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

/// True if the vertical segment x = `x`, `y0`…`y1` is covered by the union of the cables (sampled every pt).
func wireCovers(_ pl: SynopticLayout.Placement, x: CGFloat, from y0: CGFloat, to y1: CGFloat) -> Bool {
    var y = y0
    while y <= y1 {
        let hit = pl.cables.contains { c in
            abs(c.from.x - x) < 0.01 && abs(c.to.x - x) < 0.01
                && min(c.from.y, c.to.y) - 0.01 <= y && y <= max(c.from.y, c.to.y) + 0.01
        }
        if !hit { return false }
        y += 1
    }
    return true
}

func card(_ n: String) -> SynopticNode {
    SynopticNode(id: UUID(), kind: .plugin(SynopticPlugin(name: n, category: .eq)))
}

func fxLink(_ name: String, detached: Bool = false, folded: Bool = false) -> SynopticFXLink {
    var l = SynopticFXLink(blockID: UUID(), name: name, color: .red, isDetached: detached,
                           isEnabled: true, memberCount: 2)
    l.isFolded = folded
    return l
}

func block(_ kids: [SynopticNode], name: String = "Bin", detached: Bool = false,
           folded: Bool = false) -> SynopticNode {
    let fx = fxLink(name, detached: detached, folded: folded)
    var b = SynopticNode(id: fx.blockID, kind: .series(kids))
    b.fxLink = fx
    return b
}

/// What every UNFOLDED block must satisfy, whatever it holds and wherever it sits.
func checkBlock(_ f: SynopticLayout.FXBlockPlacement, in pl: SynopticLayout.Placement, _ tag: String) {
    check(!f.isFolded && f.foldedSummaryRect == nil, "\(tag): unfolded")
    // nested rectangles
    check(f.bodyRect.minY > f.headerRect.minY && f.bodyRect.minY < f.headerRect.maxY,
          "\(tag): the body starts INSIDE the header card's height (it straddles the top edge)")
    check(abs(f.bodyRect.minY - (f.headerRect.maxY - SynopticLayout.fxHeaderOverlap)) < 0.001,
          "\(tag): the overlap is the one constant")
    check(abs(f.headerRect.minY - f.rect.minY) < 0.001, "\(tag): the header card's top is the block's top")
    check(abs(f.headerRect.minX - f.bodyRect.minX) < 0.001 && abs(f.headerRect.width - f.bodyRect.width) < 0.001,
          "\(tag): the header card has the body's width and left edge")
    check(f.rect.contains(f.headerRect) && f.rect.contains(f.bodyRect), "\(tag): the extent holds both")
    check(abs(f.rect.maxY - f.bodyRect.maxY) < 0.001, "\(tag): the extent ends at the body's bottom")
    // §B.8: no output section at all — the placement has no mix box field any more (L8).
    // the body ends fxPad under the series' tail '+'
    let inserts = pl.inserts.filter { $0.seriesID == f.link.blockID }
    if let tail = inserts.max(by: { $0.insertIndex < $1.insertIndex }) {
        check(abs(f.bodyRect.maxY - (tail.plusRect.maxY + SynopticLayout.fxPad)) < 0.001,
              "\(tag): the body ends fxPad under the tail '+'")
        check(f.bodyRect.contains(tail.plusRect), "\(tag): the tail '+' is inside the body")
    } else {
        check(false, "\(tag): the series has its '+'")
    }
    // every '+' of the bin's series: a gain only (it joins the definition), never a branch nor a send
    for z in inserts {
        check(z.role == .fxSeries, "\(tag): its '+' are the bin series'")
        check(z.allowedGestures == [.gain, .gainPanMute], "\(tag): a bin's '+' offers a gain stage only")
        check(z.sendSlot == nil, "\(tag): no send out of a bin")
        check(z.command(for: CGSize(width: 60, height: 35)) == .none, "\(tag): a branch drag does nothing")
        check(z.command(for: CGSize(width: 40, height: 0)) == .insertGainStage(z.key, .gain),
              "\(tag): a drag right asks for a gain stage on the bin's series")
        check(z.command(for: CGSize(width: 2, height: 1)) == .openBrowser(.series(f.link.blockID, z.insertIndex)),
              "\(tag): a click opens the browser on the bin's series")
    }
    // the series sits under the header card, inside the body
    for c in pl.cards where f.bodyRect.contains(c.frame) {
        check(c.frame.minY >= f.headerRect.maxY - 0.001, "\(tag): \(c.plugin.name) is under the header card")
    }
    // THE ARROW BUG: no wire across the header card
    check(!anyCableCrosses(pl, f.headerRect), "\(tag): no wire crosses the header card")
    let cx = f.bodyRect.midX
    // the wire leaves the header card's foot (no arrow: the series' own head cable carries it), and runs
    // unbroken down to the body's bottom
    check(pl.cables.contains { $0.style == .plain && abs($0.from.x - cx) < 0.001
                               && abs($0.from.y - f.headerRect.maxY) < 0.001 },
          "\(tag): a plain wire leaves the header card's foot")
    check(pl.cables.contains { $0.style == .plain && abs($0.to.x - cx) < 0.001
                               && abs($0.to.y - f.bodyRect.maxY) < 0.001 },
          "\(tag): a plain wire reaches the body's bottom (the block's exit)")
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
        let expectedH = SynopticLayout.fxHeaderCardH + SynopticLayout.fxHeaderGap + inner.height + SynopticLayout.fxPad
        check(abs(size.height - expectedH) < 0.001, "block height = card + gap + series + fxPad (no mix box)")
        check(size.width >= SynopticLayout.fxMinW, "block at least fxMinW wide")
        check(size.width >= inner.width + 2 * SynopticLayout.fxPad - 0.001, "block wider than its series by the padding")
        check(SynopticLayout.fxBlockWidth(innerWidth: 10, name: "A") == SynopticLayout.fxMinW,
              "the block's width no longer reserves the mix box (narrow series → fxMinW)")

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
        checkBlock(f, in: pl, "series")
        // the root's '+' round the block: a branch of the BLOCK (an element of the trunk)
        let rootZones = pl.inserts.filter { $0.seriesID == root.id }
        check(rootZones.first { $0.insertIndex == 1 }?.branchTargetID == bin.id, "the '+' above the block branches it")

        // The detector itself must be able to fail.
        var bad = pl
        bad.cables.append(SynopticLayout.Cable(from: CGPoint(x: f.bodyRect.midX, y: f.headerRect.minY),
                                               to: CGPoint(x: f.bodyRect.midX, y: f.bodyRect.maxY), style: .connector))
        check(anyCableCrosses(bad, f.headerRect), "(detector) a wire straight through the header is caught")

        // The entry of the block is the TOP of its header card; its exit the body's bottom.
        let blockPl = SynopticLayout.place(bin, at: CGPoint(x: 40, y: 100))
        check(abs(blockPl.entry.y - blockPl.fxBlocks[0].headerRect.minY) < 0.001, "entry = the header card's top")
        check(abs(blockPl.exit.y - blockPl.fxBlocks[0].bodyRect.maxY) < 0.001, "exit = the body's bottom")
        // the wire is UNBROKEN from the header card's foot to the body's bottom (it runs through the '+')
        let bf = blockPl.fxBlocks[0]
        check(wireCovers(blockPl, x: bf.bodyRect.midX, from: bf.headerRect.maxY, to: bf.bodyRect.maxY)
              == false, "(cards interrupt it: the wire is checked between the cards below)")
        for z in blockPl.inserts {
            check(wireCovers(blockPl, x: z.center.x, from: z.plusRect.minY, to: z.plusRect.maxY),
                  "the wire runs THROUGH the '+' at index \(z.insertIndex)")
        }

        // MARK: whatever the content height
        for n in [0, 1, 2, 5, 12] {
            let nb = block((0..<n).map { card("C\($0)") }, name: "H\(n)")
            let npl = SynopticLayout.place(nb, at: CGPoint(x: 7, y: 13))
            let nf = npl.fxBlocks[0]
            check(abs(nf.bodyRect.maxY - (13 + SynopticLayout.measure(nb).height)) < 0.001, "body bottom = extent with \(n) plugins")
            checkBlock(nf, in: npl, "\(n) plugins")
        }

        // MARK: widths
        let longStr = String(repeating: "Very long bin name ", count: 4)
        let longName = block([a], name: longStr)
        check(SynopticLayout.measure(longName).width >= SynopticLayout.fxHeaderW(name: longStr) - 0.001,
              "a long name widens the block up to the header's cap")
        check(SynopticLayout.fxHeaderW(name: String(repeating: "x", count: 400)) <= SynopticLayout.audioZoneW + 0.001,
              "the header card never exceeds the audio zone's width")
        check(SynopticLayout.fxHeaderW(name: "A") >= SynopticLayout.cardW - 0.001, "a short name keeps the card width")
        let longPl = SynopticLayout.place(longName, at: .zero)
        checkBlock(longPl.fxBlocks[0], in: longPl, "long name")
        let wideName = String(repeating: "W", count: 60)
        let wide = block([card(wideName)], name: "A")
        let widePl = SynopticLayout.place(wide, at: .zero)
        check(widePl.fxBlocks[0].bodyRect.width >= SynopticLayout.cardWidth(for: SynopticPlugin(name: wideName, category: .eq)) + 2 * SynopticLayout.fxPad - 0.001,
              "a wide card widens the body")
        checkBlock(widePl.fxBlocks[0], in: widePl, "wide card")

        // MARK: gain stages are cards of their own width
        let g = SynopticPlugin(name: "Gain", category: .utility, gainStage: .gain)
        let gpm = SynopticPlugin(name: "Gain", category: .utility, gainStage: .gainPanMute)
        check(SynopticLayout.cardWidth(for: g) == SynopticLayout.gainStageW, "a gain stage: gainStageW")
        check(SynopticLayout.cardWidth(for: gpm) == SynopticLayout.fxMixW, "a gain + pan + mute stage: the old mix box's width")
        let gpl = SynopticLayout.place(block([SynopticNode(id: UUID(), kind: .plugin(gpm))]), at: .zero)
        check(gpl.cards.first.map { abs($0.frame.width - SynopticLayout.fxMixW) < 0.001 && $0.frame.height == SynopticLayout.cardH } ?? false,
              "a stage is laid as a card")
        checkBlock(gpl.fxBlocks[0], in: gpl, "gain stage inside")

        // MARK: an empty block still holds its '+', always shown
        let empty = block([])
        let epl = SynopticLayout.place(SynopticNode(id: UUID(), kind: .series([card("x"), empty])), at: .zero)
        check(epl.fxBlocks.count == 1 && epl.fxBlocks[0].pluginCount == 0, "an empty block is laid, with no entry")
        checkBlock(epl.fxBlocks[0], in: epl, "empty")
        let emptyZones = epl.inserts.filter { $0.seriesID == empty.id }
        check(emptyZones.count == 1 && emptyZones[0].insertIndex == 0, "an empty block has exactly one '+', at index 0")
        check(emptyZones.first.map { epl.fxBlocks[0].rect.contains($0.center) } ?? false, "the empty block's '+' sits inside the block")
        check(emptyZones.first?.alwaysVisible == true, "the empty block's '+' is always shown")

        // MARK: detached = the same geometry
        let det = block([a, b], detached: true)
        let dpl = SynopticLayout.place(SynopticNode(id: UUID(), kind: .series([det])), at: .zero)
        checkBlock(dpl.fxBlocks[0], in: dpl, "detached")
        check(abs(SynopticLayout.measure(det).height - size.height) < 0.001, "detached block: same size")

        // MARK: in a parallel branch
        let par = SynopticNode(id: UUID(), kind: .parallel([
            SynopticNode(id: UUID(), kind: .series([block([card("P1"), card("P2")], name: "Branch bin")])),
            SynopticNode(id: UUID(), kind: .series((0..<6).map { card("Other\($0)") })),
        ]))
        let ppl = SynopticLayout.place(SynopticNode(id: UUID(), kind: .series([par])), at: .zero)
        check(ppl.fxBlocks.count == 1, "a block in a parallel branch is laid")
        checkBlock(ppl.fxBlocks[0], in: ppl, "parallel branch")
        check(ppl.scopes.contains { $0.rect.contains(ppl.fxBlocks[0].rect) }, "the branch's backing area holds the block")

        // MARK: two blocks in a row do not crowd each other
        let two = SynopticNode(id: UUID(), kind: .series([block([a], name: "One"), block([b], name: "Two")]))
        let tpl = SynopticLayout.place(two, at: .zero)
        check(tpl.fxBlocks.count == 2, "two blocks")
        for fb in tpl.fxBlocks { checkBlock(fb, in: tpl, "two blocks (\(fb.link.name))") }
        check(!tpl.fxBlocks[0].rect.intersects(tpl.fxBlocks[1].rect), "two consecutive blocks do not overlap")

        // MARK: FOLDED (§B.7)
        let folded = block([card("F1"), card("F2"), card("F3")], name: "Folded", folded: true)
        let fs = SynopticLayout.measure(folded)
        check(abs(fs.height - (SynopticLayout.fxHeaderCardH + SynopticLayout.fxFoldedBodyH)) < 0.001,
              "folded: header card + one line")
        check(abs(fs.width - SynopticLayout.fxFoldedWidth(name: "Folded")) < 0.001, "folded: the header's width")
        let fpl = SynopticLayout.place(SynopticNode(id: UUID(), kind: .series([before, folded, after])), at: .zero)
        let ff = fpl.fxBlocks.first { $0.link.name == "Folded" }!
        check(ff.isFolded, "the block says it is folded")
        check(ff.pluginCount == 3, "a folded block still knows its count (its one line)")
        check(fpl.cards.count == 2 && !fpl.cards.contains { ff.rect.intersects($0.frame) },
              "folded: its series is not laid (no card)")
        check(!fpl.inserts.contains { $0.seriesID == folded.id }, "folded: no '+' of its series")
        check(!fpl.cableDrops.contains { $0.seriesID == folded.id }, "folded: no drop zone of its series")
        check(!anyCableCrosses(fpl, ff.headerRect), "folded: no wire across the header card")
        check(wireCovers(fpl, x: ff.bodyRect.midX, from: ff.headerRect.maxY, to: ff.bodyRect.maxY),
              "folded: the wire runs straight through the one-line body")
        if let s = ff.foldedSummaryRect {
            check(s.minX > ff.bodyRect.midX, "folded: the line is written beside the wire, never across it")
            check(ff.bodyRect.contains(s), "folded: the line is inside the body")
        } else { check(false, "folded: a summary rect is laid") }
        // the trunk's '+' still surround it: a branch drag above it targets the block
        check(fpl.inserts.first { $0.insertIndex == 1 }?.branchTargetID == folded.id, "folded: the '+' above it branches it")
        // folded is SHORTER than the same block unfolded
        var unfolded = folded; unfolded.fxLink?.isFolded = false
        check(SynopticLayout.measure(unfolded).height > fs.height, "folding shortens the block")
        check(folded.fxLink?.stateKey == folded.fxLink?.blockID, "a block without a bin id is folded by its block id")
        var withLink = folded.fxLink!; let lid = UUID(); withLink.linkID = lid
        check(withLink.stateKey == lid, "a block with a bin id is folded by the BIN's id (one fold for every host)")

        // MARK: the ARA source's card: first under the "audio file" frame, above the chain
        let araRoot = SynopticNode(id: UUID(), kind: .series([card("Fx")]))
        let withARA = SynopticLayout.diagram(for: araRoot, audioFile: true,
                                             araCardWidth: SynopticLayout.araCardWidth(name: "Melodyne"))
        let noARA = SynopticLayout.diagram(for: araRoot, audioFile: true)
        if let ac = withARA.araCard, let az = withARA.audioZone, let fx = withARA.placement.cards.first?.frame {
            check(ac.minY >= az.maxY + SynopticLayout.araCardGap - 0.5, "the ARA card sits under the audio frame")
            check(ac.maxY <= fx.minY, "the ARA card is above the first FX")
            check(abs(ac.midX - az.midX) < 0.5, "the ARA card is centred on the audio frame")
            check(ac.width <= az.width + 0.5, "the ARA card is no wider than the audio frame")
            check(withARA.canvasSize.height > noARA.canvasSize.height, "the card makes the canvas taller")
        } else {
            check(false, "an ARA card is laid when asked")
        }
        check(noARA.araCard == nil, "no ARA card when not asked")
        let plainW = SynopticLayout.cardWidth(for: SynopticPlugin(name: "Melodyne", category: .utility))
        let araW = SynopticLayout.araCardWidth(name: "Melodyne")
        check(araW >= plainW, "the ARA card is at least as wide as a plugin card of the same name")
        check(araW <= SynopticLayout.audioZoneW, "the ARA card is no wider than the audio frame")
        check(SynopticLayout.araCardWidth(name: String(repeating: "Melodyne ", count: 12)) == SynopticLayout.audioZoneW,
              "a very long name is capped at the audio frame's width")
        if let fa = withARA.placement.cards.first?.frame, let fb = noARA.placement.cards.first?.frame {
            check(abs(fa.midX - fb.midX) < 0.5, "the trunk's axis is the same with and without the ARA card")
            check(abs(withARA.canvasSize.width - noARA.canvasSize.width) < 0.5, "the ARA card does not widen the canvas")
        }

        print(failures == 0 ? "ALL PASS (\(total) assertions)" : "failures: \(failures) of \(total)")
        exit(failures == 0 ? 0 : 1)
    }
}
