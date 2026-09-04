import SwiftUI

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
    static let gainBandH: CGFloat = 30     // the band reserved for the mute plus end-of-branch dB gain of a parallel branch (under the branches)

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

    enum CableStyle { case connector, fork, merge, ghost }

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

        mutating func absorb(_ o: Placement) {
            cards += o.cards; cables += o.cables; dots += o.dots
            scopes += o.scopes; inserts += o.inserts
            cableDrops += o.cableDrops; voiceGains += o.voiceGains
        }
    }

    // MARK: Measuring (size alone, to centre before placing)

    static func measure(_ node: SynopticNode) -> CGSize {
        switch node.kind {
        case .plugin:
            return CGSize(width: cardW, height: cardH)

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
        switch node.kind {

        case .plugin(let p):
            let frame = CGRect(origin: origin, size: CGSize(width: cardW, height: cardH))
            var pl = Placement(size: frame.size,
                               entry: CGPoint(x: origin.x + cardW / 2, y: origin.y),
                               exit: CGPoint(x: origin.x + cardW / 2, y: origin.y + cardH))
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
        /// The 'clip' zone (the output mix: volume / pan / mute), between the end gain and the output.
        /// nil for a bus (no object).
        var clipZone: CGRect? = nil
        /// The 'stems' zone at the foot (replacing the Out pill): choosing the output stem.
        /// nil for a bus.
        var stemsZone: CGRect? = nil
        /// The 'sends' zone at the foot (just before the stems): one row per targeted aux.
        /// nil if the object has no reachable aux.
        var sendsZone: CGRect? = nil
        /// The head of a bus's chain (aux / group): a widened 'source' box carrying the infinite
        /// option and, for an aux, the sends it receives. nil when the head is the plain pill.
        var busHeadZone: CGRect? = nil
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
    static let clipZoneW: CGFloat = 196          // the 'clip' zone (pan / volume / mute on one line)
    static let clipZoneWWide: CGFloat = 300      // the same plus the attribute link icons (a linked sound object)
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

    /// The height of a titled box holding `rows` send rows.
    static func rowsZoneH(_ rows: Int) -> CGFloat {
        zoneTitleH + CGFloat(rows) * sendRowH + zonePadV
    }

    /// - Parameters:
    ///   - sendRows: how many outgoing sends are shown at the foot (0 = no 'sends' zone).
    ///   - receivedRows: the sends an aux receives, listed in its chain head.
    ///   - infiniteOption: the head carries the 'infinite' checkbox (a top-level aux / group).
    static func diagram(for root: SynopticNode, chainInDb: Float = 0, chainOutDb: Float = 0,
                        midi: Bool = false, audioFile: Bool = false, mix: Bool = false,
                        mixWide: Bool = false, stems: Bool = false,
                        sendRows: Int = 0, receivedRows: Int = 0,
                        infiniteOption: Bool = false) -> Diagram {
        let chainSize = measure(root)
        // A bus's head: the 'Source' pill widens into a box as soon as it carries the infinite
        // option and/or the list of sends received.
        let busHead = !midi && !audioFile && (infiniteOption || receivedRows > 0)
        let busHeadH = pillH + (receivedRows > 0 ? CGFloat(receivedRows) * sendRowH + zonePadV : 0)
        let leadW = midi ? midiZoneW : (audioFile ? audioZoneW : (busHead ? sendsZoneW : sourceW))
        let leadH = midi ? midiZoneH : (audioFile ? audioZoneH : (busHead ? busHeadH : pillH))
        let clipW = mixWide ? clipZoneWWide : clipZoneW

        // Everything is centred on a single vertical column.
        let contentW = max(chainSize.width, leadW, outW, mix ? clipW : 0, stems ? stemsZoneW : 0,
                           sendRows > 0 ? sendsZoneW : 0)
        let centerX = margin + contentW / 2

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

        // head → [start gain] → trunk
        let inGainCenter = CGPoint(x: centerX, y: leadRect.maxY + chainGainGap / 2)
        let rootOrigin = CGPoint(x: centerX - chainSize.width / 2, y: leadRect.maxY + chainGainGap)
        var placement = place(root, at: rootOrigin)

        placement.cables.insert(
            Cable(from: CGPoint(x: centerX, y: leadRect.maxY),
                  to: CGPoint(x: centerX, y: inGainCenter.y - gainHalfGap), style: .connector), at: 0)
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

        // The 'sends' zone: branches towards the auxes, taken AFTER the object's mix and just
        // before its output — hence its place at the foot, between the clip zone and the stems.
        var sendsZone: CGRect? = nil
        if sendRows > 0 {
            let h = rowsZoneH(sendRows)
            let r = CGRect(x: centerX - sendsZoneW / 2, y: afterGainY, width: sendsZoneW, height: h)
            sendsZone = r
            if mix {
                placement.cables.append(
                    Cable(from: CGPoint(x: centerX, y: r.minY - ioGap),
                          to: CGPoint(x: centerX, y: r.minY), style: .connector))
            }
            afterGainY = r.maxY + ioGap
        }

        // The foot box: the 'stems' zone (a selectable output) or the 'Out' pill.
        let bottomW = stems ? stemsZoneW : outW
        let bottomH = stems ? stemsZoneH : pillH
        let outPill = CGRect(x: centerX - bottomW / 2, y: afterGainY, width: bottomW, height: bottomH)
        let stemsZone: CGRect? = stems ? outPill : nil
        if mix || sendsZone != nil {
            // clip zone / sends → foot
            placement.cables.append(
                Cable(from: CGPoint(x: centerX, y: outPill.minY - ioGap),
                      to: CGPoint(x: centerX, y: outPill.minY), style: .connector))
        }

        let canvasW = contentW + 2 * margin
        let canvasH = outPill.maxY + margin
        return Diagram(canvasSize: CGSize(width: canvasW, height: canvasH),
                       sourcePill: leadRect, outPill: outPill, placement: placement,
                       chainInGain: ChainGain(dB: chainInDb, center: inGainCenter),
                       chainOutGain: ChainGain(dB: chainOutDb, center: outGainCenter),
                       midiZone: midiZone, instrumentSlot: instrumentSlot,
                       audioZone: audioZone, clipZone: clipZone, stemsZone: stemsZone,
                       sendsZone: sendsZone, busHeadZone: busHead ? leadRect : nil)
    }
}
