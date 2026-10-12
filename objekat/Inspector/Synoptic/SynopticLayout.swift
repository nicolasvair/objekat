import SwiftUI
import AppKit

// MARK: - The signal view's layout engine (VERTICAL)
//
// Walks a `SynopticNode` recursively and produces, in absolute coordinates, the
// positions of the cards, the fork/merge cables, the split/merge nodes, the backing
// areas of parallel blocks, and the adding zones (a series '+' / a '//' branch).
//
// A VERTICAL flow, top → bottom. A SERIES stacks its children (centred horizontally);
// a PARALLEL places its branches SIDE BY SIDE and joins them with cables from a split
// node (at the top) to a merge node (at the bottom).

enum SynopticLayout {

    // Layout constants
    static let cardW: CGFloat = 124
    static let cardH: CGFloat = 30         // a single line: on/off · name · ✕ (plus a thin VU meter)
    static let seriesGap: CGFloat = 34     // the vertical space between the elements of a series
    static let voiceGap: CGFloat = 20      // the horizontal space between parallel branches
    static let forkH: CGFloat = 26         // the height reserved for the fork/merge cables above and below a parallel
    static let scopePad: CGFloat = 14      // the inner margin of a parallel's backing area
    static let plusW: CGFloat = 20         // the diameter of a '+' zone
    static let plusGap: CGFloat = 12       // the space before the '+' zone at the end of a series
    // An FX link's block: a coloured rounded rectangle (the BODY) round its series, with a header CARD
    // (on/off · name · link badge · ✕) straddling its top edge and a mix box (pan · volume · mute) nested at
    // its foot, FLUSH with the body's bottom edge (the mix box's bottom IS the block's bottom, whatever the
    // series above holds: the top block stays at the top, the bottom block at the bottom). The wire STOPS at
    // the header card and at the mix box (an arrow into each); it starts again at the mix box's foot, which
    // is the block's exit: it never runs behind them.
    static let fxHeaderCardH: CGFloat = cardH
    /// How much of the header card hangs INSIDE the body — the ONE constant that decides how the card
    /// straddles the body's top edge (half of it: the body starts at the card's middle line).
    static let fxHeaderOverlap: CGFloat = fxHeaderCardH / 2
    static let fxHeaderGap: CGFloat = 10   // the wire between the header card and the first '+' of the series (room for the arrow)
    static let fxMixH: CGFloat = 26
    static let fxMixW: CGFloat = 150
    static let fxMixGap: CGFloat = 12      // the wire between the series' last '+' and the mix box (room for the arrow)
    static let fxPad: CGFloat = 10         // the inner margin on each side of the block's series (nothing under the mix box: it is flush with the body's bottom)
    static let fxMinW: CGFloat = 176
    /// The body's corner radius. The mix box is flush with the body's bottom edge, so its two bottom corners
    /// take the SAME radius (otherwise they would poke out of the body's outline).
    static let fxBodyCorner: CGFloat = 12
    static let fxMixTopCorner: CGFloat = 8
    /// The mix box's three slots, left → right: pan · volume · mute.
    static let fxPanW: CGFloat = 52
    static let fxVolumeW: CGFloat = 46
    static let fxMuteW: CGFloat = 18
    static let fxSlotGap: CGFloat = 6
    static let fxSlotH: CGFloat = 18
    static let gainBandH: CGFloat = 30     // the band reserved for the mute plus end-of-branch dB gain of a parallel branch (under the branches)

    /// A card's width: wide enough for its whole name and its link badge, from `cardW` (the old
    /// fixed width, which truncated a name beside the badge to a few letters) up to the
    /// 'audio file' zone's width at the head of the chain — never wider than that header.
    /// Measured on the card's own name font; the rest is the card's fixed chrome (on/off button,
    /// paddings, ✕, and the badge when there is one). @see SynopticCardView.
    static func cardWidth(for p: SynopticPlugin) -> CGFloat {
        let nameW = ceil((p.name as NSString).size(withAttributes: [.font: cardNameFont]).width)
        let hasBadge = p.showsLinkBadge
        // on/off 26 · padding 8+8 · ✕ ~9 + gap 6 · badge 18+6 · 4 of slack so the tail never ellipsises
        let chrome: CGFloat = 26 + 16 + 15 + (hasBadge ? 24 : 0) + 4
        return min(audioZoneW, max(cardW, nameW + chrome))
    }

    static let cardNameFont = NSFont.systemFont(ofSize: 12, weight: .medium)

    /// The ARA source card's width: its whole name, from `cardW` up to the 'audio file' frame's width, like
    /// any card (@see cardWidth). Its chrome is a plugin card's (on/off 26 · padding 8+8 · ✕ ~9 + gap 6 ·
    /// 4 of slack) plus the analysis spinner ~12 + gap 6; it never has a link badge.
    static func araCardWidth(name: String) -> CGFloat {
        let nameW = ceil((name as NSString).size(withAttributes: [.font: cardNameFont]).width)
        return min(audioZoneW, max(cardW, nameW + 26 + 16 + 18 + 15 + 4))
    }

    /// A bin's header card width: its name whole, from `cardW` up to the 'audio file' zone's width, like a
    /// plugin card (@see cardWidth) — the chrome is the same, and the link badge is always there:
    /// on/off 26 · padding 8+8 · ✕ ~9 + gap 6 · badge 18+6 · 4 of slack.
    static func fxHeaderW(name: String) -> CGFloat {
        let nameW = ceil((name as NSString).size(withAttributes: [.font: cardNameFont]).width)
        let chrome: CGFloat = 26 + 16 + 15 + 24 + 4
        return min(audioZoneW, max(cardW, nameW + chrome))
    }

    /// A bin's block width: its series plus the margins, never narrower than its header card or its
    /// mix box (with its margins), nor than `fxMinW`.
    static func fxBlockWidth(innerWidth: CGFloat, name: String) -> CGFloat {
        max(fxMinW, innerWidth + 2 * fxPad, fxHeaderW(name: name), fxMixW + 2 * fxPad)
    }

    /// A rectangle the size of a card, centred on `(cx, cy)`: it serves as a drop preview.
    static func cardFrame(_ cx: CGFloat, _ cy: CGFloat) -> CGRect {
        CGRect(x: cx - cardW / 2, y: cy - cardH / 2, width: cardW, height: cardH)
    }

    // MARK: Rendering elements

    struct CardPlacement: Identifiable {
        var id: UUID { plugin.id }
        let plugin: SynopticPlugin
        let frame: CGRect
    }

    /// `plain` = a straight wire with NO arrowhead (the arrow belongs to the segment that ARRIVES, never to
    /// the one that leaves). No longer laid by an FX block, whose exit is the mix box's foot itself.
    enum CableStyle { case connector, fork, merge, ghost, plain }

    struct Cable: Identifiable {
        let id = UUID()
        let from: CGPoint
        let to: CGPoint
        let style: CableStyle
    }

    struct ScopeRect: Identifiable {
        let id = UUID()
        let rect: CGRect
        let depth: Int
    }

    /// An insertion control laid on the wire after an element: '+' inserts a plugin in
    /// series at `insertIndex`, and the branch icon puts `branchElementID` in parallel.
    struct InsertZone: Identifiable {
        let id = UUID()
        let seriesID: UUID
        let insertIndex: Int
        let branchElementID: UUID?   // nil = no branching (nothing to branch, e.g. an empty series or the end)
        let center: CGPoint          // the centre of the '+', laid on the wire
    }

    /// A drop zone covering the CABLE of a series/branch (and not only the small '+'):
    /// dropping a plugin here inserts it into that series at `insertIndex`. It allows dropping on
    /// the axis, including onto an EMPTY parallel branch (no card and barely a '+' to aim at).
    /// Rendered UNDER the cards → a hovered card keeps priority (inserting before it).
    struct CableDropZone: Identifiable {
        let id = UUID()
        let seriesID: UUID
        let insertIndex: Int
        let rect: CGRect          // the DETECTION zone (wide, easy to aim at)
        let previewFrame: CGRect  // the PREVIEW shown on hover: a card-sized rectangle, on the cable
    }

    /// A dB gain control laid at the end of a parallel branch (before the sum).
    struct VoiceGain: Identifiable {
        let blockID: UUID        // the id of the parallel block (the rack carrier)
        let voiceIndex: Int
        let dB: Float
        let muted: Bool
        let center: CGPoint
        // A STABLE identity between two builds (otherwise the drag loses its @State on every re-render).
        var id: String { "\(blockID.uuidString):\(voiceIndex)" }
    }

    /// One FX link's block, as laid: three NESTED rectangles — the header card straddling the top of the
    /// body, the body itself (what is filled and outlined), and the mix box inside the body at its foot — and
    /// the mix box's three slots. No wire is ever laid across the header or the mix box.
    struct FXBlockPlacement: Identifiable {
        var id: UUID { link.blockID }
        let link: SynopticFXLink
        /// The whole extent: the header card's top down to the body's bottom (= the node's measured size).
        let rect: CGRect
        let headerRect: CGRect
        let bodyRect: CGRect
        let mixRect: CGRect
        /// Left → right inside `mixRect`: pan, volume, mute.
        let panSlot: CGRect
        let volumeSlot: CGRect
        let muteSlot: CGRect
        /// How many entries the block's series holds (where a drop on the header lands: the end).
        let pluginCount: Int
    }

    struct Placement {
        var size: CGSize
        var entry: CGPoint       // the anchor point of the incoming cable (top)
        var exit: CGPoint        // the anchor point of the outgoing cable (bottom)
        var cards: [CardPlacement] = []
        var cables: [Cable] = []
        var dots: [CGPoint] = []
        var scopes: [ScopeRect] = []
        var inserts: [InsertZone] = []
        var cableDrops: [CableDropZone] = []
        var voiceGains: [VoiceGain] = []
        var fxBlocks: [FXBlockPlacement] = []

        mutating func absorb(_ o: Placement) {
            cards += o.cards; cables += o.cables; dots += o.dots
            scopes += o.scopes; inserts += o.inserts
            cableDrops += o.cableDrops; voiceGains += o.voiceGains
            fxBlocks += o.fxBlocks
        }
    }

    // MARK: Measuring (size alone, to centre before placing)

    /// The series of a bin's block, WITHOUT the frame (the inner content the frame is laid round).
    private static func bare(_ node: SynopticNode) -> SynopticNode {
        var n = node
        n.fxLink = nil
        return n
    }

    static func measure(_ node: SynopticNode) -> CGSize {
        if let fx = node.fxLink {
            let inner = measure(bare(node))
            return CGSize(width: fxBlockWidth(innerWidth: inner.width, name: fx.name),
                          height: fxHeaderCardH + fxHeaderGap + inner.height + fxMixGap + fxMixH)
        }
        switch node.kind {
        case .plugin(let p):
            return CGSize(width: cardWidth(for: p), height: cardH)

        case .series(let a):
            // An empty series: we reserve the height of one card slot so that the '+' sits AT THE
            // BOTTOM, aligned with the end-of-chain gain (instead of sticking to the top).
            guard !a.isEmpty else { return CGSize(width: cardW, height: cardH) }
            let sizes = a.map { measure($0) }
            var h: CGFloat = 0
            for s in sizes { h += s.height }
            // A head control (before the 1st element) AND an end control.
            h += seriesGap * CGFloat(a.count - 1) + 2 * (plusGap + plusW)
            let w = sizes.map { $0.width }.max() ?? cardW
            return CGSize(width: w, height: h)

        case .parallel(let a):
            let sizes = a.map { measure($0) }
            let contentH = sizes.map { $0.height }.max() ?? cardH
            var voiesW: CGFloat = 0
            for s in sizes { voiesW += s.width }
            voiesW += voiceGap * CGFloat(max(0, a.count - 1))
            let gainH = a.contains { $0.voiceGainDb != nil } ? gainBandH : 0
            let scopeW = voiesW + 2 * scopePad
            let scopeH = contentH + 2 * scopePad + gainH
            return CGSize(width: scopeW, height: forkH + scopeH + forkH)
        }
    }

    // MARK: Placing (absolute coordinates)

    static func place(_ node: SynopticNode, at origin: CGPoint, depth: Int = 0) -> Placement {
        if let fx = node.fxLink {
            let inner = bare(node)
            let innerSize = measure(inner)
            let total = measure(node)
            let cx = origin.x + total.width / 2
            // The header card and the mix box take the BODY's width and left edge exactly: the three
            // rectangles read as one block, the top and the bottom ones flush with the sides of the one
            // round them. `fxHeaderW` / `fxMixW` stay what the body may never be narrower than
            // (@see fxBlockWidth), so the name and the three slots always fit.
            let headerRect = CGRect(x: origin.x, y: origin.y, width: total.width, height: fxHeaderCardH)
            let innerOrigin = CGPoint(x: origin.x + (total.width - innerSize.width) / 2,
                                      y: headerRect.maxY + fxHeaderGap)
            let ipl = place(inner, at: innerOrigin, depth: depth + 1)
            let mixRect = CGRect(x: origin.x, y: innerOrigin.y + innerSize.height + fxMixGap,
                                 width: total.width, height: fxMixH)
            // The body starts at the header card's middle line (`fxHeaderOverlap` of the card hangs inside)
            // and ends EXACTLY where the mix box does: the box's bottom edge is the body's bottom edge.
            let bodyTop = headerRect.maxY - fxHeaderOverlap
            let bodyRect = CGRect(x: origin.x, y: bodyTop, width: total.width,
                                  height: mixRect.maxY - bodyTop)
            // The three slots, centred as a group on the mix box.
            let groupW = fxPanW + fxVolumeW + fxMuteW + 2 * fxSlotGap
            let slotY = mixRect.midY - fxSlotH / 2
            let panSlot = CGRect(x: mixRect.midX - groupW / 2, y: slotY, width: fxPanW, height: fxSlotH)
            let volumeSlot = CGRect(x: panSlot.maxX + fxSlotGap, y: slotY, width: fxVolumeW, height: fxSlotH)
            let muteSlot = CGRect(x: volumeSlot.maxX + fxSlotGap, y: slotY, width: fxMuteW, height: fxSlotH)

            var pl = Placement(size: total,
                               entry: CGPoint(x: cx, y: headerRect.minY),
                               exit: CGPoint(x: cx, y: bodyRect.maxY))
            // The wire STOPS at the header card's foot and at the mix box's head (an arrow into each).
            // It starts again at the mix box's foot, which is also the body's bottom and the block's exit:
            // the next element's wire leaves from there (its arrow is its own). Nothing is laid across
            // the header or the mix box.
            pl.cables.append(Cable(from: CGPoint(x: cx, y: headerRect.maxY), to: ipl.entry, style: .connector))
            pl.cables.append(Cable(from: ipl.exit, to: CGPoint(x: cx, y: mixRect.minY), style: .connector))
            var pluginCount = 0
            if case .series(let kids) = inner.kind { pluginCount = kids.count }
            pl.fxBlocks.append(FXBlockPlacement(
                link: fx,
                rect: CGRect(origin: origin, size: total),
                headerRect: headerRect, bodyRect: bodyRect, mixRect: mixRect,
                panSlot: panSlot, volumeSlot: volumeSlot, muteSlot: muteSlot,
                pluginCount: pluginCount))
            pl.absorb(ipl)
            return pl
        }
        switch node.kind {

        case .plugin(let p):
            let w = cardWidth(for: p)
            let frame = CGRect(origin: origin, size: CGSize(width: w, height: cardH))
            var pl = Placement(size: frame.size,
                               entry: CGPoint(x: origin.x + w / 2, y: origin.y),
                               exit: CGPoint(x: origin.x + w / 2, y: origin.y + cardH))
            pl.cards = [CardPlacement(plugin: p, frame: frame)]
            return pl

        case .series(let a):
            let w = measure(node).width
            let cx = origin.x + w / 2
            var pl = Placement(size: measure(node),
                               entry: CGPoint(x: cx, y: origin.y),
                               exit: CGPoint(x: cx, y: origin.y))

            guard !a.isEmpty else {
                // An empty series: a single '+' (nothing to branch), laid AT THE BOTTOM of the slot
                // (near the end gain). The input lands straight on the '+': no intermediate wire,
                // otherwise its arrow would overlap the incoming cable's.
                let c = CGPoint(x: cx, y: origin.y + cardH - plusW / 2)
                pl.inserts.append(InsertZone(seriesID: node.id, insertIndex: 0,
                                             branchElementID: nil, center: c))
                pl.entry = CGPoint(x: cx, y: c.y - plusW / 2)
                pl.exit = CGPoint(x: cx, y: c.y + plusW / 2)
                // An empty branch: the whole reserved slot becomes receptive (the cable = a drop zone),
                // otherwise there is only the tiny '+' to aim at. The preview = a card centred on the slot.
                pl.cableDrops.append(CableDropZone(seriesID: node.id, insertIndex: 0,
                                                   rect: CGRect(x: origin.x, y: origin.y,
                                                                width: w, height: cardH),
                                                   previewFrame: cardFrame(cx, c.y)))
                return pl
            }

            // A head control, BEFORE the 1st element: '+' inserts at the head, and the '//' branch
            // branches the 1st element (the split happening before it).
            let leadCenter = CGPoint(x: cx, y: origin.y + plusW / 2)
            pl.inserts.append(InsertZone(seriesID: node.id, insertIndex: 0,
                                         branchElementID: a.first!.id, center: leadCenter))

            var y = origin.y + plusW + plusGap
            var prevExit: CGPoint? = nil

            for (i, child) in a.enumerated() {
                let cs = measure(child)
                let cxChild = origin.x + (w - cs.width) / 2
                let cpl = place(child, at: CGPoint(x: cxChild, y: y), depth: depth)
                if i == 0 {
                    pl.cables.append(Cable(from: CGPoint(x: cx, y: leadCenter.y + plusW / 2),
                                           to: cpl.entry, style: .connector))
                    // The head segment: dropping here inserts BEFORE the 1st element (index 0).
                    // The zone is bounded by the head cable → it does NOT cover the body of the 1st element
                    // (useful if that is a parallel: its branches stay the only receptive things).
                    pl.cableDrops.append(CableDropZone(seriesID: node.id, insertIndex: 0,
                                                       rect: CGRect(x: cx - cardW / 2, y: origin.y,
                                                                    width: cardW,
                                                                    height: cpl.entry.y - origin.y),
                                                       previewFrame: cardFrame(cx, leadCenter.y)))
                }
                if let pe = prevExit {
                    // A control BEFORE this element: '+' inserts here (index i), '//' branches it.
                    let ctrlY = (pe.y + cpl.entry.y) / 2
                    pl.cables.append(Cable(from: pe, to: CGPoint(x: cx, y: ctrlY - plusW / 2), style: .connector))
                    pl.cables.append(Cable(from: CGPoint(x: cx, y: ctrlY + plusW / 2), to: cpl.entry, style: .connector))
                    pl.inserts.append(InsertZone(seriesID: node.id, insertIndex: i,
                                                 branchElementID: child.id, center: CGPoint(x: cx, y: ctrlY)))
                    // A cable segment between element i-1 and i: insertion at `i`. Bounded by the
                    // cable (pe → input) → if i is a parallel, this covers the zone BEFORE it
                    // and the inside of the parallel is left to the branches.
                    pl.cableDrops.append(CableDropZone(seriesID: node.id, insertIndex: i,
                                                       rect: CGRect(x: cx - cardW / 2, y: pe.y,
                                                                    width: cardW,
                                                                    height: cpl.entry.y - pe.y),
                                                       previewFrame: cardFrame(cx, ctrlY)))
                }
                pl.absorb(cpl)
                prevExit = cpl.exit
                y += cs.height + seriesGap
            }

            // The end control (after the last element): '+' only.
            let lastExit = prevExit!
            let trailCenter = CGPoint(x: cx, y: lastExit.y + plusGap + plusW / 2)
            pl.cables.append(Cable(from: lastExit,
                                   to: CGPoint(x: cx, y: trailCenter.y - plusW / 2),
                                   style: .connector))
            pl.inserts.append(InsertZone(seriesID: node.id, insertIndex: a.count,
                                         branchElementID: nil, center: trailCenter))
            pl.exit = CGPoint(x: cx, y: trailCenter.y + plusW / 2)
            // The end segment (after the last element): insertion at the end of the series (index a.count).
            // Bounded by the tail cable → it does not cover the last element's body.
            pl.cableDrops.append(CableDropZone(seriesID: node.id, insertIndex: a.count,
                                               rect: CGRect(x: cx - cardW / 2, y: lastExit.y,
                                                            width: cardW,
                                                            height: pl.exit.y - lastExit.y),
                                               previewFrame: cardFrame(cx, trailCenter.y)))
            return pl

        case .parallel(let a):
            let total = measure(node)
            let sizes = a.map { measure($0) }
            let contentH = sizes.map { $0.height }.max() ?? cardH
            var voiesW: CGFloat = 0
            for s in sizes { voiesW += s.width }
            voiesW += voiceGap * CGFloat(max(0, a.count - 1))
            let hasGains = a.contains { $0.voiceGainDb != nil }

            // The block's horizontal centre (aligned on the branches).
            let centerX = origin.x + total.width / 2
            let splitDot = CGPoint(x: centerX, y: origin.y)
            let mergeDot = CGPoint(x: centerX, y: origin.y + total.height)
            let voieTop = origin.y + forkH + scopePad

            var pl = Placement(size: total, entry: splitDot, exit: mergeDot)

            // The backing area (grey, more pronounced when nested)
            let scopeRect = CGRect(x: origin.x, y: origin.y + forkH,
                                   width: total.width,
                                   height: contentH + 2 * scopePad + (hasGains ? gainBandH : 0))
            pl.scopes.append(ScopeRect(rect: scopeRect, depth: depth))
            pl.dots.append(splitDot)
            pl.dots.append(mergeDot)

            // The gain band (if at least one branch has one): under the branches, inside the backing area.
            // Each branch's dB control lands there, on the merge cable.
            let gainCenterY = voieTop + contentH + gainBandH / 2

            // The X position (origin plus centre) of each branch, so as to partition the backing area into
            // vertical columns: within the parallel's region, a drop has to land on ONE branch
            // (never in the middle), the bounds being the midpoints between neighbouring branches.
            var voiceOriginX: [CGFloat] = []
            var xCursor = origin.x + scopePad
            for s in sizes { voiceOriginX.append(xCursor); xCursor += s.width + voiceGap }
            let voiceCenterX = zip(voiceOriginX, sizes).map { $0 + $1.width / 2 }
            func columnBounds(_ i: Int) -> (left: CGFloat, right: CGFloat) {
                let left  = i == 0 ? origin.x
                                   : (voiceCenterX[i - 1] + voiceCenterX[i]) / 2
                let right = i == a.count - 1 ? origin.x + total.width
                                             : (voiceCenterX[i] + voiceCenterX[i + 1]) / 2
                return (left, right)
            }

            var x = origin.x + scopePad
            for (i, voie) in a.enumerated() {
                let cs = sizes[i]
                let vpl = place(voie, at: CGPoint(x: x, y: voieTop), depth: depth + 1)
                pl.cables.append(Cable(from: splitDot, to: vpl.entry, style: .fork))
                // The branch's drop column: it covers its whole half of the backing area (the bounds being
                // the midpoints between branches), over the parallel's full height. Added BEFORE absorbing
                // the branch's content → the inner zones (cards, nested branches) keep priority (being
                // rendered on top). Insertion at the end of the branch series.
                // An invariant: a branch is always a `.series`.
                let voiceCount: Int = { if case .series(let ss) = voie.kind { return ss.count }; return 0 }()
                let bounds = columnBounds(i)
                // The preview = a card centred on the branch, at the level of the content row (hence
                // aligned with a sister branch's plugin), and not over the zone's whole height.
                pl.cableDrops.append(CableDropZone(seriesID: voie.id, insertIndex: voiceCount,
                                                   rect: CGRect(x: bounds.left, y: origin.y,
                                                                width: bounds.right - bounds.left,
                                                                height: total.height),
                                                   previewFrame: cardFrame(voiceCenterX[i],
                                                                           voieTop + contentH / 2)))
                if hasGains, let g = voie.voiceGainDb {
                    let ctrl = CGPoint(x: vpl.exit.x, y: gainCenterY)
                    pl.cables.append(Cable(from: vpl.exit,
                                           to: CGPoint(x: ctrl.x, y: ctrl.y - gainBandH / 2 + 3), style: .merge))
                    pl.cables.append(Cable(from: CGPoint(x: ctrl.x, y: ctrl.y + gainBandH / 2 - 3),
                                           to: mergeDot, style: .merge))
                    pl.voiceGains.append(VoiceGain(blockID: node.id, voiceIndex: i, dB: g,
                                                   muted: voie.voiceMuted, center: ctrl))
                } else {
                    pl.cables.append(Cable(from: vpl.exit, to: mergeDot, style: .merge))
                }
                pl.absorb(vpl)
                x += cs.width + voiceGap
            }

            // (A branch is added through the '//' branching of the insertion control placed
            // after this block in the parent series — no more dedicated phantom branch.)
            return pl
        }
    }

    // MARK: The complete assembly (with Source / Out around the trunk)

    /// A chain gain control (start or end), with its dB value and its position.
    struct ChainGain { let dB: Float; let center: CGPoint }

    struct Diagram {
        var canvasSize: CGSize
        var sourcePill: CGRect
        var outPill: CGRect
        var placement: Placement
        var chainInGain: ChainGain? = nil
        var chainOutGain: ChainGain? = nil
        /// A MIDI clip: a 'MIDI' zone at the head of the chain (replacing the Source pill); it holds
        /// the instrument card. nil for an audio clip / group / aux.
        var midiZone: CGRect? = nil
        /// The slot of the instrument card (or of the '+' button) inside `midiZone`.
        var instrumentSlot: CGRect? = nil
        /// An audio clip: an 'audio file' zone at the head of the chain (replacing the Source pill);
        /// it holds speed / semitones / bpm. nil for a MIDI clip / group / aux.
        var audioZone: CGRect? = nil
        /// An audio clip carrying an ARA source: its card, right under the 'audio file' frame and ahead of
        /// the start gain and of the FX. nil without a source.
        var araCard: CGRect? = nil
        /// The 'clip' zone (the output mix: volume / pan / mute), between the end gain and the output.
        /// nil for a bus (no object).
        var clipZone: CGRect? = nil
        /// The 'stems' zone at the foot (replacing the Out pill): choosing the output stem.
        /// nil for a bus.
        var stemsZone: CGRect? = nil
        /// One card per outgoing send, in a column BESIDE the trunk (@see SendCardPlacement).
        var sendCards: [SendCardPlacement] = []
        /// The three fixed slots a send card can be dropped on (input, pre-fader, post-fader); a
        /// position inside the chain is dropped on the trunk's own insert points.
        var sendSlotDrops: [SendSlotDrop] = []
        /// The "+ Send to…" button, in the post-fader slot, after its cards. nil = this object does not send.
        var addSendButton: CGRect? = nil
        /// The head of a bus's chain (aux / group): a widened 'source' box carrying the infinite
        /// option and, for an aux, the sends it receives. nil when the head is the plain pill.
        var busHeadZone: CGRect? = nil
    }

    /// One outgoing send, laid as a card in the column beside the trunk. `anchor` is the point of the
    /// trunk the send is taken at: the card's wire leaves it sideways. Cards never sit in a branch of a
    /// parallel block nor in an FX link: the anchors are the ROOT series' own insert points and the
    /// three fixed slots.
    ///
    /// INC 3 — a send that carries plugins is a BOX, read top to bottom as the signal goes (Q-U19): one
    /// row per plugin in processing order, then the "+" row, then, at the BOTTOM, the send's own line
    /// (today's card: aux, level, on/off). A send without plugin is today's card and nothing else; its
    /// "+" shows on hover just above the line (`plusRect` then lies outside `frame`).
    struct SendCardPlacement: Identifiable {
        var id: UUID { send.id }
        let send: SynopticSend
        /// The whole box (the card alone when the send carries no plugin).
        let frame: CGRect
        let anchor: CGPoint

        var hasPlugins: Bool { !send.plugins.isEmpty }
        /// The send's own line, at the bottom of the box.
        var headerRect: CGRect {
            CGRect(x: frame.minX, y: frame.maxY - SynopticLayout.sendCardH,
                   width: frame.width, height: SynopticLayout.sendCardH)
        }
        /// One rect per plugin, top to bottom in processing order.
        var pluginRows: [CGRect] {
            send.plugins.indices.map { i in
                CGRect(x: frame.minX, y: frame.minY + CGFloat(i) * SynopticLayout.sendPluginRowH,
                       width: frame.width, height: SynopticLayout.sendPluginRowH)
            }
        }
        /// The "+": the row between the last plugin and the line; with no plugin, a strip just ABOVE
        /// the card (shown on hover only).
        var plusRect: CGRect {
            let h = SynopticLayout.sendPlusRowH
            return CGRect(x: frame.minX, y: headerRect.minY - h, width: frame.width, height: h)
        }
        /// Where the wire from the trunk arrives: the left edge, at the TOP of the box — its first
        /// row, or the line itself when there is no plugin.
        var entry: CGPoint {
            CGPoint(x: frame.minX, y: frame.minY + SynopticLayout.sendBoxFirstRowH(plugins: send.plugins.count) / 2)
        }
        /// The y of insertion slot `index` (0 = above the first row … N = under the last row).
        func insertLineY(_ index: Int) -> CGFloat {
            frame.minY + CGFloat(min(max(0, index), send.plugins.count)) * SynopticLayout.sendPluginRowH
        }
        /// The insertion slot a plugin let go at `point` lands in, counted from the top: the nearest
        /// boundary between two rows; anywhere on the "+" row or on the send's line = the end. nil when
        /// the point is outside the box.
        func insertIndex(at point: CGPoint) -> Int? {
            let zone = hasPlugins ? frame : frame.union(plusRect)
            guard zone.contains(point) else { return nil }
            let n = send.plugins.count
            guard n > 0 else { return 0 }
            let k = Int(((point.y - frame.minY) / SynopticLayout.sendPluginRowH).rounded())
            return min(max(0, k), n)
        }
    }

    /// A fixed slot of the sends (`.input`, `.preFader`, `.postFader`): where a dragged send card is
    /// taken to. `rect` is the detection band across the trunk and the card column; `previewFrame` the
    /// card-sized rectangle shown on hover, at the slot's anchor.
    struct SendSlotDrop: Identifiable {
        var id: SynopticSendSlot { slot }
        let slot: SynopticSendSlot
        let anchor: CGPoint
        let rect: CGRect
        let previewFrame: CGRect
    }

    static let sourceW: CGFloat = 64
    static let outW: CGFloat = 54
    static let ioGap: CGFloat = 16
    static let pillH: CGFloat = 36
    static let margin: CGFloat = 16
    static let chainGainGap: CGFloat = 56   // the room reserved for the gain control between the pill and the trunk
    static let gainHalfGap: CGFloat = 12    // the half-height reserved for the dB control on the wire (the rest = the arrow)
    static let midiZoneW: CGFloat = cardW + 24   // the MIDI zone (instrument card plus margins)
    static let midiZoneH: CGFloat = cardH + 34   // the 'MIDI' title + the card + margins
    static let audioZoneW: CGFloat = 244         // the 'audio file' zone (1× / st / bpm on one line)
    static let audioZoneH: CGFloat = 58
    /// One more row (a 16 pt pill plus the zone's 7 pt spacing) when the file is stereo: the
    /// LR / L / R / C selector.
    static let audioZoneStereoExtraH: CGFloat = 23
    /// The ARA source (Melodyne) is a CARD, the first one out of the 'audio file' frame: this is the wire
    /// between the frame's foot and the card's top (room for the "ARA" tag hanging above the card's corner).
    static let araCardGap: CGFloat = 30
    static let clipZoneW: CGFloat = 224          // the 'clip' zone (pan / volume / mute on one line)
    static let clipZoneWWide: CGFloat = 328      // the same plus the attribute link icons (a linked consolidated object)
    static let clipZoneH: CGFloat = 36

    // The 'stems' zone (output): a title plus the stem's drop-down menu, on one line.
    static let stemsZoneW: CGFloat = 176
    static let stemsZoneH: CGFloat = 36

    // The 'aux' zone (foot) and the sends received (an aux's head): one row per send, under a title.
    // The width is set by a row's content (arrow + name + dB box + switch): any wider and
    // the box stretched for nothing and imposed its width on the whole signal view.
    static let sendsZoneW: CGFloat = 206
    static let sendRowH: CGFloat = 26
    static let zoneTitleH: CGFloat = 20     // the height of the title row of a box holding rows
    static let zonePadV: CGFloat = 6

    // The send CARDS (outgoing sends): a column beside the trunk, each wired to the trunk at its anchor.
    static let sendCardW: CGFloat = 236
    static let sendCardH: CGFloat = 28
    static let sendCardGap: CGFloat = 6     // between two stacked cards
    static let sendColumnGap: CGFloat = 34  // between the trunk's extent and the column (room for the wire)
    static let sendAddW: CGFloat = 120      // the "+ Send to…" button
    static let sendAddH: CGFloat = 24
    static let sendSlotHalfH: CGFloat = 12  // half the height of a fixed slot's detection band
    // A send's BOX (INC 3): its plugins' rows above the line, and the "+" row between them and the line.
    static let sendPluginRowH: CGFloat = 22
    static let sendPlusRowH: CGFloat = 18

    /// The height of a send's box: today's card with no plugin; rows + "+" + the line otherwise.
    static func sendBoxHeight(plugins n: Int) -> CGFloat {
        n <= 0 ? sendCardH : CGFloat(n) * sendPluginRowH + sendPlusRowH + sendCardH
    }
    /// The height of the box's FIRST row — where the trunk's wire arrives.
    static func sendBoxFirstRowH(plugins n: Int) -> CGFloat { n <= 0 ? sendCardH : sendPluginRowH }

    /// The height of a titled box holding `rows` send rows.
    static func rowsZoneH(_ rows: Int) -> CGFloat {
        zoneTitleH + CGFloat(rows) * sendRowH + zonePadV
    }

    /// - Parameters:
    ///   - araCardWidth: non-nil = the audio object carries an ARA source: its card (this wide) hangs under the
    ///     'audio file' frame, and the start gain and the chain move down by its height.
    ///   - sends: the outgoing sends, one card each, each at its `slot` (@see SendCardPlacement).
    ///   - sendsEnabled: this object can send (it gets the card column and the "+ Send to…" button even
    ///     with no send yet).
    ///   - receivedRows: the sends an aux receives, listed in its chain head.
    ///   - infiniteOption: the head carries the 'infinite' checkbox (a top-level aux / group).
    static func diagram(for root: SynopticNode, chainInDb: Float = 0, chainOutDb: Float = 0,
                        midi: Bool = false, audioFile: Bool = false, audioStereo: Bool = false, araCardWidth: CGFloat? = nil,
                        mix: Bool = false,
                        mixWide: Bool = false, stems: Bool = false,
                        sends: [SynopticSend] = [], sendsEnabled: Bool = false, receivedRows: Int = 0,
                        infiniteOption: Bool = false) -> Diagram {
        let chainSize = measure(root)
        // A bus's head: the 'Source' pill widens into a box as soon as it carries the infinite
        // option and/or the list of sends received.
        let busHead = !midi && !audioFile && (infiniteOption || receivedRows > 0)
        let busHeadH = pillH + (receivedRows > 0 ? CGFloat(receivedRows) * sendRowH + zonePadV : 0)
        let leadW = midi ? midiZoneW : (audioFile ? audioZoneW : (busHead ? sendsZoneW : sourceW))
        let leadH = midi ? midiZoneH : (audioFile ? audioZoneH + (audioStereo ? audioZoneStereoExtraH : 0) : (busHead ? busHeadH : pillH))
        let clipW = mixWide ? clipZoneWWide : clipZoneW

        // Everything is centred on a single vertical column.
        let contentW = max(chainSize.width, leadW, outW, mix ? clipW : 0, stems ? stemsZoneW : 0,
                           araCardWidth ?? 0)
        let centerX = margin + contentW / 2
        // The send cards' column, to the right of everything the trunk's axis carries.
        let hasSendColumn = sendsEnabled || !sends.isEmpty
        let columnX = margin + contentW + sendColumnGap

        // The chain's head: the Source pill, the MIDI zone (instrument) or the audio file zone, AT THE TOP.
        let leadRect = CGRect(x: centerX - leadW / 2, y: margin, width: leadW, height: leadH)
        var midiZone: CGRect? = nil
        var instrumentSlot: CGRect? = nil
        var audioZone: CGRect? = nil
        if midi {
            midiZone = leadRect
            instrumentSlot = CGRect(x: leadRect.midX - cardW / 2,
                                    y: leadRect.maxY - cardH - 8, width: cardW, height: cardH)
        } else if audioFile {
            audioZone = leadRect
        }

        // head → [ARA source card] → [start gain] → trunk. The ARA source is what the file's audio goes THROUGH
        // first, so its card sits between the frame and the start gain: the chain starts below it.
        var araCard: CGRect? = nil
        var headBottomY = leadRect.maxY
        if audioFile, let w = araCardWidth {
            let r = CGRect(x: centerX - w / 2, y: leadRect.maxY + araCardGap, width: w, height: cardH)
            araCard = r
            headBottomY = r.maxY
        }
        let inGainCenter = CGPoint(x: centerX, y: headBottomY + chainGainGap / 2)
        let rootOrigin = CGPoint(x: centerX - chainSize.width / 2, y: headBottomY + chainGainGap)
        var placement = place(root, at: rootOrigin)

        placement.cables.insert(
            Cable(from: CGPoint(x: centerX, y: headBottomY),
                  to: CGPoint(x: centerX, y: inGainCenter.y - gainHalfGap), style: .connector), at: 0)
        if let r = araCard {
            // frame → card (the arrow arrives at the card, as it does at any card)
            placement.cables.insert(
                Cable(from: CGPoint(x: centerX, y: leadRect.maxY),
                      to: CGPoint(x: centerX, y: r.minY), style: .connector), at: 0)
        }
        placement.cables.insert(
            Cable(from: CGPoint(x: centerX, y: inGainCenter.y + gainHalfGap),
                  to: placement.entry, style: .connector), at: 0)

        // trunk → [end gain] → [clip zone] → Out
        let outGainCenter = CGPoint(x: centerX, y: placement.exit.y + chainGainGap / 2)
        placement.cables.append(
            Cable(from: placement.exit,
                  to: CGPoint(x: centerX, y: outGainCenter.y - gainHalfGap), style: .connector))

        var clipZone: CGRect? = nil
        var afterGainY = placement.exit.y + chainGainGap   // the top of the element following the gain
        let afterGainTop = afterGainY                      // (kept: the pre-fader send anchor lies on that wire)
        if mix {
            let clipRect = CGRect(x: centerX - clipW / 2, y: afterGainY,
                                  width: clipW, height: clipZoneH)
            clipZone = clipRect
            placement.cables.append(
                Cable(from: CGPoint(x: centerX, y: outGainCenter.y + gainHalfGap),
                      to: CGPoint(x: centerX, y: clipRect.minY), style: .connector))
            afterGainY = clipRect.maxY + ioGap
        } else {
            placement.cables.append(
                Cable(from: CGPoint(x: centerX, y: outGainCenter.y + gainHalfGap),
                      to: CGPoint(x: centerX, y: afterGainY), style: .connector))
        }

        // The foot box: the 'stems' zone (a selectable output) or the 'Out' pill.
        let bottomW = stems ? stemsZoneW : outW
        let bottomH = stems ? stemsZoneH : pillH
        let outPill = CGRect(x: centerX - bottomW / 2, y: afterGainY, width: bottomW, height: bottomH)
        let stemsZone: CGRect? = stems ? outPill : nil
        if mix {
            // clip zone → foot
            placement.cables.append(
                Cable(from: CGPoint(x: centerX, y: outPill.minY - ioGap),
                      to: CGPoint(x: centerX, y: outPill.minY), style: .connector))
        }

        // The send cards: each hangs at an ANCHOR of the trunk (the input wire, one of the root series'
        // insert points, the wire between the OUT gain and the clip zone, the wire under the clip zone),
        // in a column beside it, stacked top → bottom in anchor order without overlapping.
        var sendCards: [SendCardPlacement] = []
        var sendSlotDrops: [SendSlotDrop] = []
        var addSendButton: CGRect? = nil
        var columnBottom: CGFloat = 0
        if hasSendColumn {
            let inputY = (headBottomY + inGainCenter.y - gainHalfGap) / 2
            let outWireTop = outGainCenter.y + gainHalfGap
            let preY = (outWireTop + afterGainTop) / 2
            let postY = outPill.minY - ioGap / 2
            let rootInserts = placement.inserts.filter { $0.seriesID == root.id }
            let lastIndex = rootInserts.map(\.insertIndex).max() ?? 0
            func anchor(of slot: SynopticSendSlot) -> CGPoint {
                switch slot {
                case .input:     return CGPoint(x: centerX, y: inputY)
                case .preFader:  return CGPoint(x: centerX, y: preY)
                case .postFader: return CGPoint(x: centerX, y: postY)
                case .chain(let i):
                    let k = min(max(0, i), lastIndex)
                    return rootInserts.first(where: { $0.insertIndex == k })?.center
                        ?? CGPoint(x: centerX, y: placement.entry.y)
                }
            }
            struct Item { let offset: Int; let send: SynopticSend; let anchor: CGPoint }
            var items: [Item] = []
            for (offset, send) in sends.enumerated() {
                items.append(Item(offset: offset, send: send, anchor: anchor(of: send.slot)))
            }
            let ordered: [Item] = items.sorted { (l: Item, r: Item) -> Bool in
                if l.anchor.y != r.anchor.y { return l.anchor.y < r.anchor.y }
                return l.offset < r.offset
            }
            var nextY = -CGFloat.infinity
            for item in ordered {
                // The box hangs by its TOP row: that row's centre sits at the anchor (pushed down by a
                // box above), and the box grows downwards with its plugins.
                let n = item.send.plugins.count
                let y = max(item.anchor.y - sendBoxFirstRowH(plugins: n) / 2, nextY)
                let frame = CGRect(x: columnX, y: y, width: sendCardW, height: sendBoxHeight(plugins: n))
                sendCards.append(SendCardPlacement(send: item.send, frame: frame, anchor: item.anchor))
                nextY = frame.maxY + sendCardGap
                columnBottom = max(columnBottom, frame.maxY)
            }
            if sendsEnabled {
                let y = max(anchor(of: .postFader).y - sendAddH / 2, nextY)
                let r = CGRect(x: columnX, y: y, width: sendAddW, height: sendAddH)
                addSendButton = r
                columnBottom = max(columnBottom, r.maxY)
            }
            if sendsEnabled {
                let right = columnX + sendCardW
                for slot in [SynopticSendSlot.input, .preFader, .postFader] {
                    let a = anchor(of: slot)
                    sendSlotDrops.append(SendSlotDrop(
                        slot: slot, anchor: a,
                        rect: CGRect(x: centerX - cardW / 2, y: a.y - sendSlotHalfH,
                                     width: right - (centerX - cardW / 2), height: 2 * sendSlotHalfH),
                        previewFrame: CGRect(x: columnX, y: a.y - sendCardH / 2,
                                             width: sendCardW, height: sendCardH)))
                }
            }
        }

        let canvasW = contentW + 2 * margin + (hasSendColumn ? sendColumnGap + sendCardW : 0)
        let canvasH = max(outPill.maxY, columnBottom) + margin
        return Diagram(canvasSize: CGSize(width: canvasW, height: canvasH),
                       sourcePill: leadRect, outPill: outPill, placement: placement,
                       chainInGain: ChainGain(dB: chainInDb, center: inGainCenter),
                       chainOutGain: ChainGain(dB: chainOutDb, center: outGainCenter),
                       midiZone: midiZone, instrumentSlot: instrumentSlot,
                       audioZone: audioZone, araCard: araCard, clipZone: clipZone, stemsZone: stemsZone,
                       sendCards: sendCards, sendSlotDrops: sendSlotDrops, addSendButton: addSendButton,
                       busHeadZone: busHead ? leadRect : nil)
    }
}
