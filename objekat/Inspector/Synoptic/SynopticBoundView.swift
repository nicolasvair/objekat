import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

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
    // `category`: the colour tab the browser opens on (a '+' direction bound to a category); nil = "All".
    case insert(location: SeriesLocation, index: Int, category: Int? = nil)   // a series '+' inside a target series
    case instrument                                      // the '+' of the instruments zone (a MIDI clip)
    case insertSend(aux: UUID, index: Int?, category: Int? = nil)   // a '+' of a send's mini-chain (INC 3); nil = its end

    var id: String {
        switch self {
        case .insert(let loc, let i, _): return "insert-\(loc.key)-\(i)"
        case .instrument:             return "instrument"
        case .insertSend(let aux, let i, _): return "insertSend-\(aux.uuidString)-\(i.map(String.init) ?? "end")"
        }
    }
}

struct SynopticBoundView: View {
    var viewModel: EditViewModel
    let objectID: UUID
    var scrolls: Bool = true

    /// The instrument card's highlight only — the FX selection lives in the view-model, since
    /// every gesture that acts on several cards needs the chain (@see pluginSelection).
    @State private var selectedInstrumentID: UUID? = nil
    @State private var activeSheet: SynopticSheetKind? = nil
    @State private var pickerSearch: String = ""
    // The live state of the external instances (loading/ready/error), refreshed by a timer.
    @State private var instanceStates: [UUID: Int] = [:]
    @State private var loadErrors: [UUID: String] = [:]
    // The plugin cards' VU levels (0..1). A STORE of its own, read only by `SynopticCardVULine`s (through
    // the environment): this view never reads it in its `body`, so a refresh moves the 2-pt lines and
    // does not rebuild the synoptic (SynopticMapping.build, the layout, every card).
    @State private var levelStore = SynopticLevelStore()
    // This view's name in the engine's meter registry (the union of every open synoptic is measured).
    @State private var meterOwner = UUID()
    // On screen: the VU poll runs only then, and the engine measures only what is registered.
    @State private var isOnScreen = false
    // The ARA source of this object is still analysing (polled with the instance states).
    @State private var araAnalysing = false
    // The main bus of every external plugin of the chain (loaded instances only), polled with the states and
    // written ONLY when it changes: the widths along the chain are derived from it in `body`, never per frame.
    @State private var channelCounts: [UUID: PluginChannels] = [:]
    // An aux: the senders listed at the head (the sends it receives). A STICKY list — a row taken
    // down to -∞ stays shown until the selection changes, otherwise it would vanish mid-drag
    // (activeSenders filters silent sends out) and SwiftUI would re-associate the gesture with a neighbour.
    @State private var receivedIDs: [UUID] = []
    private let poll = Timer.publish(every: 0.6, on: .main, in: .common).autoconnect()
    /// The VU poll's period: 30 Hz (it was 0.07 s when the levels were a `@State` of this view).
    private static let vuInterval: TimeInterval = 1.0 / 30.0
    private let vuPoll = Timer.publish(every: SynopticBoundView.vuInterval, on: .main, in: .common).autoconnect()

    var body: some View {
        // Builds the graph plus the seriesID→location table from the real model. The closures below
        // capture `locations` from THIS build (consistent with the series ids being rendered).
        // The host = a timeline object OR a stem/master bus (INC 2). `obj` is nil for a bus:
        // a bus has neither a MIDI clip nor an instrument → isMIDI=false, midiInstrument=nil.
        let obj = viewModel.find(id: objectID)
        let model = viewModel.chainPlugins(objectID) ?? []
        let (root, locations) = SynopticMapping.build(model, objectID: objectID,
                                                       fxLinkInfo: { viewModel.synopticFXInfo($0) })

        let instLeaf = obj?.instruments.first.map { SynopticMapping.leaf($0) }
        // What this view asks the engine to measure: every card's plugin (gain stages included) and the
        // instrument. Compared by value, so the registration follows the chain, not each render.
        let meteredIDs = meteredPluginIDs()

        // The width the chain is fed with and what becomes of it along the chain (the file's channel choice, each
        // plugin's fold, every pick written on a cable) — ONE computation, shared with the command API
        // (@see EditViewModel.widthFlow), over the polled bus counts so it follows the chain.
        let widthFlow = viewModel.widthFlow(host: objectID, root: root, channels: channelCounts)

        // The 'audio file' zone: audio clips only (MIDI clips keep their MIDI zone;
        // groups / auxes keep the Source pill).
        // A consolidated INSTANCE has none: it reads a wave the app baked, which has neither a speed
        // choice of its own nor a channel choice nor an ARA source — its source is the content pill.
        let isInstance = obj?.isConsolidateInstance ?? false
        let audioFile: SynopticAudioFile? = ((obj?.isClip ?? false) && !isInstance)
            ? obj.map { SynopticAudioFile(speedRatio: $0.speedRatio, baseBPM: $0.baseBPM, isReversed: $0.isReversed, isLooping: $0.loopEnabled,
                                                       channelMode: viewModel.canChooseChannelMode($0) ? $0.channelMode : nil,
                                                       ara: $0.araSource.map { SynopticARA(name: $0.plugin.name, analysing: araAnalysing,
                                                                                        isEnabled: $0.plugin.isEnabled, color: $0.plugin.color) }) }
            : nil

        // The 'clip' zone (the output mix): for any real object (not a bus). The title depends on the type.
        let mix: SynopticMix? = obj.map { o in
            // The content root of an open consolidated object: its fader is the CONTENT's, shared by every
            // instance (@see ConsolidateEditSession.contentRootID).
            let title = L(viewModel.sessionContentRootIDs.contains(o.id) ? "synoptic.mix.kind.content"
                        : (o.isGroup ? "synoptic.mix.kind.group"
                        : (o.isAux ? "synoptic.mix.kind.aux" : "synoptic.mix.kind.clip")))
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
                               panAutomated:    viewModel.isAutomated(.pan, on: o))
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

        // Sends: the departures that EXIST are cards beside the trunk (Q-U7, Q-U13), each at the slot its
        // position names; the reachable auxes without a send are reached through "Send to…". A card whose
        // aux no longer overlaps the object in time, or that the scope refuses, stays — greyed, with the
        // reason (Q-U15): moving an object never makes a send vanish from the chain. An aux shows at its
        // HEAD what it receives.
        let canSend = obj != nil && !(obj?.isAux ?? true)
        let sends: [SynopticSend] = canSend ? (obj?.sends ?? []).compactMap { snd in
            guard let aux = viewModel.find(id: snd.auxID) else { return nil }
            return SynopticSend(id: snd.auxID, name: aux.displayName,
                                enabled: snd.enabled, levelDb: snd.levelDb,
                                isAutomated: viewModel.isAutomated(.send(auxID: snd.auxID), on: objectID),
                                refusal: viewModel.sendCardRefusalText(from: objectID, to: snd.auxID),
                                slot: EditViewModel.synopticSlot(obj?.sendPosition(auxID: snd.auxID)),
                                plugins: snd.plugins.map(sendPlugin))
        } : []
        let received: [SynopticSend] = (obj?.isAux ?? false)
            ? receivedIDs.compactMap { sid in
                viewModel.find(id: sid).map { sender in
                    SynopticSend(id: sid, name: sender.displayName,
                                 enabled: viewModel.isSendEnabled(from: sid, to: objectID),
                                 levelDb: viewModel.sendLevel(from: sid, to: objectID),
                                 // A send lives on the SENDER: it is ITS curve we read, even
                                 // if the row is shown at the head of the receiving aux.
                                 isAutomated: viewModel.isAutomated(.send(auxID: objectID), on: sender),
                                 refusal: { if case .refused(let why) = viewModel.sendStatus(from: sid, to: objectID) {
                                                return EditViewModel.sendReasonText(why) } else { return nil } }(),
                                 slot: EditViewModel.synopticSlot(sender.sendPosition(auxID: objectID)),
                                 // Only their presence is shown at the aux's head (a mark on the row).
                                 plugins: (sender.sends.first { $0.auxID == objectID }?.plugins ?? [])
                                    .map(sendPlugin))
                }
              }
            : []

        // The 'infinite' option: carried by the chain head of top-level auxes / groups.
        let infinite: SynopticInfinite? = obj.flatMap { o in
            guard !isInstance, o.canBeInfinite, viewModel.items.contains(where: { $0.id == o.id }) else { return nil }
            return SynopticInfinite(isOn: o.isInfinite, kindLabel: o.isAux ? L("synoptic.infinite.kind.aux") : L("synoptic.infinite.kind.group"))
        }
        // Looping: a group (the chain head) or a MIDI clip (the MIDI zone) — audio has its own
        // badge in `audioFile`. No top-level restriction here, unlike `infinite`.
        let loop: SynopticLoop? = obj.flatMap { o in
            !isInstance && (o.isGroup || o.isMIDI) && o.canLoop ? SynopticLoop(isOn: o.loopEnabled) : nil
        }

        // A drop target's aim, as a place of THIS host's chain: the table of series ids is the one of the
        // build being rendered, and a card's place is looked up in the model as it is now.
        let dropSite: (SynopticDropTarget) -> PluginDropSite? = { target in
            switch target {
            case .series(let seriesID, let index):
                return locations[seriesID].map { .series($0, index: index) }
            case .beforeCard(let cardID):
                return EditViewModel.locate(cardID, in: model).map { .series($0.0, index: $0.1) }
            case .blockEnd(let blockID):
                return EditViewModel.findBlock(blockID, in: model)?.fxBlock
                    .map { .series(.block(blockID: blockID), index: $0.plugins.filter { !$0.isChannelPick }.count) }
            }
        }

        // A send card in the hand (@see SendDrop): where it is aimed, as the pure table reads it, and what a
        // release there would do. A place of the chain is the trunk only if it is of the ROOT series.
        let sendAim: (SynopticSendTarget) -> SendDropAim = { t in
            switch t {
            case .slot(let slot): return .slot(slot)
            case .place(let target):
                guard case .series(let loc, let index)? = dropSite(target) else { return .elsewhere }
                switch loc {
                case .root:  return .trunk(index: index)
                case .voice: return .parallelBranch
                case .block: return .fxBlock
                }
            }
        }
        // The trunk's top-level entries as the view counts them (a send's marker is not one): its head '+'
        // is the input slot and its tail '+' the pre-fader one (@see SendDrop.decide(_:trunkCount:)).
        let trunkCount = model.filter { !$0.isChainMarker }.count
        let sendOutcome: (SynopticSendTarget) -> PluginDropOutcome? = { t in
            guard let payload = SendDragSession.shared.current else { return nil }
            if payload.sendSender != objectID { return .sendRefused(.refusedElsewhere) }
            switch SendDrop.decide(sendAim(t), trunkCount: trunkCount) {
            case .move(_, let line): return .sendTaken(line)
            case .refuse(let line):  return .sendRefused(line)
            }
        }

        return SynopticView(root: root, selection: pluginSelection,
                            selectedInstrumentID: $selectedInstrumentID, scrolls: scrolls,
                            // The object's frame takes the block's own colour (§B.5, D7); a bus has none.
                            frameColor: obj.map { $0.customColor ?? viewModel.stemColor(for: $0.id) },
                            isMIDI: obj?.isMIDI ?? false, midiInstrument: instLeaf,
                            audioFile: audioFile, mix: mix, stems: stems,
                            groupRouting: groupRouting,
                            sends: sends, canSend: canSend, receivedSends: received, infinite: infinite, loop: loop,
                            // A consolidated instance, closed or open: its own FX are editable (they are the
                            // instance's, never baked); the source is the shared content.
                            contentPill: obj.flatMap { o in
                                guard let defID = o.consolidateID else { return nil }
                                return SynopticContentPill(
                                    name: viewModel.consolidateDefinitions[defID]?.name ?? o.displayName,
                                    isOpen: viewModel.isInConsolidateEditStack(o.id))
                            },
                            widthFlow: widthFlow,
                            actions: SynopticActions(
            onOpenEditor: { openEditor($0) },
            onOpenEditors: { openEditors(clicked: $0, ids: $1) },
            // The power button of a card that is IN the selection speaks for the WHOLE selection;
            // one outside it speaks for itself alone. The same rule as the drag just below and as
            // the clips before it: what you GRAB is what decides. Without this the batch on/off
            // existed in the model and in the API and was unreachable from the hand.
            onToggleBypass: { id in
                if pluginSelection.wrappedValue.contains(id) {
                    viewModel.toggleSelectedPluginsEnabled()
                } else {
                    viewModel.togglePluginEnabled(objectID: objectID, pluginID: id)
                }
            },
            // Same rule for the ✕: it takes the selection when the card clicked is part of it,
            // in ONE undo step, and that card alone otherwise.
            onRemove: { id in
                if pluginSelection.wrappedValue.contains(id) {
                    viewModel.removeSelectedPlugins()
                } else {
                    viewModel.removePlugin(objectID: objectID, pluginID: id)
                }
            },
            onInsertSeries: { seriesID, index in
                if let loc = locations[seriesID] { activeSheet = .insert(location: loc, index: index) }
            },
            // A parallel branch (§B.2): the selection of THIS host decides the run (@see SynopticBranchRun).
            onBranch: { request in
                let selected = pluginSelection.wrappedValue
                let made: [UUID]?
                switch request {
                case .plus(let seriesID, let index):
                    guard let loc = locations[seriesID] else { return }
                    made = viewModel.synopticBranch(objectID: objectID, location: loc, at: index, selection: selected)
                case .plugin(let id):
                    made = viewModel.synopticBranch(objectID: objectID, pluginID: id, selection: selected)
                }
                if made == nil { NSSound.beep() }
            },
            instanceState: { instanceStates[$0] ?? 0 },
            loadError: { loadErrors[$0] },
            onUnlink: { viewModel.unlinkPlugin(objectID: objectID, pluginID: $0) },
            onRelink: { viewModel.relinkPlugin(objectID: objectID, pluginID: $0) },
            linkSiblingCount: { viewModel.linkSiblings(of: $0).count },
            sidechainBadge: { viewModel.sidechainBadge(plugin: $0, host: objectID) },
            channelMenu: { viewModel.channelMenuState(pluginID: $0, host: objectID) },
            onSetChannelVariant: { viewModel.setChannelVariantFromHand($1, pluginID: $0, host: objectID) },
            onSetMonoFold: { viewModel.setMonoFold($1, pluginID: $0, host: objectID) },
            dragProvider: { dragProvider($0) },
            dropOutcome: { target, flags in
                // A send card in the hand is answered by the send table (a plugin never is one).
                if SendDragSession.shared.current != nil { return sendOutcome(.place(target)) }
                // The drag in flight says what it carries (@see PluginDragSession); with none to read,
                // the target falls back on its legacy reading.
                guard let payload = PluginDragSession.shared.current else { return nil }
                if case .beforeCard(let id) = target, payload.ids.contains(id) { return .refuse("dropped on itself") }
                guard let site = dropSite(target) else { return .refuse("no such place in the chain") }
                return viewModel.pluginDropOutcome(payload, toHost: objectID, at: site, flags: flags)
            },
            onDrop: { target, payload, flags in
                if case .beforeCard(let id) = target, payload.ids.contains(id) { return }
                guard let site = dropSite(target) else { return }
                viewModel.synopticDrop(payload, host: objectID, at: site, flags: flags)
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
            onBeginGainEdit: { viewModel.pushUndo() },
            onAddInstrument: { activeSheet = .instrument },
            onRemoveInstrument: {
                let instID = obj?.instruments.first?.id
                viewModel.removeInstrument(objectID: objectID)
                if let instID, selectedInstrumentID == instID { selectedInstrumentID = nil }
            },
            onOpenInstrumentEditor: { if let id = obj?.instruments.first?.id { openEditor(id) } },
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
            onSetSourceChannels: { viewModel.setChannelMode(id: objectID, mode: Self.channelMode($0)) },
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
            // A HAND's door, not `updatePan`: the pan lands on its tenth (@see EditViewModel+Pan).
            onSetPan: { viewModel.setPanFromHand(id: objectID, pan: $0) },
            onToggleMute: { viewModel.edit { viewModel.toggleMute(id: objectID) } },
            // Solo is a session listening state, outside the model and outside undo (@see
            // EditViewModel+Solo): no `edit {}`, no undo point, like a stem's mute — otherwise ⌘Z
            // would replay auditions instead of undoing edits.
            onToggleSolo: { viewModel.toggleSoloHold(objectID: objectID) },
            onBeginMixEdit: { viewModel.pushUndo() },
            onAssignStem: { stemID in viewModel.edit { viewModel.assignStem(objectID: objectID, stemID: stemID) } },
            // An aux lists the sends it RECEIVES: the row carries the SENDER's id, and so it is the
            // sender we set (sender → this aux). Otherwise we set this object → the target aux.
            onSetSendLevel: { rowID, db in
                let isAux = viewModel.find(id: objectID)?.isAux ?? false
                let from = isAux ? rowID : objectID
                let to   = isAux ? objectID : rowID
                guard viewModel.handMayCreateSend(from: from, to: to) else { return }
                viewModel.setSendLevel(from: from, to: to, levelDb: db)
            },
            onToggleSend: { rowID in
                let isAux = viewModel.find(id: objectID)?.isAux ?? false
                let from = isAux ? rowID : objectID
                let to   = isAux ? objectID : rowID
                guard viewModel.isSendEnabled(from: from, to: to) || viewModel.handMayCreateSend(from: from, to: to) else { return }
                viewModel.edit {
                    viewModel.setSendEnabled(from: from, to: to,
                                             enabled: !viewModel.isSendEnabled(from: from, to: to))
                }
            },
            onBeginSendEdit: { viewModel.pushUndo() },
            onRemoveSend: { auxID in viewModel.edit { viewModel.removeSend(from: objectID, to: auxID) } },
            onMoveSend: { auxID, slot in
                viewModel.setSendPositionFromHand(from: objectID, to: auxID, EditViewModel.sendPosition(of: slot))
            },
            sendDragProvider: { sendDragProvider($0) },
            sendTargetSections: { viewModel.sendTargetSections(for: objectID, retargeting: $0) },
            onCreateSend: { aux, slot in
                viewModel.createSendFromHand(from: objectID, to: aux, at: EditViewModel.sendPosition(of: slot))
            },
            onPickSendTarget: { slot, retargeting in
                viewModel.beginSendPick(sender: objectID, position: EditViewModel.sendPosition(of: slot),
                                        retargeting: retargeting)
            },
            onRetargetSend: { old, new in viewModel.retargetSendFromHand(from: objectID, aux: old, to: new) },
            onSendDrop: { target, payload in
                guard payload.sendSender == objectID,
                      case .move(let slot, _) = SendDrop.decide(sendAim(target), trunkCount: trunkCount) else { return }
                viewModel.setSendPositionFromHand(from: objectID, to: payload.sendAux,
                                                  EditViewModel.sendPosition(of: slot))
            },
            sendDropOutcome: { sendOutcome($0) },
            // The plugins ON a send: the trunk's gestures, aimed at the send's own chain host.
            sendPluginSelection: { aux in
                viewModel.selectedPluginHostID == sendHost(aux) ? viewModel.selectedPluginIDs : []
            },
            onSendPluginClick: { aux, id, flags in clickSendPlugin(aux: aux, id: id, flags: flags) },
            onSendPluginOpen: { aux, id in openSendPluginEditor(aux: aux, id: id) },
            // A row IN the selection speaks for the whole selection (the trunk's rule).
            onSendPluginToggle: { aux, id in
                let host = sendHost(aux)
                if viewModel.selectedPluginHostID == host, viewModel.selectedPluginIDs.contains(id) {
                    viewModel.toggleSelectedPluginsEnabled()
                } else {
                    viewModel.togglePluginEnabled(objectID: host, pluginID: id)
                }
            },
            onSendPluginRemove: { aux, id in
                let host = sendHost(aux)
                if viewModel.selectedPluginHostID == host, viewModel.selectedPluginIDs.contains(id) {
                    viewModel.removeSelectedPlugins()
                } else {
                    viewModel.removePlugin(objectID: host, pluginID: id)
                }
            },
            onSendPluginAdd: { aux, index in activeSheet = .insertSend(aux: aux, index: index) },
            sendPluginDragProvider: { aux, id in sendPluginDragProvider(aux: aux, pluginID: id) },
            sendBoxDropOutcome: { aux, index, flags in
                // A send card in the hand: a box takes plugins, not sends.
                if SendDragSession.shared.current != nil {
                    return .sendRefused(SendDrop.decide(.sendBox).banner)
                }
                guard let payload = PluginDragSession.shared.current else { return nil }
                return viewModel.pluginDropOutcome(payload, toHost: sendHost(aux),
                                                   at: .series(.root, index: index), flags: flags)
            },
            onSendBoxDrop: { aux, index, payload, flags in
                viewModel.synopticDrop(payload, host: sendHost(aux), at: .series(.root, index: index), flags: flags)
            },
            onToggleInfinite: { viewModel.toggleObjectInfinite(id: objectID) },
            // FX links. The block's id is what every one of these carries; the model resolves the
            // bin (attached) or the block's own copy (detached) itself.
            onFXToggleEnabled: { blockID in fxToggleEnabled(blockID) },
            onFXRename: { blockID, name in
                if let id = fxLinkID(of: blockID) { viewModel.renameFXLink(id, to: name) }
            },
            onFXCycleColor: { blockID in
                if let id = fxLinkID(of: blockID) { viewModel.cycleFXLinkColor(id) }
            },
            onFXToggleDetach: { blockID in
                guard let block = fxBlock(blockID) else { return }
                if block.fxBlock?.isDetached == true {
                    viewModel.reattachFXBlock(hostID: objectID, blockID: blockID)
                } else {
                    viewModel.detachFXBlock(hostID: objectID, blockID: blockID)
                }
            },
            onFXRelease: { viewModel.releaseFXBlock(hostID: objectID, blockID: $0) },
            onFXRemove: { viewModel.removeFXBlock(hostID: objectID, blockID: $0) },
            onFXDelete: { blockID in
                if let id = fxLinkID(of: blockID) { viewModel.deleteFXLink(id) }
            },
            canCreateFXLink: { viewModel.canCreateFXLink(host: objectID, pluginIDs: $0) },
            onCreateFXLink: { ids in
                if viewModel.createFXLink(from: objectID, pluginIDs: ids) != nil {
                    viewModel.setPluginSelection([], host: objectID)
                }
            },
            joinableFXLinks: { viewModel.joinableFXLinks(host: objectID) },
            onJoinFXLink: { viewModel.attachFXLink($0, to: objectID) },
            onToggleContent: {
                if viewModel.isInConsolidateEditStack(objectID) {
                    if viewModel.editingPlacementID == objectID { viewModel.closeConsolidate() }
                } else if !viewModel.isLiveMirror(objectID) {
                    viewModel.openConsolidate(viaPlacementID: objectID)
                }
            },
            onOpenARAEditor: { viewModel.openARAEditor(objectID: objectID) },
            onRemoveARA: { viewModel.removeARASource(objectID: objectID) },
            onToggleARABypass: { viewModel.toggleARABypass(objectID: objectID) },
            // Wave 2 of the signal view rework (docs/plan_synoptic_rework.md §B). A gain stage dragged out of
            // a '+' of a series (the trunk, a branch, a bin's — a bin's joins its DEFINITION), or out of a
            // send's mini-chain '+': ONE undo point each (@see EditViewModel.insertGainStage).
            onPlusGesture: { seriesID, index, result in
                guard let face = Self.gainFace(result), let loc = locations[seriesID] else { return }
                layGainStage(host: objectID, series: loc, index: index, face: face)
            },
            onSendPlusGesture: { aux, index, result in
                guard let face = Self.gainFace(result) else { return }
                layGainStage(host: sendHost(aux), series: .root, index: index, face: face)
            },
            // A direction the user bound to a plugin (@see PlusShortcutStore): the plugin is inserted at the
            // '+' exactly as if it had been chosen in the browser its click opens (same door, same undo point,
            // same editor opening). Not installed any more → nothing (the zone was drawn greyed already).
            onPlusInsertPlugin: { seriesID, index, ref in
                guard let loc = locations[seriesID], let available = viewModel.availablePlugin(for: ref) else {
                    NSSound.beep()
                    return
                }
                viewModel.synopticInsert(objectID: objectID, available: available, into: loc, at: index)
            },
            // A direction bound to a colour category: the browser its click opens, on that colour's tab.
            onOpenBrowserInCategory: { key, category in
                switch key {
                case .series(let seriesID, let index):
                    if let loc = locations[seriesID] {
                        activeSheet = .insert(location: loc, index: index, category: category)
                    }
                case .sendChain(let aux, let index):
                    activeSheet = .insertSend(aux: aux, index: index, category: category)
                case .postFader:
                    break
                }
            },
            onSendPlusInsertPlugin: { aux, index, ref in
                guard let available = viewModel.availablePlugin(for: ref) else {
                    NSSound.beep()
                    return
                }
                let host = sendHost(aux)
                let count = viewModel.chainPlugins(host)?.count ?? 0
                viewModel.synopticInsert(objectID: host, available: available, into: .root,
                                         at: min(max(0, index), count))
            },
            plusPluginInstalled: { ref in viewModel.availablePlugin(for: ref) != nil },
            // The card's boxes: the undo point is `onBeginGainEdit`'s, at the start of each gesture.
            onSetGainStage: { id, gain, pan, muted in
                viewModel.setGainStage(pluginID: id, gainDb: gain, pan: pan, muted: muted, undo: false)
            },
            gainStageValues: { id in gainStageValues(id) },
            onToggleClipOptions: { SynopticUIState.shared.toggleClipOptions() },
            // A bin's fold and its rename are keyed by the BIN (every host of it shows the same state).
            onToggleFXFold: { blockID in SynopticUIState.shared.toggleFXFold(fxLinkID(of: blockID) ?? blockID) },
            onRenameFXLink: { blockID in
                if let id = fxLinkID(of: blockID) { viewModel.beginRenamingFXLink(id) }
            }
        ))
        .environment(\.synopticLevels, levelStore)
        .onAppear {
            refreshStates(); receivedIDs = viewModel.activeSenders(toAux: objectID)
            isOnScreen = true
            registerMeters(meteredIDs)
        }
        .onDisappear {
            isOnScreen = false
            viewModel.setMeteredPlugins(owner: meterOwner.uuidString, objectID: objectID, ids: [])
            if !levelStore.levels.isEmpty { levelStore.levels = [:] }
        }
        .onChange(of: objectID) { _, newID in
            receivedIDs = viewModel.activeSenders(toAux: newID)
            levelStore.levels = [:]
        }
        .onChange(of: meteredIDs) { _, ids in registerMeters(ids) }
        .onReceive(poll) { _ in refreshStates(); refreshReceived() }
        .onReceive(vuPoll) { _ in refreshLevels() }
        .sheet(item: $activeSheet) { kind in
            switch kind {
            case .insert(let location, let index, let category):
                pickerSheet(insertion: PluginBrowserInsertion(location: location, index: index),
                            category: category) { available in
                    viewModel.synopticInsert(objectID: objectID, available: available, into: location, at: index)
                }
            case .instrument:
                pickerSheet(instrumentsOnly: true) { available in
                    viewModel.setInstrument(objectID: objectID, available: available)
                }
            case .insertSend(let aux, let index, let category):
                // The send's own chain host: the plugin lands at the '+' clicked (the END from the line's
                // menu). No ARA source there (a source is an object's), and instruments are left out like in
                // any FX chain.
                let host = sendHost(aux)
                pickerSheet(title: L("synoptic.sheet.addPluginOnSend", viewModel.find(id: aux)?.displayName ?? ""),
                            showsARASource: false, category: category) { available in
                    let count = viewModel.chainPlugins(host)?.count ?? 0
                    viewModel.synopticInsert(objectID: host, available: available, into: .root,
                                             at: min(max(0, index ?? count), count))
                }
            }
        }
    }

    /// A plugin selection sheet reused by '+' (insert), '//' (branch) and the instruments zone.
    /// `instrumentsOnly` restricts it to instruments (the MIDI zone); otherwise we ALWAYS exclude
    /// instruments from the FX zone — an instrument needs MIDI at its input (which only a MIDI clip
    /// provides, and through its dedicated MIDI zone), so it belongs in NO FX chain.
    @ViewBuilder
    private func pickerSheet(instrumentsOnly: Bool = false, title: String? = nil, showsARASource: Bool = true,
                             insertion: PluginBrowserInsertion? = nil, category: Int? = nil,
                             onSelect: @escaping (AvailablePlugin) -> Void) -> some View {
        let size = PluginBrowserLayout.sheetSize()
        PluginBrowserView(
            viewModel: viewModel,
            objectID: objectID,
            title: title ?? (instrumentsOnly ? L("synoptic.sheet.chooseInstrument") : L("synoptic.sheet.addPlugin")),
            searchText: $pickerSearch,
            dismiss: { activeSheet = nil },
            onSelect: { available in onSelect(available); activeSheet = nil },
            kind: instrumentsOnly ? .instrumentsOnly : .effectsOnly,
            showsARASource: showsARASource && !instrumentsOnly,
            insertion: insertion,
            initialPage: category.map { .plugins(.category($0)) } ?? .plugins(.all)
        )
        .frame(width: size.width)   // the height is the browser's own: it depends on the page shown
    }

    // MARK: Gain stages (docs/plan_synoptic_rework.md §B.4)

    /// The face a '+' drag asks for; nil for any other result (a branch and a send have their own closures).
    private static func gainFace(_ r: PlusGestureResult) -> GainStageFace? {
        switch r {
        case .gain:        return .gain
        case .gainPanMute: return .gainPanMute
        default:           return nil
        }
    }

    /// Lays a NEW gain stage; a chain with no room left says so with a beep, like a plugin that would not fit.
    private func layGainStage(host: UUID, series: SeriesLocation, index: Int, face: GainStageFace) {
        if case .failure(let why) = viewModel.insertGainStage(host: host, series: series, index: index, face: face) {
            NSLog("[SYNOPTIC] gain stage not laid: %@", why.rawValue)
            NSSound.beep()
        }
    }

    /// A stage's values as its card shows them, with the three automation flags: a curve on a parameter
    /// greys its box (the curve is the authority, the hand no longer moves it). A stage's curves live on the
    /// object this view shows — a send's mini-chain included (its curves are its sender's).
    private func gainStageValues(_ id: UUID) -> SynopticGainStageValues? {
        guard let v = viewModel.gainStageValues(id) else { return nil }
        func automated(_ param: String) -> Bool {
            viewModel.isAutomated(.plugin(pluginKey: id, paramID: param), on: objectID)
        }
        return SynopticGainStageValues(gainDb: v.gainDb, pan: v.pan, muted: v.muted,
                                       gainAutomated: automated(GainStageValues.gainParamID),
                                       panAutomated: automated(GainStageValues.panParamID),
                                       muteAutomated: automated(GainStageValues.muteParamID))
    }

    /// A plugin of a send's mini-chain, as its box draws it: identity colour and, for a stage, its face.
    private func sendPlugin(_ p: ObjectPlugin) -> SynopticSendPlugin {
        SynopticSendPlugin(id: p.id, name: p.name, enabled: p.isEnabled, color: p.color,
                           gainStage: SynopticMapping.synopticFace(of: p))
    }

    // MARK: FX link helpers (a block's id → what the model needs)

    private func fxBlock(_ blockID: UUID) -> ObjectPlugin? {
        viewModel.chainPlugins(objectID).flatMap { EditViewModel.findBlock(blockID, in: $0) }
    }

    private func fxLinkID(of blockID: UUID) -> UUID? { fxBlock(blockID)?.fxBlock?.linkID }

    /// The common on/off: the bin's while the block follows it, the block's own once detached.
    private func fxToggleEnabled(_ blockID: UUID) {
        guard let block = fxBlock(blockID), let fb = block.fxBlock else { return }
        let now = viewModel.fxOutput(of: block).isEnabled
        if fb.isDetached {
            viewModel.fxSetLocalEnabled(hostID: objectID, blockID: blockID, enabled: !now)
        } else {
            viewModel.fxSetEnabled(linkID: fb.linkID, enabled: !now)
        }
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

    /// The double click on a card of a multiple selection: one editor per selected plugin, each
    /// through the SAME opening path as a single double click (an external one goes through the
    /// engine, which prepares the unit before showing its GUI; a built-in gets its SwiftUI window).
    /// The clicked card decides for all: its editor open → close those of the selection, otherwise
    /// open them all (one already open is brought to the front).
    private func openEditors(clicked: UUID, ids: Set<UUID>) {
        let candidates = viewModel.leafPlugins(objectID: objectID)
            + (viewModel.find(id: objectID)?.instruments ?? [])
        let plugs = candidates.filter { ids.contains($0.id) }      // reading order
        guard let clickedPlug = plugs.first(where: { $0.id == clicked }) else { return }
        if viewModel.isPluginEditorOpen(plug: clickedPlug) {
            for p in plugs where viewModel.isPluginEditorOpen(plug: p) { viewModel.closePluginEditor(plug: p) }
            return
        }
        viewModel.openPluginEditors(objectID: objectID, plugs: plugs)
    }

    /// The FX selection of THIS chain, seen as a `Set`. It reads EMPTY as soon as the view-model's
    /// selection belongs to another host — which is what makes changing object in the inspector
    /// drop the highlight with no `onChange` anywhere: the question "is this selection mine?" is
    /// asked at every read rather than answered once and left to go stale.
    private var pluginSelection: Binding<Set<UUID>> {
        Binding(get: { viewModel.selectedPluginHostID == objectID ? viewModel.selectedPluginIDs : [] },
                set: { viewModel.setPluginSelection($0, host: objectID) })
    }

    /// A card's drag payload (the same format as the chips → it reuses the timeline drop to
    /// move/copy/link to another object, and the '+'s to reorder).
    ///
    /// A card taken WHILE IT IS IN THE SELECTION carries the whole selection with it; a card taken
    /// from outside carries itself alone. The clips' rule word for word (@see the timeline's drag
    /// handler): what you GRAB is what decides, and grabbing something you had not chosen is a new
    /// choice rather than a mistake to be punished by losing the old one.
    private func dragProvider(_ pluginID: UUID) -> NSItemProvider {
        let all = pluginSelection.wrappedValue.contains(pluginID)
            ? viewModel.orderedSelectedPluginIDs()
            : [pluginID]
        let payload = PluginDragPayload(sourceObjectID: objectID, pluginID: pluginID,
                                        pluginIDs: all)
        let data = (try? JSONEncoder().encode(payload)) ?? Data()
        // The drag begins: the targets read what it carries from here (@see PluginDragSession).
        PluginDragSession.shared.begin(payload)
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.plainText.identifier,
                                             visibility: .all) { completion in
            completion(data, nil); return nil
        }
        return provider
    }

    // MARK: A send's box (INC 3): the chain host behind it and the trunk's gestures aimed at it

    /// The chain host of the send from THIS object to `aux` (@see SendChain.hostID).
    private func sendHost(_ aux: UUID) -> UUID { SendChain.hostID(sender: objectID, aux: aux) }

    /// A click on a row of a send's box. Plain = that row alone; ⌘ = toggle it; ⇧ = from the rows
    /// already held to this one, in the box's order. The selection is the view-model's, with the send
    /// as its host — so the trunk's highlight drops by itself (@see pluginSelection) and ⌫ ⌘C ⌘V ⌘D
    /// reach the box.
    private func clickSendPlugin(aux: UUID, id: UUID, flags: NSEvent.ModifierFlags) {
        let host = sendHost(aux)
        selectedInstrumentID = nil
        let order = (viewModel.chainPlugins(host) ?? []).map(\.id)
        let current = viewModel.selectedPluginHostID == host ? viewModel.selectedPluginIDs : []
        if flags.contains(.command) {
            viewModel.selectPlugin(id, host: host, additive: true)
        } else if flags.contains(.shift), let clicked = order.firstIndex(of: id) {
            let held = order.indices.filter { current.contains(order[$0]) } + [clicked]
            viewModel.setPluginSelection(Set(order[(held.min() ?? clicked)...(held.max() ?? clicked)]), host: host)
        } else {
            viewModel.setPluginSelection([id], host: host)
        }
    }

    /// The double click on a row: the plugin's editor, through the same path as a trunk card's.
    private func openSendPluginEditor(aux: UUID, id: UUID) {
        let host = sendHost(aux)
        guard let plug = viewModel.leafPlugins(objectID: host).first(where: { $0.id == id }) else { return }
        viewModel.togglePluginEditor(objectID: host, plug: plug)
    }

    /// A row taken in the hand: the trunk's payload with the SEND as its source host. A row taken while
    /// it is in the selection carries the selection (the rows of that box). Announced as coming from a
    /// send: such a drag never links, wherever it lands (@see PluginDragSession.fromSend).
    private func sendPluginDragProvider(aux: UUID, pluginID: UUID) -> NSItemProvider {
        let host = sendHost(aux)
        let all = (viewModel.selectedPluginHostID == host && viewModel.selectedPluginIDs.contains(pluginID))
            ? viewModel.orderedSelectedPluginIDs()
            : [pluginID]
        let payload = PluginDragPayload(sourceObjectID: host, pluginID: pluginID, pluginIDs: all)
        let data = (try? JSONEncoder().encode(payload)) ?? Data()
        PluginDragSession.shared.begin(payload, fromSend: true)
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.plainText.identifier,
                                             visibility: .all) { completion in
            completion(data, nil); return nil
        }
        return provider
    }

    /// A send card taken in the hand: its payload (sender + aux), announced to the doors that read a drag
    /// before it hovers them (@see SendDragSession) — the signal view's own targets, the timeline, a strip.
    private func sendDragProvider(_ auxID: UUID) -> NSItemProvider {
        let payload = SendDragPayload(sendSender: objectID, sendAux: auxID)
        let data = (try? JSONEncoder().encode(payload)) ?? Data()
        SendDragSession.shared.begin(payload)
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

    /// The plugins whose output level this view shows: the cards of the chain and the instrument.
    private func meteredPluginIDs() -> [UUID] {
        viewModel.leafPlugins(objectID: objectID).map(\.id)
            + (viewModel.find(id: objectID)?.instruments.map(\.id) ?? [])
    }

    /// Tells the engine which plugins to measure (an empty list = none). Only while on screen.
    private func registerMeters(_ ids: [UUID]) {
        guard isOnScreen else { return }
        viewModel.setMeteredPlugins(owner: meterOwner.uuidString, objectID: objectID, ids: ids)
    }

    /// Polls the VU levels at 30 Hz — only while the synoptic is on screen AND the transport plays (when
    /// it stops the lines fall to 0 once). A bypassed plugin reads 0 straight away: its bar is OFF, not
    /// decaying, since it shows nothing of the signal that goes through it.
    private func refreshLevels() {
        guard isOnScreen else { return }
        guard viewModel.isTransportPlaying else {
            if levelStore.lastTick != 0 {
                // The first poll after the transport stopped: one read per plugin EMPTIES the engine's
                // peak-hold (a client keeps its maximum until read). Without it the first poll of the
                // NEXT playback would draw the previous one's last peak for a frame.
                for p in viewModel.leafPlugins(objectID: objectID) + (viewModel.find(id: objectID)?.instruments ?? []) {
                    _ = viewModel.pluginAudioLevel(objectID: objectID, pluginID: p.id)
                }
            }
            if !levelStore.levels.isEmpty { levelStore.levels = [:] }
            levelStore.lastTick = 0
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let dt = levelStore.lastTick > 0 ? min(now - levelStore.lastTick, 0.25) : Self.vuInterval
        levelStore.lastTick = now
        let alpha = VUBallistics.releaseAlpha(interval: dt)

        let leaves = viewModel.leafPlugins(objectID: objectID)
            + (viewModel.find(id: objectID)?.instruments ?? [])
        var next: [UUID: Double] = [:]
        for p in leaves where p.isEnabled {
            let raw = Float(viewModel.pluginAudioLevel(objectID: objectID, pluginID: p.id))
            let prev = Float(levelStore.levels[p.id] ?? 0)
            let v = VUBallistics.smoothed(previous: prev, raw: raw, alpha: alpha)
            if v > 0.002 { next[p.id] = Double(v) }     // a dead-quiet bar is simply absent
        }
        if next != levelStore.levels { levelStore.levels = next }
    }

    /// Polls the loading state of the external instances (built-ins ignored).
    private func refreshStates() {
        let analysing = viewModel.araIsAnalysing(objectID)
        if analysing != araAnalysing { araAnalysing = analysing }
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
        // The main buses of the external instances that are loaded (a cheap read each, no probing).
        let channels = viewModel.pluginChannels(pluginIDs: Array(st.keys))
        if channels != channelCounts { channelCounts = channels }
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
    @State private var selection: Set<UUID> = []
    @State private var selectedInstrumentID: UUID? = nil

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("synoptic.demo.title", title)).font(.headline)
                Spacer()
                Button(L("common.close")) { dismiss() }
            }
            .padding(12)

            Divider()

            SynopticView(root: root, selection: $selection,
                         selectedInstrumentID: $selectedInstrumentID,
                         actions: SynopticActions(
                onToggleBypass: { root = root.togglingBypass($0) },
                onRemove: {
                    root = root.removingPluginAtRoot($0)
                    selection.remove($0)
                },
                onInsertSeries: { sid, idx in root = root.insertingPlaceholder(intoSeries: sid, atIndex: idx) },
                onBranch: { request in
                    switch request {
                    case .plugin(let id): root = root.branching(id)
                    case .plus(let s, let i): if let id = root.branchTarget(series: s, index: i) { root = root.branching(id) }
                    }
                }
            ))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            HStack(spacing: 12) {
                Text(L("synoptic.demo.legend"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L("common.reset")) { root = .demo; selection = [] }
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

extension SynopticBoundView {
    /// The audio file's `ChannelMode` as the signal view's wire reads it, and back.
    static func sourceChoice(_ mode: ChannelMode) -> SourceChannelChoice {
        switch mode {
        case .lr: return .both
        case .l:  return .left
        case .r:  return .right
        case .c:  return .sum
        }
    }

    static func channelMode(_ choice: SourceChannelChoice) -> ChannelMode {
        switch choice {
        case .both:  return .lr
        case .left:  return .l
        case .right: return .r
        case .sum:   return .c
        }
    }
}
