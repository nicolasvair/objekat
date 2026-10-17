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
//
// The rework of October 2026 (docs/plan_synoptic_rework.md, lot L2):
//  - the wire runs THROUGH every '+': a '+' shows only while its line is hovered (or while its series
//    is empty, or while a drag leaves from it), so no cable may stop at it — the '+' is drawn OVER the
//    wire, opaque. Each insert point carries the rect that hovering means (`InsertZone.hoverRect`) and
//    the pure hit test is `Placement.insertZone(at:)` / `Diagram.plusTarget(at:)`;
//  - no more start / end trims (they became gain stages, plugins of the chain): the 56 pt gaps are gone;
//  - an object host is drawn in a FRAME of its colour (`Diagram.objectFrame`), the head zone and the
//    mixer straddling its top and bottom edges;
//  - the sends hang BELOW the stems, wired by the LEFT, nested (@see Diagram.sendCards);
//  - an FX link has no mix box any more, and can be FOLDED.

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
    // (on/off · name · link badge · ✕) straddling its top edge. The body ends `fxPad` under the series'
    // tail '+' (no mix box any more: a gain on a bin is a gain stage dragged out of the bin's own '+').
    // The wire STOPS at the header card (an arrow into it) and starts again at its foot; it never runs
    // behind it. FOLDED, the body is one line ("3 plugins") and the wire runs straight through it.
    static let fxHeaderCardH: CGFloat = cardH
    /// How much of the header card hangs INSIDE the body — the ONE constant that decides how the card
    /// straddles the body's top edge (half of it: the body starts at the card's middle line).
    static let fxHeaderOverlap: CGFloat = fxHeaderCardH / 2
    static let fxHeaderGap: CGFloat = 10   // the wire between the header card and the first '+' of the series (room for the arrow)
    /// The width of a gain + pan + mute stage's card (the old mix box of a bin, as a card, §B.4).
    static let fxMixW: CGFloat = 150
    static let fxPad: CGFloat = 10         // the inner margin round the block's series (sides and bottom)
    static let fxMinW: CGFloat = 176
    /// A FOLDED block's body, under the header card: one line ("3 plugins") the wire runs through.
    static let fxFoldedBodyH: CGFloat = 24
    /// The body's corner radius.
    static let fxBodyCorner: CGFloat = 12
    static let gainBandH: CGFloat = 30     // the band reserved for the mute plus end-of-branch dB gain of a parallel branch (under the branches)
    /// A gain stage's card, `.gain` face: grip · the dB box · ✕ on hover (§B.4). The `.gainPanMute` face
    /// is `fxMixW` wide (the old mix box as a card).
    static let gainStageW: CGFloat = 96

    /// A card's width: wide enough for its whole name and its link badge, from `cardW` (the old
    /// fixed width, which truncated a name beside the badge to a few letters) up to the
    /// 'audio file' zone's width at the head of the chain — never wider than that header.
    /// Measured on the card's own name font; the rest is the card's fixed chrome (on/off button,
    /// paddings, ✕, and the badge when there is one). @see SynopticCardView.
    static func cardWidth(for p: SynopticPlugin) -> CGFloat {
        switch p.gainStage {
        case .gain?:        return gainStageW
        case .gainPanMute?: return fxMixW
        case nil:           break
        }
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
    /// on/off 26 · padding 8+8 · ✕ ~9 + gap 6 · badge 18+6 · the fold chevron ~12 + gap 6 · 4 of slack.
    static func fxHeaderW(name: String) -> CGFloat {
        let nameW = ceil((name as NSString).size(withAttributes: [.font: cardNameFont]).width)
        let chrome: CGFloat = 26 + 16 + 15 + 24 + 18 + 4
        return min(audioZoneW, max(cardW, nameW + chrome))
    }

    /// A bin's block width: its series plus the margins, never narrower than its header card nor than
    /// `fxMinW`.
    static func fxBlockWidth(innerWidth: CGFloat, name: String) -> CGFloat {
        max(fxMinW, innerWidth + 2 * fxPad, fxHeaderW(name: name))
    }

    /// A FOLDED block's width: its header card's, never narrower than `fxMinW` (the series is not shown,
    /// so it does not widen the block).
    static func fxFoldedWidth(name: String) -> CGFloat {
        max(fxMinW, fxHeaderW(name: name))
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
    /// the one that leaves): laid where a wire continues past something that is not an element — through
    /// a series' tail '+', through an empty series, under a bin's last '+', through a folded bin.
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

    /// What kind of series a '+' belongs to: it decides which drags the '+' offers (§B.2).
    enum InsertRole: Equatable {
        /// The trunk (the root series).
        case trunk
        /// A branch of a parallel block.
        case branch
        /// The series inside an FX link's block (a gain dragged out of it joins the bin's DEFINITION).
        case fxSeries
        /// A send's mini-chain (the series' id is the SEND's, i.e. its aux's): a gain stage only — no
        /// branch, no FX link, no send from a send (request 5 of 13 October 2026).
        case sendChain
    }

    /// An insertion point laid on the wire: '+' inserts a plugin in series at `insertIndex` (a click), and
    /// a drag out of it asks for what the user's map puts on its direction — by default a gain stage, a
    /// parallel branch or a send; possibly a given plugin (@see SynopticPlusGesture, PlusShortcutMap).
    /// The '+' is drawn OVER the wire, which runs through it; it shows only while `hoverRect` is hovered,
    /// or always when its series is empty (`alwaysVisible`).
    struct InsertZone: Identifiable {
        let id = UUID()
        let seriesID: UUID
        let insertIndex: Int
        /// The OLD parallel-branch button's element (the element AFTER the '+'; nil at the tail and in an
        /// empty series). Read only by the old branch button; @see branchTargetID for the drag's rule.
        let branchElementID: UUID?
        let center: CGPoint          // the centre of the '+', laid on the wire
        var role: InsertRole = .trunk
        /// The element a drag down-right puts in parallel (D3): the element UNDER the '+' (after it in the
        /// flow); for the series' tail '+', the element ABOVE it; nil in an empty series (where the drag
        /// makes an EMPTY branch). With a selection, the receiver extends it to the selected run that starts
        /// there (@see SynopticBranchRun.forPlus, which applies the same rule to the model).
        var branchTargetID: UUID? = nil
        /// The line's band round the '+' (the cable segment it sits on): hovering it shows the '+'.
        var hoverRect: CGRect = .zero
        /// The series holds nothing: its '+' is always shown (there is nothing else to aim at).
        var seriesIsEmpty: Bool = false
        /// The trunk only: the send slot a drag to the left takes (head ≡ input, tail ≡ pre-fader, between
        /// entries ≡ chain(i) — @see SynopticSendSlot.forTrunkInsert). nil elsewhere.
        var sendSlot: SynopticSendSlot? = nil

        /// A STABLE identity across two builds of the layout (`id` is not): what a hovered '+' is
        /// remembered by.
        var key: SynopticPlusKey {
            role == .sendChain ? .sendChain(aux: seriesID, index: insertIndex) : .series(seriesID, insertIndex)
        }
        /// An empty series shows its '+' whatever the hand does — except a send's: its '+' shows on hover only
        /// (a plugin-less send is its line and nothing else, request 5).
        var alwaysVisible: Bool { seriesIsEmpty && role != .sendChain }
        /// The '+' circle itself (what the hand grabs, and a blocker of the marquee).
        var plusRect: CGRect {
            CGRect(x: center.x - SynopticLayout.plusW / 2, y: center.y - SynopticLayout.plusW / 2,
                   width: SynopticLayout.plusW, height: SynopticLayout.plusW)
        }
        /// The drags this '+' offers (§B.2): a gain on every series; a branch on the trunk and in a
        /// parallel's branch — an EMPTY one when the series holds nothing (user rule of 13 October 2026);
        /// a send on the trunk only.
        var allowedGestures: Set<PlusGestureResult> {
            if role == .sendChain { return SynopticLayout.sendChainGestures }
            var s: Set<PlusGestureResult> = [.gain, .gainPanMute]
            if role != .fxSeries { s.insert(.branch) }
            if role == .trunk, sendSlot != nil { s.insert(.send) }
            return s
        }
        /// Every insert point inserts plugins (a click opens the browser on it), so every one can carry out a
        /// direction the user bound to a plugin (@see PlusShortcutMap).
        var allowsPluginInsertion: Bool { true }
        /// What a gesture of `translation` out of this '+' does under `map` (a click = the browser).
        func command(for translation: CGSize, map: PlusShortcutMap = .defaults) -> SynopticPlusCommand {
            if SynopticPlusGesture.isClick(translation) { return .openBrowser(key) }
            switch SynopticPlusGesture.classify(translation, allowed: allowedGestures,
                                                pluginAllowed: allowsPluginInsertion, map: map) {
            case .none:            return .none
            case .gain:            return .insertGainStage(key, .gain)
            case .gainPanMute:     return .insertGainStage(key, .gainPanMute)
            case .branch:          return .branch(key)
            case .send:            return sendSlot.map { .send($0) } ?? .none
            case .plugin(let ref): return .insertPlugin(key, ref)
            case .category(let i): return .openBrowserInCategory(key, i)
            }
        }
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

    /// One FX link's block, as laid: the header card straddling the top of the body, and the body itself
    /// (what is filled and outlined). No wire is ever laid across the header. FOLDED, the body is one line
    /// and the series inside is not laid at all (no card, no '+', no drop zone): a drop on the header lands
    /// at the bin's end, as always.
    struct FXBlockPlacement: Identifiable {
        var id: UUID { link.blockID }
        let link: SynopticFXLink
        /// The whole extent: the header card's top down to the body's bottom (= the node's measured size).
        let rect: CGRect
        let headerRect: CGRect
        let bodyRect: CGRect
        /// How many entries the block's series holds (where a drop on the header lands: the end; and what
        /// a folded body says).
        let pluginCount: Int
        /// Folded: header + a one-line body, the wire straight through.
        var isFolded: Bool = false
        /// Folded only: where the one line ("3 plugins") is written — beside the wire, never across it.
        var foldedSummaryRect: CGRect? = nil
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

        /// The hover bands of the insert points, in the order of `inserts`.
        var insertHoverRects: [CGRect] { inserts.map(\.hoverRect) }

        /// The insert point whose line is under `point` (the pure hover hit test, §B.3): the smallest band
        /// holding it, so that a nested series wins over the one round it. nil = no '+' line there.
        func insertZone(at point: CGPoint) -> InsertZone? {
            inserts.filter { $0.hoverRect.contains(point) }
                .min { $0.hoverRect.width * $0.hoverRect.height < $1.hoverRect.width * $1.hoverRect.height }
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
            if fx.isFolded {
                return CGSize(width: fxFoldedWidth(name: fx.name), height: fxHeaderCardH + fxFoldedBodyH)
            }
            let inner = measure(bare(node))
            return CGSize(width: fxBlockWidth(innerWidth: inner.width, name: fx.name),
                          height: fxHeaderCardH + fxHeaderGap + inner.height + fxPad)
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

    /// - Parameter role: the kind of series `node` is when it is one (the trunk by default; a parallel's
    ///   branches and a bin's series are told so by their parent).
    static func place(_ node: SynopticNode, at origin: CGPoint, depth: Int = 0,
                      role: InsertRole = .trunk) -> Placement {
        if let fx = node.fxLink {
            let inner = bare(node)
            let total = measure(node)
            let cx = origin.x + total.width / 2
            var pluginCount = 0
            if case .series(let kids) = inner.kind { pluginCount = kids.count }
            // The header card takes the BODY's width and left edge exactly: the two rectangles read as one
            // block. `fxHeaderW` stays what the body may never be narrower than (@see fxBlockWidth).
            let headerRect = CGRect(x: origin.x, y: origin.y, width: total.width, height: fxHeaderCardH)
            // The body starts at the header card's middle line (`fxHeaderOverlap` of the card hangs inside).
            let bodyTop = headerRect.maxY - fxHeaderOverlap
            let bodyRect = CGRect(x: origin.x, y: bodyTop, width: total.width,
                                  height: origin.y + total.height - bodyTop)
            var pl = Placement(size: total,
                               entry: CGPoint(x: cx, y: headerRect.minY),
                               exit: CGPoint(x: cx, y: bodyRect.maxY))
            if fx.isFolded {
                // The wire runs straight through the one-line body; the line is written beside it.
                pl.cables.append(Cable(from: CGPoint(x: cx, y: headerRect.maxY),
                                       to: CGPoint(x: cx, y: bodyRect.maxY), style: .plain))
                let sx = cx + 8
                let summary = CGRect(x: sx, y: headerRect.maxY + 2,
                                     width: max(0, bodyRect.maxX - fxPad - sx), height: fxFoldedBodyH - 4)
                pl.fxBlocks.append(FXBlockPlacement(
                    link: fx, rect: CGRect(origin: origin, size: total),
                    headerRect: headerRect, bodyRect: bodyRect,
                    pluginCount: pluginCount, isFolded: true, foldedSummaryRect: summary))
                return pl
            }
            let innerSize = measure(inner)
            let innerOrigin = CGPoint(x: origin.x + (total.width - innerSize.width) / 2,
                                      y: headerRect.maxY + fxHeaderGap)
            let ipl = place(inner, at: innerOrigin, depth: depth + 1, role: .fxSeries)
            // The wire STOPS at the header card's foot and leaves again from there (the series' own head
            // cable carries the arrow into its first element). Under the series' tail '+' it runs on to the
            // body's bottom — the block's exit — without an arrow (the next element's wire has its own).
            pl.cables.append(Cable(from: CGPoint(x: cx, y: headerRect.maxY), to: ipl.entry, style: .plain))
            pl.cables.append(Cable(from: ipl.exit, to: CGPoint(x: cx, y: bodyRect.maxY), style: .plain))
            pl.fxBlocks.append(FXBlockPlacement(
                link: fx, rect: CGRect(origin: origin, size: total),
                headerRect: headerRect, bodyRect: bodyRect, pluginCount: pluginCount))
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
            func slot(_ i: Int) -> SynopticSendSlot? {
                role == .trunk ? SynopticSendSlot.forTrunkInsert(index: i, count: a.count) : nil
            }

            guard !a.isEmpty else {
                // An empty series: a single '+' (nothing to branch), laid AT THE BOTTOM of the slot
                // (near the end gain). The wire runs through it (it is always shown here).
                let c = CGPoint(x: cx, y: origin.y + cardH - plusW / 2)
                // An empty branch: the whole reserved slot becomes receptive (the cable = a drop zone),
                // otherwise there is only the tiny '+' to aim at. The preview = a card centred on the slot.
                let band = CGRect(x: origin.x, y: origin.y, width: w, height: cardH)
                pl.inserts.append(InsertZone(seriesID: node.id, insertIndex: 0,
                                             branchElementID: nil, center: c, role: role,
                                             branchTargetID: nil, hoverRect: band,
                                             seriesIsEmpty: true, sendSlot: slot(0)))
                pl.entry = CGPoint(x: cx, y: c.y - plusW / 2)
                pl.exit = CGPoint(x: cx, y: c.y + plusW / 2)
                pl.cables.append(Cable(from: pl.entry, to: pl.exit, style: .plain))
                pl.cableDrops.append(CableDropZone(seriesID: node.id, insertIndex: 0,
                                                   rect: band, previewFrame: cardFrame(cx, c.y)))
                return pl
            }

            // A head control, BEFORE the 1st element: '+' inserts at the head, and a drag down-right
            // branches the 1st element (the split happening before it).
            let leadCenter = CGPoint(x: cx, y: origin.y + plusW / 2)

            var y = origin.y + plusW + plusGap
            var prevExit: CGPoint? = nil

            for (i, child) in a.enumerated() {
                let cs = measure(child)
                let cxChild = origin.x + (w - cs.width) / 2
                let cpl = place(child, at: CGPoint(x: cxChild, y: y), depth: depth, role: role)
                if i == 0 {
                    // The wire runs from the series' entry through the head '+' into the 1st element.
                    pl.cables.append(Cable(from: pl.entry, to: cpl.entry, style: .connector))
                    // The head segment: dropping here inserts BEFORE the 1st element (index 0).
                    // The zone is bounded by the head cable → it does NOT cover the body of the 1st element
                    // (useful if that is a parallel: its branches stay the only receptive things).
                    let band = CGRect(x: cx - cardW / 2, y: origin.y, width: cardW,
                                      height: cpl.entry.y - origin.y)
                    pl.inserts.append(InsertZone(seriesID: node.id, insertIndex: 0,
                                                 branchElementID: child.id, center: leadCenter, role: role,
                                                 branchTargetID: child.id, hoverRect: band,
                                                 sendSlot: slot(0)))
                    pl.cableDrops.append(CableDropZone(seriesID: node.id, insertIndex: 0, rect: band,
                                                       previewFrame: cardFrame(cx, leadCenter.y)))
                }
                if let pe = prevExit {
                    // A control BEFORE this element: '+' inserts here (index i), a drag branches it.
                    let ctrlY = (pe.y + cpl.entry.y) / 2
                    pl.cables.append(Cable(from: pe, to: cpl.entry, style: .connector))
                    // A cable segment between element i-1 and i: insertion at `i`. Bounded by the
                    // cable (pe → input) → if i is a parallel, this covers the zone BEFORE it
                    // and the inside of the parallel is left to the branches.
                    let band = CGRect(x: cx - cardW / 2, y: pe.y, width: cardW, height: cpl.entry.y - pe.y)
                    pl.inserts.append(InsertZone(seriesID: node.id, insertIndex: i,
                                                 branchElementID: child.id, center: CGPoint(x: cx, y: ctrlY),
                                                 role: role, branchTargetID: child.id, hoverRect: band,
                                                 sendSlot: slot(i)))
                    pl.cableDrops.append(CableDropZone(seriesID: node.id, insertIndex: i, rect: band,
                                                       previewFrame: cardFrame(cx, ctrlY)))
                }
                pl.absorb(cpl)
                prevExit = cpl.exit
                y += cs.height + seriesGap
            }

            // The end control (after the last element): '+', and a drag branches the element ABOVE it.
            let lastExit = prevExit!
            let trailCenter = CGPoint(x: cx, y: lastExit.y + plusGap + plusW / 2)
            pl.exit = CGPoint(x: cx, y: trailCenter.y + plusW / 2)
            // The wire runs on through the tail '+' to the series' exit, with no arrow of its own.
            pl.cables.append(Cable(from: lastExit, to: pl.exit, style: .plain))
            // The end segment (after the last element): insertion at the end of the series (index a.count).
            // Bounded by the tail cable → it does not cover the last element's body.
            let band = CGRect(x: cx - cardW / 2, y: lastExit.y, width: cardW, height: pl.exit.y - lastExit.y)
            pl.inserts.append(InsertZone(seriesID: node.id, insertIndex: a.count,
                                         branchElementID: nil, center: trailCenter, role: role,
                                         branchTargetID: a.last!.id, hoverRect: band,
                                         sendSlot: slot(a.count)))
            pl.cableDrops.append(CableDropZone(seriesID: node.id, insertIndex: a.count, rect: band,
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
                let vpl = place(voie, at: CGPoint(x: x, y: voieTop), depth: depth + 1, role: .branch)
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

            // (A branch is added by a drag down-right out of a '+' of the series round this block — no
            // dedicated phantom branch.)
            return pl
        }
    }

    // MARK: The complete assembly (with Source / Out around the trunk)

    /// The '+' laid on the wire between the mixer (the clip zone) and the stems (§B.2, D2): it offers ONE
    /// gesture, a send taken after the fader. A click opens the same "Send to…" menu.
    struct PostFaderPlus {
        let center: CGPoint
        /// The wire's band round the '+' (hovering it shows the '+').
        let hoverRect: CGRect
        var key: SynopticPlusKey { .postFader }
        var plusRect: CGRect {
            CGRect(x: center.x - SynopticLayout.plusW / 2, y: center.y - SynopticLayout.plusW / 2,
                   width: SynopticLayout.plusW, height: SynopticLayout.plusW)
        }
        var allowedGestures: Set<PlusGestureResult> { SynopticLayout.postFaderGestures }
        /// No plugin there: the wire mixer → stems is not a chain.
        var allowsPluginInsertion: Bool { false }
        /// A click = the send; a drag = the send in whichever direction `map` puts it, nothing elsewhere.
        func command(for translation: CGSize, map: PlusShortcutMap = .defaults) -> SynopticPlusCommand {
            if SynopticPlusGesture.isClick(translation) { return .send(.postFader) }
            return SynopticPlusGesture.classify(translation, allowed: allowedGestures, map: map) == .send
                ? .send(.postFader) : .none
        }
    }

    /// The only gesture the mixer → stems '+' offers.
    static let postFaderGestures: Set<PlusGestureResult> = [.send]
    /// The gestures a send's mini-chain '+' offers (a gain stage, never a branch nor a send).
    static let sendChainGestures: Set<PlusGestureResult> = [.gain, .gainPanMute]

    struct Diagram {
        var canvasSize: CGSize
        var sourcePill: CGRect
        var outPill: CGRect
        var placement: Placement
        /// A MIDI clip: a 'MIDI' zone at the head of the chain (replacing the Source pill); it holds
        /// the instrument card. nil for an audio clip / group / aux.
        var midiZone: CGRect? = nil
        /// The slot of the instrument card (or of the '+' button) inside `midiZone`.
        var instrumentSlot: CGRect? = nil
        /// An audio clip: an 'audio file' zone at the head of the chain (replacing the Source pill);
        /// it holds speed / semitones / bpm. nil for a MIDI clip / group / aux. FOLDED (the default,
        /// @see SynopticUIState.clipOptionsExpanded) it is one row: `audioZoneFoldedH`.
        var audioZone: CGRect? = nil
        /// The audio zone is laid folded (one row).
        var audioZoneFolded: Bool = false
        /// An audio clip carrying an ARA source: its card, right under the 'audio file' frame and ahead of
        /// the FX. nil without a source.
        var araCard: CGRect? = nil
        /// The 'clip' zone (the output mix: volume / pan / mute), between the trunk and the output.
        /// nil for a bus (no object).
        var clipZone: CGRect? = nil
        /// The 'stems' zone at the foot (replacing the Out pill): choosing the output stem.
        /// nil for a bus.
        var stemsZone: CGRect? = nil
        /// One column per outgoing send, stacked BELOW the stems and wired by the LEFT (@see SendCardPlacement).
        var sendCards: [SendCardPlacement] = []
        /// The fixed slots a send card can be dropped on that have no '+' of the trunk: the post-fader one
        /// only (the input ≡ the trunk's head '+', the pre-fader ≡ its tail '+').
        var sendSlotDrops: [SendSlotDrop] = []
        /// The "+ Send to…" button, at the bottom of the stack of columns. nil = this object does not send.
        var addSendButton: CGRect? = nil
        /// The head of a bus's chain (aux / group): a widened 'source' box carrying the infinite
        /// option and, for an aux, the sends it receives. nil when the head is the plain pill.
        var busHeadZone: CGRect? = nil
        /// The object's FRAME (§B.5): from the head zone's TOP edge to the mixer's BOTTOM edge, its left and
        /// right edges the two boxes' (same x, same width): its outline IS their outer outline, the head and
        /// the mixer sitting inside it as the object's intro and outro. Its FILL is drawn behind everything,
        /// its LINE above the two boxes (the whole outline shows in the object's colour). The chain sits
        /// `fxPad` (at least) inside its sides; the stems and the sends lie outside it. nil for a stem / the
        /// Main (their popover has no object). The line is drawn INSIDE this rectangle (@see
        /// objectFrameStrokeRect), as the boxes' own borders are, so the outer edges coincide to the pixel.
        var objectFrame: CGRect? = nil
        /// The '+' on the wire mixer → stems (a send after the fader). nil when this object does not send.
        var postFaderPlus: PostFaderPlus? = nil

        /// The '+' whose line is under `point` (the ONE hover hit test of the view, §B.3): the post-fader
        /// '+', a '+' of a send's mini-chain (@see SendCardPlacement.plusTarget), or the trunk's / a branch's /
        /// a bin's insert point. nil = no '+' line there.
        func plusTarget(at point: CGPoint) -> SynopticPlusKey? {
            if let p = postFaderPlus, p.hoverRect.contains(point) { return p.key }
            for c in sendCards { if let k = c.plusTarget(at: point) { return k } }
            return placement.insertZone(at: point)?.key
        }

        /// The insert point of a send's mini-chain a key names (nil = that send or that '+' is gone).
        func sendInsert(_ key: SynopticPlusKey) -> InsertZone? {
            guard case .sendChain(let aux, let index) = key else { return nil }
            return sendCards.first { $0.send.id == aux }?.insert(index)
        }

        /// The '+' a key names, as laid now (nil when it no longer exists).
        func plusRect(for key: SynopticPlusKey) -> CGRect? {
            switch key {
            case .postFader:
                return postFaderPlus?.plusRect
            case .sendChain:
                return sendInsert(key)?.plusRect
            case .series:
                return placement.inserts.first { $0.key == key }?.plusRect
            }
        }

        /// What a gesture of `translation` started on the '+' `key` does under `map` (@see SynopticPlusCommand).
        func command(for key: SynopticPlusKey, translation: CGSize,
                     map: PlusShortcutMap = .defaults) -> SynopticPlusCommand {
            switch key {
            case .postFader:
                return postFaderPlus?.command(for: translation, map: map) ?? .none
            case .sendChain:
                return sendInsert(key)?.command(for: translation, map: map) ?? .none
            case .series:
                return placement.inserts.first { $0.key == key }?.command(for: translation, map: map) ?? .none
            }
        }

        /// Whether the '+' `key` can insert a plugin (false when it no longer exists).
        func allowsPluginInsertion(for key: SynopticPlusKey) -> Bool {
            switch key {
            case .postFader:  return false
            case .sendChain:  return sendInsert(key)?.allowsPluginInsertion ?? false
            case .series:     return placement.inserts.first { $0.key == key }?.allowsPluginInsertion ?? false
            }
        }

        /// The gestures the '+' `key` offers, as laid now (empty when it no longer exists).
        func allowedGestures(for key: SynopticPlusKey) -> Set<PlusGestureResult> {
            switch key {
            case .postFader:
                return postFaderPlus?.allowedGestures ?? []
            case .sendChain:
                return sendInsert(key)?.allowedGestures ?? []
            case .series:
                return placement.inserts.first { $0.key == key }?.allowedGestures ?? []
            }
        }

        /// The '+' shown whatever the hand does: those of an empty series.
        var alwaysVisiblePlusKeys: Set<SynopticPlusKey> {
            Set(placement.inserts.filter(\.alwaysVisible).map(\.key))
        }
    }

    /// One outgoing send, laid as a COLUMN in the stack below the stems (request 5 of 13 October 2026: a send
    /// is drawn LIKE THE OBJECT). `anchor` is the point of the trunk the send is taken at (its TAP DOT): the
    /// wire leaves it to the LEFT, goes out of the frame, down its own gutter, and comes in at the column's
    /// TOP, on its axis (`wire`, `entry`). From there the signal goes DOWN: the send's plugins as a chain of
    /// real cards — the very cards of the trunk, joined by the wire, a '+' on every segment shown on hover —
    /// and, at the BOTTOM, the send's own line (aux, level, on/off, …, ×), as the mixer sits at the bottom of
    /// an object (`lineRect`). A send without plugin is that line under a short stub of wire, whose '+' shows
    /// on hover. The send tapped HIGHEST takes the OUTERMOST gutter and the LOWEST column, so no two wires
    /// cross (§B.6). Anchors are the ROOT series' own insert points and the post-fader '+': never inside a
    /// parallel's branch nor a bin.
    ///
    /// The mini-chain is laid by `place` as a series whose id is the SEND's (role `.sendChain`): its '+' are
    /// `SynopticPlusKey.sendChain(aux:index:)` and offer a gain stage only (`sendChainGestures`).
    struct SendCardPlacement: Identifiable {
        var id: UUID { send.id }
        let send: SynopticSend
        /// The whole column: the chain (or the stub) and the line under it.
        let frame: CGRect
        /// The tap point on the trunk's axis (where the tap dot is drawn).
        let anchor: CGPoint
        /// The x of this send's gutter, left of the frame.
        var gutterX: CGFloat = 0
        /// The send's own line (aux, level, on/off, menu, ×), at the BOTTOM of the column.
        let lineRect: CGRect
        /// The mini-chain as laid: its cards, its '+' (`inserts`), its drop bands, and the wire's run down
        /// the column (`cables`, the last one arriving at the line). A send without plugin: one '+' on the stub.
        let chain: Placement

        var hasPlugins: Bool { !send.plugins.isEmpty }
        /// The tap dot (the same point as `anchor`: it can be dragged like the line).
        var tapDot: CGPoint { anchor }
        /// The column's axis (the chain's and the line's centre line).
        var axisX: CGFloat { lineRect.midX }
        /// Where the wire from the trunk meets the column: its axis, at the top.
        var entry: CGPoint { CGPoint(x: axisX, y: frame.minY) }
        /// The wire, as a polyline: tap dot → left to the gutter → down the gutter → right to the column's
        /// axis. From there it runs down the column (`chain.cables`), drawn in the same style.
        var wire: [CGPoint] {
            [anchor, CGPoint(x: gutterX, y: anchor.y), CGPoint(x: gutterX, y: entry.y), entry]
        }
        /// The '+' of the mini-chain at insertion index `index` (nil = no such '+').
        func insert(_ index: Int) -> InsertZone? {
            chain.inserts.first { $0.insertIndex == index }
        }
        /// The '+' whose segment is under `point` (nil = none): the chain's own bands, and — for a send
        /// without plugin — its stub and its line (hovering the line shows the '+' above it).
        func plusTarget(at point: CGPoint) -> SynopticPlusKey? {
            chain.insertZone(at: point)?.key
        }
        /// Where a plugin let go at `point` lands in the mini-chain (nil = outside the column): on the line
        /// or under the chain's tail = the end; elsewhere the '+' NEAREST the pointer vertically (a card's
        /// upper half = before it, its lower half = after it).
        func insertIndex(at point: CGPoint) -> Int? {
            guard frame.contains(point) else { return nil }
            let n = send.plugins.count
            guard n > 0, point.y < chain.exit.y else { return n }
            return chain.inserts.min { abs($0.center.y - point.y) < abs($1.center.y - point.y) }?.insertIndex ?? n
        }
        /// The card-sized rectangle a drop at `index` previews (on that '+').
        func dropPreview(_ index: Int) -> CGRect {
            let c = insert(min(max(0, index), send.plugins.count))?.center ?? entry
            return SynopticLayout.cardFrame(c.x, c.y)
        }
    }

    /// A fixed slot of the sends that has no '+' of the trunk (today: `.postFader` only): where a dragged
    /// send card is taken to. `rect` is the detection band across the wire; `previewFrame` the card-sized
    /// rectangle shown on hover, centred on the slot's anchor.
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
    /// The wire between the head zone and the trunk, and between the trunk and the mixer (the trims' 56 pt
    /// gaps are gone: the trunk's own head and tail '+' sit on these wires' ends).
    static let chainGap: CGFloat = 20
    /// The wire mixer → stems when it carries the post-fader '+'.
    static let postFaderGap: CGFloat = 40
    static let midiZoneW: CGFloat = cardW + 24   // the MIDI zone (instrument card plus margins)
    static let midiZoneH: CGFloat = cardH + 34   // the 'MIDI' title + the card + margins
    static let audioZoneW: CGFloat = 244         // the 'audio file' zone (1× / st / bpm on one line)
    static let audioZoneH: CGFloat = 58
    /// The 'audio file' zone FOLDED: one row — title, loop, reverse, chevron, and the pill of a hidden
    /// setting that is not neutral (§B.7).
    static let audioZoneFoldedH: CGFloat = 30
    /// One more row (a 16 pt pill plus the zone's 7 pt spacing) when the file is stereo: the
    /// LR / L / R / C selector (unfolded only).
    static let audioZoneStereoExtraH: CGFloat = 23
    /// The ARA source (Melodyne) is a CARD, the first one out of the 'audio file' frame: this is the wire
    /// between the frame's foot and the card's top (room for the "ARA" tag hanging above the card's corner).
    static let araCardGap: CGFloat = 30
    static let clipZoneW: CGFloat = 224          // the 'clip' zone (pan / volume / mute on one line)
    static let clipZoneH: CGFloat = 36
    /// The object frame's corner radius: the head's and the mixer's (`SynopticZoneBox`), whose outer corners
    /// ARE the frame's.
    static let objectFrameCorner: CGFloat = 10
    /// The object frame's line: an FX link body's.
    static let objectFrameLineWidth: CGFloat = 1.5
    /// The path the frame's line is stroked along: `frame` inset by half the line on its sides, so that the
    /// line's OUTER edge lies on the frame's sides — where the head and the mixer, whose borders are drawn
    /// inside their rect (`strokeBorder`), have theirs. (A Canvas stroke is centred on its path.)
    static func objectFrameStrokeRect(_ frame: CGRect) -> CGRect {
        frame.insetBy(dx: objectFrameLineWidth / 2, dy: objectFrameLineWidth / 2)
    }

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

    // The SENDS (outgoing): a column each, stacked below the stems, each wired by the left down its gutter.
    /// The send's line (aux, level, on/off, menu, ×): its width, and its height.
    static let sendCardW: CGFloat = 236
    static let sendCardH: CGFloat = 28
    static let sendCardGap: CGFloat = 10    // between two stacked columns
    /// The space between the stems (or the foot) and the first column.
    static let sendsTopGap: CGFloat = 18
    /// The step between two gutters, and the space between the frame and the innermost gutter.
    static let sendGutterStep: CGFloat = 10
    static let sendGutterGap: CGFloat = 10
    static let sendAddW: CGFloat = 120      // the "+ Send to…" button
    static let sendAddH: CGFloat = 24
    static let sendSlotHalfH: CGFloat = 12  // half the height of a fixed slot's detection band
    /// A send WITHOUT plugin: the stub of wire between the wire's arrival and the line (room for the '+'
    /// shown on hover, and the arrow into the line).
    static let sendStubH: CGFloat = 30
    /// A send WITH plugins: the wire between the chain's tail '+' and the line (the trunk → mixer wire's).
    static let sendLineGap: CGFloat = chainGap

    /// A send's column, laid with its top at `top` and its left edge at `left` (@see SendCardPlacement).
    static func sendColumn(_ send: SynopticSend, top: CGFloat, left: CGFloat,
                           anchor: CGPoint, gutterX: CGFloat) -> SendCardPlacement {
        if send.plugins.isEmpty {
            let colW = sendCardW
            let axis = left + colW / 2
            let line = CGRect(x: left, y: top + sendStubH, width: sendCardW, height: sendCardH)
            let column = CGRect(x: left, y: top, width: colW, height: line.maxY - top)
            let plus = CGPoint(x: axis, y: top + plusW / 2 + 2)
            var chain = Placement(size: column.size, entry: CGPoint(x: axis, y: top), exit: CGPoint(x: axis, y: line.minY))
            // The '+' shows while the hand is over the stub OR the line (a plugin-less send is its line).
            chain.inserts = [InsertZone(seriesID: send.id, insertIndex: 0, branchElementID: nil, center: plus,
                                        role: .sendChain, branchTargetID: nil, hoverRect: column,
                                        seriesIsEmpty: true)]
            chain.cables = [Cable(from: chain.entry, to: chain.exit, style: .connector)]
            chain.cableDrops = [CableDropZone(seriesID: send.id, insertIndex: 0,
                                              rect: CGRect(x: left, y: top, width: colW, height: sendStubH),
                                              previewFrame: cardFrame(axis, plus.y))]
            return SendCardPlacement(send: send, frame: column, anchor: anchor, gutterX: gutterX,
                                     lineRect: line, chain: chain)
        }
        let node = SynopticNode(id: send.id, kind: .series(send.plugins.map { p in
            SynopticNode(id: p.id, kind: .plugin(SynopticPlugin(id: p.id, name: p.name, category: .utility,
                                                                isEnabled: p.enabled, color: p.color,
                                                                gainStage: p.gainStage)))
        }))
        let size = measure(node)
        let colW = max(sendCardW, size.width)
        let axis = left + colW / 2
        var chain = place(node, at: CGPoint(x: axis - size.width / 2, y: top), role: .sendChain)
        let line = CGRect(x: axis - sendCardW / 2, y: chain.exit.y + sendLineGap, width: sendCardW, height: sendCardH)
        chain.cables.append(Cable(from: chain.exit, to: CGPoint(x: axis, y: line.minY), style: .connector))
        let column = CGRect(x: left, y: top, width: colW, height: line.maxY - top)
        return SendCardPlacement(send: send, frame: column, anchor: anchor, gutterX: gutterX,
                                 lineRect: line, chain: chain)
    }

    /// The height of a titled box holding `rows` send rows.
    static func rowsZoneH(_ rows: Int) -> CGFloat {
        zoneTitleH + CGFloat(rows) * sendRowH + zonePadV
    }

    /// The width the gutters of `n` sends take on the left of the frame.
    static func sendGutterSpace(_ n: Int) -> CGFloat {
        n > 0 ? CGFloat(n) * sendGutterStep + sendGutterGap : 0
    }

    /// - Parameters:
    ///   - araCardWidth: non-nil = the audio object carries an ARA source: its card (this wide) hangs under the
    ///     'audio file' frame, and the chain moves down by its height.
    ///   - sends: the outgoing sends, one column each, each tapped at its `slot` (@see SendCardPlacement).
    ///   - sendsEnabled: this object can send (it gets the post-fader '+' and the "+ Send to…" button even
    ///     with no send yet).
    ///   - receivedRows: the sends an aux receives, listed in its chain head.
    ///   - infiniteOption: the head carries the 'infinite' checkbox (a top-level aux / group).
    ///   - objectFrame: the host is an OBJECT (clip, MIDI, group, aux): lay its frame (§B.5). False for a
    ///     stem / the Main.
    ///   - clipOptionsExpanded: the audio zone is unfolded (@see SynopticUIState.clipOptionsExpanded).
    static func diagram(for root: SynopticNode,
                        midi: Bool = false, audioFile: Bool = false, audioStereo: Bool = false, araCardWidth: CGFloat? = nil,
                        mix: Bool = false,
                        stems: Bool = false,
                        sends: [SynopticSend] = [], sendsEnabled: Bool = false, receivedRows: Int = 0,
                        infiniteOption: Bool = false,
                        objectFrame: Bool = false, clipOptionsExpanded: Bool = true) -> Diagram {
        let chainSize = measure(root)
        // A bus's head: the 'Source' pill widens into a box as soon as it carries the infinite
        // option and/or the list of sends received.
        let busHead = !midi && !audioFile && (infiniteOption || receivedRows > 0)
        let busHeadH = pillH + (receivedRows > 0 ? CGFloat(receivedRows) * sendRowH + zonePadV : 0)
        let audioH = clipOptionsExpanded ? audioZoneH + (audioStereo ? audioZoneStereoExtraH : 0) : audioZoneFoldedH
        let leadW = midi ? midiZoneW : (audioFile ? audioZoneW : (busHead ? sendsZoneW : sourceW))
        let leadH = midi ? midiZoneH : (audioFile ? audioH : (busHead ? busHeadH : pillH))
        let clipW = clipZoneW

        // Everything is centred on a single vertical column, right of the gutters.
        //
        // With an object FRAME (§B.5) the frame's width comes FIRST, and the two boxes that straddle its
        // edges — the head zone at the top, the mixer at the bottom — take that width and that left edge
        // EXACTLY: their sides ARE the frame's sides (the FX link rule, @see FXBlockPlacement.headerRect: one
        // source of truth for the width, so the edges can never drift apart). The frame holds the chain and
        // the ARA card `fxPad` from its sides; a head or a mixer wider than that widens the frame instead.
        // Without a frame (a stem / the Main) each box keeps its own width, centred.
        let bottomInFrame = mix ? clipW : (stems ? stemsZoneW : outW)   // the box the frame's bottom crosses
        let frameW = max(chainSize.width + 2 * fxPad, (araCardWidth ?? 0) + 2 * fxPad, leadW, bottomInFrame)
        let boxedLeadW = objectFrame ? frameW : leadW
        let boxedClipW = objectFrame ? frameW : clipW
        let boxedFootW = (objectFrame && !mix) ? frameW : (stems ? stemsZoneW : outW)
        let contentW = objectFrame
            ? max(frameW, stems ? stemsZoneW : outW)
            : max(chainSize.width, leadW, outW, mix ? clipW : 0, stems ? stemsZoneW : 0, araCardWidth ?? 0)
        let sendsArea = sendsEnabled || !sends.isEmpty
        let innerEdge = margin + sendGutterSpace(sends.count)   // the content's left edge (and the send columns')
        let contentLeft = innerEdge
        let centerX = contentLeft + contentW / 2

        // The chain's head: the Source pill, the MIDI zone (instrument) or the audio file zone, AT THE TOP.
        let leadRect = CGRect(x: centerX - boxedLeadW / 2, y: margin, width: boxedLeadW, height: leadH)
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

        // head → [ARA source card] → trunk. The ARA source is what the file's audio goes THROUGH first, so
        // its card sits between the frame and the chain.
        var araCard: CGRect? = nil
        var headBottomY = leadRect.maxY
        if audioFile, let w = araCardWidth {
            let r = CGRect(x: centerX - w / 2, y: leadRect.maxY + araCardGap, width: w, height: cardH)
            araCard = r
            headBottomY = r.maxY
        }
        let rootOrigin = CGPoint(x: centerX - chainSize.width / 2, y: headBottomY + chainGap)
        var placement = place(root, at: rootOrigin)

        // The wire into the trunk runs on through its head '+' (the trunk's own first cable carries the
        // arrow into its first element): no arrow here.
        placement.cables.insert(
            Cable(from: CGPoint(x: centerX, y: headBottomY), to: placement.entry, style: .plain), at: 0)
        if let r = araCard {
            // frame → card (the arrow arrives at the card, as it does at any card)
            placement.cables.insert(
                Cable(from: CGPoint(x: centerX, y: leadRect.maxY),
                      to: CGPoint(x: centerX, y: r.minY), style: .connector), at: 0)
        }

        // trunk → [clip zone] → [post-fader '+'] → foot
        var clipZone: CGRect? = nil
        var wireTop: CGFloat           // the top of the wire that arrives at the foot
        if mix {
            let clipRect = CGRect(x: centerX - boxedClipW / 2, y: placement.exit.y + chainGap,
                                  width: boxedClipW, height: clipZoneH)
            clipZone = clipRect
            placement.cables.append(
                Cable(from: placement.exit, to: CGPoint(x: centerX, y: clipRect.minY), style: .connector))
            wireTop = clipRect.maxY
        } else {
            wireTop = placement.exit.y
        }
        let footGap = sendsEnabled ? postFaderGap : (mix ? ioGap : chainGap)

        // The foot box: the 'stems' zone (a selectable output) or the 'Out' pill.
        let bottomW = boxedFootW
        let bottomH = stems ? stemsZoneH : pillH
        let outPill = CGRect(x: centerX - bottomW / 2, y: wireTop + footGap, width: bottomW, height: bottomH)
        let stemsZone: CGRect? = stems ? outPill : nil
        placement.cables.append(
            Cable(from: CGPoint(x: centerX, y: wireTop), to: CGPoint(x: centerX, y: outPill.minY),
                  style: .connector))

        // The post-fader '+' on that wire.
        var postFaderPlus: PostFaderPlus? = nil
        if sendsEnabled {
            let c = CGPoint(x: centerX, y: (wireTop + outPill.minY) / 2)
            postFaderPlus = PostFaderPlus(
                center: c,
                hoverRect: CGRect(x: centerX - cardW / 2, y: wireTop, width: cardW, height: outPill.minY - wireTop))
        }

        // The frame: from the head's TOP edge to the mixer's BOTTOM edge (the foot's, with no mixer) — its outline
        // IS the two boxes' outer outline, so they read as the object's intro and outro inside it.
        var frame: CGRect? = nil
        if objectFrame {
            let bottom = (clipZone ?? outPill).maxY
            frame = CGRect(x: leadRect.minX, y: leadRect.minY, width: leadRect.width,
                           height: bottom - leadRect.minY)
        }

        // The send columns: stacked BELOW the foot, lowest tap first (top) — the highest tap takes the lowest
        // column and the outermost gutter, so the wires nest and never cross.
        var sendCards: [SendCardPlacement] = []
        var sendSlotDrops: [SendSlotDrop] = []
        var addSendButton: CGRect? = nil
        var stackBottom: CGFloat = 0
        if sendsArea {
            let rootInserts = placement.inserts.filter { $0.seriesID == root.id }
            let lastIndex = rootInserts.map(\.insertIndex).max() ?? 0
            let postAnchor = postFaderPlus?.center ?? CGPoint(x: centerX, y: (wireTop + outPill.minY) / 2)
            func anchor(of slot: SynopticSendSlot) -> CGPoint {
                let k: Int
                switch slot {
                case .postFader:    return postAnchor
                case .input:        k = 0
                case .preFader:     k = lastIndex
                case .chain(let i): k = min(max(0, i), lastIndex)
                }
                return rootInserts.first(where: { $0.insertIndex == k })?.center
                    ?? CGPoint(x: centerX, y: placement.entry.y)
            }
            struct Item { let offset: Int; let send: SynopticSend; let anchor: CGPoint }
            var items: [Item] = []
            for (offset, send) in sends.enumerated() {
                items.append(Item(offset: offset, send: send, anchor: anchor(of: send.slot)))
            }
            // Lowest tap first; sends at one tap keep the order they were given (their wires share the
            // tap's horizontal, so any order nests).
            let ordered: [Item] = items.sorted { (l: Item, r: Item) -> Bool in
                if l.anchor.y != r.anchor.y { return l.anchor.y > r.anchor.y }
                return l.offset < r.offset
            }
            var y = outPill.maxY + sendsTopGap
            for (b, item) in ordered.enumerated() {
                let c = sendColumn(item.send, top: y, left: innerEdge, anchor: item.anchor,
                                   gutterX: innerEdge - sendGutterGap - CGFloat(b) * sendGutterStep)
                sendCards.append(c)
                y = c.frame.maxY + sendCardGap
                stackBottom = max(stackBottom, c.frame.maxY)
            }
            if sendsEnabled {
                let r = CGRect(x: innerEdge, y: y, width: sendAddW, height: sendAddH)
                addSendButton = r
                stackBottom = max(stackBottom, r.maxY)
                // The post-fader slot (the others are the trunk's head and tail '+').
                if let p = postFaderPlus {
                    sendSlotDrops.append(SendSlotDrop(
                        slot: .postFader, anchor: p.center, rect: p.hoverRect,
                        previewFrame: cardFrame(p.center.x, p.center.y)))
                }
            }
        }

        let contentRight = contentLeft + contentW
        var right = contentRight
        if sendsArea { right = ([right, innerEdge + sendCardW, innerEdge + sendAddW] + sendCards.map(\.frame.maxX)).max() ?? right }
        let canvasW = right + margin
        let canvasH = max(outPill.maxY, stackBottom) + margin
        return Diagram(canvasSize: CGSize(width: canvasW, height: canvasH),
                       sourcePill: leadRect, outPill: outPill, placement: placement,
                       midiZone: midiZone, instrumentSlot: instrumentSlot,
                       audioZone: audioZone, audioZoneFolded: audioFile && !clipOptionsExpanded,
                       araCard: araCard, clipZone: clipZone, stemsZone: stemsZone,
                       sendCards: sendCards, sendSlotDrops: sendSlotDrops, addSendButton: addSendButton,
                       busHeadZone: busHead ? leadRect : nil,
                       objectFrame: frame, postFaderPlus: postFaderPlus)
    }
}

// MARK: - What a '+' does (the wave-2 contract, pure)

/// A '+' named STABLY across two builds of the layout (a layout's ids are fresh at every build): what the
/// view remembers as hovered, or as the source of a drag in flight.
enum SynopticPlusKey: Hashable {
    /// An insert point of a series (the trunk, a parallel's branch, a bin's series): `index` = the
    /// insertion index in that series.
    case series(UUID, Int)
    /// The '+' on the wire mixer → stems.
    case postFader
    /// The "+" of a send's mini-chain (`aux` = the send's id), appending at `index`.
    case sendChain(aux: UUID, index: Int)
}

/// What a gesture on a '+' does, decided by the layout (@see Diagram.command(for:translation:)); the view
/// dispatches it to `SynopticActions`:
///  - `.openBrowser(.series(s, i))`     → `onInsertSeries(s, i)` (a click: the plugin browser, as before);
///  - `.openBrowser(.sendChain(a, _))`  → `onSendPluginAdd(a)`;
///  - `.insertGainStage(.series(s, i), face)` → `onPlusGesture(s, i, face == .gain ? .gain : .gainPanMute)`;
///  - `.insertGainStage(.sendChain(a, i), face)` → `onSendPlusGesture(a, i, …)`;
///  - `.branch(.series(s, i))`          → `onBranch(.plus(seriesID: s, index: i))` (the receiver reads the
///                                        element under the '+' and the selection, @see SynopticBranchRun);
///  - `.send(slot)`                     → `presentSendMenu(slot:)` (the existing "Send to…" menu at that slot);
///  - `.insertPlugin(.series(s, i), p)` → `onPlusInsertPlugin(s, i, p)` (a direction bound to that plugin);
///  - `.insertPlugin(.sendChain(a, i), p)` → `onSendPlusInsertPlugin(a, i, p)`;
///  - `.openBrowserInCategory(key, c)`  → `onOpenBrowserInCategory(key, c)` (a direction bound to a colour
///                                        category: the browser on that tab, the plugin chosen inserted at key).
enum SynopticPlusCommand: Equatable {
    case none
    case openBrowser(SynopticPlusKey)
    case insertGainStage(SynopticPlusKey, SynopticGainStageFace)
    case branch(SynopticPlusKey)
    case send(SynopticSendSlot)
    case insertPlugin(SynopticPlusKey, PlusPluginRef)
    case openBrowserInCategory(SynopticPlusKey, Int)
}
