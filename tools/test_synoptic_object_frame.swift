import SwiftUI

// Standalone geometry test of the signal view's OBJECT FRAME and of the '+' laid on the wire
// (docs/plan_synoptic_rework.md §B.2, §B.3, §B.5, §B.7):
//  - the frame runs from the head zone's top edge to the mixer's bottom edge; its left/right edges ARE the head
//    zone's and the mixer's (to the pixel, the FX link rule), its line is drawn inside so the outer edges
//    coincide; the chain sits fxPad inside; the stems and the sends lie outside; no frame for a stem / the
//    Main; the trims' 56 pt gaps are gone;
//  - every '+' sits ON the wire (the wire runs through it), knows the band whose hovering shows it, the
//    element a branch drag puts in parallel (D3), the gestures it offers, and what a gesture does;
//  - the audio zone folds to one row.
//
//     swiftc -parse-as-library -o /tmp/t_frame \
//         ../objekat/Inspector/Synoptic/SynopticGraph.swift \
//         ../objekat/Inspector/Synoptic/SynopticPlusGesture.swift \
//         ../objekat/Inspector/Synoptic/SynopticPlusShortcuts.swift \
//         ../objekat/Inspector/Synoptic/SynopticWidthFlow.swift \
//         ../objekat/Inspector/Synoptic/SynopticLayout.swift test_synoptic_object_frame.swift \
//         && /tmp/t_frame

func L(_ key: String, _ args: CVarArg...) -> String { key }

var failures = 0
var total = 0
func check(_ ok: Bool, _ what: String) {
    total += 1
    if !ok { failures += 1; print("FAIL: \(what)") }
}
func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 1e-6 }

func plug(_ name: String) -> SynopticNode { .plugin(SynopticPlugin(name: name, category: .utility)) }

/// True if the vertical segment x = `x`, `y0`…`y1` is covered by the union of the straight cables.
func wireCovers(_ pl: SynopticLayout.Placement, x: CGFloat, from y0: CGFloat, to y1: CGFloat) -> Bool {
    var y = y0
    while y <= y1 {
        let hit = pl.cables.contains { c in
            abs(c.from.x - x) < 0.01 && abs(c.to.x - x) < 0.01
                && min(c.from.y, c.to.y) - 0.01 <= y && y <= max(c.from.y, c.to.y) + 0.01
        }
        if !hit { return false }
        y += 0.5
    }
    return true
}

@main
struct Main {
    static func main() {
        let a = plug("A"), b = plug("B"), c = plug("C")
        let trunk = SynopticNode.series([a, b, c])

        // MARK: the frame
        func object(_ root: SynopticNode, midi: Bool = false, audio: Bool = true, ara: Bool = false,
                    sends: [SynopticSend] = [], expanded: Bool = true, frame: Bool = true,
                    mix: Bool = true, infinite: Bool = false,
                    received: Int = 0) -> SynopticLayout.Diagram {
            SynopticLayout.diagram(for: root, midi: midi, audioFile: audio && !midi,
                                   araCardWidth: ara ? SynopticLayout.araCardWidth(name: "Melodyne") : nil,
                                   mix: mix, stems: true, sends: sends, sendsEnabled: true,
                                   receivedRows: received, infiniteOption: infinite,
                                   objectFrame: frame, clipOptionsExpanded: expanded)
        }
        let wide = SynopticNode.series([a, .parallel([.series([b]), .series([c]), .series([plug("D")])])])
        let oneSend = [SynopticSend(id: UUID(), name: "Rev", enabled: true, levelDb: -6)]
        let cases: [(String, SynopticLayout.Diagram)] = [
            ("audio unfolded", object(trunk)), ("audio folded", object(trunk, expanded: false)),
            ("midi", object(trunk, midi: true)), ("midi folded", object(trunk, midi: true, expanded: false)),
            ("group (Source pill)", object(trunk, audio: false)),
            ("group infinite (bus head)", object(trunk, audio: false, infinite: true)),
            ("aux receiving (bus head)", object(trunk, audio: false, received: 2)),
            ("ara", object(trunk, ara: true)), ("ara folded", object(trunk, ara: true, expanded: false)),
            ("sends", object(trunk, sends: oneSend)),
            ("empty", object(.series([]))), ("empty group", object(.series([]), audio: false)),
            ("wide chain", object(wide)), ("wide chain group", object(wide, audio: false)),
        ]
        /// Equal to the pixel: the same value once rounded to a whole point AND to the half point (retina).
        func samePixel(_ x: CGFloat, _ y: CGFloat) -> Bool { abs(x - y) < 1e-9 }
        for (tag, d) in cases {
            guard let f = d.objectFrame, let clip = d.clipZone else { check(false, "\(tag): a frame and a mixer"); continue }
            let head = d.sourcePill
            // the head zone and the mixer ARE the frame's sides (the FX link rule): same left, same right, same width
            check(samePixel(head.minX, f.minX) && samePixel(head.maxX, f.maxX), "\(tag): the head's left/right edges are the frame's")
            check(samePixel(clip.minX, f.minX) && samePixel(clip.maxX, f.maxX), "\(tag): the mixer's left/right edges are the frame's")
            check(samePixel(head.width, clip.width), "\(tag): the head and the mixer have one width")
            // the frame's outline IS the boxes' outer outline: top = the head's top, bottom = the mixer's bottom
            check(samePixel(f.minY, head.minY), "\(tag): the frame's top edge is the head's top edge")
            check(samePixel(f.maxY, clip.maxY), "\(tag): the frame's bottom edge is the mixer's bottom edge")
            check(f.contains(head.insetBy(dx: 0.5, dy: 0.5)), "\(tag): the head sits inside the frame (its intro)")
            check(f.contains(clip.insetBy(dx: 0.5, dy: 0.5)), "\(tag): the mixer sits inside the frame (its outro)")
            // the head zone the view draws is that rect
            if let z = d.audioZone { check(z == head, "\(tag): the audio zone is the head rect") }
            if let z = d.midiZone {
                check(z == head, "\(tag): the MIDI zone is the head rect")
                if let s = d.instrumentSlot { check(samePixel(s.midX, f.midX) && f.contains(CGPoint(x: s.midX, y: f.minY)),
                                                   "\(tag): the instrument card is centred in the frame") }
            }
            if let z = d.busHeadZone { check(z == head, "\(tag): the bus head is the head rect") }
            // the stroke: inside the frame by half its line, so its OUTER edge is the boxes' outer edge
            let sr = SynopticLayout.objectFrameStrokeRect(f)
            check(samePixel(sr.minX - SynopticLayout.objectFrameLineWidth / 2, head.minX)
                  && samePixel(sr.maxX + SynopticLayout.objectFrameLineWidth / 2, head.maxX),
                  "\(tag): the frame's line's outer edge lies on the head's and the mixer's outer edge")
            // everything is centred on ONE axis: the frame's
            check(samePixel(head.midX, f.midX) && samePixel(clip.midX, f.midX), "\(tag): head and mixer on the frame's axis")
            check(samePixel(d.outPill.midX, f.midX), "\(tag): the stems on the frame's axis")
            if let p = d.postFaderPlus { check(samePixel(p.center.x, f.midX), "\(tag): the post-fader '+' on the axis") }
            for k in d.placement.cards {
                check(f.contains(k.frame), "\(tag): card \(k.plugin.name) inside the frame")
                check(k.frame.minX >= f.minX + SynopticLayout.fxPad - 1e-6 && k.frame.maxX <= f.maxX - SynopticLayout.fxPad + 1e-6,
                      "\(tag): card \(k.plugin.name) at least fxPad from the frame's sides")
            }
            for z in d.placement.inserts { check(f.contains(z.plusRect), "\(tag): every '+' of the chain is inside the frame") }
            if let r = d.araCard {
                check(f.contains(r) && r.minX >= f.minX + SynopticLayout.fxPad - 1e-6, "\(tag): the ARA card is inside the frame")
                check(samePixel(r.midX, f.midX), "\(tag): the ARA card on the axis")
            }
            check(!f.intersects(d.outPill), "\(tag): the stems lie outside the frame")
            for s in d.sendCards { check(!f.intersects(s.frame), "\(tag): a send box lies outside the frame") }
            check(d.canvasSize.width >= f.maxX + SynopticLayout.margin - 1e-6, "\(tag): the canvas holds the frame")
            check(f.minX >= SynopticLayout.margin - 1e-6, "\(tag): the frame is inside the margin")
            if let p = d.postFaderPlus { check(p.center.y > f.maxY, "\(tag): the post-fader '+' is outside the frame") }
            // the frame is as narrow as it can be: the widest of the chain + 2·fxPad, the head, the mixer
            let chainW = d.placement.cards.map(\.frame.maxX).max().map { $0 - d.placement.cards.map(\.frame.minX).min()! } ?? 0
            check(f.width >= chainW + 2 * SynopticLayout.fxPad - 1e-6, "\(tag): the frame holds the chain with its padding")
        }
        // the frame's width follows the widest of its contents
        check(near(object(trunk, audio: false).objectFrame!.width, SynopticLayout.clipZoneW),
              "a narrow group: the frame is the mixer's width (the Source pill widens to it)")
        check(near(object(trunk).objectFrame!.width, SynopticLayout.audioZoneW), "an audio clip: the audio zone's width")
        let dw = object(wide)
        check(near(dw.objectFrame!.width, SynopticLayout.measure(wide).width + 2 * SynopticLayout.fxPad),
              "a chain wider than the boxes: chain + 2·fxPad, the boxes widen to it")
        // no frame for a stem / the Main (their popover has no object): the boxes keep their own widths
        let host = SynopticLayout.diagram(for: trunk, mix: false, stems: false)
        check(host.objectFrame == nil, "no frame for a bus host")
        check(near(host.sourcePill.width, SynopticLayout.sourceW), "no frame: the Source pill keeps its width")
        let noFrame = SynopticLayout.diagram(for: trunk, audioFile: true, mix: true, stems: true)
        check(noFrame.objectFrame == nil, "no frame unless asked (the interim default)")
        check(near(noFrame.clipZone!.width, SynopticLayout.clipZoneW), "no frame: the mixer keeps its width")
        // a frame without a mixer (not laid by the app, which frames hosts with a mixer only): the foot box is
        // the one the frame's bottom crosses, so it takes the frame's sides
        let footOnly = object(trunk, mix: false)
        check(samePixel(footOnly.outPill.minX, footOnly.objectFrame!.minX) && samePixel(footOnly.outPill.maxX, footOnly.objectFrame!.maxX)
              && samePixel(footOnly.objectFrame!.maxY, footOnly.outPill.maxY), "no mixer: the foot box takes the frame's sides")
        // the frame never moves the content DOWN
        let withF = object(trunk), withoutF = object(trunk, frame: false)
        check(zip(withF.placement.cards, withoutF.placement.cards).allSatisfy { near($0.frame.minY, $1.frame.minY) },
              "the frame never moves the content down")

        // MARK: no 56 pt gap: head → trunk and trunk → mixer are short wires through the trunk's own '+'
        let d = object(trunk)
        let ri = d.placement.inserts.filter { $0.seriesID == trunk.id }.sorted { $0.insertIndex < $1.insertIndex }
        check(ri.count == 4, "four '+' on a 3-entry trunk")
        let head = ri.first!, tail = ri.last!
        check(near(head.plusRect.minY - d.sourcePill.maxY, SynopticLayout.chainGap), "head zone -> head '+': chainGap, no trim gap")
        check(near(d.clipZone!.minY - tail.plusRect.maxY, SynopticLayout.chainGap), "tail '+' -> mixer: chainGap, no trim gap")
        check(d.sourcePill.maxY + 56 > head.plusRect.minY, "the old 56 pt gap is gone")
        let cx = d.sourcePill.midX
        check(wireCovers(d.placement, x: cx, from: d.sourcePill.maxY, to: d.placement.cards[0].frame.minY),
              "an unbroken wire from the head zone into the first card, through the head '+'")
        check(wireCovers(d.placement, x: cx, from: d.placement.cards[2].frame.maxY, to: d.clipZone!.minY),
              "an unbroken wire from the last card into the mixer, through the tail '+'")
        check(wireCovers(d.placement, x: cx, from: d.clipZone!.maxY, to: d.outPill.minY),
              "an unbroken wire mixer -> stems, through the post-fader '+'")
        for z in ri { check(wireCovers(d.placement, x: z.center.x, from: z.plusRect.minY, to: z.plusRect.maxY),
                            "the wire runs THROUGH '+' \(z.insertIndex)") }
        // the arrow belongs to the segment that ARRIVES: the wires that leave a '+' towards no element are plain
        check(d.placement.cables.contains { $0.style == .plain && near($0.from.y, d.sourcePill.maxY) },
              "head zone -> trunk: no arrow of its own")
        check(d.placement.cables.contains { $0.style == .connector && near($0.to.y, d.clipZone!.minY) },
              "the wire arrives at the mixer with an arrow")

        // MARK: the audio zone folds to one row
        let unf = object(trunk, expanded: true), fol = object(trunk, expanded: false)
        check(near(fol.audioZone!.height, SynopticLayout.audioZoneFoldedH) && fol.audioZoneFolded, "folded: one row")
        check(near(unf.audioZone!.height, SynopticLayout.audioZoneH) && !unf.audioZoneFolded,
              "unfolded: the zone (no stereo row: the channels are chosen on the wire)")
        check(near(unf.placement.cards[0].frame.minY - fol.placement.cards[0].frame.minY,
                   unf.audioZone!.height - fol.audioZone!.height), "folding moves the chain up by the difference")
        check(object(trunk, midi: true, expanded: false).audioZone == nil, "a MIDI clip has no audio zone to fold")

        // MARK: the '+': hover bands, D3 branch targets, roles, gestures
        for z in ri {
            check(z.hoverRect.contains(z.center), "'+' \(z.insertIndex): its hover band holds it")
            check(z.role == .trunk, "'+' \(z.insertIndex): the trunk's")
            check(!z.alwaysVisible, "'+' \(z.insertIndex): shown on hover only (the trunk is not empty)")
            check(d.placement.insertZone(at: z.center)?.key == z.key, "'+' \(z.insertIndex): the hit test finds it")
            check(d.plusTarget(at: z.center) == z.key, "'+' \(z.insertIndex): the diagram's hit test finds it")
            check(d.plusRect(for: z.key) == z.plusRect, "'+' \(z.insertIndex): the diagram finds its rect by key")
            for k in d.placement.cards { check(!z.hoverRect.intersects(k.frame.insetBy(dx: 0.5, dy: 0.5)),
                                               "'+' \(z.insertIndex): its band does not cover a card") }
        }
        check(ri[0].branchTargetID == a.id, "D3: the head '+' branches the FIRST element")
        check(ri[1].branchTargetID == b.id && ri[2].branchTargetID == c.id, "D3: a middle '+' branches the element UNDER it")
        check(ri[3].branchTargetID == c.id, "D3: the tail '+' branches the element ABOVE it")
        for z in ri {
            check(z.allowedGestures == [.gain, .gainPanMute, .branch, .send], "'+' \(z.insertIndex): the trunk offers everything")
            check(z.command(for: CGSize(width: 2, height: 1)) == .openBrowser(.series(trunk.id, z.insertIndex)), "click: the browser")
            check(z.command(for: CGSize(width: 40, height: 0)) == .insertGainStage(z.key, .gain), "right: a gain")
            check(z.command(for: CGSize(width: 90, height: 0)) == .insertGainStage(z.key, .gainPanMute), "far right: gain + pan + mute")
            check(z.command(for: CGSize(width: 60, height: 35)) == .branch(z.key), "down-right: the branch, at this '+'")
            check(z.command(for: CGSize(width: -40, height: 0)) == .send(z.sendSlot!), "left: a send at its slot")
            check(z.command(for: CGSize(width: 60, height: -35)) == .none, "up-right: nothing any more")
            check(d.command(for: z.key, translation: CGSize(width: 60, height: 35)) == .branch(z.key),
                  "the diagram dispatches the same command by key")
        }
        // the gestures each '+' offers, by key, as the canvas asks for its zones
        for z in ri { check(d.allowedGestures(for: z.key) == z.allowedGestures, "'+' \(z.insertIndex): allowed gestures by key") }
        check(d.allowedGestures(for: .postFader) == [.send], "the post-fader '+' by key: the send")
        check(d.allowedGestures(for: .series(UUID(), 0)).isEmpty, "a '+' that is gone: nothing")
        // off the wire, no '+'
        check(d.plusTarget(at: CGPoint(x: d.objectFrame!.minX + 1, y: ri[1].center.y)) == nil, "far left of the wire: no '+'")
        check(d.plusTarget(at: CGPoint(x: d.placement.cards[1].frame.midX, y: d.placement.cards[1].frame.midY)) == nil,
              "over a card: no '+'")
        check(d.alwaysVisiblePlusKeys.isEmpty, "nothing always shown on a full trunk")

        // An EMPTY chain: one '+', always shown; a branch there is an EMPTY branch (13 October 2026); a gain, a send.
        let empty = SynopticNode.series([])
        let de = object(empty)
        let ez = de.placement.inserts.filter { $0.seriesID == empty.id }
        check(ez.count == 1 && ez[0].seriesIsEmpty && ez[0].alwaysVisible, "an empty chain: one '+', always shown")
        check(de.alwaysVisiblePlusKeys == [ez[0].key], "the diagram lists it as always shown")
        check(ez[0].branchTargetID == nil && ez[0].allowedGestures.contains(.branch), "an empty chain: a branch offered (an empty one)")
        check(ez[0].command(for: CGSize(width: 60, height: 35)) == .branch(ez[0].key), "branch on an empty chain -> an empty branch there")
        check(ez[0].command(for: CGSize(width: 40, height: 0)) == .insertGainStage(ez[0].key, .gain), "an empty chain: a gain")
        check(ez[0].command(for: CGSize(width: -60, height: 0)) == .send(.input), "an empty chain: a send at the input (left)")
        check(wireCovers(de.placement, x: ez[0].center.x, from: de.sourcePill.maxY, to: de.clipZone!.minY),
              "an empty chain: the wire runs unbroken through its '+'")

        // A parallel: its branches' '+' are `.branch` (gain + branch, no send); a nested '+' wins the hit test.
        let p1 = plug("P1"), p2 = plug("P2")
        let vA = SynopticNode.series([p1]), vB = SynopticNode.series([p2]), vC = SynopticNode.series([])
        let par = SynopticNode.parallel([vA, vB, vC])
        let withPar = SynopticNode.series([a, par])
        let dp = object(withPar)
        for v in [vA, vB] {
            let zs = dp.placement.inserts.filter { $0.seriesID == v.id }
            check(zs.count == 2, "a one-card branch: two '+'")
            for z in zs {
                check(z.role == .branch && z.sendSlot == nil, "a branch's '+': no send")
                check(z.allowedGestures == [.gain, .gainPanMute, .branch], "a branch's '+': gain and branch")
                check(z.command(for: CGSize(width: -60, height: 0)) == .none, "a branch's '+': left (a send) does nothing")
                check(dp.plusTarget(at: z.center) == z.key, "a branch's '+' wins the hit test over the trunk round it")
            }
            check(zs.first { $0.insertIndex == 1 }?.branchTargetID == (v.id == vA.id ? p1.id : p2.id),
                  "a branch's tail '+' branches the element above it")
        }
        let vz = dp.placement.inserts.filter { $0.seriesID == vC.id }
        check(vz.count == 1 && vz[0].alwaysVisible && vz[0].allowedGestures.contains(.branch), "an empty branch: '+' always shown, an (empty) branch offered")
        let rz = dp.placement.inserts.filter { $0.seriesID == withPar.id }
        check(rz.first { $0.insertIndex == 1 }?.branchTargetID == par.id, "the '+' above a parallel branches the parallel")
        check(rz.first { $0.insertIndex == 2 }?.branchTargetID == par.id, "the tail '+' under a parallel branches it")
        // the old branch button's rule is untouched (the element AFTER the '+', nil at the tail)
        check(rz.first { $0.insertIndex == 2 }?.branchElementID == nil && rz.first { $0.insertIndex == 0 }?.branchElementID == a.id,
              "branchElementID keeps its old meaning until L8")

        // insertHoverRects follows inserts
        check(dp.placement.insertHoverRects == dp.placement.inserts.map(\.hoverRect), "insertHoverRects, in the order of inserts")

        // trunk slots
        check(SynopticSendSlot.forTrunkInsert(index: 0, count: 3) == .input, "head ≡ input")
        check(SynopticSendSlot.forTrunkInsert(index: 1, count: 3) == .chain(1), "middle ≡ chain(i)")
        check(SynopticSendSlot.forTrunkInsert(index: 3, count: 3) == .preFader, "tail ≡ pre-fader")
        check(SynopticSendSlot.forTrunkInsert(index: 0, count: 0) == .input, "the one '+' of an empty trunk ≡ input")

        print(failures == 0 ? "ALL PASS (\(total) assertions)" : "failures: \(failures) of \(total)")
        exit(failures == 0 ? 0 : 1)
    }
}
