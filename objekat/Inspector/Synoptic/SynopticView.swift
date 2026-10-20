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
    /// The colour of the object's FRAME (§B.5, D7: `customColor ?? stemColor`). The frame is laid for an
    /// OBJECT host only — one that has a mixer (`mix != nil`): a clip, a MIDI clip, a group, an aux; never
    /// for a stem or the Main (their popover). nil = a neutral grey until the caller passes the colour.
    var frameColor: Color? = nil
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
    /// A consolidated INSTANCE (closed clip or open stage): its source is the shared CONTENT, shown as a
    /// pill with the definition's name — double click opens it for editing (or validates it when it
    /// is open). Replaces the 'audio file' zone and the Source pill. The instance's own FX, mix, sends
    /// and stem are the instance's: fully interactive, closed or open.
    var contentPill: SynopticContentPill? = nil
    /// The width of the signal along the chain (@see SynopticWidthFlow), computed by the bound view once per
    /// chain change: one wire for mono, two for stereo, an orange merge / split where a plugin's input is not
    /// the width it is fed. Empty = nothing to say (the demo): the wires keep their single look.
    var widthFlow = SynopticWidthFlow()
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

    // The '+' (§B.2, §B.3). Both are held by a STABLE name (@see SynopticStablePlus): the bound view
    // rebuilds the graph several times a second (the VU poll) and a parallel's branches get fresh series
    // ids at every build, so a key of the build would forget the hover and cancel a drag in flight.
    /// The '+' whose line is under the pointer (the ONE hover hit test, @see SynopticHoverTracker).
    @State private var hoveredPlus: SynopticStablePlus? = nil
    /// The drag in flight out of a '+': which one, and how far the hand has gone.
    @State private var plusDrag: PlusDrag? = nil
    /// The wire under the pointer that has a channel menu of its own (@see hoveredChannelWire): read by the
    /// canvas' right click. Nothing is written over it (request of 20 October 2026: the tooltip hid everything).
    @State private var hoveredWire: HoveredWire? = nil

    private enum HoveredWire: Equatable {
        /// A MERGING wire into a one-input plugin: the plugin, and the fold it was given (nil = none chosen).
        case fold(plugin: UUID, current: MonoFold?)
        /// The wire that leaves a stereo audio file: its channel choice.
        case source(current: SourceChannelChoice)
    }

    private struct PlusDrag: Equatable {
        let key: SynopticStablePlus
        var translation: CGSize
    }

    var body: some View {
        let d = currentDiagram
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
        // The stable names of this build's series, and the '+' shown whatever the hand does (empty series).
        let names = SynopticPlusPresentation.seriesNames(of: root)
        let alwaysShown = Set(d.alwaysVisiblePlusKeys.map { stablePlus($0, names: names) })
        ZStack(alignment: .topLeading) {
            Canvas { ctx, _ in draw(ctx, diagram: d) }
                .frame(width: d.canvasSize.width, height: d.canvasSize.height)

            if let cp = contentPill {
                contentPillView(cp, rect: d.sourcePill)
            } else if let mz = d.midiZone {
                midiZoneView(mz, slot: d.instrumentSlot)
            } else if let az = d.audioZone, let af = audioFile {
                audioFileZoneView(az, file: af, folded: d.audioZoneFolded)
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
            // The object frame's LINE, over the head and the mixer: the whole outline in the object's colour,
            // the two boxes inside it as intro and outro. Deaf to the mouse.
            if let f = d.objectFrame {
                RoundedRectangle(cornerRadius: SynopticLayout.objectFrameCorner)
                    .strokeBorder((frameColor ?? Color.secondary).opacity(0.95),
                                  lineWidth: SynopticLayout.objectFrameLineWidth)
                    .frame(width: f.width, height: f.height)
                    .position(x: f.midX, y: f.midY)
                    .allowsHitTesting(false)
            }
            if let sz = d.stemsZone, let gr = groupRouting {
                GroupRoutingZoneView(rect: sz, routing: gr)
            } else if let sz = d.stemsZone, let stemList = stems {
                StemsZoneView(rect: sz, stems: stemList,
                              onAssign: { actions.onAssignStem?($0) })
            } else {
                pill(L("synoptic.out"), rect: d.outPill)
            }

            // FX (cards, inserts, branches, gains). Source / mix / stems are NOT in this group.
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
            // body. The wire stops at it and starts again at its foot, so it is never laid over it (@see
            // draw). No mix box any more (§B.8): a gain on a bin is a stage dragged out of the bin's '+'.
            ForEach(d.placement.fxBlocks) { b in
                FXBlockHeaderView(link: b.link, rect: b.headerRect, pluginCount: b.pluginCount,
                                  actions: actions,
                                  onSelect: { selectedInstrumentID = nil; selection = [b.link.blockID] })
                    .position(x: b.headerRect.midX, y: b.headerRect.midY)
            }

            ForEach(d.placement.cards) { c in
                pluginCard(c, cards: d.placement.cards)
                    .contextMenu {
                        // A card outside the selection speaks for itself alone (the drag's own rule).
                        fxLinkMenu(ids: selection.contains(c.plugin.id) ? Array(selection) : [c.plugin.id])
                        // A parallel branch of this card — of the selected run round it when it is selected
                        // (@see SynopticBranchRun.around). Never for a bin's instance: its block is branched whole.
                        if !c.plugin.inFXBlock, let branch = actions.onBranch {
                            Button(L("synoptic.menu.createBranch")) { branch(.plugin(c.plugin.id)) }
                        }
                        // The width of the main bus: mono / mono→stereo / stereo (only an external plugin has one).
                        if c.plugin.gainStage == nil, let menu = actions.channelMenu?(c.plugin.id) {
                            channelsMenu(menu, plugin: c.plugin.id)
                        }
                    }
                    .position(x: c.frame.midX, y: c.frame.midY)
            }

            // '+' on the wire (§B.2, §B.3): shown while its line is hovered, always in an empty series, and
            // while a drag leaves from it. A CLICK opens the plugin browser (as before); a DRAG asks for the
            // action the user put on its direction — by default a gain stage (right), a parallel branch
            // (down-right) or a send (left) (@see SynopticPlusGesture, PlusShortcutMap), with a ghost under way.
            // Drawn OPAQUE over the wire, which runs through it. Laid after the cable drop zones, so that a
            // shown '+' is what the hand grabs; no `.onDrop` on it (the `CableDropView` under it receives).
            ForEach(d.placement.inserts, id: \.key) { z in
                let sk = stablePlus(z.key, names: names)
                let shown = SynopticPlusPresentation.isShown(sk, hovered: hoveredPlus, dragging: plusDrag?.key,
                                                             alwaysVisible: alwaysShown)
                SynopticPlusButton(active: plusDrag?.key == sk,
                                   onChanged: { plusMoved(sk, $0) },
                                   onEnded: { plusReleased(sk, $0) })
                    .help(plusHelp)
                    .opacity(shown ? 1 : 0)
                    .allowsHitTesting(shown)
                    .position(z.center)
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
            }   // Group FX

            // The '+' on the wire mixer → stems: a send taken after the fader, its only gesture (D2) — a
            // click opens the same "Send to…" menu. Not in the FX group: a closed consolidated object keeps
            // its sends interactive, as it keeps its mix.
            if let p = d.postFaderPlus, actions.sendTargetSections != nil {
                let sk = SynopticStablePlus.postFader
                let shown = SynopticPlusPresentation.isShown(sk, hovered: hoveredPlus, dragging: plusDrag?.key,
                                                             alwaysVisible: alwaysShown)
                SynopticPlusButton(active: plusDrag?.key == sk,
                                   onChanged: { plusMoved(sk, $0) },
                                   onEnded: { plusReleased(sk, $0) })
                    .help(postFaderHelp)
                    .opacity(shown ? 1 : 0)
                    .allowsHitTesting(shown)
                    .position(p.center)
            }

            // The outgoing sends: a COLUMN each, stacked BELOW the stems and wired by the left (the wires are
            // drawn in `draw`), drawn like the object (request 5): the send's plugins as the trunk's own cards,
            // a '+' on each segment of the wire, and the send's LINE at the bottom. Not in the FX group: a closed
            // consolidated object keeps its sends interactive, as it keeps its mix. Laid over the slots' drop
            // bands; outside the trunk's selection, and ignored by the marquee.
            ForEach(d.sendCards) { c in
                // The column's drop layer first (under the cards and the line, never their ancestor).
                SendColumnDropView(placement: c, actions: actions)
                SendCardView(send: c.send, actions: actions)
                    .frame(width: c.lineRect.width, height: c.lineRect.height)
                    .position(x: c.lineRect.midX, y: c.lineRect.midY)
                ForEach(c.chain.cards) { card in
                    SendChainCardView(card: card, send: c.send, actions: actions)
                        .position(x: card.frame.midX, y: card.frame.midY)
                }
                // The '+' of the send's mini-chain: shown on hover only (even a plugin-less send's), the
                // canvas' own button — a click = the picker aimed at the send, a drag right = a gain stage.
                ForEach(c.chain.inserts, id: \.key) { z in
                    let sk = stablePlus(z.key, names: names)
                    let shown = SynopticPlusPresentation.isShown(sk, hovered: hoveredPlus, dragging: plusDrag?.key,
                                                                 alwaysVisible: alwaysShown)
                    SynopticPlusButton(active: plusDrag?.key == sk,
                                       onChanged: { plusMoved(sk, $0) },
                                       onEnded: { plusReleased(sk, $0) })
                        .help(plusHelp)
                        .opacity(shown ? 1 : 0)
                        .allowsHitTesting(shown)
                        .position(z.center)
                }
            }

            // The HANDLES: where each send is taken on the trunk. A handle is grabbed like the line (§B.6):
            // dragged onto another place of the chain it moves where the send is taken (the same payload as
            // the line's, @see sendDragProvider). It sits on the wire just LEFT of the '+' ring it stands for,
            // never under it, and sends taken at one point fan out by their rank (@see SendWire.handleCenter).
            ForEach(d.sendCards) { c in
                SendTapDotView(placement: c, rank: SendWire.rank(of: c, in: d.sendCards), actions: actions)
            }

            // "+ Send to…", at the bottom of the stack of columns: a send made there is post-fader.
            if let b = d.addSendButton, actions.sendTargetSections != nil {
                AddSendButton { actions.presentSendMenu(slot: .postFader) }
                    .frame(width: b.width, height: b.height)
                    .position(x: b.midX, y: b.midY)
            }

            // The zones round a dragged '+' (one per direction it offers, each with its icon; the one the hand
            // is in lights up), then the ghost of what letting go here would make. Both deaf to the mouse.
            if let drag = plusDrag, let from = plusCenter(drag.key, in: d, names: names),
               let key = currentKey(drag.key, in: d, names: names),
               !SynopticPlusGesture.isClick(drag.translation) {
                let zones = SynopticPlusPresentation.sectors(allowed: d.allowedGestures(for: key), key: key,
                                                            availability, translation: drag.translation, map: plusMap)
                PlusSectorsView(center: from, sectors: zones.sectors, highlighted: zones.highlighted)
                    .frame(width: d.canvasSize.width, height: d.canvasSize.height)
                    .allowsHitTesting(false)
            }
            if let drag = plusDrag, let from = plusCenter(drag.key, in: d, names: names) {
                let raw = currentKey(drag.key, in: d, names: names)
                    .map { d.command(for: $0, translation: drag.translation, map: plusMap) } ?? .none
                SynopticPlusGhostView(from: from, translation: drag.translation,
                                      ghost: SynopticPlusPresentation.ghost(raw: raw, availability,
                                                                            translation: drag.translation))
                    .frame(width: d.canvasSize.width, height: d.canvasSize.height)
                    .allowsHitTesting(false)
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
        // The ONE hover hit test of the '+' (§B.3): an AppKit tracking area deaf to clicks, since a SwiftUI
        // hover on this container goes `.ended` as soon as the pointer enters a card or a zone.
        .overlay(SynopticHoverTracker { point in
            let k = point.flatMap { d.plusTarget(at: $0) }.map { stablePlus($0, names: names) }
            if hoveredPlus != k { hoveredPlus = k }
            let w = point.flatMap { hoveredChannelWire(at: $0, in: d) }
            if hoveredWire != w { hoveredWire = w }
        })
        .contentShape(Rectangle())
        .gesture(marqueeGesture(cards: d.placement.cards, blockers: marqueeBlockers(d)))
        .contextMenu {
            // On a wire that carries a channel choice, and only there: what the one-input plugin is fed, or
            // which channels of the audio file the chain gets.
            switch hoveredWire {
            case .fold(let id, let current)?:
                if let set = actions.onSetMonoFold { monoFoldMenu(plugin: id, current: current, set: set) }
            case .source(let current)?:
                if let set = actions.onSetSourceChannels { sourceChannelMenu(current: current, set: set) }
            case nil:
                fxLinkMenu(ids: Array(selection))
            }
        }
    }

    /// Left / Right / Sum, the current one ticked (none for a plugin that never had a choice: it reads the
    /// left channel and lets the right one pass round it, which none of the three is).
    @ViewBuilder
    private func monoFoldMenu(plugin id: UUID, current: MonoFold?,
                              set: @escaping (UUID, MonoFold) -> Void) -> some View {
        ForEach(MonoFold.allCases, id: \.self) { f in
            Toggle(Self.foldLabel(f),
                   isOn: Binding(get: { current == f }, set: { _ in if current != f { set(id, f) } }))
        }
    }

    /// Both / Left / Right / Sum for the audio file, the current one ticked.
    @ViewBuilder
    private func sourceChannelMenu(current: SourceChannelChoice,
                                   set: @escaping (SourceChannelChoice) -> Void) -> some View {
        ForEach([SourceChannelChoice.both, .left, .right, .sum], id: \.self) { c in
            Toggle(Self.sourceChoiceLabel(c),
                   isOn: Binding(get: { current == c }, set: { _ in if current != c { set(c) } }))
        }
    }

    // MARK: - The '+' (§B.2, §B.3)

    /// Which wave-2 closures this view was given: a gesture whose closure is missing is offered as
    /// "not here" (@see SynopticPlusPresentation.available).
    private var availability: SynopticPlusAvailability {
        let installed = actions.plusPluginInstalled
        return SynopticPlusAvailability(gainStage: actions.onPlusGesture != nil,
                                        sendGainStage: actions.onSendPlusGesture != nil,
                                        branch: actions.onBranch != nil,
                                        send: actions.sendTargetSections != nil,
                                        sendPluginAdd: actions.onSendPluginAdd != nil,
                                        insertPlugin: actions.onPlusInsertPlugin != nil,
                                        sendInsertPlugin: actions.onSendPlusInsertPlugin != nil,
                                        category: actions.onOpenBrowserInCategory != nil,
                                        missingPlugins: Set(plusMap.pluginRefs.filter { !(installed?($0) ?? true) }))
    }

    /// What each direction of a '+' asks for: the user's map (an app preference, @see PlusShortcutStore).
    /// Read while drawing, so a change made in the settings or the plugin browser shows at once.
    private var plusMap: PlusShortcutMap { PlusShortcutStore.shared.map }

    private func stablePlus(_ key: SynopticPlusKey, names: [UUID: String]) -> SynopticStablePlus {
        SynopticPlusPresentation.stable(key, names: names)
    }

    /// The key of THIS build that a stable name stands for (nil = that '+' is gone).
    private func currentKey(_ sk: SynopticStablePlus, in d: SynopticLayout.Diagram,
                            names: [UUID: String]) -> SynopticPlusKey? {
        switch sk {
        case .postFader:
            return d.postFaderPlus?.key
        case .sendChain(let aux, let i):
            return d.sendInsert(.sendChain(aux: aux, index: i))?.key
        case .series:
            return d.placement.inserts.first { stablePlus($0.key, names: names) == sk }?.key
        }
    }

    private func plusCenter(_ sk: SynopticStablePlus, in d: SynopticLayout.Diagram,
                            names: [UUID: String]) -> CGPoint? {
        guard let key = currentKey(sk, in: d, names: names), let r = d.plusRect(for: key) else { return nil }
        return CGPoint(x: r.midX, y: r.midY)
    }

    private func plusMoved(_ sk: SynopticStablePlus, _ translation: CGSize) {
        if plusDrag?.key == sk {
            plusDrag?.translation = translation
        } else {
            plusDrag = PlusDrag(key: sk, translation: translation)
        }
    }

    /// The hand lets go of a '+': what the gesture asked for, on the graph AS IT IS NOW (rebuilt since the
    /// press, perhaps — the stable name finds the same '+' again).
    private func plusReleased(_ sk: SynopticStablePlus, _ translation: CGSize) {
        plusDrag = nil
        let d = currentDiagram
        let names = SynopticPlusPresentation.seriesNames(of: root)
        guard let key = currentKey(sk, in: d, names: names) else { return }
        perform(SynopticPlusPresentation.available(d.command(for: key, translation: translation, map: plusMap),
                                                   availability))
    }

    /// The command of a '+' carried out through `SynopticActions` (@see SynopticPlusCommand for the table).
    private func perform(_ command: SynopticPlusCommand) {
        switch command {
        case .none:
            break
        case .openBrowser(let key):
            switch key {
            case .series(let s, let i):     actions.onInsertSeries(s, i)
            case .sendChain(let aux, let i): actions.onSendPluginAdd?(aux, i)
            case .postFader:                actions.presentSendMenu(slot: .postFader)
            }
        case .insertGainStage(let key, let face):
            let result: PlusGestureResult = face == .gain ? .gain : .gainPanMute
            switch key {
            case .series(let s, let i):     actions.onPlusGesture?(s, i, result)
            case .sendChain(let aux, let i): actions.onSendPlusGesture?(aux, i, result)
            case .postFader:                break
            }
        case .branch(let key):
            if case .series(let s, let i) = key { actions.onBranch?(.plus(seriesID: s, index: i)) }
        case .send(let slot):
            actions.presentSendMenu(slot: slot)
        case .insertPlugin(let key, let ref):
            switch key {
            case .series(let s, let i):      actions.onPlusInsertPlugin?(s, i, ref)
            case .sendChain(let aux, let i): actions.onSendPlusInsertPlugin?(aux, i, ref)
            case .postFader:                 break
            }
        case .openBrowserInCategory(let key, let category):
            actions.onOpenBrowserInCategory?(key, category)
        }
    }

    /// The diagram of the current values: what `body` lays, and what a release is resolved against.
    private var currentDiagram: SynopticLayout.Diagram {
        SynopticLayout.diagram(for: root,
                               midi: isMIDI, audioFile: audioFile != nil,
                               araCardWidth: audioFile?.ara.map { SynopticLayout.araCardWidth(name: $0.name) }, mix: mix != nil,
                               stems: stems != nil || groupRouting != nil,
                               sends: sends, sendsEnabled: canSend, receivedRows: receivedSends.count,
                               infiniteOption: infinite != nil,
                               // The frame is an OBJECT's (D7): a host with a mixer — never a stem / the Main.
                               objectFrame: mix != nil,
                               // The session's fold of the clip options (§B.7, folded by default).
                               clipOptionsExpanded: SynopticUIState.shared.clipOptionsExpanded)
    }

    /// A '+''s tooltip: the click alone, and where the channels are chosen (request of 20 October 2026: the
    /// list of every drag direction hid the chain). The drags themselves are unchanged.
    private var plusHelp: String {
        L("synoptic.plus.help.click") + "\n" + L("synoptic.plus.help.rightClick")
    }

    /// The post-fader '+''s tooltip: a click, or a drag in the direction (and at the level) the map gives the
    /// send, if any.
    private var postFaderHelp: String {
        guard let s = plusMap.slot(of: .send) else { return L("synoptic.plus.postFader.help.click") }
        let label = PlusShortcutText.directionLabel(s.direction)
        return s.level == .far ? L("synoptic.plus.postFader.help.far", label) : L("synoptic.plus.postFader.help", label)
    }

    /// Where the marquee may not start: what has a gesture of its own there.
    private func marqueeBlockers(_ d: SynopticLayout.Diagram) -> [CGRect] {
        var r = d.placement.fxBlocks.map(\.headerRect)
        r += d.sendCards.map(\.frame)
        r += d.placement.inserts.map(\.plusRect)
        if let p = d.postFaderPlus { r.append(p.plusRect) }
        r += d.sendCards.map { SendWire.handleRect(of: $0, rank: SendWire.rank(of: $0, in: d.sendCards)) }
        return r
    }

    /// A plugin card of the chain. A GAIN STAGE (§B.4) is laid by the same view (its face is the card's,
    /// @see SynopticPlugin.gainStage) but has no editor to open, and no bypass (D2).
    @ViewBuilder
    private func pluginCard(_ c: SynopticLayout.CardPlacement, cards: [SynopticLayout.CardPlacement]) -> some View {
        let isStage = c.plugin.gainStage != nil
        SynopticCardView(
            plugin: c.plugin,
            isSelected: selection.contains(c.plugin.id),
            onSelect: { clickCard(c.plugin.id, cards: cards) },
            onOpenEditor: isStage ? nil : actions.onOpenEditor.map { _ in { openEditorFromCard(c.plugin.id) } },
            onToggleBypass: { if !isStage { actions.onToggleBypass(c.plugin.id) } },
            onRemove: { actions.onRemove(c.plugin.id) },
            dragProvider: actions.dragProvider.map { f in { f(c.plugin.id) } },
            dragCount: selection.contains(c.plugin.id) ? selection.count : 1,
            dropOutcome: { actions.dropOutcome?(.beforeCard(c.plugin.id), $0) },
            onDropPlugin: actions.onDrop.map { f in { payload, flags in f(.beforeCard(c.plugin.id), payload, flags) } },
            onDropSend: actions.onSendDrop.map { f in { payload in f(.place(.beforeCard(c.plugin.id)), payload) } },
            onUnlink: actions.onUnlink.map { f in { f(c.plugin.id) } },
            onRelink: actions.onRelink.map { f in { f(c.plugin.id) } },
            linkSiblingCount: actions.linkSiblingCount?(c.plugin.id) ?? 0,
            sidechainBadge: isStage ? nil : actions.sidechainBadge?(c.plugin.id),
            // A gain stage's faces read and write their values through the bound view (@see
            // SynopticGainStageControls); a plugin card ignores it.
            actions: actions
        )
    }

    /// The "Channels" submenu of a card: the three variants, the current one ticked, the ones this plugin
    /// cannot take (or any, while playback runs) greyed. A hint says why, or that the change reaches the
    /// plugin's linked instances too.
    @ViewBuilder
    private func channelsMenu(_ m: ChannelMenuState, plugin id: UUID) -> some View {
        Menu(L("synoptic.menu.channels")) {
            ForEach(m.entries, id: \.variant) { e in
                Button {
                    actions.onSetChannelVariant?(id, e.variant)
                } label: {
                    if e.isCurrent {
                        Label(Self.variantTitle(e.variant), systemImage: "checkmark")
                    } else {
                        Text(Self.variantTitle(e.variant))
                    }
                }
                .disabled(!e.supported || m.blockedByPlayback)
            }
            if m.blockedByPlayback || m.linkedCount > 0 || !m.exact {
                Divider()
                if m.blockedByPlayback { Text(L("synoptic.menu.channels.playing")) }
                if m.linkedCount > 0 { Text(L("synoptic.menu.channels.linked", m.linkedCount)) }
                if !m.exact { Text(L("synoptic.menu.channels.approximate")) }
            }
        }
    }

    private static func variantTitle(_ v: ChannelVariant) -> String {
        switch v {
        case .mono:       return L("synoptic.menu.channels.mono")
        case .monoStereo: return L("synoptic.menu.channels.monoStereo")
        case .stereo:     return L("synoptic.menu.channels.stereo")
        }
    }

    /// The FX link entries of the right-click menus: make a bin of the plugins in hand, or join one
    /// that exists. Nothing at all (an empty menu is not shown) when neither applies.
    @ViewBuilder
    private func fxLinkMenu(ids: [UUID]) -> some View {
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

    /// The CONTENT pill of a consolidated instance: a violet waveform icon and the definition's name.
    /// Double click = open the content for editing / validate it when it is open.
    private func contentPillView(_ cp: SynopticContentPill, rect: CGRect) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "waveform.circle")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.purple)
            Text(L("synoptic.consolidate.content", cp.name))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 8)
        .frame(width: rect.width, height: rect.height)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.purple.opacity(cp.isOpen ? 0.14 : 0.06))
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor))))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(Color.purple.opacity(cp.isOpen ? 0.7 : 0.35), lineWidth: cp.isOpen ? 1 : 0.5))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture(count: 2) { actions.onToggleContent?() }
        .help(L(cp.isOpen ? "synoptic.consolidate.contentOpen" : "synoptic.consolidate.contentHelp"))
        .position(x: rect.midX, y: rect.midY)
    }

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
            // OPAQUE: the zone straddles the object frame's top edge (§B.5), which must not show through.
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.accentColor.opacity(0.06))
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
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
    private func audioFileZoneView(_ rect: CGRect, file: SynopticAudioFile, folded: Bool) -> some View {
        AudioFileZoneView(rect: rect, file: file, actions: actions, folded: folded)
    }

    // MARK: Canvas drawing (backing areas, cables, split/merge nodes)

    /// Half the distance between the two wires of a stereo signal (wide enough to read two wires, request of
    /// 20 October 2026), and the size of the cross that ends a channel left out.
    private static let wirePairHalfGap: CGFloat = 4.5
    private static let wireCrossHalf: CGFloat = 2.6

    /// What one cable is drawn with: one path per wire, the crosses ending a channel left out, the dots where
    /// two channels are summed, and where its arrowheads go (one per wire arriving).
    private struct WireStrokes {
        var paths: [Path] = []
        var crosses: [CGPoint] = []
        var dots: [CGPoint] = []
        var arrowXs: [CGFloat] = []
    }

    /// The wires of one cable: mono = one, stereo = two side by side. Only a STRAIGHT cable (connector / plain)
    /// changes width along its length — the one that runs into a card or leaves the file always is: the two
    /// wires of a SUM bend together and go on as one (a dot where they meet); a PICK takes one of them on as
    /// one wire while the other stops short with a small cross; a SPLIT parts one wire into two. The change
    /// sits in the middle third of the cable, so the end that reaches a card is already the new width.
    private static func wireStrokes(_ cable: SynopticLayout.Cable, look: WireLook?) -> WireStrokes {
        let a = cable.from, b = cable.to
        let straight = cable.style == .connector || cable.style == .plain
        func line(_ pts: [CGPoint]) -> Path {
            var p = Path()
            p.move(to: pts[0])
            for q in pts.dropFirst() { p.addLine(to: q) }
            return p
        }
        func curve(dx: CGFloat) -> Path {
            var p = Path()
            let f = CGPoint(x: a.x + dx, y: a.y), t = CGPoint(x: b.x + dx, y: b.y)
            p.move(to: f)
            if straight {
                p.addLine(to: t)
            } else {
                // A vertical flow: the fork/merge curve bends vertically (control points on midY).
                let midY = (f.y + t.y) / 2
                p.addCurve(to: t, control1: CGPoint(x: f.x, y: midY), control2: CGPoint(x: t.x, y: midY))
            }
            return p
        }
        let g = wirePairHalfGap
        var out = WireStrokes()
        guard let look else {
            out.paths = [curve(dx: 0)]; out.arrowXs = [b.x]
            return out
        }
        let len = b.y - a.y
        let j0 = a.y + len * 0.3, j1 = a.y + len * 0.65    // the bend starts / the width has changed
        let changes = straight && len > 8
        switch look.shape {
        case .sum where changes:
            for dx in [-g, g] {
                out.paths.append(line([CGPoint(x: a.x + dx, y: a.y), CGPoint(x: a.x + dx, y: j0), CGPoint(x: b.x, y: j1)]))
            }
            out.paths.append(line([CGPoint(x: b.x, y: j1), b]))
            out.dots = [CGPoint(x: b.x, y: j1)]
            out.arrowXs = [b.x]
        case .pick(let keep) where changes:
            let kept: CGFloat = keep == .left ? -g : g
            out.paths.append(line([CGPoint(x: a.x + kept, y: a.y), CGPoint(x: a.x + kept, y: j0),
                                   CGPoint(x: b.x, y: j1), b]))
            let cut = CGPoint(x: a.x - kept, y: j0)
            out.paths.append(line([CGPoint(x: a.x - kept, y: a.y), cut]))
            out.crosses = [cut]
            out.arrowXs = [b.x]
        case .split where changes:
            out.paths.append(line([a, CGPoint(x: a.x, y: j0)]))
            for dx in [-g, g] {
                out.paths.append(line([CGPoint(x: a.x, y: j0), CGPoint(x: b.x + dx, y: j1), CGPoint(x: b.x + dx, y: b.y)]))
            }
            out.dots = [CGPoint(x: a.x, y: j0)]
            out.arrowXs = [b.x - g, b.x + g]
        default:
            if look.count >= 2 {
                out.paths = [curve(dx: -g), curve(dx: g)]
                out.arrowXs = [b.x - g, b.x + g]
            } else {
                out.paths = [curve(dx: 0)]
                out.arrowXs = [b.x]
            }
        }
        return out
    }

    private static func foldLabel(_ f: MonoFold) -> String {
        switch f {
        case .left:  return L("synoptic.wire.fold.left")
        case .right: return L("synoptic.wire.fold.right")
        case .sum:   return L("synoptic.wire.fold.sum")
        }
    }

    private static func sourceChoiceLabel(_ c: SourceChannelChoice) -> String {
        switch c {
        case .both:  return L("synoptic.wire.source.both")
        case .left:  return L("synoptic.wire.fold.left")
        case .right: return L("synoptic.wire.fold.right")
        case .sum:   return L("synoptic.wire.fold.sum")
        }
    }

    /// The wire under the pointer that has a channel menu (the ONE hover tracker reports the point): a wire
    /// merging into a one-input plugin, or the one leaving a stereo audio file — within 9 pt of its axis (the
    /// two wires of a pair are 9 pt apart).
    private func hoveredChannelWire(at p: CGPoint, in d: SynopticLayout.Diagram) -> HoveredWire? {
        guard !widthFlow.isEmpty else { return nil }
        for cable in d.placement.cables {
            guard let look = widthFlow.look(cable.carries) else { continue }
            let f = cable.from, t = cable.to
            let minY = min(f.y, t.y) - 2, maxY = max(f.y, t.y) + 2
            guard p.y >= minY, p.y <= maxY, abs(p.x - (f.x + t.x) / 2) <= 9 else { continue }
            if let c = look.sourceChoice { return .source(current: c) }
            if case .merge(let fold, _)? = look.adaptation, case .into(let node)? = cable.carries,
               let plugin = widthFlow.mergePlugin[node] {
                return .fold(plugin: plugin, current: fold)
            }
        }
        return nil
    }

    private func draw(_ ctx: GraphicsContext, diagram d: SynopticLayout.Diagram) {
        // The object's FRAME (§B.5): its FILL here, UNDER everything; its line is laid ABOVE the head and the
        // mixer (@see objectFrameLine), whose outer outline it is.
        if let f = d.objectFrame {
            let color = frameColor ?? Color.secondary
            let path = Path(roundedRect: SynopticLayout.objectFrameStrokeRect(f),
                            cornerRadius: SynopticLayout.objectFrameCorner)
            ctx.fill(path, with: .color(color.opacity(0.10)))
        }

        for s in d.placement.scopes.sorted(by: { $0.depth < $1.depth }) {
            let path = Path(roundedRect: s.rect, cornerRadius: 14)
            ctx.fill(path, with: .color(Color.gray.opacity(0.06 + Double(s.depth) * 0.05)))
        }

        // A bin's block: its colour round its series (dashed once the host has left the bin). The BODY
        // alone: the header card that straddles its top edge is a view of its own, opaque, laid over it.
        for b in d.placement.fxBlocks {
            let path = Path(roundedRect: b.bodyRect, cornerRadius: SynopticLayout.fxBodyCorner)
            ctx.fill(path, with: .color(b.link.color.opacity(b.link.isEnabled ? 0.16 : 0.06)))
            // OFF = the same frame dimmed as its header is (×0.6), so the two edges meet in one colour.
            let edge = (b.link.isDetached ? 0.6 : 0.95) * (b.link.isEnabled ? 1 : 0.6)
            ctx.stroke(path, with: .color(b.link.color.opacity(edge)),
                       style: StrokeStyle(lineWidth: 1.5, dash: b.link.isDetached ? [4, 3] : []))
        }

        for cable in d.placement.cables {
            let isGhost = cable.style == .ghost
            // Mono = one wire, stereo = two well apart; a sum JOINS the two into one, a channel left out STOPS
            // short with a cross, a mono signal into a stereo input SPLITS — all three in orange. A cable whose
            // width is not known here keeps the single neutral line.
            let look = isGhost ? nil : widthFlow.look(cable.carries)
            let orange = look?.isOrange ?? false
            let color = (orange ? Color.orange : Color.secondary).opacity(isGhost ? 0.4 : (orange ? 0.95 : 0.7))
            let width: CGFloat = isGhost ? 1 : (look == nil ? 1.5 : 1.2)
            let strokes = Self.wireStrokes(cable, look: look)
            let style = StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round, dash: isGhost ? [3, 3] : [])
            for path in strokes.paths { ctx.stroke(path, with: .color(color), style: style) }
            for c in strokes.crosses {
                let h = Self.wireCrossHalf
                var x = Path()
                x.move(to: CGPoint(x: c.x - h, y: c.y - h)); x.addLine(to: CGPoint(x: c.x + h, y: c.y + h))
                x.move(to: CGPoint(x: c.x + h, y: c.y - h)); x.addLine(to: CGPoint(x: c.x - h, y: c.y + h))
                ctx.stroke(x, with: .color(color), style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
            }
            for p in strokes.dots {
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 2, y: p.y - 2, width: 4, height: 4)), with: .color(color))
            }
            if cable.style == .connector || cable.style == .fork {
                // An arrowhead pointing DOWN (the vertical direction of the signal), one per wire arriving: two
                // narrower ones for a stereo pair.
                let pair = strokes.arrowXs.count > 1
                let hw: CGFloat = pair ? 3 : 4, hh: CGFloat = pair ? 5 : 6
                for x in strokes.arrowXs {
                    var head = Path()
                    head.move(to: CGPoint(x: x - hw, y: cable.to.y - hh))
                    head.addLine(to: CGPoint(x: x, y: cable.to.y))
                    head.addLine(to: CGPoint(x: x + hw, y: cable.to.y - hh))
                    ctx.stroke(head, with: .color((orange ? Color.orange : Color.secondary).opacity(orange ? 0.95 : 0.7)),
                               style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                }
            }
        }

        for p in d.placement.dots {
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)),
                     with: .color(Color.secondary.opacity(0.8)))
        }

        // The sends' wires (§B.6): from the tap point on the trunk, out to the LEFT of the frame, down the
        // send's own gutter, in at the column's top and down it — the geometry and the stroke are lot L7's
        // (@see SendWire.draw, asserted by tools/test_synoptic_send_wire.swift). The handle that moves a send
        // is a view laid over this (@see SendTapDotView).
        SendWire.draw(ctx, cards: d.sendCards)
    }
}

// MARK: - A '+' on the wire (§B.2): a click opens the browser, a drag asks for a gain, a branch or a send

/// The '+' itself: an OPAQUE disc laid over the wire. Its gesture is a `DragGesture(minimumDistance: 0)`
/// so that the click (< 6 pt, @see SynopticPlusGesture.isClick) and the drags are ONE gesture, whose
/// meaning is decided at the release by the layout. The view reports, it decides nothing.
private struct SynopticPlusButton: View {
    /// A drag is in flight from this '+'.
    let active: Bool
    let onChanged: (CGSize) -> Void
    let onEnded: (CGSize) -> Void

    var body: some View {
        let tint = active ? Color.accentColor : Color.secondary
        Image(systemName: "plus")
            .font(.system(size: 10, weight: active ? .bold : .regular))
            .foregroundStyle(tint)
            .frame(width: SynopticLayout.plusW, height: SynopticLayout.plusW)
            .background(Circle().fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(Circle().strokeBorder(active ? tint : tint.opacity(0.6),
                                           style: StrokeStyle(lineWidth: 1, dash: active ? [] : [2, 2])))
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { onChanged($0.translation) }
                .onEnded { onEnded($0.translation) })
    }
}

/// What a drag out of a '+' would make if the hand let go here: a dashed line from the '+' to the pointer,
/// and beside the pointer a ghost card naming the result — or "not here" (§B.2). Pure display.
private struct SynopticPlusGhostView: View {
    let from: CGPoint
    let translation: CGSize
    let ghost: SynopticPlusGhost

    private static let labelH: CGFloat = SynopticLayout.cardH - 6

    var body: some View {
        let to = CGPoint(x: from.x + translation.width, y: from.y + translation.height)
        let valid = isValid
        let tint = valid ? Color.accentColor : Color.secondary
        ZStack(alignment: .topLeading) {
            if ghost != .none {
                Path { p in p.move(to: from); p.addLine(to: to) }
                    .stroke(tint.opacity(0.7), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: [3, 3]))
                label(tint: tint, valid: valid)
                    .fixedSize()
                    // Left-aligned on the pointer, a little to its right: the hand never covers it. An
                    // OFFSET (the label's height is fixed), which does not move the stack's own bounds.
                    .offset(x: to.x + 10, y: to.y - Self.labelH / 2)
            }
        }
    }

    /// False when letting go would do nothing: "not here", or a plugin no longer installed.
    private var isValid: Bool {
        switch ghost {
        case .notHere, .pluginMissing: return false
        default:                       return true
        }
    }

    @ViewBuilder
    private func label(tint: Color, valid: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(iconColor ?? (valid ? Color.primary : Color.secondary))
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(valid ? Color.primary : Color.secondary)
        .padding(.horizontal, 8)
        .frame(height: Self.labelH)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor).opacity(0.92)))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .strokeBorder(tint.opacity(valid ? 0.9 : 0.5), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
    }

    /// The zone's icon (@see SynopticPlusPresentation.symbol), "not here" and a missing plugin aside.
    private var symbol: String {
        switch ghost {
        case .gain, .none:             return SynopticPlusPresentation.symbol(for: .gain)
        case .gainPanMute:             return SynopticPlusPresentation.symbol(for: .gainPanMute)
        case .branch:                  return SynopticPlusPresentation.symbol(for: .branch)
        case .send:                    return SynopticPlusPresentation.symbol(for: .send)
        case .plugin:                  return PlusShortcutText.pluginSymbol
        case .category:                return SynopticPlusPresentation.symbol(for: .category(0))
        case .pluginMissing, .notHere: return "nosign"
        }
    }

    /// A category's dot takes its colour.
    private var iconColor: Color? {
        if case .category(let i) = ghost { return ObjekatPalette.pluginCategory(i) }
        return nil
    }

    private var text: String {
        switch ghost {
        case .gain, .none:             return L("synoptic.plus.ghost.gain")
        case .gainPanMute:             return L("synoptic.plus.ghost.gainPanMute")
        case .branch:                  return L("synoptic.plus.ghost.branch")
        case .send:                    return L("synoptic.plus.ghost.send")
        case .plugin(let name):        return name
        case .category:                return L("plusAction.category")
        case .pluginMissing(let name): return L("synoptic.plus.ghost.pluginMissing", name)
        case .notHere:                 return L("synoptic.plus.ghost.notHere")
        }
    }
}

// MARK: - The '+' hover (§B.3): one AppKit tracking area over the whole canvas

/// Reports the pointer's position over the canvas (nil when it leaves), in the canvas's own coordinates,
/// WITHOUT taking a click (`hitTest` → nil). A SwiftUI `.onContinuousHover` on the canvas would go
/// `.ended` as soon as the pointer enters a child view (a card, a zone), which is where the lines of the
/// '+' run between — hence AppKit, as the timeline does (@see HoverTracker).
private struct SynopticHoverTracker: NSViewRepresentable {
    var onHover: (CGPoint?) -> Void

    func makeNSView(context: Context) -> TrackerView {
        let v = TrackerView()
        v.onHover = onHover
        return v
    }

    func updateNSView(_ nsView: TrackerView, context: Context) {
        nsView.onHover = onHover
    }

    final class TrackerView: NSView {
        var onHover: ((CGPoint?) -> Void)?
        private var trackingArea: NSTrackingArea?

        override var isFlipped: Bool { true }   // SwiftUI's coordinates (origin top-left)
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            guard trackingArea == nil else { return }
            let t = NSTrackingArea(rect: bounds,
                                   options: [.activeInActiveApp, .mouseMoved, .mouseEnteredAndExited,
                                             .inVisibleRect],
                                   owner: self, userInfo: nil)
            addTrackingArea(t)
            trackingArea = t
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.acceptsMouseMovedEvents = true
        }

        override func mouseMoved(with event: NSEvent) { onHover?(convert(event.locationInWindow, from: nil)) }
        override func mouseEntered(with event: NSEvent) { onHover?(convert(event.locationInWindow, from: nil)) }
        override func mouseExited(with event: NSEvent) { onHover?(nil) }
    }
}
