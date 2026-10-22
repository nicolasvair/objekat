import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

// MARK: - The signal view's actions
//
// The view is 'dumb': it renders a `SynopticNode` and delegates every mutation to
// these closures. They are wired either onto a mock (a local @State, the phase A demo),
// or onto `EditViewModel`/the engine (phase B — step 1: a real series).

/// Where in the signal view a plugin drag is aimed. A drop target knows only what it is laid on — a
/// cable (a series and an index), a card, a bin's header — and the bound view resolves it to a
/// `PluginDropSite` of the host's chain.
/// Where a send card is aimed in the signal view: a place of the chain (what a plugin is aimed at) or
/// one of the three fixed slots. The bound view resolves it to a `SendDropAim`.
enum SynopticSendTarget: Equatable {
    case place(SynopticDropTarget)
    case slot(SynopticSendSlot)
}

extension SynopticActions {
    /// Opens the "Send to…" menu at the mouse: for a NEW send taken at `slot`, or (`retargeting`) to change
    /// the target of that card's send. The data is read now, at the click.
    @MainActor
    func presentSendMenu(slot: SynopticSendSlot, retargeting: UUID? = nil) {
        guard let sections = sendTargetSections?(retargeting) else { return }
        SendTargetMenuPresenter.present(
            sections: sections,
            onPick: { aux in
                if let old = retargeting { onRetargetSend?(old, aux) } else { onCreateSend?(aux, slot) }
            },
            onChoose: { onPickSendTarget?(slot, retargeting) })
    }
}

enum SynopticDropTarget: Equatable {
    /// A cable or a '+': the series `seriesID`, at `index`.
    case series(UUID, Int)
    /// A card: just before it, in the series it sits in.
    case beforeCard(UUID)
    /// A bin's header: the end of the bin's block.
    case blockEnd(UUID)
}

struct SynopticActions {
    var onOpenEditor: ((UUID) -> Void)? = nil
    /// The double click on a card that belongs to a MULTIPLE selection: opens the editors of the
    /// whole selection (`clicked` decides open vs close). nil = falls back to `onOpenEditor`.
    var onOpenEditors: ((_ clicked: UUID, _ ids: Set<UUID>) -> Void)? = nil
    var onToggleBypass: (UUID) -> Void = { _ in }
    var onRemove: (UUID) -> Void = { _ in }
    var onInsertSeries: (_ seriesID: UUID, _ index: Int) -> Void = { _, _ in }
    /// A parallel branch: from a '+' (a drag down-right) or from a card's menu (@see SynopticBranchRequest;
    /// the receiver reads the selection). nil = parallel branching disabled (not routed).
    var onBranch: ((SynopticBranchRequest) -> Void)? = nil

    // Carried over from the chips (step 1.x):
    var instanceState: ((UUID) -> Int)? = nil       // 0 unknown · 1 loading · 2 ready · 3 error
    var loadError: ((UUID) -> String?)? = nil

    // The audio bridge (sidechain): a card's key, as one line (nil = none). The key is CHOSEN in the
    // plugin editor's Sidechain strip (@see SidechainStripView), not from the card.
    var sidechainBadge: ((UUID) -> SidechainBadge?)? = nil

    // The width of a plugin's main bus (mono / mono→stereo / stereo): the "Channels" submenu of a card.
    // `channelMenu` answers nil for a card that has none (a built-in, an instrument, a gain stage, the demo);
    // `onSetChannelVariant` carries out a choice (the view-model refuses it with a reason, and the view
    // beeps). @see EditViewModel.channelMenuState / setChannelVariant.
    var channelMenu: ((UUID) -> ChannelMenuState?)? = nil
    var onSetChannelVariant: ((_ plugin: UUID, _ variant: ChannelVariant) -> Void)? = nil
    /// The right click on a STEREO cable (any cable point of the chain): the channels the cable carries on —
    /// Stereo (no choice), Left, Right or Sum (@see CableChoice, SynopticWidthFlow.menuAt). nil = no menu on
    /// the wires.
    var onSetCableChannels: ((_ point: CablePoint, _ choice: CableChoice) -> Void)? = nil

    // Dragging a card (towards the timeline = move/copy/link; towards a '+' = reorder).
    var dragProvider: ((UUID) -> NSItemProvider)? = nil
    // What a release at `target` would do with the drag in flight, for the cursor and the band
    // (@see PluginDropOutcome). nil = no drag in flight to answer for → the legacy reading.
    var dropOutcome: ((_ target: SynopticDropTarget, _ flags: NSEvent.ModifierFlags) -> PluginDropOutcome?)? = nil
    // A plugin (or a whole bin's block) let go at `target`: the view-model resolves it and carries it out —
    // reorder, move, copy, join a bin, leave one. nil = the view does not receive (the demo).
    var onDrop: ((_ target: SynopticDropTarget, _ payload: PluginDragPayload, _ flags: NSEvent.ModifierFlags) -> Void)? = nil

    // The dB gain at the end of a parallel branch (drag ↑/↓).
    var onSetVoiceGain: ((_ blockID: UUID, _ voiceIndex: Int, _ dB: Float) -> Void)? = nil
    // Removing a parallel branch (along with its gain).
    var onRemoveVoice: ((_ blockID: UUID, _ voiceIndex: Int) -> Void)? = nil
    // Muting a parallel branch (listen to one / the other / both; no solo).
    var onSetVoiceMute: ((_ blockID: UUID, _ voiceIndex: Int, _ muted: Bool) -> Void)? = nil
    // The start of a gain drag (a parallel branch's gain, a gain stage's box): push an undo point,
    // the same convention as onBeginMixEdit / onBeginSpeedEdit.
    var onBeginGainEdit: (() -> Void)? = nil

    // MIDI zone (a MIDI clip): the instrument at the head of the chain.
    var onAddInstrument: (() -> Void)? = nil           // the '+' of an empty MIDI zone
    var onRemoveInstrument: (() -> Void)? = nil
    var onOpenInstrumentEditor: (() -> Void)? = nil
    // Bypassing the instrument — an action separate from `onToggleBypass`: the instrument does
    // not live in the model's FX chain but in `instruments` (@see toggleInstrumentEnabled).
    var onToggleInstrumentBypass: (() -> Void)? = nil

    // The 'audio file' zone (an audio clip): speed / semitones / bpm.
    var onSetSpeed: ((Double) -> Void)? = nil          // the new speed ratio
    var onSetBaseBPM: ((Double?) -> Void)? = nil       // the base bpm (nil = clear)
    var onToggleReverse: (() -> Void)? = nil
    var onToggleLoop: (() -> Void)? = nil
    /// The right click on the wire that leaves a stereo audio file: which of its channels the chain gets
    /// (both, left, right, their sum — the file's `ChannelMode`). nil = no menu on that wire.
    var onSetSourceChannels: ((SourceChannelChoice) -> Void)? = nil
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

    // The 'stems' zone (output): assigning the stem.
    var onAssignStem: ((UUID) -> Void)? = nil

    // The 'sends' zone (the foot): the level / on-off of a departure towards an aux. `id` = the
    // target aux for a departure, the sending object for a received send (an aux's head).
    var onSetSendLevel: ((UUID, Float) -> Void)? = nil
    var onToggleSend: ((UUID) -> Void)? = nil
    var onBeginSendEdit: (() -> Void)? = nil
    /// A send card's ✕ / menu "Delete": removes the send of that aux (its marker goes with it).
    var onRemoveSend: ((UUID) -> Void)? = nil
    /// A send card's menu "Fold to post-fader": moves the send of that aux to a slot (undoable).
    var onMoveSend: ((_ aux: UUID, _ slot: SynopticSendSlot) -> Void)? = nil
    /// The card of the send towards `aux` is taken in the hand (nil = cards are not draggable).
    var sendDragProvider: ((UUID) -> NSItemProvider)? = nil
    /// The sections of the "Send to…" menu for this object (`retargeting`: the aux of the card whose target is
    /// being changed, left out). Asked when the menu is OPENED, never while rendering.
    var sendTargetSections: ((_ retargeting: UUID?) -> [SendTargetMenu.Section])? = nil
    /// A menu entry: make the send towards `aux` at `slot`.
    var onCreateSend: ((_ aux: UUID, _ slot: SynopticSendSlot) -> Void)? = nil
    /// "Choose an object on the timeline…": arms the pick for a send at `slot` (or re-aims `retargeting`).
    var onPickSendTarget: ((_ slot: SynopticSendSlot, _ retargeting: UUID?) -> Void)? = nil
    /// "Change target…": re-aims the send towards `old` at `new`.
    var onRetargetSend: ((_ old: UUID, _ new: UUID) -> Void)? = nil
    /// A send card let go at `target` (a place of the chain or one of the three fixed slots).
    var onSendDrop: ((_ target: SynopticSendTarget, _ payload: SendDragPayload) -> Void)? = nil
    /// What a send card let go at `target` would do, for the cursor and the band (@see SendDrop). nil = no
    /// send in flight to answer for.
    var sendDropOutcome: ((_ target: SynopticSendTarget) -> PluginDropOutcome?)? = nil

    // The plugins ON a send (INC 3): the cards of its column. Every closure names the send by its AUX (the
    // line's id); the plugin by its own id. The chain behind them is a chain host like any other
    // (@see SendChain.hostID), so these are the trunk's gestures aimed at another host.
    /// The selected cards of that send (empty when the plugin selection is elsewhere).
    var sendPluginSelection: ((_ aux: UUID) -> Set<UUID>)? = nil
    /// A click on a card: plain = that card alone, ⌘ = toggle it, ⇧ = extend, inside the send's chain.
    var onSendPluginClick: ((_ aux: UUID, _ plugin: UUID, _ flags: NSEvent.ModifierFlags) -> Void)? = nil
    /// A double click on a card's name: its editor (open / close).
    var onSendPluginOpen: ((_ aux: UUID, _ plugin: UUID) -> Void)? = nil
    /// The card's dot (bypass) and its cross: a card IN the selection speaks for the whole selection.
    var onSendPluginToggle: ((_ aux: UUID, _ plugin: UUID) -> Void)? = nil
    var onSendPluginRemove: ((_ aux: UUID, _ plugin: UUID) -> Void)? = nil
    /// A click on a '+' of the send's mini-chain (`index` = where the plugin goes) and the line's menu entry
    /// (`index` nil = the end): the plugin picker, aimed at that send.
    var onSendPluginAdd: ((_ aux: UUID, _ index: Int?) -> Void)? = nil
    /// A card taken in the hand (nil = the cards are not draggable).
    var sendPluginDragProvider: ((_ aux: UUID, _ plugin: UUID) -> NSItemProvider)? = nil
    /// What the drag in flight would do let go on that send's column at insertion slot `index` (counted from
    /// the top). nil = no drag in flight to answer for.
    var sendBoxDropOutcome: ((_ aux: UUID, _ index: Int, _ flags: NSEvent.ModifierFlags) -> PluginDropOutcome?)? = nil
    /// A plugin let go on that send's column at slot `index`. nil = the columns do not receive (the demo).
    var onSendBoxDrop: ((_ aux: UUID, _ index: Int, _ payload: PluginDragPayload, _ flags: NSEvent.ModifierFlags) -> Void)? = nil

    // A bus's chain head: the 'infinite' toggle (a top-level aux / group).
    var onToggleInfinite: (() -> Void)? = nil

    // FX links (a bin's block). Every closure that takes a UUID takes the BLOCK's id.
    /// The common on/off of the block.
    var onFXToggleEnabled: ((UUID) -> Void)? = nil
    var onFXRename: ((UUID, String) -> Void)? = nil
    /// "Next colour" of the header's right-click menu: the next colour of the palette.
    var onFXCycleColor: ((UUID) -> Void)? = nil
    /// Detach / reattach (the same button: the state says which).
    var onFXToggleDetach: ((UUID) -> Void)? = nil
    /// Leave the bin and keep the plugins as plain, independent ones.
    var onFXRelease: ((UUID) -> Void)? = nil
    /// Drop the block and its plugins from THIS host.
    var onFXRemove: ((UUID) -> Void)? = nil
    /// Dissolve the bin on every host.
    var onFXDelete: ((UUID) -> Void)? = nil
    /// Right click → 'Create an FX link' from these plugins (nil = never offered).
    var canCreateFXLink: (([UUID]) -> Bool)? = nil
    var onCreateFXLink: (([UUID]) -> Void)? = nil
    /// The bins this host does not hold yet, and joining one.
    var joinableFXLinks: (() -> [(id: UUID, name: String)])? = nil
    var onJoinFXLink: ((UUID) -> Void)? = nil

    /// A double click on the content pill of a consolidated instance: open its content, or validate
    /// it when it is open.
    var onToggleContent: (() -> Void)? = nil

    /// The ARA source of the object this view shows (Melodyne): open its editor / take it off.
    var onOpenARAEditor: (() -> Void)? = nil
    var onRemoveARA: (() -> Void)? = nil
    /// The power button of the ARA card: the source plays / the object plays its dry file. Not a
    /// plugin bypass (@see `EditViewModel.setARAEnabled`): the source is unloaded while it is off.
    var onToggleARABypass: (() -> Void)? = nil

    // MARK: Wave 2 of the signal view rework (docs/plan_synoptic_rework.md, contract laid by L2)
    //
    // All optional, nil by default: a view that finds one nil offers nothing for it. How a gesture on a
    // '+' reaches them is decided by the layout (@see SynopticPlusCommand, which names the closure each
    // command goes to); the existing `onInsertSeries`, `onBranch`, `onSendPluginAdd` and
    // `presentSendMenu(slot:)` carry the click, the branch and the send.

    /// A gain stage asked for by a drag out of a '+' of a series (the trunk, a parallel's branch, a bin's
    /// series — a bin's joins its DEFINITION): insert it at `index` of `seriesID`. `result` is `.gain` or
    /// `.gainPanMute` (the face); any other value is ignored. One undo point.
    var onPlusGesture: ((_ seriesID: UUID, _ index: Int, _ result: PlusGestureResult) -> Void)? = nil
    /// The same, out of the "+" of a send's mini-chain (`aux` = the send's id): a gain stage on the send.
    var onSendPlusGesture: ((_ aux: UUID, _ index: Int, _ result: PlusGestureResult) -> Void)? = nil
    /// A direction the user bound to a plugin (@see PlusShortcutMap), dragged out of a '+' of a series: insert
    /// that plugin at `index` of `seriesID`, as the browser would. One undo point.
    var onPlusInsertPlugin: ((_ seriesID: UUID, _ index: Int, _ plugin: PlusPluginRef) -> Void)? = nil
    /// A direction the user bound to a colour category (@see PlusAction.category): open the plugin browser on
    /// that colour's tab, the plugin chosen there inserted at `key` (a series' or a send's mini-chain "+").
    var onOpenBrowserInCategory: ((_ key: SynopticPlusKey, _ category: Int) -> Void)? = nil
    /// `onPlusInsertPlugin`'s counterpart, out of the "+" of a send's mini-chain (`aux` = the send's id).
    var onSendPlusInsertPlugin: ((_ aux: UUID, _ index: Int, _ plugin: PlusPluginRef) -> Void)? = nil
    /// Whether a plugin a direction is bound to is installed and insertable (nil = assume it is). One that is
    /// not keeps its zone, greyed, and its drag does nothing.
    var plusPluginInstalled: ((_ plugin: PlusPluginRef) -> Bool)? = nil
    /// A gain stage's card sets its values (nil = left as it is): gain in dB (±24), pan (−1…1), mute.
    /// The undo point is the caller's at the drag's start (`onBeginGainEdit`).
    var onSetGainStage: ((_ pluginID: UUID, _ gainDb: Float?, _ pan: Float?, _ muted: Bool?) -> Void)? = nil
    /// A gain stage's current values, read from the engine (nil = unknown: the card shows a dash).
    var gainStageValues: ((_ pluginID: UUID) -> SynopticGainStageValues?)? = nil
    /// The audio zone's fold (a double click on the zone, its chevron): @see SynopticUIState.
    var onToggleClipOptions: (() -> Void)? = nil
    /// An FX link block's fold (a double click on its header, its chevron): @see SynopticUIState.
    var onToggleFXFold: ((_ blockID: UUID) -> Void)? = nil
    /// Starts the inline renaming of an FX link block (⌘R, the header's menu): @see
    /// SynopticUIState.renamingFXLinkID. The name itself is committed through `onFXRename`.
    var onRenameFXLink: ((_ blockID: UUID) -> Void)? = nil
}

/// The values of a gain stage, as its card shows them (@see SynopticActions.gainStageValues).
struct SynopticGainStageValues: Equatable {
    var gainDb: Float
    var pan: Float = 0
    var muted: Bool = false
    /// A curve drives the parameter: its box is greyed, the hand does not move it.
    var gainAutomated: Bool = false
    var panAutomated: Bool = false
    var muteAutomated: Bool = false
}

/// The ARA source an audio object plays THROUGH. It is drawn as a CARD, the first one out of the 'audio file'
/// frame (@see SynopticLayout.Diagram.araCard); the frame itself only needs to know it is there, to lock the
/// speed / reverse / loop controls.
struct SynopticARA: Equatable {
    var name: String
    /// The plugin is still analysing the audio (a spinner on the card, and the editor cannot be opened yet).
    var analysing: Bool
    /// False = the source is switched off: the object plays its dry file, the card is dimmed with a grey
    /// power button, and the editor cannot be opened (there is no instance).
    var isEnabled: Bool = true
    /// The source's identity colour, like any plugin card's halo.
    var color: Color = .gray
}

/// The data of the 'audio file' zone (an audio clip), carried over into the signal view.
struct SynopticAudioFile: Equatable {
    var speedRatio: Double
    var baseBPM: Double?
    var isReversed: Bool
    /// True ⇒ the content repeats for as long as the object's window exceeds its source range.
    var isLooping: Bool
    /// Non-nil ⇒ the source is a STEREO file (exactly two channels) whose channels can be chosen: the
    /// current choice, chosen by a right click on the wire that leaves the file (request of 20 October 2026:
    /// the zone's LR / L / R / C selector is gone). nil for a mono file (or one that cannot be read).
    var channelMode: ChannelMode? = nil
    /// Non-nil ⇒ the object carries an ARA source: its card hangs under the zone, and the time
    /// controls (speed, reverse, loop) are locked — an ARA source needs speed 1, forward, no loop.
    var ara: SynopticARA? = nil
}

/// A setting of the 'audio file' zone that the FOLDED zone hides and that is not neutral: the folded row
/// shows a pill for each (§B.7). Order = the pills' order.
enum SynopticHiddenSetting: Equatable {
    /// The speed is not 1 and no base tempo is set: shown as semitones (`−3 st`) or a ratio (`×1.07`).
    case pitch(semitones: Double, ratio: Double)
    /// A base tempo is set and the speed is not 1: the object is stretched to `targetBPM` (`→ 120`).
    case tempo(targetBPM: Double)
}

extension SynopticAudioFile {
    /// The hidden settings that are not neutral, for the folded zone's pills (empty = no pill).
    var hiddenNonNeutralSettings: [SynopticHiddenSetting] {
        var out: [SynopticHiddenSetting] = []
        let ratio = speedRatio
        if abs(ratio - 1) > 1e-6 {
            if let base = baseBPM, base > 0 {
                out.append(.tempo(targetBPM: base * ratio))
            } else {
                out.append(.pitch(semitones: 12 * log2(max(1e-6, ratio)), ratio: ratio))
            }
        }
        return out
    }
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
}

/// A stem badge ('stems' zone) carried over into the signal view.
struct SynopticStem: Identifiable, Equatable {
    let id: UUID
    let name: String
    let color: Color
    let isCurrent: Bool
}

/// A bus's 'infinite' option (a top-level aux / group), carried by the chain's head.
struct SynopticInfinite: Equatable {
    let isOn: Bool
    /// 'aux' / 'group' — used in the tooltip.
    let kindLabel: String
}

/// The CONTENT pill of a consolidated instance: the shared content it reads, by the definition's name.
/// `isOpen`: the instance is being edited (its stage is open) — a double click then validates it.
struct SynopticContentPill: Equatable {
    let name: String
    let isOpen: Bool
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
    /// fault: we grey it out, like the FX of a closed consolidated object just above.
    @ViewBuilder
    func automationLocked(_ locked: Bool) -> some View {
        if locked {
            // The fading says 'this no longer answers', the glyph says why — kept BRIGHT, as on the
            // timeline's send knob (a reason as dim as the thing it explains explains nothing).
            self.disabled(true)
                .opacity(0.4)
                .overlay(alignment: .topTrailing) {
                    Image(systemName: FeatureIcons.automated)
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white.opacity(0.9))
                        .offset(x: 3, y: -3)
                        .allowsHitTesting(false)
                }
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

    /// Applies `.onDrag` only if a provider is supplied (otherwise it leaves the view untouched).
    @ViewBuilder
    func onDragIf(_ provider: (() -> NSItemProvider)?) -> some View {
        if let provider { self.onDrag(provider) } else { self }
    }

    /// Same as `onDragIf(_:)`, with a custom drag image instead of AppKit's default "grabbed
    /// view" snapshot — used by a plugin card, whose default preview (the bare name, cropped to
    /// its label's own frame) said nothing about what dropping it does.
    @ViewBuilder
    func onDragIf<Preview: View>(_ provider: (() -> NSItemProvider)?,
                                  @ViewBuilder preview: () -> Preview) -> some View {
        if let provider { self.onDrag(provider, preview: preview) } else { self }
    }
}
