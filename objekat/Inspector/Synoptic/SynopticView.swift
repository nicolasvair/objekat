import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

// MARK: - The signal view's actions
//
// The view is 'dumb': it renders a `SynopticNode` and delegates every mutation to
// these closures. They are wired either onto a mock (a local @State, the phase A demo),
// or onto `EditViewModel`/the engine (phase B — step 1: a real series).

struct SynopticActions {
    var onSelect: (UUID) -> Void = { _ in }
    var onOpenEditor: ((UUID) -> Void)? = nil
    var onToggleBypass: (UUID) -> Void = { _ in }
    var onRemove: (UUID) -> Void = { _ in }
    var onInsertSeries: (_ seriesID: UUID, _ index: Int) -> Void = { _, _ in }
    var onBranch: ((UUID) -> Void)? = nil   // nil = parallel branching disabled (not routed)

    // Carried over from the chips (step 1.x):
    var instanceState: ((UUID) -> Int)? = nil       // 0 unknown · 1 loading · 2 ready · 3 error
    var loadError: ((UUID) -> String?)? = nil
    var onDiagnose: ((UUID) -> Void)? = nil
    var onUnlink: ((UUID) -> Void)? = nil
    var onRelink: ((UUID) -> Void)? = nil
    var linkSiblingCount: ((UUID) -> Int)? = nil

    // Dragging a card (towards the timeline = move/copy/link; towards a '+' = reorder).
    var dragProvider: ((UUID) -> NSItemProvider)? = nil
    // A drop on a '+' (or a branch's axis): reorders/moves the plugin into the target series;
    // `copy` (⌥ held) → an independent copy instead of a move.
    var onReorder: ((_ pluginID: UUID, _ seriesID: UUID, _ toIndex: Int, _ copy: Bool) -> Void)? = nil
    // Dropping a plugin ONTO a card (a branch's axis): inserts it into the same branch, just
    // before the target card. `copy` = ⌥ (an independent copy). It allows dropping on the axis
    // and not only on the small '+'.
    var onDropOntoCard: ((_ targetPluginID: UUID, _ draggedPluginID: UUID, _ copy: Bool) -> Void)? = nil

    // The dB gain at the end of a parallel branch (drag ↑/↓).
    var onSetVoiceGain: ((_ blockID: UUID, _ voiceIndex: Int, _ dB: Float) -> Void)? = nil
    // Removing a parallel branch (along with its gain).
    var onRemoveVoice: ((_ blockID: UUID, _ voiceIndex: Int) -> Void)? = nil
    // Muting a parallel branch (listen to one / the other / both; no solo).
    var onSetVoiceMute: ((_ blockID: UUID, _ voiceIndex: Int, _ muted: Bool) -> Void)? = nil
    // The dB gain at the start (isOutput=false) / end (isOutput=true) of the chain.
    var onSetChainGain: ((_ isOutput: Bool, _ dB: Float) -> Void)? = nil
    // The start of a gain drag (a branch or the chain): push an undo point,
    // the same convention as onBeginMixEdit / onBeginSpeedEdit.
    var onBeginGainEdit: (() -> Void)? = nil

    // MIDI zone (a MIDI clip): the instrument at the head of the chain.
    var onAddInstrument: (() -> Void)? = nil           // the '+' of an empty MIDI zone
    var onRemoveInstrument: (() -> Void)? = nil
    var onOpenInstrumentEditor: (() -> Void)? = nil
    var onSelectInstrument: (() -> Void)? = nil
    // Bypassing the instrument — an action separate from `onToggleBypass`: the instrument does
    // not live in the model's FX chain but in `instruments` (@see toggleInstrumentEnabled).
    var onToggleInstrumentBypass: (() -> Void)? = nil

    // The 'audio file' zone (an audio clip): speed / semitones / bpm.
    var onSetSpeed: ((Double) -> Void)? = nil          // the new speed ratio
    var onSetBaseBPM: ((Double?) -> Void)? = nil       // the base bpm (nil = clear)
    var onToggleReverse: (() -> Void)? = nil
    var onToggleLoop: (() -> Void)? = nil
    var onBeginSpeedEdit: (() -> Void)? = nil          // push an undo point before a drag

    /// A parameter control has just been TOUCHED — clicked, taken in a drag, or received from the
    /// keyboard — without necessarily having changed value. That is what names the object's
    /// 'future automation' row (@see SoundObject.pendingAutomationParam): you choose what you are
    /// about to automate by laying a finger on it, not by knocking it off its value first.
    var onTouchParam: ((ParamRef) -> Void)? = nil

    // The 'clip' zone (the output mix): volume / pan / mute.
    var onSetVolume: ((Float) -> Void)? = nil
    var onSetPan: ((Float) -> Void)? = nil
    var onToggleMute: (() -> Void)? = nil
    var onToggleSolo: (() -> Void)? = nil
    var onBeginMixEdit: (() -> Void)? = nil
    /// A double click on the link icon of a mix attribute (a sound object): toggles synced/independent.
    var onToggleAttrSync: ((SynopticMixAttr) -> Void)? = nil

    // The 'stems' zone (output): assigning the stem.
    var onAssignStem: ((UUID) -> Void)? = nil

    // The 'sends' zone (the foot): the level / on-off of a departure towards an aux. `id` = the
    // target aux for a departure, the sending object for a received send (an aux's head).
    var onSetSendLevel: ((UUID, Float) -> Void)? = nil
    var onToggleSend: ((UUID) -> Void)? = nil
    var onBeginSendEdit: (() -> Void)? = nil

    // A bus's chain head: the 'infinite' toggle (a top-level aux / group).
    var onToggleInfinite: (() -> Void)? = nil

    // TRACE — freezing what a plugin does to this signal, so the session travels without it.
    // nil = the actions are not wired (the demo). @see docs/objekat-capture-trace.md
    var onCaptureTrace: ((UUID) -> Void)? = nil
    /// Stops the capture under way. Offered on the card that is showing its progress.
    var onCancelTrace: (() -> Void)? = nil
    /// Plays the slot from its trace, or back from its plugin. Only ever offered where BOTH are
    /// available: with the plugin missing, the trace is not a choice, it is what is left.
    var onSetTraceUse: ((_ pluginID: UUID, _ useTrace: Bool) -> Void)? = nil
    var onClearTrace: ((UUID) -> Void)? = nil
    /// A one-line summary of a slot's trace, for the tooltip on its badge.
    var traceSummary: ((UUID) -> String?)? = nil
    /// The capture under way, if it is this plugin's: 0…1. nil = nothing running on it.
    var traceProgress: ((UUID) -> Double?)? = nil
}

/// The data of the 'audio file' zone (an audio clip), carried over into the signal view.
struct SynopticAudioFile: Equatable {
    var speedRatio: Double
    var baseBPM: Double?
    var isReversed: Bool
    /// True ⇒ the content repeats for as long as the object's window exceeds its source range.
    var isLooping: Bool
}

/// A sound object's mix attribute ('clip' zone) whose synced/independent link can be toggled.
enum SynopticMixAttr { case volume, pan, mute }

/// The synced/independent state of a sound object instance's mix attributes (`true` = synced
/// with the other instances). nil on `SynopticMix.attrLinks` = an unlinked object (no icons).
struct SynopticMixLinks: Equatable {
    var volumeSynced: Bool
    var panSynced: Bool
    var muteSynced: Bool
}

/// What makes an object audible on its own, in ONE state — the two solo layers add up, but a
/// button has only one look: held wins, since that is the one that will outlive the gesture.
enum SynopticSoloState: Equatable {
    case off
    /// The temporary layer ('s' held, or an audition): it clears itself.
    case temporary
    /// The committed layer: held until it is cleared.
    case hold
}

/// The data of the 'clip' zone (the output mix), carried over into the signal view.
struct SynopticMix: Equatable {
    var title: String        // 'clip' / 'group' / 'aux'
    var volumeDb: Float
    var pan: Float
    var isMuted: Bool
    var solo: SynopticSoloState = .off
    /// Volume / pan driven by an automation CURVE (their static setting is neutralised).
    var volumeAutomated: Bool = false
    var panAutomated: Bool = false
    /// Non-nil ⇒ a sound object instance: it shows the per-attribute link icons.
    var attrLinks: SynopticMixLinks? = nil
}

/// A stem badge ('stems' zone) carried over into the signal view.
struct SynopticStem: Identifiable, Equatable {
    let id: UUID
    let name: String
    let color: Color
    let isCurrent: Bool
}

/// One send row in the signal view. At the foot of an object = a departure towards an aux
/// (`id` = the aux); at the head of an aux = a received send (`id` = the sending object).
struct SynopticSend: Identifiable, Equatable {
    let id: UUID
    let name: String
    /// The user's intent (the toggle) — independent of the level, which may stay at -∞.
    let enabled: Bool
    let levelDb: Float
    /// An automation CURVE drives this level: the static setting is no longer heard.
    var isAutomated: Bool = false
}

/// A bus's 'infinite' option (a top-level aux / group), carried by the chain's head.
struct SynopticInfinite: Equatable {
    let isOn: Bool
    /// 'aux' / 'group' — used in the tooltip.
    let kindLabel: String
}

/// A group's 'loop' option (the chain head, @see BusHeadZoneView) or a MIDI clip's (the MIDI
/// zone, @see midiZoneView). Non-nil ⇔ `SoundObject.canLoop` — audio has its own badge in
/// `AudioFileZoneView` (@see [[loop-item-plan]]).
struct SynopticLoop: Equatable {
    let isOn: Bool
}

/// The output of a group's CHILD: routed to its parent group (no direct stem assignment —
/// the stem is carried by the group; routing a child to a stem while staying inside the group
/// = the 'edit group' case, planned for later). It replaces the 'stems' zone.
struct SynopticGroupRouting: Equatable {
    let groupName: String
    /// The colour of the effective stem (the root group's) — a visual hint of the final bus.
    let stemColor: Color
}

extension View {
    /// Greys out and neutralises a STATIC setting an automation curve has taken over.
    ///
    /// A decision from the automation work: no offset, no composition — as soon as a parameter
    /// carries a point, the curve is what counts and the static setting is no longer heard. A
    /// control that still answered the gesture without changing the sound would look like a
    /// fault: we grey it out, like the FX of a closed sound object just above.
    @ViewBuilder
    func automationLocked(_ locked: Bool) -> some View {
        if locked {
            self.disabled(true)
                .opacity(0.4)
                .help(L("synoptic.lockedByAutomation"))
        } else {
            self
        }
    }

    /// A conditional tooltip: `nil` or empty ⇒ NO `.help` is applied at all.
    ///
    /// To be used whenever a tooltip is only worth having in one case. A tooltip laid on an
    /// ancestor overrides those of its descendants — an EMPTY tooltip included: `.help("")`
    /// 'to say nothing' does not let the children speak, it gags them. That is what deprived
    /// the signal view's plugin cards (bypass, name, link, ✕) and the inspector's Speed /
    /// Semitones boxes of a tooltip for months. Applying nothing is the only way to say
    /// nothing.
    @ViewBuilder
    func helpIf(_ text: String?) -> some View {
        if let text, !text.isEmpty { self.help(text) } else { self }
    }

    /// Greys out and neutralises the FX of a CLOSED sound object, saying why they do not answer.
    func fxReadOnlyLocked(_ readOnly: Bool) -> some View {
        disabled(readOnly)
            .opacity(readOnly ? 0.45 : 1)
            .helpIf(readOnly ? L("synoptic.openToEdit") : nil)
    }

    /// Applies `.onDrag` only if a provider is supplied (otherwise it leaves the view untouched).
    @ViewBuilder
    func onDragIf(_ provider: (() -> NSItemProvider)?) -> some View {
        if let provider { self.onDrag(provider) } else { self }
    }
}

// MARK: - Signal view (pure rendering)

struct SynopticView: View {
    let root: SynopticNode
    @Binding var selectedID: UUID?
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
    /// Departures towards the reachable auxes, listed at the foot (the 'sends' zone). Empty = no zone.
    var sends: [SynopticSend] = []
    /// An aux: the sends it RECEIVES, listed at the head of the chain (the signal comes in there). Empty = no list.
    var receivedSends: [SynopticSend] = []
    /// Non-nil ⇒ the chain's head carries the 'infinite' checkbox (a top-level aux / group).
    var infinite: SynopticInfinite? = nil
    /// Non-nil ⇒ looping is available: a group (the chain head) or a MIDI clip (the MIDI zone).
    /// Audio has its own badge in `audioFile` (@see [[loop-item-plan]]).
    var loop: SynopticLoop? = nil
    /// True = a sound object shown CLOSED: the FX (cards, '+' inserts, parallel branches, branch
    /// and chain gains) are visible but greyed out and disabled, with an 'Open to edit' tooltip.
    /// The source, the mix and the stems stay interactive. Fully interactive as soon as the object
    /// is opened for editing (double click). See SynopticBoundView.
    var fxReadOnly: Bool = false
    var actions = SynopticActions()

    var body: some View {
        let d = SynopticLayout.diagram(for: root, chainInDb: chainInDb, chainOutDb: chainOutDb,
                                       midi: isMIDI, audioFile: audioFile != nil, mix: mix != nil,
                                       mixWide: mix?.attrLinks != nil,
                                       stems: stems != nil || groupRouting != nil,
                                       sendRows: sends.count, receivedRows: receivedSends.count,
                                       infiniteOption: infinite != nil)
        Group {
            if scrolls {
                ScrollView([.horizontal, .vertical]) { canvas(d).padding(20) }
            } else {
                canvas(d).padding(8)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { selectedID = nil }   // a click in empty space → deselect
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
            if let cz = d.clipZone, let m = mix {
                ClipMixZoneView(rect: cz, mix: m, actions: actions)
            }
            if let sz = d.sendsZone {
                SendsZoneView(rect: sz, sends: sends, actions: actions)
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
            // closed sound object (`fxReadOnly`), fully interactive otherwise. Source / mix / stems are
            // NOT in this group (they always stay active).
            Group {
            // 'Cable' drop zones: rendered FIRST (hence under the cards) so that dropping a plugin on a
            // branch's axis inserts it there — even an empty parallel branch. A hovered card keeps
            // priority (inserting just before it) since it is drawn on top.
            if let onReorder = actions.onReorder {
                ForEach(d.placement.cableDrops) { z in
                    CableDropView(rect: z.rect, previewFrame: z.previewFrame) { dragged, copy in
                        onReorder(dragged, z.seriesID, z.insertIndex, copy)
                    }
                }
            }

            ForEach(d.placement.cards) { c in
                SynopticCardView(
                    plugin: c.plugin,
                    isSelected: selectedID == c.plugin.id,
                    onSelect: { actions.onSelect(c.plugin.id) },
                    onOpenEditor: actions.onOpenEditor.map { f in { f(c.plugin.id) } },
                    onToggleBypass: { actions.onToggleBypass(c.plugin.id) },
                    onRemove: { actions.onRemove(c.plugin.id) },
                    dragProvider: actions.dragProvider.map { f in { f(c.plugin.id) } },
                    onDropPlugin: actions.onDropOntoCard.map { f in { dragged, copy in f(c.plugin.id, dragged, copy) } },
                    onUnlink: actions.onUnlink.map { f in { f(c.plugin.id) } },
                    onRelink: actions.onRelink.map { f in { f(c.plugin.id) } },
                    linkSiblingCount: actions.linkSiblingCount?(c.plugin.id) ?? 0,
                    onCaptureTrace: actions.onCaptureTrace.map { f in { f(c.plugin.id) } },
                    onCancelTrace: actions.onCancelTrace,
                    onSetTraceUse: actions.onSetTraceUse.map { f in { use in f(c.plugin.id, use) } },
                    onClearTrace: actions.onClearTrace.map { f in { f(c.plugin.id) } },
                    traceSummary: actions.traceSummary?(c.plugin.id),
                    traceProgress: actions.traceProgress?(c.plugin.id),
                    // 'Missing' says the plugin cannot be gone back to — which is exactly the
                    // state a trace exists for. The instance state (3 = error) is what the card
                    // already uses to say a plugin did not load.
                    pluginIsMissing: (actions.instanceState?(c.plugin.id) ?? 0) == 3
                )
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
        }
        .frame(width: d.canvasSize.width, height: d.canvasSize.height, alignment: .topLeading)
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
                        isSelected: selectedID == inst.id,
                        onSelect: { actions.onSelectInstrument?() },
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
                        linkSiblingCount: actions.linkSiblingCount?(inst.id) ?? 0
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

        for cable in d.placement.cables {
            var path = Path()
            path.move(to: cable.from)
            if cable.style == .connector {
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
    }
}

// MARK: - Plugin card

struct SynopticCardView: View {
    let plugin: SynopticPlugin
    let isSelected: Bool
    let onSelect: () -> Void
    var onOpenEditor: (() -> Void)? = nil
    let onToggleBypass: () -> Void
    let onRemove: () -> Void
    var dragProvider: (() -> NSItemProvider)? = nil
    /// Dropping ANOTHER plugin on this card (the branch's axis): `(draggedPluginID, copy)`.
    /// `copy` = ⌥ held. nil = the card does not receive (the demo).
    var onDropPlugin: ((_ draggedPluginID: UUID, _ copy: Bool) -> Void)? = nil
    /// Unlinks this instance from its group (nil = the card cannot be driven, e.g. the demo).
    var onUnlink: (() -> Void)? = nil
    var onRelink: (() -> Void)? = nil
    /// The number of linked instances (for the tooltip). 0 if unlinked.
    var linkSiblingCount: Int = 0

    // TRACE. nil closures = the card cannot be driven (the demo): no menu entry is offered.
    var onCaptureTrace: (() -> Void)? = nil
    var onCancelTrace: (() -> Void)? = nil
    var onSetTraceUse: ((Bool) -> Void)? = nil
    var onClearTrace: (() -> Void)? = nil
    /// A one-line summary of the trace, for the badge's tooltip.
    var traceSummary: String? = nil
    /// A capture running ON THIS PLUGIN: 0…1. nil = none.
    var traceProgress: Double? = nil
    /// True when the plugin is not installed here — the case the trace exists for. It changes
    /// what the menu may offer: with no plugin there is nothing to switch back to.
    var pluginIsMissing: Bool = false

    @State private var dropTargeted = false

    private let cardW = SynopticLayout.cardW
    private let cardH = SynopticLayout.cardH

    private let toggleW: CGFloat = 26

    private var linkHelp: String {
        // `linkSiblings` already excludes the plugin itself: that count IS the others'.
        let others = linkSiblingCount
        if plugin.isLinked {
            return others > 0
                ? L("synoptic.link.linkedWithOthers", others)
                : L("synoptic.link.linked")
        }
        return others > 0
            ? L("synoptic.link.unlinkedWithOthers", others)
            : L("synoptic.link.unlinked")
    }

    var body: some View {
        HStack(spacing: 0) {
            // on/off — a REAL button, full height, square edges (the identity colour = active)
            Button(action: onToggleBypass) {
                ZStack {
                    Rectangle()
                        .fill(plugin.isEnabled ? plugin.color : Color.secondary.opacity(0.18))
                    Image(systemName: "power")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(plugin.isEnabled ? .white : .secondary)
                }
                .frame(width: toggleW)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("synoptic.bypass"))

            // Content: NAME (the drag area) · ✕  +  a thin VU meter
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    // NAME — the ONLY drag area (reorder / move) plus a double click for the editor
                    Text(plugin.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(plugin.isEnabled ? .primary : .secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { (onOpenEditor ?? onSelect)() }
                        .onDragIf(dragProvider)
                        .help(L("synoptic.openPlugin"))

                    // 🔗 — the link toggle. Linked: a solid badge, tinted by the group's colour.
                    // DETACHED: the badge REMAINS, hollow and in the same tint — the group left is
                    // therefore recognisable by eye, and a click takes it back (@see relinkPlugin).
                    if plugin.isLinked || plugin.isLinkDetached {
                        Button(action: { plugin.isLinked ? onUnlink?() : onRelink?() }) {
                            Image(systemName: "link")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(plugin.isLinked ? .white : plugin.color.opacity(0.8))
                                .padding(3)
                                .background {
                                    if plugin.isLinked {
                                        Circle().fill(plugin.color)
                                    } else {
                                        Circle().strokeBorder(plugin.color.opacity(0.55), lineWidth: 1.5)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .help(linkHelp)
                    }

                    // TRACE — the badge. Present as soon as a trace exists; FILLED when the
                    // chain is actually playing it, hollow when the plugin is still what is
                    // heard. The distinction is the whole point: a captured trace changes
                    // nothing until it is in use, and a slot that plays a recording of a plugin
                    // instead of the plugin must never look like an ordinary slot.
                    if let health = plugin.traceHealth {
                        Image(systemName: Self.traceIcon(health))
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(plugin.traceInUse ? .white : Self.traceTint(health))
                            .padding(3)
                            .background {
                                if plugin.traceInUse { Circle().fill(Self.traceTint(health)) }
                                else { Circle().strokeBorder(Self.traceTint(health).opacity(0.55), lineWidth: 1.5) }
                            }
                            .helpIf(traceSummary)
                    }

                    // ✕ — remove the fx (always visible)
                    Button(action: onRemove) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(L("synoptic.removePlugin"))
                }

                Spacer(minLength: 0)

                // VU meter: a very thin horizontal line, right at the bottom
                Capsule()
                    .fill(Color.secondary.opacity(0.2))
                    .frame(height: 2)
                    .overlay(alignment: .leading) {
                        GeometryReader { g in
                            Capsule().fill(Color.green)
                                .frame(width: max(0, g.size.width * plugin.vu))
                        }
                    }
            }
            .padding(.horizontal, 8)
            .padding(.top, 5)
            .padding(.bottom, 4)
        }
        .frame(width: cardW, height: cardH, alignment: .topLeading)
        .background(isSelected ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        // The halo = the instance's identity colour, always visible (not only when linked): it is
        // what allows finding an open plugin's card at a glance. Linked → a thicker line plus a glow,
        // so as to tell 'this group moves together' from plain identity.
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isSelected ? Color.accentColor : plugin.color.opacity(plugin.isLinked ? 1 : 0.7),
                              lineWidth: isSelected ? 2 : (plugin.isLinked ? 2 : 1))
        )
        .shadow(color: plugin.isLinked ? plugin.color.opacity(0.6) : .clear,
                radius: plugin.isLinked ? 5 : 0)
        .opacity(plugin.isEnabled ? 1 : 0.5)
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture { onSelect() }
        // Highlighted when a plugin card hovers this card (the axis accepts the drop).
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.accentColor, lineWidth: dropTargeted ? 2 : 0)
        )
        // Dropping a plugin ONTO the card (a branch's axis): reorders/moves/copies into this
        // branch, without having to aim at the small '+'. ⌥ = a copy.
        //
        // The `.onDrop` is laid on a `.background` layer (a SIBLING layer, behind the content) and
        // NOT on the card itself: the card is the ANCESTOR of the `Text` carrying the `.onDrag`, and
        // macOS does not deliver a drop to an ancestor of a drag source — which is why the '+'
        // (with no descendant source) received drops but the axis did not. The background steals no
        // click from the buttons (bypass / ✕ / link), which stay above it.
        .background(dropLayer)
        // A capture running on THIS plugin: a thin progress line laid across the foot of the
        // card. Two or three offline renders are long enough that saying nothing would read as
        // a freeze, and short enough that a modal would be in the way.
        .overlay(alignment: .bottom) {
            if let progress = traceProgress {
                GeometryReader { g in
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: max(0, g.size.width * progress), height: 3)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
                .allowsHitTesting(false)
            }
        }
        .contextMenu { traceMenu }
    }

    // MARK: - The trace menu
    //
    // Capturing a trace is a right-click on the plugin and nothing else: it is a rare, deliberate
    // act — minutes of render for one slot — and it has no business taking room on a card that
    // already carries four controls. @see docs/objekat-capture-trace.md

    @ViewBuilder private var traceMenu: some View {
        // A capture is two or three offline renders: minutes, on a session with a heavy AU. It
        // has to be possible to change one's mind, and the place to do it is where it was
        // started — the same menu, on the same card that shows the progress.
        if traceProgress != nil, let onCancelTrace {
            Button(L("trace.menu.cancel"), action: onCancelTrace)
        } else if let onCaptureTrace {
            Button(plugin.traceHealth == nil ? L("trace.menu.capture") : L("trace.menu.recapture"),
                   action: onCaptureTrace)
        }

        if plugin.traceHealth != nil {
            // Switching to the trace is only a CHOICE where the plugin is installed. With the
            // plugin missing, the trace is not one option among two — it is what is left, and
            // offering to "go back to the plugin" would offer silence.
            if let onSetTraceUse, !pluginIsMissing {
                Button(plugin.traceInUse ? L("trace.menu.usePlugin") : L("trace.menu.useTrace")) {
                    onSetTraceUse(!plugin.traceInUse)
                }
            }
            if let onClearTrace {
                Divider()
                Button(L("trace.menu.clear"), action: onClearTrace)
            }
        }
    }

    /// The badge's icon: what the trace is worth, at a glance and without a tooltip.
    static func traceIcon(_ health: PluginTraceHealth) -> String {
        switch health {
        case .exact, .acceptable: return "waveform.badge.checkmark"
        case .frozen:             return "snowflake"
        case .stale:              return "exclamationmark.triangle.fill"
        case .problem:            return "waveform.badge.exclamationmark"
        }
    }

    /// And its colour. `stale` and `problem` are warnings and read as warnings; `frozen` is not
    /// a fault but a change of behaviour, so it gets its own tint rather than a red one.
    static func traceTint(_ health: PluginTraceHealth) -> Color {
        switch health {
        case .exact:      return .green
        case .acceptable: return .teal
        case .frozen:     return .cyan
        case .problem:    return .orange
        case .stale:      return .orange
        }
    }

    @ViewBuilder private var dropLayer: some View {
        if let onDropPlugin {
            Color.clear
                .contentShape(Rectangle())
                .onDrop(of: [.plainText],
                        delegate: PluginDropDelegate(isTargeted: $dropTargeted,
                                                     onDrop: onDropPlugin))
        }
    }
}

/// A drop target covering the CABLE of a branch/series (a band rendered UNDER the cards):
/// dropping a plugin on the axis inserts it into that branch — an EMPTY parallel branch
/// included. A discreet highlight on hover. `onDrop` closes over the zone's (seriesID, insertIndex).
struct CableDropView: View {
    let rect: CGRect          // the DETECTION zone (wide, transparent)
    let previewFrame: CGRect  // the PREVIEW shown on hover (card-sized, on the cable)
    let onDrop: (_ draggedPluginID: UUID, _ copy: Bool) -> Void
    @State private var targeted = false

    var body: some View {
        // The target covers the whole `rect` (easy to aim at) but stays invisible; only a
        // card-sized rectangle, laid on the cable at `previewFrame`, lights up on hover —
        // a preview of exactly where the plugin will land.
        Color.clear
            .frame(width: rect.width, height: rect.height)
            .contentShape(Rectangle())
            .onDrop(of: [.plainText],
                    delegate: PluginDropDelegate(isTargeted: $targeted, onDrop: onDrop))
            .overlay(alignment: .topLeading) {
                if targeted {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.accentColor.opacity(0.12))
                        .overlay(RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.accentColor, lineWidth: 2))
                        .frame(width: previewFrame.width, height: previewFrame.height)
                        .offset(x: previewFrame.minX - rect.minX,
                                y: previewFrame.minY - rect.minY)
                }
            }
            .position(x: rect.midX, y: rect.midY)
    }
}

/// Reliable delivery of a plugin drop (on a card's axis OR on a branch's cable). We go through
/// a `DropDelegate` — for the card, laid on a `.background` layer, because an `.onDrop` laid on
/// an ANCESTOR of an `.onDrag` view is not delivered by macOS. `dropUpdated` returns the
/// .copy/.move operation depending on ⌥ so as to show the right cursor; the copy is reread at the drop.
private struct PluginDropDelegate: DropDelegate {
    let isTargeted: Binding<Bool>
    let onDrop: (_ draggedPluginID: UUID, _ copy: Bool) -> Void

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.plainText]) }
    func dropEntered(info: DropInfo) { isTargeted.wrappedValue = true }
    func dropExited(info: DropInfo)  { isTargeted.wrappedValue = false }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: NSEvent.modifierFlags.contains(.option) ? .copy : .move)
    }
    func performDrop(info: DropInfo) -> Bool {
        isTargeted.wrappedValue = false
        guard let p = info.itemProviders(for: [.plainText]).first else { return false }
        let copy = NSEvent.modifierFlags.contains(.option)
        p.loadDataRepresentation(forTypeIdentifier: UTType.plainText.identifier) { data, _ in
            guard let data,
                  let payload = try? JSONDecoder().decode(PluginDragPayload.self, from: data)
            else { return }
            DispatchQueue.main.async { onDrop(payload.pluginID, copy) }
        }
        return true
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

// MARK: - dB gain control (a parallel branch, or the start/end of the chain)

/// A small dB readout: dragging ↑/↓ adjusts in 1 dB steps (without recompiling), double click = 0 dB.
struct GainDbControl: View {
    let dB: Float
    var minDb: Float = -24
    var maxDb: Float = 12
    var unit: String = "dB"              // the unit shown next to the value
    var muted: Bool? = nil               // nil = no mute button (parallel branches)
    var onToggleMute: (() -> Void)? = nil
    var onTouch: (() -> Void)? = nil     // called on TOUCH (click/drag/keyboard), before any change
    var onBegin: (() -> Void)? = nil     // called at the start of a drag (to push an undo point, say)
    let onChange: (Float) -> Void

    private var label: String { dB == 0 ? "0 \(unit)" : String(format: "%+.0f \(unit)", dB) }
    private var isMuted: Bool { muted == true }

    var body: some View {
        HStack(spacing: 3) {
            // Mute — on chain gains only, to the left of the value.
            if let muted, let onToggleMute {
                Button(action: onToggleMute) {
                    Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(muted ? Color.red : Color.secondary)
                        .frame(width: 16, height: 16)
                        .background(RoundedRectangle(cornerRadius: 4)
                            .fill(muted ? Color.red.opacity(0.18) : Color.secondary.opacity(0.18)))
                        .overlay(RoundedRectangle(cornerRadius: 4)
                            .strokeBorder((muted ? Color.red : Color.secondary).opacity(0.45)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L("common.mute"))
            }
            gainReadout
        }
    }

    private var gainReadout: some View {
        // Reuses the value box (drag ↑/↓, click plus arrows, Delete = 0, direct typing).
        DragValueBox(value: Double(dB),
                     format: { _ in label },           // a signed label with its unit
                     range: Double(minDb)...Double(maxDb),
                     pointsPerStep: 6, snap: true, width: 46,
                     keyStep: 1,
                     help: L("help.drag.volume"),
                     onTouch: onTouch,
                     onBegin: onBegin,
                     onChange: { onChange(Float($0)) },
                     onReset: { onBegin?(); onChange(0) })   // the reset (double click/Delete) is undoable too
            .opacity(isMuted ? 0.5 : 1)
    }
}

// MARK: - Draggable value box ('gain' style: a value plus a unit, drag ↑/↓)

/// A small box showing a formatted value. Editing:
///  · dragging ↑/↓ adjusts (a step of 1 by default, ⌘ = fine adjustment);
///  · a click then the ↑/↓ arrows = a `keyStep` step, Delete = reset;
///  · a click then a digit = typing the value directly (Return commits, Esc cancels);
///  · a double click = reset.
/// Reused for speed / semitones / bpm / pan / gains.
struct DragValueBox: View {
    let value: Double
    let format: (Double) -> String
    var range: ClosedRange<Double>
    var pointsPerStep: CGFloat = 6
    /// true = rounds to the whole step (⌘ = fine); false = continuous (no snapping).
    var snap: Bool = true
    var width: CGFloat = 56
    /// Not applied to the keyboard's ↑/↓ arrows.
    var keyStep: Double = 1
    /// Reads a direct keyboard entry (nil = refuse). By default: a plain number.
    var parse: (String) -> Double? = { Double($0.replacingOccurrences(of: ",", with: ".")) }
    var help: String = ""
    /// TOUCHING the control: a click, the start of a drag, or a keystroke — before any change,
    /// and even if there is none. Distinct from `onBegin`, which pushes an undo point and must
    /// therefore only run when a value really is about to change.
    var onTouch: (() -> Void)? = nil
    var onBegin: (() -> Void)? = nil
    var onChange: (Double) -> Void
    var onReset: (() -> Void)? = nil

    @State private var start: Double? = nil
    @State private var typing: String? = nil   // non-nil = direct keyboard entry under way
    @FocusState private var focused: Bool       // the container (display mode: drag / arrows / digit)
    @FocusState private var fieldFocused: Bool  // the TextField (typing mode)

    private var isFocused: Bool { focused || fieldFocused }

    private func clamp(_ v: Double) -> Double { min(max(v, range.lowerBound), range.upperBound) }

    private func bump(_ delta: Double) { onTouch?(); onBegin?(); onChange(clamp(value + delta)) }

    /// Takes keyboard focus for THIS box. The crux of the 'digit → Search field' bug:
    /// a search/filter field ('Search…' / 'Filter…') can keep AppKit's FIRST RESPONDER while
    /// SwiftUI has given this box no more than visual focus. The global keyboard monitor
    /// (TimelineKeyHandler) bails as soon as the first responder is an `NSTextView` → the digit
    /// typed goes into that field instead of starting the entry here. So we take the first
    /// responder away from it (window → the SwiftUI hosting view) so that the keystroke reaches
    private func grabKeyFocus() {
        // `onKeyPress`.
        // A COMPULSORY passage for a plain click as for the start of a drag: so it is here, and
        onTouch?()
        focused = true
        if let win = NSApp.keyWindow, let fr = win.firstResponder,
           (fr is NSTextView || fr is NSTextField), fieldFocused == false {
            NSLog(" only once, that 'this control has just been touched' is reported.", String(describing: type(of: fr)))
            win.makeFirstResponder(nil)
        }
    }

    private func commitTyping() {
        if let t = typing, let v = parse(t.trimmingCharacters(in: .whitespaces)) {
            onBegin?(); onChange(clamp(v))
            NSLog("[MIXFOCUS] commitTyping: value '%@' applied", t)
        }
        typing = nil
        // Giving focus back to the container MUST be deferred: done synchronously, it races with the
        // TextField being torn down (having just resigned) → the first responder shoots off to the
        // window/nowhere and the ↑/↓ arrows stop working until the view is rebuilt. One runloop hop
        // lets the TextField unmount first, then we refocus the container (drag/arrow mode).
        DispatchQueue.main.async { focused = true }
    }

    private func cancelTyping() {
        typing = nil
        DispatchQueue.main.async { focused = true }
    }

    var body: some View {
        Group {
            if typing != nil {
                TextField(noLabel, text: Binding(get: { typing ?? "" }, set: { typing = $0 }))
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.center)
                    .focused($fieldFocused)
                    .onSubmit { commitTyping() }
                    .onExitCommand { cancelTyping() }
            } else {
                Text(format(value))
            }
        }
        .font(.system(size: 10, weight: .medium)).monospacedDigit()
        .foregroundStyle(.primary)
        .frame(width: width, height: 18)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.18)))
        .overlay(RoundedRectangle(cornerRadius: 4)
            .strokeBorder((isFocused ? Color.accentColor : Color.secondary).opacity(isFocused ? 0.9 : 0.45),
                          lineWidth: isFocused ? 1.5 : 1))
        .contentShape(Rectangle())
        // Always focusable (even while typing): otherwise, the instant `typing` becomes non-nil, the
        // box would lose focus and — the TextField only being focused on the next runloop — the first
        // responder would shoot off to the 'Search…' field. By staying focusable, the container holds
        // the focus until the TextField takes it back.
        .focusable()
        .focused($focused)
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { v in
                    if start == nil { start = value; onBegin?(); grabKeyFocus() }
                    let s = start ?? value
                    let fine = NSEvent.modifierFlags.contains(.command)
                    let raw = s - Double(v.translation.height) / Double(pointsPerStep)
                    let val = (snap && !fine) ? raw.rounded() : raw
                    onChange(clamp(val))
                }
                .onEnded { _ in start = nil }
        )
        .onTapGesture(count: 2) { onReset?() }
        .onTapGesture { grabKeyFocus() }
        .onKeyPress(phases: .down) { press in
            guard typing == nil else { return .ignored }   // typing under way → leave it to the TextField
            switch press.key {
            case .upArrow:   bump(keyStep);  return .handled
            case .downArrow: bump(-keyStep); return .handled
            case .delete, .deleteForward: onReset?(); return .handled
            default:
                guard let ch = press.characters.first,
                      ch.isNumber || ch == "-" || ch == "." || ch == "," else {
                    NSLog("[MIXFOCUS] onKeyPress ignored (char='%@')", String(press.characters))
                    return .ignored
                }
                NSLog("[MIXFOCUS] onKeyPress → typing started (char='%@')", String(ch))
                typing = String(ch)
                DispatchQueue.main.async {
                    fieldFocused = true
                    // AppKit selects all of the field editor's text when it becomes
                    // first responder programmatically. We put the cursor back at the end of
                    // text so that the next digit is added instead of replacing.
                    DispatchQueue.main.async {
                        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
                            editor.selectedRange = NSRange(location: editor.string.count, length: 0)
                        }
                    }
                }
                return .handled
            }
        }
        .help(help)
    }
}

// MARK: - The 'audio file' zone (an audio clip): speed / semitones / bpm

struct AudioFileZoneView: View {
    let rect: CGRect
    let file: SynopticAudioFile
    let actions: SynopticActions
    @State private var bpmBaseText: String = ""
    @FocusState private var baseFocused: Bool

    private var semis: Double { 12 * log2(max(1e-6, file.speedRatio)) }
    private var targetBPM: Double? { file.baseBPM.map { $0 * file.speedRatio } }

    private func stLabel(_ s: Double) -> String {
        let r = s.rounded()
        if abs(s - r) < 0.05 { return r == 0 ? "0 st" : String(format: "%+.0f st", r) }
        return String(format: "%+.1f st", s)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.secondary.opacity(0.35), lineWidth: 1))
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 4) {
                    Text(L("synoptic.audioFile"))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button { actions.onToggleLoop?() } label: {
                        Text(L("synoptic.loop.label"))
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(file.isLooping ? Color.white : Color.secondary.opacity(file.isReversed ? 0.4 : 1))
                            .padding(.horizontal, 6).frame(height: 16)
                            .background(RoundedRectangle(cornerRadius: 4)
                                .fill(file.isLooping ? Color.accentColor : Color.secondary.opacity(0.18)))
                            .overlay(RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(Color.secondary.opacity(0.35)))
                    }
                    .buttonStyle(.plain)
                    .disabled(file.isReversed)
                    // Looping is not handled in reverse yet: the source anchor is recomputed from the
                    // length, which becomes unbounded precisely when looping (@see [[loop-item-plan]]).
                    .help(file.isReversed ? L("synoptic.loop.unavailableReversed")
                          : file.isLooping ? L("synoptic.loop.on")
                          : L("synoptic.loop.off"))
                    Button { actions.onToggleReverse?() } label: {
                        Text(L("synoptic.reverse.label"))
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(file.isReversed ? Color.white : Color.secondary)
                            .padding(.horizontal, 6).frame(height: 16)
                            .background(RoundedRectangle(cornerRadius: 4)
                                .fill(file.isReversed ? Color.accentColor : Color.secondary.opacity(0.18)))
                            .overlay(RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(Color.secondary.opacity(0.35)))
                    }
                    .buttonStyle(.plain)
                    .help(file.isReversed ? L("synoptic.reverse.on") : L("synoptic.reverse.off"))
                }

                // 1× / st / bpm on the same line (saving height).
                HStack(spacing: 6) {
                    DragValueBox(value: semis,
                                 format: { String(format: "%.2f×", pow(2.0, $0 / 12.0)) },
                                 range: -48...48, pointsPerStep: 6, snap: false, width: 52,
                                 keyStep: 1,
                                 parse: { Double($0.replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: "×", with: "").replacingOccurrences(of: "x", with: "")).map { 12 * log2(max(1e-6, $0)) } },
                                 help: L("help.drag.speed"),
                                 onBegin: { actions.onBeginSpeedEdit?() },
                                 onChange: { actions.onSetSpeed?(pow(2.0, $0 / 12.0)) },
                                 onReset: { actions.onSetSpeed?(1.0) })
                    DragValueBox(value: semis,
                                 format: stLabel,
                                 range: -48...48, pointsPerStep: 6, width: 48,
                                 keyStep: 1,
                                 help: L("help.drag.semitones"),
                                 onBegin: { actions.onBeginSpeedEdit?() },
                                 onChange: { actions.onSetSpeed?(pow(2.0, $0 / 12.0)) },
                                 onReset: { actions.onSetSpeed?(1.0) })

                    Spacer(minLength: 0)

                    TextField(text: $bpmBaseText) { Text(verbatim: "—") }
                        .frame(width: 34).multilineTextAlignment(.center)
                        .font(.system(size: 10, design: .monospaced))
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 3).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.18)))
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.secondary.opacity(0.45)))
                        .focused($baseFocused)
                        .onSubmit { commitBase() }
                        .help(L("synoptic.wavBPM"))

                    Image(systemName: "arrow.right")
                        .font(.system(size: 8)).foregroundStyle(.tertiary)

                    if let base = file.baseBPM, base > 0 {
                        DragValueBox(value: targetBPM ?? base,
                                     format: { String(format: "%.0f", $0) },
                                     range: 20...400, pointsPerStep: 2, width: 38,
                                     keyStep: 1,
                                     help: L("help.drag.bpm"),
                                     onBegin: { actions.onBeginSpeedEdit?() },
                                     onChange: { actions.onSetSpeed?($0 / base) })
                    } else {
                        Text(verbatim: "—")
                            .font(.system(size: 10, weight: .medium)).monospacedDigit()
                            .foregroundStyle(.tertiary)
                            .frame(width: 38, height: 18)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.08)))
                    }

                    Text(verbatim: "bpm").font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10).padding(.top, 8)
            .frame(width: rect.width, height: rect.height, alignment: .topLeading)
            .position(x: rect.midX, y: rect.midY)
        }
        .onAppear { syncBaseText() }
        .onChange(of: file.baseBPM) { _, _ in syncBaseText() }
    }

    private func syncBaseText() {
        guard !baseFocused else { return }
        if let base = file.baseBPM {
            let r = base.rounded()
            bpmBaseText = abs(base - r) < 0.5 ? String(Int(r)) : String(format: "%.1f", base)
        } else {
            bpmBaseText = ""
        }
    }

    private func commitBase() {
        let t = bpmBaseText.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { actions.onSetBaseBPM?(nil) }
        else if let v = Double(t), v > 0 { actions.onSetBaseBPM?(v) }
    }
}

// MARK: - The 'clip' zone (the output mix): volume / pan / mute
//
// Reuses GainDbControl (a gain box plus a mute icon) for the volume, and adapts it through
// DragValueBox for the pan (the C / L xx% / R xx% format).

struct ClipMixZoneView: View {
    let rect: CGRect
    let mix: SynopticMix
    let actions: SynopticActions

    private func panLabel(_ p: Float) -> String {
        if abs(p) < 0.01 { return "C" }
        return p < 0 ? "L \(Int((-p * 100).rounded()))%" : "R \(Int((p * 100).rounded()))%"
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.secondary.opacity(0.35), lineWidth: 1))
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)

            // Title plus pan / volume / mute on ONE line (saving height).
            HStack(spacing: 6) {
                Text(mix.title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                // A 'linked sound object' marker (the attributes below carry a link icon).
                if mix.attrLinks != nil {
                    Image(systemName: "waveform.circle")
                        .font(.system(size: 17))
                        .foregroundStyle(LinkColor.soundObject)
                        .help(L("synoptic.soundObject.linked"))
                }
                Spacer(minLength: 0)
                // Each attribute: the value, then (tight to the right) its link icon.
                HStack(spacing: 3) {
                    DragValueBox(value: Double(mix.pan),
                                 format: { panLabel(Float($0)) },
                                 range: -1...1, pointsPerStep: 80, snap: false, width: 52,
                                 keyStep: 0.05,
                                 parse: { Double($0.replacingOccurrences(of: ",", with: ".")).map { $0 / 100 } },
                                 help: L("help.drag.pan"),
                                 onTouch: { actions.onTouchParam?(.pan) },
                                 onBegin: { actions.onBeginMixEdit?() },
                                 onChange: { actions.onSetPan?(Float($0)) },
                                 onReset: { actions.onSetPan?(0) })
                        .automationLocked(mix.panAutomated)
                    if let links = mix.attrLinks { attrLinkBadge(.pan, synced: links.panSynced) }
                }
                HStack(spacing: 3) {
                    GainDbControl(dB: mix.volumeDb, minDb: -96, maxDb: 40,
                                  onTouch: { actions.onTouchParam?(.volume) },
                                  onBegin: { actions.onBeginMixEdit?() }) { newDB in
                        actions.onSetVolume?(newDB)
                    }
                    .automationLocked(mix.volumeAutomated)
                    if let links = mix.attrLinks { attrLinkBadge(.volume, synced: links.volumeSynced) }
                }
                HStack(spacing: 3) {
                    muteButton
                    soloButton
                    if let links = mix.attrLinks { attrLinkBadge(.mute, synced: links.muteSynced) }
                }
            }
            .padding(.horizontal, 10)
            .frame(width: rect.width, height: rect.height, alignment: .leading)
            .position(x: rect.midX, y: rect.midY)
        }
    }

    /// An attribute's link icon (a sound object): green = synced between instances,
    /// red = independent. Double click to flip the state.
    private func attrLinkBadge(_ attr: SynopticMixAttr, synced: Bool) -> some View {
        Image(systemName: "arrow.down.left.arrow.up.right.square.fill")
            .font(.system(size: 17))
            .foregroundStyle(synced ? Color.green : Color.red)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { actions.onToggleAttrSync?(attr) }
            .help(synced
                  ? L("synoptic.soundObject.attrSynced")
                  : L("synoptic.soundObject.attrIndependent"))
    }

    private var muteButton: some View {
        Button { actions.onToggleMute?() } label: {
            Image(systemName: mix.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(mix.isMuted ? Color.red : Color.secondary)
                .frame(width: 18, height: 18)
                .background(RoundedRectangle(cornerRadius: 4)
                    .fill(mix.isMuted ? Color.red.opacity(0.18) : Color.secondary.opacity(0.18)))
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .strokeBorder((mix.isMuted ? Color.red : Color.secondary).opacity(0.45)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("common.mute"))
    }

    /// The object's solo: ONE button for both layers. Tinted = temporary (it will clear itself),
    /// solid = held (it stays). A click always writes into the held layer — it is the only one a
    /// click can own (@see EditViewModel.toggleSoloHold).
    private var soloButton: some View {
        let hold = mix.solo == .hold
        let on   = mix.solo != .off
        return Button { actions.onToggleSolo?() } label: {
            Image(systemName: "headphones")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(hold ? Color.black : (on ? Color.yellow : Color.secondary))
                .frame(width: 18, height: 18)
                .background(RoundedRectangle(cornerRadius: 4)
                    .fill(hold ? Color.yellow
                               : (on ? Color.yellow.opacity(0.18) : Color.secondary.opacity(0.18))))
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .strokeBorder((on ? Color.yellow : Color.secondary).opacity(0.45)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(hold ? L("synoptic.solo.held")
                   : (on ? L("synoptic.solo.temporary") : L("synoptic.solo")))
    }
}

// MARK: - Sends: one row, the foot zone (departures) and a bus's head (infinite + received sends)
//
// Sends are no longer a column of the inspector: a departure is taken at the foot of the
// chain (after the mix, before the stems) and reads as a branch leaving the trunk — hence the
// 'up and to the right' arrow on each row. Symmetrically, the sends an aux RECEIVES come in
// at the head, at the level of its source.

/// One send row: the branch arrow, the name, a draggable level, a switch.
struct SynopticSendRow: View {
    let send: SynopticSend
    /// true = a departure (foot); false = a received send (an aux's head) — the arrow flips.
    let outgoing: Bool
    let actions: SynopticActions

    private var isSilent: Bool { send.levelDb <= sendMinDb }
    private var isRouted: Bool { send.enabled && !isSilent }

    private func levelLabel(_ db: Double) -> String {
        db <= Double(sendMinDb) ? "-∞ dB" : (db == 0 ? "0 dB" : String(format: "%+.0f dB", db))
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: outgoing ? "arrow.turn.down.right" : "arrow.turn.right.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isRouted ? Color.accentColor : Color.secondary.opacity(0.6))
                .frame(width: 14)
                .help(outgoing ? L("synoptic.send.outgoing") : L("synoptic.send.incoming"))
            Text(send.name)
                .font(.system(size: 10))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(isRouted ? .primary : .secondary)
            Spacer(minLength: 4)
            DragValueBox(value: Double(send.levelDb),
                         format: { levelLabel($0) },
                         range: Double(sendMinDb)...Double(sendMaxDb),
                         pointsPerStep: 6, snap: true, width: 52, keyStep: 1,
                         help: L("help.drag.sendLevel"),
                         onTouch: { actions.onTouchParam?(.send(auxID: send.id)) },
                         onBegin: { actions.onBeginSendEdit?() },
                         onChange: { actions.onSetSendLevel?(send.id, Float($0)) },
                         onReset: {
                             actions.onBeginSendEdit?()
                             actions.onSetSendLevel?(send.id, sendMinDb)
                         })
                .opacity(send.enabled ? 1 : 0.5)
                .automationLocked(send.isAutomated)
            Button { actions.onToggleSend?(send.id) } label: {
                Image(systemName: "power")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(send.enabled ? Color.accentColor : Color.secondary)
                    .frame(width: 18, height: 18)
                    .background(RoundedRectangle(cornerRadius: 4)
                        .fill((send.enabled ? Color.accentColor : Color.secondary).opacity(0.18)))
                    .overlay(RoundedRectangle(cornerRadius: 4)
                        .strokeBorder((send.enabled ? Color.accentColor : Color.secondary).opacity(0.45)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("common.mute"))
        }
        .frame(height: SynopticLayout.sendRowH)
    }
}

/// The 'sends' zone at the foot: the departures towards the auxes, taken after the object's mix.
/// A dashed border = a branch (the main signal carries on towards the stems).
struct SendsZoneView: View {
    let rect: CGRect
    let sends: [SynopticSend]
    let actions: SynopticActions

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.secondary.opacity(0.35),
                                  style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)

            VStack(alignment: .leading, spacing: 0) {
                Text(L("synoptic.zone.aux"))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(height: SynopticLayout.zoneTitleH, alignment: .center)
                ForEach(sends) { s in
                    SynopticSendRow(send: s, outgoing: true, actions: actions)
                }
            }
            .padding(.horizontal, 10)
            .frame(width: rect.width, height: rect.height, alignment: .topLeading)
            .position(x: rect.midX, y: rect.midY)
        }
    }
}

/// A bus's chain head (aux / group): 'source', the infinite option, and — for an aux —
/// the list of the sends it receives (the incoming signal comes from there).
struct BusHeadZoneView: View {
    let rect: CGRect
    let infinite: SynopticInfinite?
    let loop: SynopticLoop?
    let received: [SynopticSend]
    let actions: SynopticActions

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 0.5))
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Text(L("synoptic.source"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if let lp = loop { loopToggle(lp) }
                    if let inf = infinite { infiniteToggle(inf) }
                }
                .frame(height: SynopticLayout.pillH)
                ForEach(received) { s in
                    SynopticSendRow(send: s, outgoing: false, actions: actions)
                }
            }
            .padding(.horizontal, 10)
            .frame(width: rect.width, height: rect.height, alignment: .topLeading)
            .position(x: rect.midX, y: rect.midY)
        }
    }

    private func loopToggle(_ lp: SynopticLoop) -> some View {
        Button { actions.onToggleLoop?() } label: {
            HStack(spacing: 4) {
                Image(systemName: "repeat")
                    .font(.system(size: 10, weight: .bold))
                Text(L("synoptic.loop.label"))
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(lp.isOn ? Color.accentColor : Color.secondary)
            .padding(.horizontal, 7).frame(height: 20)
            .background(RoundedRectangle(cornerRadius: 5)
                .fill((lp.isOn ? Color.accentColor : Color.secondary).opacity(lp.isOn ? 0.18 : 0.10)))
            .overlay(RoundedRectangle(cornerRadius: 5)
                .strokeBorder((lp.isOn ? Color.accentColor : Color.secondary).opacity(0.45)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("synoptic.loop"))
    }

    private func infiniteToggle(_ inf: SynopticInfinite) -> some View {
        Button { actions.onToggleInfinite?() } label: {
            HStack(spacing: 4) {
                Image(systemName: "infinity")
                    .font(.system(size: 10, weight: .bold))
                Text(L("synoptic.infinite"))
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(inf.isOn ? Color.accentColor : Color.secondary)
            .padding(.horizontal, 7).frame(height: 20)
            .background(RoundedRectangle(cornerRadius: 5)
                .fill((inf.isOn ? Color.accentColor : Color.secondary).opacity(inf.isOn ? 0.18 : 0.10)))
            .overlay(RoundedRectangle(cornerRadius: 5)
                .strokeBorder((inf.isOn ? Color.accentColor : Color.secondary).opacity(0.45)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("synoptic.infinite.help", inf.kindLabel))
    }
}

// MARK: - The 'stems' zone (output): choosing the destination stem
//
// It only shows and selects (creating and renaming stems happen in the toolbar). The current
// badge is ringed in white; a click reassigns.

struct StemsZoneView: View {
    let rect: CGRect
    let stems: [SynopticStem]
    let onAssign: (UUID) -> Void

    private var current: SynopticStem? { stems.first { $0.isCurrent } }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.secondary.opacity(0.35), lineWidth: 1))
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)

            // The title plus the destination stem's drop-down menu, on one line.
            HStack(spacing: 8) {
                Text(L("synoptic.zone.stems"))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Menu {
                    ForEach(Array(stems.enumerated()), id: \.element.id) { idx, stem in
                        // The number prefix = the keyboard shortcut (1 = Main, 2 = the 2nd stem…).
                        let prefix = idx < 9 ? "\(idx + 1)  " : ""
                        // A `String` and not a literal: see `ObjectInspectorView`, same trap.
                        let title = "\(prefix)\(stem.name)"
                        Button { onAssign(stem.id) } label: {
                            if stem.isCurrent { Label(title, systemImage: "checkmark") }
                            else { Text(verbatim: title) }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill((current?.color ?? .secondary).opacity(0.85))
                            .frame(width: 11, height: 11)
                        Text(current?.name ?? "—")
                            .font(.system(size: 10, weight: .medium))
                            .lineLimit(1)
                            .foregroundStyle(.primary)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 7))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 7).frame(height: 20)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.18)))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.secondary.opacity(0.45)))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .padding(.horizontal, 12)
            .frame(width: rect.width, height: rect.height, alignment: .leading)
            .position(x: rect.midX, y: rect.midY)
        }
    }
}

// MARK: - The 'output' zone of a group's child: routed to the group (read only)
//
// A group's child has no stem assignment of its own: its output feeds the group's submix,
// and it is the (root) group that belongs to a stem. The colour badge is a reminder of the
// effective stem at the end of the chain.

struct GroupRoutingZoneView: View {
    let rect: CGRect
    let routing: SynopticGroupRouting

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.secondary.opacity(0.35), lineWidth: 1))
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)

            HStack(spacing: 8) {
                Text(L("synoptic.zone.output"))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    Circle()
                        .fill(routing.stemColor.opacity(0.85))
                        .frame(width: 11, height: 11)
                    Image(systemName: "rectangle.3.group")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Text(routing.groupName)
                        .font(.system(size: 10, weight: .medium))
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                }
                .padding(.horizontal, 7).frame(height: 20)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.10)))
                .fixedSize()
                .help(L("synoptic.routedToGroup", routing.groupName))
            }
            .padding(.horizontal, 12)
            .frame(width: rect.width, height: rect.height, alignment: .leading)
            .position(x: rect.midX, y: rect.midY)
        }
    }
}

// MARK: - Real model → graph adapter (step 1: a pure series)

extension PluginCategory {
    /// Guesses a category from the name/manufacturer (purely cosmetic, for the badge).
    static func infer(from p: ObjectPlugin) -> PluginCategory {
        let n = (p.name + " " + p.manufacturer).lowercased()
        if n.contains("eq") || n.contains("equal") { return .eq }
        if n.contains("comp") || n.contains("limit") || n.contains("gate") || n.contains("dyn") { return .dynamics }
        if n.contains("sat") || n.contains("dist") || n.contains("drive") || n.contains("crush") || n.contains("amp") { return .distortion }
        if n.contains("reverb") || n.contains("verb") || n.contains("room") || n.contains("hall") || n.contains("space") { return .space }
        if n.contains("delay") || n.contains("chorus") || n.contains("flang") || n.contains("phas") || n.contains("mod") { return .modulation }
        return .utility
    }
}

// MARK: - The core wired to the engine (step 1) — reused inline AND in a window

enum SynopticSheetKind: Identifiable {
    case insert(location: SeriesLocation, index: Int)   // a series '+' inside a target series
    case instrument                                      // the '+' of the instruments zone (a MIDI clip)

    var id: String {
        switch self {
        case .insert(let loc, let i): return "insert-\(loc.key)-\(i)"
        case .instrument:             return "instrument"
        }
    }
}

struct SynopticBoundView: View {
    var viewModel: EditViewModel
    let objectID: UUID
    var scrolls: Bool = true

    @State private var selectedID: UUID? = nil
    @State private var activeSheet: SynopticSheetKind? = nil
    @State private var pickerSearch: String = ""
    // The live state of the external instances (loading/ready/error), refreshed by a timer.
    @State private var instanceStates: [UUID: Int] = [:]
    @State private var loadErrors: [UUID: String] = [:]
    // VU meter levels per plugin (0..1), polled read-only.
    @State private var levels: [UUID: Double] = [:]
    // An aux: the senders listed at the head (the sends it receives). A STICKY list — a row taken
    // down to -∞ stays shown until the selection changes, otherwise it would vanish mid-drag
    // (activeSenders filters silent sends out) and SwiftUI would re-associate the gesture with a neighbour.
    @State private var receivedIDs: [UUID] = []
    private let poll = Timer.publish(every: 0.6, on: .main, in: .common).autoconnect()
    private let vuPoll = Timer.publish(every: 0.07, on: .main, in: .common).autoconnect()

    var body: some View {
        // Builds the graph plus the seriesID→location table from the real model. The closures below
        // capture `locations` from THIS build (consistent with the series ids being rendered).
        // The host = a timeline object OR a stem/master bus (INC 2). `obj` is nil for a bus:
        // a bus has neither a MIDI clip nor an instrument → isMIDI=false, midiInstrument=nil.
        let obj = viewModel.find(id: objectID)
        let model = viewModel.chainPlugins(objectID) ?? []
        let gains = viewModel.chainGains(objectID)
        // TRACE. Judging a slot's trace needs the view-model — is the plugin installed on this
        // machine, has anything upstream moved since the capture — so it is settled here and
        // handed to the mapping ready made. @see EditViewModel.traceHealth
        let traces = viewModel.traceStates(for: model, on: objectID)
        let (root, locations) = SynopticMapping.build(model, objectID: objectID, levels: levels,
                                                      traces: traces)

        // No trace state on the instrument, and none is asked for: tracing is offered on the FX
        // chain only. The instrument card below wires no trace action either, so the two agree —
        // a badge on a slot with no way to capture one would be a promise nothing keeps.
        let instLeaf = obj?.instruments.first.map { SynopticMapping.leaf($0, vu: levels[$0.id] ?? 0) }

        // The 'audio file' zone: audio clips only (MIDI clips keep their MIDI zone;
        // groups / auxes keep the Source pill).
        let audioFile: SynopticAudioFile? = (obj?.isClip ?? false)
            ? obj.map { SynopticAudioFile(speedRatio: $0.speedRatio, baseBPM: $0.baseBPM, isReversed: $0.isReversed, isLooping: $0.loopEnabled) }
            : nil

        // The 'clip' zone (the output mix): for any real object (not a bus). The title depends on the type.
        let mix: SynopticMix? = obj.map { o in
            let title = L(o.isGroup ? "synoptic.mix.kind.group"
                        : (o.isAux ? "synoptic.mix.kind.aux" : "synoptic.mix.kind.clip"))
            let links: SynopticMixLinks? = o.isObjectInstance
                ? SynopticMixLinks(volumeSynced: viewModel.isAttrSynced(o, .volume),
                                   panSynced:    viewModel.isAttrSynced(o, .pan),
                                   muteSynced:   viewModel.isAttrSynced(o, .mute))
                : nil
            // Volume / pan AUTOMATED: we show what the curve plays at the playback
            // position, not the static setting it has replaced (@see liveAutomationValue).
            // The control stays neutralised — it shows, it no longer sets.
            let vol = viewModel.liveAutomationValue(.volume, on: o.id) ?? o.volume
            let pan = viewModel.liveAutomationValue(.pan,    on: o.id) ?? o.pan
            let solo: SynopticSoloState = viewModel.soloedIDs.contains(o.id) ? .hold
                : ((viewModel.tempSoloRoots?.contains(o.id) ?? false) ? .temporary : .off)
            return SynopticMix(title: title, volumeDb: vol, pan: pan, isMuted: o.isMuted,
                               solo: solo,
                               volumeAutomated: viewModel.isAutomated(.volume, on: o),
                               panAutomated:    viewModel.isAutomated(.pan, on: o),
                               attrLinks: links)
        }

        // Output zone: a group's CHILD is routed to its group (read only, the stem being
        // carried by the group); a top-level object chooses its stem (badges for every stem,
        // the current one ringed).
        let parentGroup = obj.flatMap { viewModel.parentGroup(for: $0.id) }
        let groupRouting: SynopticGroupRouting? = parentGroup.map { p in
            SynopticGroupRouting(groupName: p.displayName,
                                 stemColor: viewModel.stemColor(for: p.id))
        }
        let stems: [SynopticStem]? = (parentGroup != nil) ? nil : obj.map { o in
            viewModel.stems.map { s in
                let isCurrent = (o.stemID == s.id) || (o.stemID == nil && s.id == viewModel.mainStemID)
                return SynopticStem(id: s.id, name: s.name, color: s.color, isCurrent: isCurrent)
            }
        }

        // Sends: departures towards the reachable auxes read at the FOOT of the chain (after the mix,
        // before the stems); an aux shows at its HEAD what it receives. No more dedicated column.
        let sends: [SynopticSend] = (obj != nil && !(obj?.isAux ?? false))
            ? viewModel.sendToolAuxes(for: objectID).map { aux in
                SynopticSend(id: aux.id, name: aux.displayName,
                             enabled: viewModel.isSendEnabled(from: objectID, to: aux.id),
                             levelDb: viewModel.sendLevel(from: objectID, to: aux.id),
                             isAutomated: viewModel.isAutomated(.send(auxID: aux.id), on: objectID))
              }
            : []
        let received: [SynopticSend] = (obj?.isAux ?? false)
            ? receivedIDs.compactMap { sid in
                viewModel.find(id: sid).map { sender in
                    SynopticSend(id: sid, name: sender.displayName,
                                 enabled: viewModel.isSendEnabled(from: sid, to: objectID),
                                 levelDb: viewModel.sendLevel(from: sid, to: objectID),
                                 // A send lives on the SENDER: it is ITS curve we read, even
                                 // if the row is shown at the head of the receiving aux.
                                 isAutomated: viewModel.isAutomated(.send(auxID: objectID), on: sender))
                }
              }
            : []

        // The 'infinite' option: carried by the chain head of top-level auxes / groups.
        let infinite: SynopticInfinite? = obj.flatMap { o in
            guard o.canBeInfinite, viewModel.items.contains(where: { $0.id == o.id }) else { return nil }
            return SynopticInfinite(isOn: o.isInfinite, kindLabel: o.isAux ? L("synoptic.infinite.kind.aux") : L("synoptic.infinite.kind.group"))
        }
        // Looping: a group (the chain head) or a MIDI clip (the MIDI zone) — audio has its own
        // badge in `audioFile`. No top-level restriction here, unlike `infinite`.
        let loop: SynopticLoop? = obj.flatMap { o in
            (o.isGroup || o.isMIDI) && o.canLoop ? SynopticLoop(isOn: o.loopEnabled) : nil
        }

        return SynopticView(root: root, selectedID: $selectedID, scrolls: scrolls,
                            chainInDb: gains.inDb, chainOutDb: gains.outDb,
                            chainInAutomated:  viewModel.isAutomated(.chainInGain, on: objectID),
                            chainOutAutomated: viewModel.isAutomated(.chainOutGain, on: objectID),
                            isMIDI: obj?.isMIDI ?? false, midiInstrument: instLeaf,
                            audioFile: audioFile, mix: mix, stems: stems,
                            groupRouting: groupRouting,
                            sends: sends, receivedSends: received, infinite: infinite, loop: loop,
                            // A closed sound object → read-only FX ('Open to edit'). While editing, the
                            // placement is materialised (no longer isObjectInstance) so the FX become
                            // interactive again.
                            fxReadOnly: (obj?.isObjectInstance ?? false),
                            actions: SynopticActions(
            onSelect: { selectedID = $0 },
            onOpenEditor: { openEditor($0) },
            onToggleBypass: { viewModel.togglePluginEnabled(objectID: objectID, pluginID: $0) },
            onRemove: {
                viewModel.removePlugin(objectID: objectID, pluginID: $0)
                if selectedID == $0 { selectedID = nil }
            },
            onInsertSeries: { seriesID, index in
                if let loc = locations[seriesID] { activeSheet = .insert(location: loc, index: index) }
            },
            onBranch: { elementID in viewModel.synopticBranch(objectID: objectID, elementID: elementID) },
            instanceState: { instanceStates[$0] ?? 0 },
            loadError: { loadErrors[$0] },
            onDiagnose: { viewModel.diagnosePlugin(objectID: objectID, pluginID: $0) },
            onUnlink: { viewModel.unlinkPlugin(objectID: objectID, pluginID: $0) },
            onRelink: { viewModel.relinkPlugin(objectID: objectID, pluginID: $0) },
            linkSiblingCount: { viewModel.linkSiblings(of: $0).count },
            onCaptureTrace: { viewModel.captureTrace(hostID: objectID, pluginID: $0) },
            onCancelTrace: { viewModel.cancelTraceCapture() },
            onSetTraceUse: { pluginID, use in
                viewModel.edit { viewModel.setTraceForced(hostID: objectID, pluginID: pluginID, forced: use) }
            },
            onClearTrace: { pluginID in
                viewModel.edit { viewModel.clearTrace(hostID: objectID, pluginID: pluginID) }
            },
            traceSummary: { viewModel.traceSummary(pluginID: $0, on: objectID) },
            traceProgress: { viewModel.capturingTracePluginID == $0 ? viewModel.traceProgress : nil },
            dragProvider: { dragProvider($0) },
            onReorder: { pluginID, seriesID, toIndex, copy in
                if let loc = locations[seriesID] {
                    if copy {
                        viewModel.synopticCopyPlugin(objectID: objectID, pluginID: pluginID, to: loc, at: toIndex)
                    } else {
                        viewModel.synopticReorder(objectID: objectID, pluginID: pluginID, to: loc, at: toIndex)
                    }
                }
            },
            onDropOntoCard: { targetPluginID, draggedPluginID, copy in
                viewModel.synopticDropOnPlugin(objectID: objectID, pluginID: draggedPluginID,
                                               targetPluginID: targetPluginID, copy: copy)
            },
            onSetVoiceGain: { blockID, voiceIndex, dB in
                viewModel.setVoiceGain(objectID: objectID, blockID: blockID, voiceIndex: voiceIndex, dB: dB)
            },
            onRemoveVoice: { blockID, voiceIndex in
                viewModel.removeVoice(objectID: objectID, blockID: blockID, voiceIndex: voiceIndex)
            },
            onSetVoiceMute: { blockID, voiceIndex, muted in
                // A discreet toggle → one undo per flip (like the mix's toggleMute).
                viewModel.edit {
                    viewModel.setVoiceMute(objectID: objectID, blockID: blockID, voiceIndex: voiceIndex, muted: muted)
                }
            },
            onSetChainGain: { isOutput, dB in
                viewModel.setChainGain(objectID: objectID, output: isOutput, dB: dB)
            },
            onBeginGainEdit: { viewModel.pushUndo() },
            onAddInstrument: { activeSheet = .instrument },
            onRemoveInstrument: {
                let instID = obj?.instruments.first?.id
                viewModel.removeInstrument(objectID: objectID)
                if let instID, selectedID == instID { selectedID = nil }
            },
            onOpenInstrumentEditor: { if let id = obj?.instruments.first?.id { openEditor(id) } },
            onSelectInstrument: { selectedID = obj?.instruments.first?.id },
            onToggleInstrumentBypass: {
                if let id = obj?.instruments.first?.id {
                    viewModel.toggleInstrumentEnabled(objectID: objectID, pluginID: id)
                }
            },
            onSetSpeed: { viewModel.updateSpeed(id: objectID, ratio: $0) },
            onSetBaseBPM: { bpm in viewModel.edit { viewModel.updateBaseBPM(id: objectID, bpm: bpm) } },
            onToggleReverse: {
                let rev = !(obj?.isReversed ?? false)
                viewModel.edit { viewModel.updateReversed(id: objectID, reversed: rev) }
            },
            onToggleLoop: {
                let loop = !(obj?.loopEnabled ?? false)
                viewModel.edit { viewModel.updateLoopEnabled(id: objectID, enabled: loop) }
            },
            onBeginSpeedEdit: { viewModel.pushUndo() },
            // Touching a control: it names the 'future automation' row, without changing anything. An
            // aux lists the sends it RECEIVES, so the send row belongs to the SENDER — the same
            // inversion as `onSetSendLevel`, failing which we would remember the touch on the wrong
            // object.
            onTouchParam: { ref in
                let isAux = viewModel.find(id: objectID)?.isAux ?? false
                if isAux, case .send(let senderID) = ref {
                    viewModel.recordAutomationTouch(senderID, .send(auxID: objectID))
                } else {
                    viewModel.recordAutomationTouch(objectID, ref)
                }
            },
            onSetVolume: { viewModel.updateVolume(id: objectID, volume: $0) },
            onSetPan: { viewModel.updatePan(id: objectID, pan: $0) },
            onToggleMute: { viewModel.edit { viewModel.toggleMute(id: objectID) } },
            // Solo is a session listening state, outside the model and outside undo (@see
            // EditViewModel+Solo): no `edit {}`, no undo point, like a stem's mute — otherwise ⌘Z
            // would replay auditions instead of undoing edits.
            onToggleSolo: { viewModel.toggleSoloHold(objectID: objectID) },
            onBeginMixEdit: { viewModel.pushUndo() },
            onToggleAttrSync: { attr in
                guard let o = viewModel.find(id: objectID) else { return }
                let mask: ObjectAttrLinks
                switch attr {
                case .volume: mask = .volume
                case .pan:    mask = .pan
                case .mute:   mask = .mute
                }
                viewModel.setAttrSynced(mask, !viewModel.isAttrSynced(o, mask), forPlacement: objectID)
            },
            onAssignStem: { stemID in viewModel.edit { viewModel.assignStem(objectID: objectID, stemID: stemID) } },
            // An aux lists the sends it RECEIVES: the row carries the SENDER's id, and so it is the
            // sender we set (sender → this aux). Otherwise we set this object → the target aux.
            onSetSendLevel: { rowID, db in
                let isAux = viewModel.find(id: objectID)?.isAux ?? false
                viewModel.setSendLevel(from: isAux ? rowID : objectID,
                                       to: isAux ? objectID : rowID, levelDb: db)
            },
            onToggleSend: { rowID in
                let isAux = viewModel.find(id: objectID)?.isAux ?? false
                let from = isAux ? rowID : objectID
                let to   = isAux ? objectID : rowID
                viewModel.edit {
                    viewModel.setSendEnabled(from: from, to: to,
                                             enabled: !viewModel.isSendEnabled(from: from, to: to))
                }
            },
            onBeginSendEdit: { viewModel.pushUndo() },
            onToggleInfinite: { viewModel.toggleObjectInfinite(id: objectID) }
        ))
        .onAppear { refreshStates(); receivedIDs = viewModel.activeSenders(toAux: objectID) }
        .onChange(of: objectID) { _, newID in receivedIDs = viewModel.activeSenders(toAux: newID) }
        .onReceive(poll) { _ in refreshStates(); refreshReceived() }
        .onReceive(vuPoll) { _ in refreshLevels() }
        .sheet(item: $activeSheet) { kind in
            switch kind {
            case .insert(let location, let index):
                pickerSheet { available in
                    viewModel.synopticInsert(objectID: objectID, available: available, into: location, at: index)
                }
            case .instrument:
                pickerSheet(instrumentsOnly: true) { available in
                    viewModel.setInstrument(objectID: objectID, available: available)
                }
            }
        }
    }

    /// A plugin selection sheet reused by '+' (insert), '//' (branch) and the instruments zone.
    /// `instrumentsOnly` restricts it to instruments (the MIDI zone); otherwise we ALWAYS exclude
    /// instruments from the FX zone — an instrument needs MIDI at its input (which only a MIDI clip
    /// provides, and through its dedicated MIDI zone), so it belongs in NO FX chain.
    @ViewBuilder
    private func pickerSheet(instrumentsOnly: Bool = false,
                             onSelect: @escaping (AvailablePlugin) -> Void) -> some View {
        let filter: (AvailablePlugin) -> Bool =
            instrumentsOnly ? { $0.isInstrument } : { !$0.isInstrument }
        VStack(spacing: 0) {
            HStack {
                Text(instrumentsOnly ? L("synoptic.sheet.chooseInstrument") : L("synoptic.sheet.addPlugin")).font(.headline)
                Spacer()
                Button(L("common.cancel")) { activeSheet = nil }
            }
            .padding(12)
            Divider()
            PluginPickerPopover(
                viewModel: viewModel,
                objectID: objectID,
                searchText: $pickerSearch,
                dismiss: { activeSheet = nil },
                onSelect: { available in onSelect(available); activeSheet = nil },
                filter: filter
            )
        }
        .frame(width: 280, height: 420)
    }

    /// Toggles the editor: a native window for an external plugin, a dedicated window for a
    /// Tracktion built-in (the same path as the chip list). The double click that opens also
    /// closes (@see EditViewModel.togglePluginEditor).
    private func openEditor(_ pluginID: UUID) {
        // A recursive search: the plugin may live in the branch of a parallel block, or be the
        // instrument at the head of the chain (a MIDI clip).
        let candidates = viewModel.leafPlugins(objectID: objectID)
            + (viewModel.find(id: objectID)?.instruments ?? [])
        guard let plug = candidates.first(where: { $0.id == pluginID })
        else { return }
        viewModel.togglePluginEditor(objectID: objectID, plug: plug)
    }

    /// A card's drag payload (the same format as the chips → it reuses the timeline drop to
    /// move/copy/link to another object, and the '+'s to reorder).
    private func dragProvider(_ pluginID: UUID) -> NSItemProvider {
        let payload = PluginDragPayload(sourceObjectID: objectID, pluginID: pluginID)
        let data = (try? JSONEncoder().encode(payload)) ?? Data()
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.plainText.identifier,
                                             visibility: .all) { completion in
            completion(data, nil); return nil
        }
        return provider
    }

    /// Refreshes the list of the sends an aux RECEIVES: we ADD the new senders without removing
    /// those already shown (a sticky row, see `receivedIDs`); only objects that have gone from
    /// the project are removed.
    private func refreshReceived() {
        guard viewModel.find(id: objectID)?.isAux == true else {
            if !receivedIDs.isEmpty { receivedIDs = [] }
            return
        }
        let live = viewModel.activeSenders(toAux: objectID)
        var merged = receivedIDs.filter { viewModel.find(id: $0) != nil }
        for id in live where !merged.contains(id) { merged.append(id) }
        if merged != receivedIDs { receivedIDs = merged }
    }

    /// Polls the VU meter levels (during playback only; otherwise it decays to 0 once).
    private func refreshLevels() {
        guard viewModel.isTransportPlaying else {
            if !levels.isEmpty { levels = [:] }
            return
        }
        var l: [UUID: Double] = [:]
        for p in viewModel.leafPlugins(objectID: objectID) {
            l[p.id] = viewModel.pluginAudioLevel(objectID: objectID, pluginID: p.id)
        }
        levels = l
    }

    /// Polls the loading state of the external instances (built-ins ignored).
    private func refreshStates() {
        guard viewModel.chainPlugins(objectID) != nil else { return }   // an object OR a stem bus
        var st: [UUID: Int] = [:]
        var errs: [UUID: String] = [:]
        for p in viewModel.leafPlugins(objectID: objectID) where !p.isBuiltIn {
            let s = viewModel.pluginInstanceState(pluginID: p.id)
            st[p.id] = s
            if s == 3, let e = viewModel.pluginLoadError(pluginID: p.id) { errs[p.id] = e }
        }
        if st != instanceStates { instanceStates = st }
        if errs != loadErrors { loadErrors = errs }
    }
}

// MARK: - Presenting in a large window (comfortable editing)

struct SynopticEditorView: View {
    @Environment(\.dismiss) private var dismiss
    var viewModel: EditViewModel
    let objectID: UUID
    let title: String

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("synoptic.window.title", title)).font(.headline)
                Spacer()
                Button(L("common.close")) { dismiss() }
            }
            .padding(12)

            Divider()

            SynopticBoundView(viewModel: viewModel, objectID: objectID, scrolls: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            HStack(spacing: 12) {
                Text(L("synoptic.window.legend"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(8)
        }
        .frame(minWidth: 780, minHeight: 480)
    }
}

// MARK: - Demonstration sheet (phase A: made-up data, parallel active)

struct SynopticSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String

    @State private var root: SynopticNode = .demo
    @State private var selectedID: UUID? = nil

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("synoptic.demo.title", title)).font(.headline)
                Spacer()
                Button(L("common.close")) { dismiss() }
            }
            .padding(12)

            Divider()

            SynopticView(root: root, selectedID: $selectedID, actions: SynopticActions(
                onSelect: { selectedID = $0 },
                onToggleBypass: { root = root.togglingBypass($0) },
                onRemove: {
                    root = root.removingPluginAtRoot($0)
                    if selectedID == $0 { selectedID = nil }
                },
                onInsertSeries: { sid, idx in root = root.insertingPlaceholder(intoSeries: sid, atIndex: idx) },
                onBranch: { root = root.branching($0) }
            ))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            HStack(spacing: 12) {
                Text(L("synoptic.demo.legend"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L("common.reset")) { root = .demo; selectedID = nil }
                    .controlSize(.small)
            }
            .padding(8)
        }
        .frame(minWidth: 780, minHeight: 480)
    }
}

#Preview {
    SynopticSheet(title: "Demo")
}
