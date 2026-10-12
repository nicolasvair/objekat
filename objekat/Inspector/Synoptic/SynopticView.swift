import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

// MARK: - Signal view (pure rendering)

struct SynopticView: View {
    let root: SynopticNode
    /// The selected cards. A SET, and held by the view-model rather than by a `@State` of this
    /// view: every batch gesture (⌫ ⌘C ⌘V ⌘D, a drag onto another object) needs the chain's
    /// reading order, which only the model knows. @see EditViewModel.selectedPluginIDs
    @Binding var selection: Set<UUID>
    /// The instrument card's highlight — its own slot, exclusive with `selection`. An instrument
    /// is not in the FX chain (it lives in `SoundObject.instruments`), so not one of the batch
    /// gestures can act on it; letting it into the set would arm them all over something they
    /// cannot touch, and ⌫ would then eat the key to do nothing.
    @Binding var selectedInstrumentID: UUID?
    var scrolls = true              // false = embedded (the parent handles the scrolling)
    var chainInDb: Float = 0
    var chainOutDb: Float = 0
    /// Chain trims driven by an automation curve (@see automationLocked).
    var chainInAutomated: Bool = false
    var chainOutAutomated: Bool = false
    /// A MIDI clip: shows the 'MIDI' zone (the instrument) at the head instead of the Source pill.
    var isMIDI: Bool = false
    var midiInstrument: SynopticPlugin? = nil
    /// An audio clip: shows the 'audio file' zone (speed / st / bpm) at the head. nil otherwise.
    var audioFile: SynopticAudioFile? = nil
    /// The output mix (volume / pan / mute) in the 'clip' zone. nil for a bus.
    var mix: SynopticMix? = nil
    /// Selectable stems at the foot (the 'stems' zone, replacing Out). nil for a bus.
    var stems: [SynopticStem]? = nil
    /// A group's child: a read-only 'output' zone (→ the parent group) in place
    /// of the stems zone. Mutually exclusive with `stems`.
    var groupRouting: SynopticGroupRouting? = nil
    /// The departures that exist, one CARD each beside the trunk (@see SendCardView). Empty = none yet.
    var sends: [SynopticSend] = []
    /// This object can send (a clip, a group, a MIDI clip: not an aux, a stem or the Main): it gets the
    /// card column and the "+ Send to…" button even with no send yet.
    var canSend: Bool = false
    /// An aux: the sends it RECEIVES, listed at the head of the chain (the signal comes in there). Empty = no list.
    var receivedSends: [SynopticSend] = []
    /// Non-nil ⇒ the chain's head carries the 'infinite' checkbox (a top-level aux / group).
    var infinite: SynopticInfinite? = nil
    /// Non-nil ⇒ looping is available: a group (the chain head) or a MIDI clip (the MIDI zone).
    /// Audio has its own badge in `audioFile` (@see [[loop-item-plan]]).
    var loop: SynopticLoop? = nil
    /// True = a consolidated object shown CLOSED: the FX (cards, '+' inserts, parallel branches, branch
    /// and chain gains) are visible but greyed out and disabled, with an 'Open to edit' tooltip.
    /// The source, the mix and the stems stay interactive. Fully interactive as soon as the object
    /// is opened for editing (double click). See SynopticBoundView.
    var fxReadOnly: Bool = false
    var actions = SynopticActions()

    // The marquee's state, all of it torn down at the end of the gesture. @see marqueeGesture
    @State private var marqueeOrigin: CGPoint? = nil
    @State private var marqueeCurrent: CGPoint? = nil
    /// What was selected when the rectangle started: ⇧ and ⌘ recompute from it at every frame.
    @State private var marqueeBase: Set<UUID> = []
    @State private var marqueeAdds = false
    @State private var marqueeFlips = false
    /// The multiple selection a plain click has just collapsed onto one of its cards, and when.
    /// The first click of a double click IS such a click (the card's single tap fires before
    /// the name's double tap): without this the double click would only ever see one card.
    @State private var collapsedSelection: (ids: Set<UUID>, at: TimeInterval)? = nil

    var body: some View {
        let d = SynopticLayout.diagram(for: root, chainInDb: chainInDb, chainOutDb: chainOutDb,
                                       midi: isMIDI, audioFile: audioFile != nil,
                                       audioStereo: audioFile?.channelMode != nil,
                                       araCardWidth: audioFile?.ara.map { SynopticLayout.araCardWidth(name: $0.name) }, mix: mix != nil,
                                       mixWide: mix?.attrLinks != nil,
                                       stems: stems != nil || groupRouting != nil,
                                       sends: sends, sendsEnabled: canSend, receivedRows: receivedSends.count,
                                       infiniteOption: infinite != nil)
        Group {
            if scrolls {
                ScrollView([.horizontal, .vertical]) { canvas(d).padding(20) }
            } else {
                canvas(d).padding(8)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { selection = []; selectedInstrumentID = nil }   // a click in empty space → deselect
    }

    @ViewBuilder
    private func canvas(_ d: SynopticLayout.Diagram) -> some View {
        ZStack(alignment: .topLeading) {
            Canvas { ctx, _ in draw(ctx, diagram: d) }
                .frame(width: d.canvasSize.width, height: d.canvasSize.height)

            if let mz = d.midiZone {
                midiZoneView(mz, slot: d.instrumentSlot)
            } else if let az = d.audioZone, let af = audioFile {
                audioFileZoneView(az, file: af)
            } else if let bh = d.busHeadZone {
                BusHeadZoneView(rect: bh, infinite: infinite, loop: loop, received: receivedSends,
                                actions: actions)
            } else {
                pill(L("synoptic.source"), rect: d.sourcePill)
            }
            // The ARA source: the FIRST card out of the 'audio file' frame, ahead of the FX. It is the SOURCE,
            // not an insert — so it sits outside the FX group below (never greyed with a closed consolidated
            // object), cannot be dragged, bypassed, linked or dropped upon, and has no '+' around it.
            if let r = d.araCard, let ara = audioFile?.ara {
                SynopticCardView(
                    plugin: SynopticPlugin(name: ara.name, category: .utility, isEnabled: ara.isEnabled,
                                           formatLabel: "VST3", color: ara.color),
                    isSelected: false,
                    onSelect: {},
                    onOpenEditor: (ara.analysing || !ara.isEnabled) ? nil : actions.onOpenARAEditor,
                    onToggleBypass: { actions.onToggleARABypass?() },
                    onRemove: { actions.onRemoveARA?() },
                    width: r.width,
                    ara: ara
                )
                .position(x: r.midX, y: r.midY)
            }
            if let cz = d.clipZone, let m = mix {
                ClipMixZoneView(rect: cz, mix: m, actions: actions)
            }
            if let sz = d.stemsZone, let gr = groupRouting {
                GroupRoutingZoneView(rect: sz, routing: gr)
            } else if let sz = d.stemsZone, let stemList = stems {
                StemsZoneView(rect: sz, stems: stemList,
                              onAssign: { actions.onAssignStem?($0) })
            } else {
                pill(L("synoptic.out"), rect: d.outPill)
            }

            // FX (cards, inserts, branches, gains): greyed out and disabled outside the editing of a
            // closed consolidated object (`fxReadOnly`), fully interactive otherwise. Source / mix / stems are
            // NOT in this group (they always stay active).
            Group {
            // 'Cable' drop zones: rendered FIRST (hence under the cards) so that dropping a plugin on a
            // branch's axis inserts it there — even an empty parallel branch. A hovered card keeps
            // priority (inserting just before it) since it is drawn on top.
            if let onDrop = actions.onDrop {
                ForEach(d.placement.cableDrops) { z in
                    let target = SynopticDropTarget.series(z.seriesID, z.insertIndex)
                    CableDropView(rect: z.rect, previewFrame: z.previewFrame,
                                  outcome: { actions.dropOutcome?(target, $0) },
                                  onDrop: { payload, flags in onDrop(target, payload, flags) },
                                  onSendDrop: actions.onSendDrop.map { f in { payload in f(.place(target), payload) } })
                }
            }

            // The three fixed slots of the sends (input, pre-fader, post-fader): where a send card can be
            // taken to besides the trunk's own insert points.
            if actions.onSendDrop != nil {
                ForEach(d.sendSlotDrops) { z in
                    SendSlotDropView(zone: z, outcome: { actions.sendDropOutcome?(.slot(z.slot)) },
                                     onSendDrop: { payload in actions.onSendDrop?(.slot(z.slot), payload) })
                }
            }

            // A bin's block: its header card (on/off · name · link badge · ✕) straddling the top of the
            // body, and its mix box (pan · volume · mute) nested at the body's foot. The wire stops at
            // each and starts again on the other side, so neither is laid over it (@see draw).
            ForEach(d.placement.fxBlocks) { b in
                FXBlockHeaderView(link: b.link, rect: b.headerRect, pluginCount: b.pluginCount,
                                  actions: actions)
                    .position(x: b.headerRect.midX, y: b.headerRect.midY)
                FXBlockMixView(link: b.link, block: b, actions: actions)
                    .position(x: b.mixRect.midX, y: b.mixRect.midY)
            }

            ForEach(d.placement.cards) { c in
                SynopticCardView(
                    plugin: c.plugin,
                    isSelected: selection.contains(c.plugin.id),
                    onSelect: { clickCard(c.plugin.id, cards: d.placement.cards) },
                    onOpenEditor: actions.onOpenEditor.map { _ in { openEditorFromCard(c.plugin.id) } },
                    onToggleBypass: { actions.onToggleBypass(c.plugin.id) },
                    onRemove: { actions.onRemove(c.plugin.id) },
                    dragProvider: actions.dragProvider.map { f in { f(c.plugin.id) } },
                    dragCount: selection.contains(c.plugin.id) ? selection.count : 1,
                    dropOutcome: { actions.dropOutcome?(.beforeCard(c.plugin.id), $0) },
                    onDropPlugin: actions.onDrop.map { f in { payload, flags in f(.beforeCard(c.plugin.id), payload, flags) } },
                    onDropSend: actions.onSendDrop.map { f in { payload in f(.place(.beforeCard(c.plugin.id)), payload) } },
                    onUnlink: actions.onUnlink.map { f in { f(c.plugin.id) } },
                    onRelink: actions.onRelink.map { f in { f(c.plugin.id) } },
                    linkSiblingCount: actions.linkSiblingCount?(c.plugin.id) ?? 0,
                    sidechainBadge: actions.sidechainBadge?(c.plugin.id)
                )
                .contextMenu {
                    // A card outside the selection speaks for itself alone (the drag's own rule).
                    fxLinkMenu(ids: selection.contains(c.plugin.id) ? Array(selection) : [c.plugin.id])
                }
                .position(x: c.frame.midX, y: c.frame.midY)
            }

            // '+': insert a plugin in series at this point.
            ForEach(d.placement.inserts) { z in
                Button { actions.onInsertSeries(z.seriesID, z.insertIndex) } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .frame(width: SynopticLayout.plusW, height: SynopticLayout.plusW)
                        .background(
                            Circle().strokeBorder(Color.secondary.opacity(0.6),
                                                  style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                        )
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(L("synoptic.addPluginSeries"))
                // On the TRUNK's own insert points (not a branch's): right click = take a send right here.
                .contextMenu {
                    if z.seriesID == root.id, actions.sendTargetSections != nil {
                        Button(L("send.menu.sendHere")) { actions.presentSendMenu(slot: .chain(z.insertIndex)) }
                    }
                }
                // No `.onDrop` here: the drop is handled by the `CableDropView` (the preview
                // rectangle) centred on this '+'. The '+' serves only for the click (insertion).
                .position(z.center)
            }

            // The parallel icon, to the RIGHT of the '+': a branch from this point (before the element).
            ForEach(d.placement.inserts.filter { $0.branchElementID != nil }) { z in
                ParallelBranchButton(enabled: actions.onBranch != nil) {
                    if let f = actions.onBranch, let bid = z.branchElementID { f(bid) }
                }
                .position(x: z.center.x + 26, y: z.center.y)
            }

            // The dB gain at the end of each parallel branch (drag ↑/↓).
            ForEach(d.placement.voiceGains) { vg in
                GainDbControl(dB: vg.dB, muted: vg.muted,
                              onToggleMute: { actions.onSetVoiceMute?(vg.blockID, vg.voiceIndex, !vg.muted) },
                              onBegin: { actions.onBeginGainEdit?() }) { newDB in
                    actions.onSetVoiceGain?(vg.blockID, vg.voiceIndex, newDB)
                }
                .position(vg.center)
            }
            // 🗑 removing a branch, to the RIGHT of the gain (offset enough not to overlap the value).
            ForEach(d.placement.voiceGains) { vg in
                Button { actions.onRemoveVoice?(vg.blockID, vg.voiceIndex) } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L("synoptic.removeBranch"))
                .position(x: vg.center.x + 48, y: vg.center.y)
            }

            // The start / end chain gains (always present, even without a parallel).
            if let cin = d.chainInGain {
                GainDbControl(dB: cin.dB,
                              onTouch: { actions.onTouchParam?(.chainInGain) },
                              onBegin: { actions.onBeginGainEdit?() }) {
                    actions.onSetChainGain?(false, $0)
                }
                .automationLocked(chainInAutomated)
                .position(cin.center)
            }
            if let cout = d.chainOutGain {
                GainDbControl(dB: cout.dB,
                              onTouch: { actions.onTouchParam?(.chainOutGain) },
                              onBegin: { actions.onBeginGainEdit?() }) {
                    actions.onSetChainGain?(true, $0)
                }
                .automationLocked(chainOutAutomated)
                .position(cout.center)
            }
            }   // Group FX
            .fxReadOnlyLocked(fxReadOnly)

            // The outgoing sends: a card each, in a column beside the trunk (the wires are drawn in `draw`).
            // Not in the FX group: a closed consolidated object keeps its sends interactive, as it keeps
            // its mix. Laid LAST, over the slots' drop bands, so that a card is always the one that is
            // grabbed; and not a plugin card: it is outside the selection and ignored by the marquee.
            // A send that carries plugins is a BOX: its plugins' rows on top, the "+", then the card as
            // the bottom line (the order of the signal, Q-U19).
            ForEach(d.sendCards) { c in
                let zone = SendBoxView.zone(of: c)
                SendBoxView(placement: c, actions: actions)
                    .frame(width: zone.width, height: zone.height)
                    .position(x: zone.midX, y: zone.midY)
            }

            // "+ Send to…", in the post-fader slot after its cards: a send made there is post-fader.
            if let b = d.addSendButton, actions.sendTargetSections != nil {
                AddSendButton { actions.presentSendMenu(slot: .postFader) }
                    .frame(width: b.width, height: b.height)
                    .position(x: b.midX, y: b.midY)
            }

            // The marquee under the hand. Drawn last and deaf to the mouse: it is a report of
            // what the gesture is taking, never a surface one can catch.
            if let r = marqueeRect {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.10))
                    .overlay(Rectangle().strokeBorder(Color.accentColor.opacity(0.75), lineWidth: 1))
                    .frame(width: r.width, height: r.height)
                    .position(x: r.midX, y: r.midY)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: d.canvasSize.width, height: d.canvasSize.height, alignment: .topLeading)
        .contentShape(Rectangle())
        .gesture(fxReadOnly ? nil : marqueeGesture(cards: d.placement.cards,
                                                   blockers: d.placement.fxBlocks.flatMap { [$0.headerRect, $0.mixRect] } + d.sendCards.map(\.frame)))
        .contextMenu { fxLinkMenu(ids: Array(selection)) }
    }

    /// The FX link entries of the right-click menus: make a bin of the plugins in hand, or join one
    /// that exists. Nothing at all (an empty menu is not shown) when neither applies, and never on a
    /// closed consolidated object, whose FX are read-only.
    @ViewBuilder
    private func fxLinkMenu(ids: [UUID]) -> some View {
        if !fxReadOnly {
            if !ids.isEmpty, actions.canCreateFXLink?(ids) == true {
                Button(L("fxlink.menu.create")) { actions.onCreateFXLink?(ids) }
            }
            let joinable = actions.joinableFXLinks?() ?? []
            if !joinable.isEmpty {
                Menu(L("fxlink.menu.join")) {
                    ForEach(joinable, id: \.id) { j in
                        Button(j.name) { actions.onJoinFXLink?(j.id) }
                    }
                }
            }
        }
    }

    // MARK: - Choosing cards

    /// A click on a card, modifiers resolved. It happens HERE and not in the view-model because
    /// ⇧ is GEOMETRIC (@see SynopticMarquee.boundingBox) and the frames only exist in this
    /// build's layout. The flags are read off `NSEvent` at the moment of the click, the same way
    /// the timeline's tap handler reads them — SwiftUI's tap carries none.
    private func clickCard(_ id: UUID, cards: [SynopticLayout.CardPlacement]) {
        let flags = NSEvent.modifierFlags
        selectedInstrumentID = nil
        if flags.contains(.command) {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        } else if flags.contains(.shift) {
            selection = Set(SynopticMarquee.boundingBox(of: selection, extendedTo: id,
                                                        cards: marqueeCards(cards)))
        } else {
            // Remembered for the double click that may follow (@see openEditorFromCard).
            collapsedSelection = (selection.count > 1 && selection.contains(id))
                ? (selection, ProcessInfo.processInfo.systemUptime) : nil
            selection = [id]
        }
    }

    /// The double click on a card's name. A card that belongs to a MULTIPLE selection opens the
    /// editors of the whole selection — the selection as it was BEFORE the first click of this
    /// double click collapsed it, which is then given back. A card outside it opens its own alone.
    private func openEditorFromCard(_ id: UUID) {
        var group = selection
        if let c = collapsedSelection, c.ids.contains(id),
           ProcessInfo.processInfo.systemUptime - c.at <= NSEvent.doubleClickInterval + 0.2 {
            group = c.ids
            selection = c.ids
        }
        collapsedSelection = nil
        if group.count > 1, group.contains(id), let many = actions.onOpenEditors {
            many(id, group)
        } else {
            actions.onOpenEditor?(id)
        }
    }

    /// The rectangle being drawn, in the canvas's own coordinates (the cards' frames live there
    /// too). nil = no marquee under way.
    private var marqueeRect: CGRect? {
        guard let o = marqueeOrigin, let c = marqueeCurrent else { return nil }
        return CGRect(x: min(o.x, c.x), y: min(o.y, c.y),
                      width: abs(c.x - o.x), height: abs(c.y - o.y))
    }

    /// The marquee. Three things are decided ONCE, at the first pixel, and never again for the
    /// rest of the gesture:
    ///
    ///  • whether there is a marquee at all — a drag that STARTS on a card is that card's own
    ///    (reorder, move, copy), and a container gesture that stole it would make the chain
    ///    unorderable; so is one that starts on a bin's header card or mix box (the header's drag
    ///    moves the block, the mix box's boxes are dragged for their value). The test is the frames,
    ///    which this view has and AppKit has not (@see SynopticMarquee.startsMarquee);
    ///  • what the modifiers mean — ⇧ adds to what was already taken, ⌘ flips it, neither
    ///    replaces it. Read at the start, because a hand that lets go of ⇧ mid-drag is resting a
    ///    finger, not changing its mind;
    ///  • what was already selected (`marqueeBase`), so that widening AND narrowing the rectangle
    ///    both recompute from the same ground instead of piling up.
    private func marqueeGesture(cards: [SynopticLayout.CardPlacement], blockers: [CGRect]) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { g in
                if marqueeOrigin == nil {
                    guard SynopticMarquee.startsMarquee(at: g.startLocation, cards: marqueeCards(cards),
                                                        blockers: blockers) else { return }
                    let flags = NSEvent.modifierFlags
                    marqueeAdds = flags.contains(.shift)
                    marqueeFlips = flags.contains(.command)
                    marqueeBase = (marqueeAdds || marqueeFlips) ? selection : []
                    marqueeOrigin = g.startLocation
                }
                marqueeCurrent = g.location
                applyMarquee(cards: cards)
            }
            .onEnded { _ in
                if marqueeOrigin != nil { applyMarquee(cards: cards) }
                marqueeOrigin = nil
                marqueeCurrent = nil
                marqueeBase = []
            }
    }

    /// The placements stripped down to what the geometry needs — an id and a rectangle. It is
    /// what lets `SynopticMarquee` know nothing of views, plugins or layout.
    private func marqueeCards(_ cards: [SynopticLayout.CardPlacement]) -> [SynopticMarquee.Card] {
        cards.map { SynopticMarquee.Card(id: $0.plugin.id, frame: $0.frame) }
    }

    private func applyMarquee(cards: [SynopticLayout.CardPlacement]) {
        guard let r = marqueeRect else { return }
        let caught = Set(SynopticMarquee.touching(r, cards: marqueeCards(cards)))
        if marqueeFlips {
            selection = marqueeBase.symmetricDifference(caught)
        } else if marqueeAdds {
            selection = marqueeBase.union(caught)
        } else {
            selection = caught
        }
        if !selection.isEmpty { selectedInstrumentID = nil }
    }

    // MARK: Source / Out pills

    private func pill(_ text: String, rect: CGRect) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(width: rect.width, height: rect.height)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.3), lineWidth: 0.5))
            .position(x: rect.midX, y: rect.midY)
    }

    /// The 'MIDI' zone at the head of the chain (a MIDI clip): a titled box holding the instrument
    /// card, or a '+' button if no instrument is assigned.
    @ViewBuilder
    private func midiZoneView(_ rect: CGRect, slot: CGRect?) -> some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.accentColor.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor.opacity(0.4), lineWidth: 1))
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)

            Text(L("synoptic.midi"))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .position(x: rect.midX, y: rect.minY + 11)

            if let lp = loop {
                Button { actions.onToggleLoop?() } label: {
                    Image(systemName: "repeat")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(lp.isOn ? Color.accentColor : Color.secondary)
                        .padding(4)
                        .background(Circle()
                            .fill((lp.isOn ? Color.accentColor : Color.secondary).opacity(lp.isOn ? 0.18 : 0.10)))
                }
                .buttonStyle(.plain)
                .help(L("synoptic.loop"))
                .position(x: rect.maxX - 14, y: rect.minY + 11)
            }

            if let slot {
                if let inst = midiInstrument {
                    SynopticCardView(
                        plugin: inst,
                        isSelected: selectedInstrumentID == inst.id,
                        onSelect: { selectedInstrumentID = inst.id; selection = [] },
                        onOpenEditor: actions.onOpenInstrumentEditor,
                        onToggleBypass: { actions.onToggleInstrumentBypass?() },
                        onRemove: { actions.onRemoveInstrument?() },
                        // The same drag handle as the FX cards: the name. Dropped on another MIDI
                        // clip in the timeline, the instrument takes the instrument slot there
                        // (⌥ = a copy, ⌘ = a linked copy) — @see EditViewModel.transferInstrument.
                        dragProvider: actions.dragProvider.map { f in { f(inst.id) } },
                        // A link badge, as on an FX card: an instrument links to
                        // another instance (⌘-drop) and unlinks with a click.
                        onUnlink: actions.onUnlink.map { f in { f(inst.id) } },
                        onRelink: actions.onRelink.map { f in { f(inst.id) } },
                        linkSiblingCount: actions.linkSiblingCount?(inst.id) ?? 0,
                        width: slot.width
                    )
                    .frame(width: slot.width, height: slot.height)
                    .position(x: slot.midX, y: slot.midY)
                } else {
                    Button { actions.onAddInstrument?() } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "plus")
                            Text(L("synoptic.instrument"))
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: slot.width, height: slot.height)
                        .background(RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.secondary.opacity(0.5),
                                          style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(L("synoptic.addInstrument"))
                    .position(x: slot.midX, y: slot.midY)
                }
            }
        }
    }

    /// The 'audio file' zone at the head of the chain (an audio clip): speed / semitones / bpm.
    private func audioFileZoneView(_ rect: CGRect, file: SynopticAudioFile) -> some View {
        AudioFileZoneView(rect: rect, file: file, actions: actions)
    }

    // MARK: Canvas drawing (backing areas, cables, split/merge nodes)

    private func draw(_ ctx: GraphicsContext, diagram d: SynopticLayout.Diagram) {
        for s in d.placement.scopes.sorted(by: { $0.depth < $1.depth }) {
            let path = Path(roundedRect: s.rect, cornerRadius: 14)
            ctx.fill(path, with: .color(Color.gray.opacity(0.06 + Double(s.depth) * 0.05)))
        }

        // A bin's block: its colour round its series (dashed once the host has left the bin). The BODY
        // alone: the header card that straddles its top edge is a view of its own, opaque, laid over it.
        for b in d.placement.fxBlocks {
            let path = Path(roundedRect: b.bodyRect, cornerRadius: SynopticLayout.fxBodyCorner)
            ctx.fill(path, with: .color(b.link.color.opacity(b.link.isEnabled ? 0.16 : 0.06)))
            ctx.stroke(path, with: .color(b.link.color.opacity(b.link.isDetached ? 0.6 : 0.95)),
                       style: StrokeStyle(lineWidth: 1.5, dash: b.link.isDetached ? [4, 3] : []))
        }

        for cable in d.placement.cables {
            var path = Path()
            path.move(to: cable.from)
            if cable.style == .connector || cable.style == .plain {
                path.addLine(to: cable.to)
            } else {
                // A vertical flow: the fork/merge curve bends vertically (control points on midY).
                let midY = (cable.from.y + cable.to.y) / 2
                path.addCurve(to: cable.to,
                              control1: CGPoint(x: cable.from.x, y: midY),
                              control2: CGPoint(x: cable.to.x, y: midY))
            }
            let isGhost = cable.style == .ghost
            ctx.stroke(path,
                       with: .color(Color.secondary.opacity(isGhost ? 0.4 : 0.7)),
                       style: StrokeStyle(lineWidth: isGhost ? 1 : 1.5,
                                          lineCap: .round,
                                          dash: isGhost ? [3, 3] : []))
            if cable.style == .connector || cable.style == .fork {
                // An arrowhead pointing DOWN (the vertical direction of the signal).
                var head = Path()
                head.move(to: CGPoint(x: cable.to.x - 4, y: cable.to.y - 6))
                head.addLine(to: cable.to)
                head.addLine(to: CGPoint(x: cable.to.x + 4, y: cable.to.y - 6))
                ctx.stroke(head, with: .color(Color.secondary.opacity(0.7)),
                           style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
        }

        for p in d.placement.dots {
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)),
                     with: .color(Color.secondary.opacity(0.8)))
        }

        // The sends' wires: a branch leaves the trunk at the card's anchor, sideways, and arrives at the
        // box's left edge, at its TOP — the first plugin's row, or the card itself when the send carries
        // none (the main signal carries on down the trunk). Dashed: it is a TAP, not the
        // flow. A refused send is dimmer.
        for c in d.sendCards {
            let from = CGPoint(x: c.anchor.x + SynopticLayout.plusW / 2 + 2, y: c.anchor.y)
            let to = c.entry
            var path = Path()
            path.move(to: from)
            let midX = (from.x + to.x) / 2
            path.addCurve(to: to, control1: CGPoint(x: midX, y: from.y), control2: CGPoint(x: midX, y: to.y))
            let live = c.send.enabled && c.send.refusal == nil
            ctx.stroke(path, with: .color((live ? Color.accentColor : Color.secondary).opacity(live ? 0.75 : 0.4)),
                       style: StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: [4, 3]))
            var head = Path()
            head.move(to: CGPoint(x: to.x - 6, y: to.y - 4))
            head.addLine(to: to)
            head.addLine(to: CGPoint(x: to.x - 6, y: to.y + 4))
            ctx.stroke(head, with: .color((live ? Color.accentColor : Color.secondary).opacity(live ? 0.75 : 0.4)),
                       style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
            ctx.fill(Path(ellipseIn: CGRect(x: c.anchor.x - 2.5 + SynopticLayout.plusW / 2 + 2, y: c.anchor.y - 2.5, width: 5, height: 5)),
                     with: .color((live ? Color.accentColor : Color.secondary).opacity(0.8)))
        }
    }
}

// MARK: - Parallel branch button (discreet: translucent at rest, sharp on hover)

struct ParallelBranchButton: View {
    let enabled: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ParallelBranchGlyph(color: .secondary)
                .frame(width: 11, height: 15)
                .padding(3)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(Color.secondary.opacity(hovering && enabled ? 0.5 : 0),
                                      style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                )
                .contentShape(RoundedRectangle(cornerRadius: 5))
                .opacity(enabled ? (hovering ? 1 : 0.3) : 0.18)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .help(L("synoptic.newBranch"))
    }
}

// MARK: - The parallel branch icon (a vertical 'Y': a trunk splitting into two downward arrows)

struct ParallelBranchGlyph: View {
    var color: Color = .secondary

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            let cx = w / 2
            let ty: CGFloat = 1.5          // the trunk's input (top)
            let fy = h * 0.42             // the fork point
            let by = h - 2.5             // the arrowheads (bottom)
            let xLeft = w * 0.16, xRight = w * 0.84
            let fork = CGPoint(x: cx, y: fy)

            var p = Path()
            p.move(to: CGPoint(x: cx, y: ty)); p.addLine(to: fork)         // the trunk
            p.move(to: fork); p.addLine(to: CGPoint(x: xLeft, y: by))      // the left branch
            p.move(to: fork); p.addLine(to: CGPoint(x: xRight, y: by))     // the right branch
            ctx.stroke(p, with: .color(color),
                       style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))

            // An arrowhead at the end of each branch.
            let ah: CGFloat = 4
            for tip in [CGPoint(x: xLeft, y: by), CGPoint(x: xRight, y: by)] {
                let dx = tip.x - fork.x, dy = tip.y - fork.y
                let len = max(0.001, (dx * dx + dy * dy).squareRoot())
                let ux = dx / len, uy = dy / len      // the branch's direction
                let px = -uy, py = ux                 // the perpendicular
                var head = Path()
                head.move(to: CGPoint(x: tip.x - ux * ah + px * ah * 0.6, y: tip.y - uy * ah + py * ah * 0.6))
                head.addLine(to: tip)
                head.addLine(to: CGPoint(x: tip.x - ux * ah - px * ah * 0.6, y: tip.y - uy * ah - py * ah * 0.6))
                ctx.stroke(head, with: .color(color),
                           style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
            }
        }
    }
}
