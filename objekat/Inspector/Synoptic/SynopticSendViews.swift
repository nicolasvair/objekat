import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

// MARK: - Sends: the boxes below the stems, their wires' handles, and a bus's head (received sends)
//
// Signal view rework, lot L7 (docs/plan_synoptic_rework.md §B.6, request 12). A departure is a BOX stacked
// BELOW the stems (@see SendBoxView); the line that says where it is taken from leaves the trunk at the
// send's tap, runs out to the LEFT of the object's frame and down to the box (the geometry is the layout's,
// @see SynopticLayout.SendCardPlacement.wire; the drawing and the handle are @see SendWire /
// SendTapDotView). A send is moved by dragging its BOX onto the place it should be taken from, or by
// dragging its source point (the handle) along the chain: the same `SendDragPayload` either way.
// Symmetrically, the sends an aux RECEIVES come in at the head, at the level of its source
// (@see SynopticSendRow).

/// One send row: the branch arrow, the name, a draggable level, a switch.
struct SynopticSendRow: View {
    let send: SynopticSend
    /// true = a departure (foot); false = a received send (an aux's head) — the arrow flips.
    let outgoing: Bool
    let actions: SynopticActions

    private var isSilent: Bool { send.levelDb <= sendMinDb }
    private var isRouted: Bool { send.enabled && !isSilent && send.refusal == nil }

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
                .help(send.refusal ?? "")
            // A received row says where the sender takes the signal when it is not the usual post-fader.
            if !outgoing, let short = send.slot.shortLabel {
                Text(short)
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 3)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.15)))
                    .help(send.slot.longLabel)
            }
            // …and that the sender's send goes through plugins before arriving (nothing editable here).
            if !outgoing, !send.plugins.isEmpty {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .help(L("synoptic.send.hasPlugins.help"))
            }
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
        .opacity(send.refusal == nil ? 1 : 0.55)
    }
}

/// "+ Send to…": a dashed capsule at the foot of the card column.
struct AddSendButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "plus").font(.system(size: 9, weight: .bold))
                Text(L("synoptic.send.add")).font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(hovering ? Color.accentColor : Color.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 7)
                .strokeBorder((hovering ? Color.accentColor : Color.secondary).opacity(0.6),
                              style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(L("synoptic.send.add.help"))
    }
}

/// A send CARD: the branch arrow, the aux's name, a draggable level, the on/off switch, a menu and the
/// cross. Greyed, with the reason as its tooltip, when the bridge refuses the send or its aux no longer
/// overlaps the object in time (Q-U15) — a card never disappears because an object was moved.
struct SendCardView: View {
    let send: SynopticSend
    let actions: SynopticActions
    /// true = the bottom line of a send's BOX (the send carries plugins): the box draws the ground,
    /// the border and the greying; the card only draws the rule that parts it from the rows.
    var boxed: Bool = false

    private var isSilent: Bool { send.levelDb <= sendMinDb }
    private var isRouted: Bool { send.enabled && !isSilent && send.refusal == nil }

    private func levelLabel(_ db: Double) -> String {
        db <= Double(sendMinDb) ? "-∞ dB" : (db == 0 ? "0 dB" : String(format: "%+.0f dB", db))
    }

    /// The position, in words (the tooltip of the arrow).
    private var positionText: String {
        switch send.slot {
        case .input:      return L("synoptic.send.pos.input")
        case .chain(let i): return L("synoptic.send.pos.chain", i + 1)
        case .preFader:   return L("synoptic.send.pos.preFader")
        case .postFader:  return L("synoptic.send.pos.postFader")
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            // The grip: the arrow and the name take the card in the hand (the level, the switch and the
            // menu keep their own gestures).
            HStack(spacing: 5) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isRouted ? Color.accentColor : Color.secondary.opacity(0.6))
                    .frame(width: 14)
                    .help(positionText)
                Text(send.name)
                    .font(.system(size: 10))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(isRouted ? .primary : .secondary)
                    .help(send.refusal ?? positionText)
                Spacer(minLength: 2)
            }
            .contentShape(Rectangle())
            .onDragIf(actions.sendDragProvider.map { f in { f(send.id) } }) {
                SendDragPreview(name: send.name, live: isRouted)
            }
            DragValueBox(value: Double(send.levelDb),
                         format: { levelLabel($0) },
                         range: Double(sendMinDb)...Double(sendMaxDb),
                         pointsPerStep: 6, snap: true, width: 52, keyStep: 1,
                         // The level acts AFTER the send's plugins (Q-U17): said where there are some.
                         help: send.plugins.isEmpty ? L("help.drag.sendLevel") : L("synoptic.send.level.afterPlugins"),
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
            Menu {
                sendMenuItems
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 18)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(L("synoptic.send.menu.help"))
            Button { actions.onRemoveSend?(send.id) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("synoptic.send.remove.help"))
        }
        .padding(.horizontal, 7)
        .background {
            if !boxed {
                RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .controlBackgroundColor))
            }
        }
        .overlay {
            if !boxed {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder((isRouted ? Color.accentColor : Color.secondary).opacity(isRouted ? 0.55 : 0.3), lineWidth: 1)
            }
        }
        .overlay(alignment: .top) {
            if boxed {
                Rectangle().fill(Color.secondary.opacity(0.3)).frame(height: 0.5)
            }
        }
        .opacity(boxed || send.refusal == nil ? 1 : 0.55)
        .contextMenu { sendMenuItems }
    }

    /// The card's menu (the ellipsis and the right click). "Change target…" joins it in step 2.11.
    @ViewBuilder
    private var sendMenuItems: some View {
        Button(L("synoptic.send.menu.retarget")) { actions.presentSendMenu(slot: send.slot, retargeting: send.id) }
            .disabled(actions.sendTargetSections == nil)
        Button(L("synoptic.send.menu.fold")) { actions.onMoveSend?(send.id, .postFader) }
            .disabled(send.slot == .postFader || actions.onMoveSend == nil)
        Button(L("synoptic.send.menu.addPlugin")) { actions.onSendPluginAdd?(send.id) }
            .disabled(actions.onSendPluginAdd == nil)
        Divider()
        Button(L("synoptic.send.menu.delete"), role: .destructive) { actions.onRemoveSend?(send.id) }
    }
}

// MARK: - A send's box (INC 3, reworked in L7): the plugins ON the send

/// A send as the signal view draws it. With no plugin: the send's line, plus a small "+" that shows just
/// above it while the hand is over it. With plugins: a BOX, read top to bottom in the order of the signal
/// (Q-U19) — one CARD per plugin (the very card of a plugin of the chain, @see sendPluginCard), the "+" after
/// the last one, then the send's own line (aux, level, on/off) at the bottom. The wire from the trunk
/// arrives at the top row, from the left (@see SendWire).
///
/// The "+" of the mini-chain shows only while the hand is over the box (or a drag out of it is in flight):
/// a click opens the plugin picker aimed at this send, a drag to the RIGHT puts a gain stage on the send
/// (further right: gain + pan + mute), under a ghost that says what letting go would do (§B.2). A send's
/// chain takes no branch and no send, so every other direction shows "not here".
///
/// A plugin is let go on the box, between two rows (the insertion line says where), on the "+" or on the
/// line (= the end): nothing = move, ⌥ = copy, ⌘ = copy as well — a send's plugin is never linked. A send
/// card let go here is refused (a box takes plugins, not sends).
struct SendBoxView: View {
    let placement: SynopticLayout.SendCardPlacement
    let actions: SynopticActions
    @State private var hovering = false
    /// The pending "hand left" (see `setHover`): cancelled if the hand comes back within `hoverLinger`.
    @State private var leaveWork: DispatchWorkItem? = nil
    /// The translation of a drag in flight out of the "+" (nil = none): keeps the "+" shown, and the ghost.
    @State private var plusDrag: CGSize? = nil
    /// The insertion slot a plugin drag is aiming at (nil = none).
    @State private var dropIndex: Int? = nil
    @State private var dropHintID = UUID()

    /// The margin between the box's border and its plugin cards, each side.
    static let cardInset: CGFloat = 4
    /// How long the "+" outlives the hand leaving the box. The hand goes from the line to the "+" through
    /// the strip's edge, where the hover is lost for a frame: without this the "+" would flicker off
    /// under it and could not be reached.
    static let hoverLinger: TimeInterval = 0.12

    private var send: SynopticSend { placement.send }
    private var isRouted: Bool { send.enabled && send.levelDb > sendMinDb && send.refusal == nil }
    /// The "+" is shown while the hand is over the box, or a drag out of it is in flight.
    private var plusShown: Bool { hovering || plusDrag != nil }

    /// The rect this view fills on the canvas: the box; with no plugin, the card plus the strip above
    /// it where the hover "+" shows. The canvas' marquee must treat it as a blocker (the "+" strip lies
    /// outside `placement.frame`).
    static func zone(of p: SynopticLayout.SendCardPlacement) -> CGRect {
        p.hasPlugins ? p.frame : p.frame.union(p.plusRect)
    }

    var body: some View {
        let zone = Self.zone(of: placement)
        let selection = actions.sendPluginSelection?(send.id) ?? []
        VStack(spacing: 0) {
            if placement.hasPlugins {
                ForEach(send.plugins) { p in
                    sendPluginCard(p, selection: selection)
                        .frame(width: placement.frame.width, height: SynopticLayout.sendPluginRowH)
                }
                plusRow.frame(height: SynopticLayout.sendPlusRowH)
            } else {
                // No box yet: the "+" strip lies just above the line (it may overlap the box above: the
                // strip is not hit-testable unless shown, and it is shown only while this view is hovered).
                plusRow.frame(height: SynopticLayout.sendPlusRowH)
            }
            SendCardView(send: send, actions: actions, boxed: placement.hasPlugins)
                .frame(height: SynopticLayout.sendCardH)
        }
        .frame(width: zone.width, height: zone.height, alignment: .top)
        // The box's ground and border (a plugin-less send's card draws its own).
        .background {
            if placement.hasPlugins {
                RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .controlBackgroundColor))
            }
        }
        .overlay {
            if placement.hasPlugins {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder((isRouted ? Color.accentColor : Color.secondary).opacity(isRouted ? 0.55 : 0.3), lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
        // The drop layer: a SIBLING behind the content, never an ancestor of the cards' drag sources
        // (@see SynopticCardView.dropLayer). It covers the box — the card alone for a plugin-less send.
        .background(alignment: .bottom) { dropLayer }
        // Where the plugin in the hand would be inserted.
        .overlay(alignment: .topLeading) {
            if let i = dropIndex {
                if placement.hasPlugins {
                    Capsule().fill(Color.accentColor)
                        .frame(width: zone.width - 8, height: 2)
                        .offset(x: 4, y: placement.insertLineY(i) - zone.minY - 1)
                        .allowsHitTesting(false)
                } else {
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .frame(width: placement.frame.width, height: placement.frame.height)
                        .offset(y: placement.frame.minY - zone.minY)
                        .allowsHitTesting(false)
                }
            }
        }
        .onHover { setHover($0) }
        // A refused send: the whole box greyed. The reason is the tooltip of the line's name (the card's
        // own text): no `.help` here, a tooltip on the box would gag its children's.
        .opacity(placement.hasPlugins && send.refusal != nil ? 0.55 : 1)
    }

    /// The hand enters at once, and leaves after `hoverLinger` unless it came back.
    private func setHover(_ on: Bool) {
        leaveWork?.cancel()
        leaveWork = nil
        if on {
            hovering = true
        } else {
            let work = DispatchWorkItem { hovering = false }
            leaveWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.hoverLinger, execute: work)
        }
    }

    // MARK: A plugin of the send, as a card

    /// A plugin of the send's mini-chain: the SAME card as a plugin of the chain (on/off column in its
    /// identity colour, name, ✕, VU line, halo), fed from the send's gestures. A send's plugin is never
    /// linked (no badge) and takes no drop of its own: a plugin let go on a card lands on the box's drop
    /// layer, which reads the insertion slot from the pointer.
    ///
    /// A GAIN STAGE on the send (`SynopticSendPlugin.gainStage`) takes its face here as on the trunk: no editor
    /// to open, no power button, its values read and written through `actions` (@see
    /// SynopticGainStageControls).
    @ViewBuilder
    private func sendPluginCard(_ p: SynopticSendPlugin, selection: Set<UUID>) -> some View {
        let aux = send.id
        SynopticCardView(
            plugin: SynopticPlugin(id: p.id, name: p.name, category: .utility, isEnabled: p.enabled,
                                   color: p.color, gainStage: p.gainStage),
            isSelected: selection.contains(p.id),
            onSelect: { actions.onSendPluginClick?(aux, p.id, NSEvent.modifierFlags) },
            // A refused send has no engine plugin: nothing to open.
            onOpenEditor: (send.refusal == nil && p.gainStage == nil)
                ? actions.onSendPluginOpen.map { f in { f(aux, p.id) } } : nil,
            onToggleBypass: { if p.gainStage == nil { actions.onSendPluginToggle?(aux, p.id) } },
            onRemove: { actions.onSendPluginRemove?(aux, p.id) },
            dragProvider: actions.sendPluginDragProvider.map { f in { f(aux, p.id) } },
            dragCount: selection.contains(p.id) ? selection.count : 1,
            actions: actions,
            width: placement.frame.width - 2 * Self.cardInset)
    }

    // MARK: The "+" of the mini-chain

    /// The ghost under the hand while the "+" is dragged (nothing for a click).
    private var ghost: SendPlusGhost {
        guard let t = plusDrag else { return .hidden }
        let g = SendPlusGhost.of(command: placement.command(for: t), translation: t)
        // No door to put a stage on a send (the demo): "not here" for what would have been one.
        if case .stage = g, actions.onSendPlusGesture == nil { return .refused }
        return g
    }

    /// What letting go of the "+" at `translation` does, handed to the view-model.
    private func perform(_ translation: CGSize) {
        switch SendPlusIntent(placement.command(for: translation)) {
        case .none:
            break
        case .openBrowser(let aux):
            actions.onSendPluginAdd?(aux)
        case .gainStage(let aux, let index, let result):
            actions.onSendPlusGesture?(aux, index, result)
        }
    }

    /// The "+": a click opens the plugin picker aimed at this send, a drag to the right puts a gain stage
    /// on it. Shown while the hand is over the box; not hit-testable otherwise.
    private var plusRow: some View {
        HStack(spacing: 0) {
            Image(systemName: "plus")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 16)
                .background(RoundedRectangle(cornerRadius: 4)
                    .fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.secondary.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [2, 2])))
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { plusDrag = $0.translation }
                    .onEnded { v in
                        plusDrag = nil
                        perform(v.translation)
                    })
                .overlay { SendPlusGhostView(ghost: ghost, translation: plusDrag ?? .zero) }
                .opacity(actions.onSendPluginAdd == nil ? 0.4 : 1)
                .help(L("synoptic.send.plus.help"))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        // The whole strip answers the hand while shown (no gap between the line and the "+").
        .contentShape(Rectangle())
        .opacity(plusShown ? 1 : 0)
        .allowsHitTesting(plusShown)
    }

    @ViewBuilder private var dropLayer: some View {
        if let onDrop = actions.onSendBoxDrop {
            // Local (0, 0) of the layer, on the canvas: the box's top — the card's for a plugin-less send.
            let top = placement.frame.minY
            Color.clear
                .frame(width: placement.frame.width, height: placement.frame.height)
                .contentShape(Rectangle())
                .onDrop(of: [.plainText],
                        delegate: SendBoxDropDelegate(
                            placement: placement, layerTop: top, dropIndex: $dropIndex,
                            hintKey: "sendbox:\(dropHintID.uuidString)",
                            outcome: { index, flags in actions.sendBoxDropOutcome?(send.id, index, flags) },
                            onDrop: { index, payload, flags in onDrop(send.id, index, payload, flags) }))
        }
    }
}

/// What the "+" of a send's mini-chain shows under the hand while it is dragged: a dashed pill naming the
/// stage that letting go would put on the send, or a crossed one for a direction the "+" does not offer.
/// Deaf to the mouse; it follows the hand by `translation`, from the "+" it is laid over.
struct SendPlusGhostView: View {
    let ghost: SendPlusGhost
    let translation: CGSize

    var body: some View {
        switch ghost {
        case .hidden:
            EmptyView()
        case .stage(let face):
            pill {
                Text(L(face == .gain ? "synoptic.send.plus.ghost.gain" : "synoptic.send.plus.ghost.gainPanMute"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }
            .overlay(Capsule().strokeBorder(Color.accentColor,
                                            style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
        case .refused:
            pill {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.secondary)
            }
            .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.7),
                                            style: StrokeStyle(lineWidth: 1, dash: [2, 2])))
        }
    }

    private func pill<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 8)
            .frame(minWidth: 30, minHeight: 20)
            .background(Capsule().fill(Color(nsColor: .controlBackgroundColor).opacity(0.92)))
            .fixedSize()
            .offset(x: translation.width, y: translation.height)
            .allowsHitTesting(false)
    }
}

// MARK: - A send in the hand: its preview, and the handle that takes it

/// The image AppKit shows under the pointer while a send is dragged — by its box or by its handle. Like
/// `PluginDragPreview` it is rendered outside the view hierarchy (explicit colours throughout), and it
/// names the send, which the default snapshot of a grip (an arrow and a cropped label) did not.
struct SendDragPreview: View {
    let name: String
    let live: Bool

    var body: some View {
        let tint = live ? Color(nsColor: .controlAccentColor) : Color.gray
        HStack(spacing: 5) {
            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
            Text(name)
                .font(.system(size: 11))
                .foregroundStyle(Color.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(tint, lineWidth: 1.5))
    }
}

/// The send's SOURCE POINT: a small dot on the send's wire, just left of the trunk's "+" it is taken at
/// (@see SendWire.handleCenter). Taken in the hand it carries the same payload as the send's box, so the
/// send is moved by dropping it on the "+" / cable / slot it should leave from — along the chain — exactly
/// as the box is. Laid by the canvas' ZStack over the wires, one per send; it positions itself.
///
/// `rank` is the send's order among those taken at the SAME point (`SendWire.rank(of:in:)`): their handles
/// would otherwise sit on one another, and only the last would be reachable.
struct SendTapDotView: View {
    let placement: SynopticLayout.SendCardPlacement
    var rank: Int = 0
    let actions: SynopticActions
    @State private var hovering = false

    var body: some View {
        let send = placement.send
        let live = SendWire.state(of: send) == .live
        let tint = (live ? Color.accentColor : Color.secondary)
        let c = SendWire.handleCenter(of: placement, rank: rank)
        Circle()
            .fill(tint.opacity(live ? 0.9 : 0.6))
            .frame(width: SendWire.dotDiameter, height: SendWire.dotDiameter)
            .overlay(Circle().strokeBorder(tint.opacity(hovering ? 0.9 : 0), lineWidth: 1.5)
                .frame(width: SendWire.dotDiameter + 6, height: SendWire.dotDiameter + 6))
            .frame(width: SendWire.handleDiameter, height: SendWire.handleDiameter)
            .contentShape(Circle())
            .onHover { hovering = $0 }
            .onDragIf(actions.sendDragProvider.map { f in { f(send.id) } }) {
                SendDragPreview(name: send.name, live: live)
            }
            .help(L("synoptic.send.tap.help"))
            .position(c)
    }
}

/// A plugin drag over a send's box. Like `PluginDropDelegate`, it asks the resolver about the drag in
/// flight on every movement (the cursor, the band, the insertion line); unlike it, WHERE in the box the
/// hand is decides the insertion slot, read from the pure layout (@see SendCardPlacement.insertIndex).
/// Two refusals speak on the band — a non-plain plugin, a full chain (@see SendBoxPluginRefusal) — and
/// so does a send card, which a box never takes.
struct SendBoxDropDelegate: DropDelegate {
    let placement: SynopticLayout.SendCardPlacement
    /// The canvas y of the drop layer's top (`DropInfo.location` is in the layer's own coordinates).
    let layerTop: CGFloat
    let dropIndex: Binding<Int?>
    let hintKey: String
    let outcome: (_ index: Int, _ flags: NSEvent.ModifierFlags) -> PluginDropOutcome?
    let onDrop: (_ index: Int, _ payload: PluginDragPayload, _ flags: NSEvent.ModifierFlags) -> Void

    private func carriesPlugin(_ info: DropInfo) -> Bool {
        info.itemProviders(for: [.plainText]).contains(where: PluginDrop.carries)
    }

    /// The insertion slot under the hand (the end when the layout cannot say).
    private func index(_ info: DropInfo) -> Int {
        let point = CGPoint(x: placement.frame.minX + info.location.x, y: layerTop + info.location.y)
        return placement.insertIndex(at: point) ?? placement.send.plugins.count
    }

    private func withdraw() {
        dropIndex.wrappedValue = nil
        PluginDropHint.shared.leave(hintKey)
    }

    private func present(_ info: DropInfo) -> DropProposal {
        let flags = NSEvent.modifierFlags
        let i = index(info)
        guard let o = outcome(i, flags) else {
            // No drag in flight to read: the legacy reading (⌥ / ⌘ copy, anything else moves).
            dropIndex.wrappedValue = i
            PluginDropHint.shared.present(hintKey, context: .sendChain)
            return DropProposal(operation: flags.contains(.option) || flags.contains(.command) ? .copy : .move)
        }
        switch o {
        case .refuse(let why):
            dropIndex.wrappedValue = nil
            if let key = SendBoxPluginRefusal.titleKey(reason: why) {
                PluginDropHint.shared.present(hintKey, context: .refusal(key))
            } else {
                PluginDropHint.shared.leave(hintKey)
            }
            return DropProposal(operation: .forbidden)
        case .sendTaken(let line), .sendRefused(let line):
            dropIndex.wrappedValue = nil
            PluginDropHint.shared.present(hintKey, context: .send(line))
            return DropProposal(operation: .forbidden)
        default:
            dropIndex.wrappedValue = i
            PluginDropHint.shared.present(hintKey, context: .sendChain)
            return DropProposal(operation: o.operation)
        }
    }

    func validateDrop(info: DropInfo) -> Bool { carriesPlugin(info) }
    func dropEntered(info: DropInfo) {
        guard carriesPlugin(info) else { return }
        _ = present(info)
    }
    func dropExited(info: DropInfo) { withdraw() }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard carriesPlugin(info) else {
            withdraw()
            return DropProposal(operation: .forbidden)
        }
        return present(info)
    }
    func performDrop(info: DropInfo) -> Bool {
        let i = index(info)
        withdraw()
        // The delivery itself (the modifiers read now, the sessions ended, the payload decoded) is the
        // card's: one implementation. A send card does not decode as a plugin payload and is ignored.
        let onDrop = self.onDrop
        return PluginDropDelegate(isTargeted: .constant(false), hintKey: hintKey,
                                  onDrop: { payload, flags in onDrop(i, payload, flags) })
            .performDrop(info: info)
    }
}
