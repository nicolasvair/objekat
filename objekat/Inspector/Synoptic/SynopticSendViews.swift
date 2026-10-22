import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

// MARK: - Sends: the columns below the stems, their wires' handles, and a bus's head (received sends)
//
// Signal view rework, lot L7 (docs/plan_synoptic_rework.md §B.6, request 12), reworked on 13 October 2026
// (request 5). A departure is a COLUMN stacked BELOW the stems — its plugins as cards, its line at the bottom
// (@see SendColumnDropView, SendChainCardView, SendCardView); the wire that says where it is taken from
// leaves the trunk at the send's tap, runs out to the LEFT of the object's frame, down to the column and on
// down through it (the geometry is the layout's, @see SynopticLayout.SendCardPlacement; the drawing and the
// handle are @see SendWire / SendTapDotView). A send is moved by dragging its LINE onto the place it should be
// taken from, or by dragging its source point (the handle) along the chain: the same `SendDragPayload` either
// way. Symmetrically, the sends an aux RECEIVES come in at the head, at the level of its source
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

    private var sendGlyph: some View {
        Image(systemName: FeatureIcons.auxSend)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(isRouted ? Color.accentColor : Color.secondary.opacity(0.6))
            .frame(width: 14)
            .help(outgoing ? L("synoptic.send.outgoing") : L("synoptic.send.incoming"))
    }

    var body: some View {
        // The glyph's SIDE says the direction: a received send comes IN to the name (glyph on its
        // left), an outgoing one leaves FROM the name towards elsewhere (glyph on its right).
        HStack(spacing: 6) {
            if !outgoing { sendGlyph }
            Text(send.name)
                .font(.system(size: 10))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(isRouted ? .primary : .secondary)
                .help(send.refusal ?? "")
            if outgoing { sendGlyph }
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
                         pointsPerStep: 6, snap: true, width: 52, keyStep: 1, coarseKeyStep: FineAdjust.dbBigStep,
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
                Image(systemName: FeatureIcons.auxSend)
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
                         pointsPerStep: 6, snap: true, width: 52, keyStep: 1, coarseKeyStep: FineAdjust.dbBigStep,
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
        .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 7)
            .strokeBorder((isRouted ? Color.accentColor : Color.secondary).opacity(isRouted ? 0.55 : 0.3), lineWidth: 1)
            .allowsHitTesting(false))
        .opacity(send.refusal == nil ? 1 : 0.55)
        .contextMenu { sendMenuItems }
    }

    /// The card's menu (the ellipsis and the right click). "Change target…" joins it in step 2.11.
    @ViewBuilder
    private var sendMenuItems: some View {
        Button(L("synoptic.send.menu.retarget")) { actions.presentSendMenu(slot: send.slot, retargeting: send.id) }
            .disabled(actions.sendTargetSections == nil)
        Button(L("synoptic.send.menu.fold")) { actions.onMoveSend?(send.id, .postFader) }
            .disabled(send.slot == .postFader || actions.onMoveSend == nil)
        Button(L("synoptic.send.menu.addPlugin")) { actions.onSendPluginAdd?(send.id, nil) }
            .disabled(actions.onSendPluginAdd == nil)
        Divider()
        Button(L("synoptic.send.menu.delete"), role: .destructive) { actions.onRemoveSend?(send.id) }
    }
}

// MARK: - A send's column (INC 3, reworked in L7, then on 13 October 2026): the plugins ON the send
//
// A send is drawn LIKE THE OBJECT (request 5): the wire from the trunk comes in at the column's top and goes
// DOWN through the send's plugins — the very cards of the trunk, laid by the layout (@see
// SynopticLayout.SendCardPlacement.chain), a '+' on every segment shown on hover (the canvas' own
// `SynopticPlusButton`: a click = the picker aimed at the send, a drag right = a gain stage; no branch, no FX
// link, no send from a send) — to the send's line at the BOTTOM (@see SendCardView). A plugin-less send is its
// line under a short stub of wire, whose '+' shows while the hand is over the line or the stub.
//
// A plugin is let go anywhere on the column: the '+' nearest the pointer says where it lands (the line = the
// end): nothing = move, ⌥ = copy (a send's plugin is never linked). A send card let go
// here is refused (a send takes plugins, not sends). The drop layer is ONE view under the column (@see
// SendColumnDropView); the cards and the line take no drop of their own.

/// A plugin of a send's mini-chain: the SAME card as a plugin of the chain (on/off column in its identity
/// colour, name, ✕, VU line, halo), at the layout's place and width, fed from the send's gestures. A send's
/// plugin is never linked (no badge) and takes no drop of its own: a plugin let go on a card lands on the
/// column's drop layer, which reads the insertion point from the pointer.
///
/// A GAIN STAGE on the send (`SynopticSendPlugin.gainStage`) takes its face here as on the trunk: no editor
/// to open, no power button, its values read and written through `actions` (@see
/// SynopticGainStageControls).
struct SendChainCardView: View {
    let card: SynopticLayout.CardPlacement
    let send: SynopticSend
    let actions: SynopticActions

    var body: some View {
        let aux = send.id
        let p = card.plugin
        let selection = actions.sendPluginSelection?(aux) ?? []
        SynopticCardView(
            plugin: p,
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
            width: card.frame.width)
            .frame(width: card.frame.width, height: card.frame.height)
            // A refused send: its cards greyed, as its line is.
            .opacity(send.refusal == nil ? 1 : 0.55)
    }
}

/// The drop layer of a send's column: ONE invisible view under the whole column (its cards, its '+', its line),
/// a SIBLING laid before them — never an ancestor of the cards' drag sources (@see SynopticCardView.dropLayer).
/// The insertion point is read from the pointer (@see SendCardPlacement.insertIndex(at:)) and previewed as a
/// card-sized rectangle on that '+'.
struct SendColumnDropView: View {
    let placement: SynopticLayout.SendCardPlacement
    let actions: SynopticActions
    @State private var dropIndex: Int? = nil
    @State private var dropHintID = UUID()

    var body: some View {
        let f = placement.frame
        if let onDrop = actions.onSendBoxDrop {
            let send = placement.send
            Color.clear
                .frame(width: f.width, height: f.height)
                .contentShape(Rectangle())
                .onDrop(of: [.plainText],
                        delegate: SendColumnDropDelegate(
                            placement: placement, dropIndex: $dropIndex,
                            hintKey: "sendcolumn:\(dropHintID.uuidString)",
                            outcome: { index, flags in actions.sendBoxDropOutcome?(send.id, index, flags) },
                            onDrop: { index, payload, flags in onDrop(send.id, index, payload, flags) }))
                .overlay(alignment: .topLeading) {
                    if let i = dropIndex {
                        let r = placement.dropPreview(i)
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.accentColor.opacity(0.12))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: 2))
                            .frame(width: r.width, height: r.height)
                            .offset(x: r.minX - f.minX, y: r.minY - f.minY)
                            .allowsHitTesting(false)
                    }
                }
                .position(x: f.midX, y: f.midY)
        }
    }
}

// MARK: - A send in the hand: its preview, and the handle that takes it

/// The image AppKit shows under the pointer while a send is dragged — by its line or by its handle. Like
/// `PluginDragPreview` it is rendered outside the view hierarchy (explicit colours throughout), and it
/// names the send, which the default snapshot of a grip (an arrow and a cropped label) did not.
struct SendDragPreview: View {
    let name: String
    let live: Bool

    var body: some View {
        let tint = live ? Color(nsColor: .controlAccentColor) : Color.gray
        HStack(spacing: 5) {
            Image(systemName: FeatureIcons.auxSend)
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
/// (@see SendWire.handleCenter). Taken in the hand it carries the same payload as the send's line, so the
/// send is moved by dropping it on the "+" / cable / slot it should leave from — along the chain — exactly
/// as the line is. Laid by the canvas' ZStack over the wires, one per send; it positions itself.
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

/// A plugin drag over a send's column. Like `PluginDropDelegate`, it asks the resolver about the drag in
/// flight on every movement (the cursor, the band, the preview); unlike it, WHERE in the column the hand is
/// decides the insertion point, read from the pure layout (@see SendCardPlacement.insertIndex). Two refusals
/// speak on the band — a non-plain plugin, a full chain (@see SendBoxPluginRefusal) — and so does a send
/// card, which a send never takes.
struct SendColumnDropDelegate: DropDelegate {
    let placement: SynopticLayout.SendCardPlacement
    let dropIndex: Binding<Int?>
    let hintKey: String
    let outcome: (_ index: Int, _ flags: NSEvent.ModifierFlags) -> PluginDropOutcome?
    let onDrop: (_ index: Int, _ payload: PluginDragPayload, _ flags: NSEvent.ModifierFlags) -> Void

    private func carriesPlugin(_ info: DropInfo) -> Bool {
        info.itemProviders(for: [.plainText]).contains(where: PluginDrop.carries)
    }

    /// The insertion point under the hand (the end when the layout cannot say). `DropInfo.location` is in the
    /// layer's own coordinates, whose origin is the column's top-left corner.
    private func index(_ info: DropInfo) -> Int {
        let point = CGPoint(x: placement.frame.minX + info.location.x, y: placement.frame.minY + info.location.y)
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
            // No drag in flight to read: the legacy reading (⌥ copies, anything else moves).
            dropIndex.wrappedValue = i
            PluginDropHint.shared.present(hintKey, context: .sendChain)
            return DropProposal(operation: flags.contains(.option) ? .copy : .move)
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
