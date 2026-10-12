import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

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
            .onDragIf(actions.sendDragProvider.map { f in { f(send.id) } })
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

// MARK: - A send's box (INC 3): the plugins ON the send

/// A send as the signal view draws it. With no plugin: today's card, plus a small "+" that shows above
/// it on hover. With plugins: a BOX, read top to bottom in the order of the signal (Q-U19) — one compact
/// row per plugin, the "+" after the last one, then the send's own line (the card: aux, level, on/off)
/// at the bottom. The wire from the trunk arrives at the top.
///
/// A plugin is let go on the box, between two rows (the insertion line says where), on the "+" or on the
/// line (= the end): nothing = move, ⌥ = copy, ⌘ = copy as well — a send's plugin is never linked. A send
/// card let go here is refused (a box takes plugins, not sends).
struct SendBoxView: View {
    let placement: SynopticLayout.SendCardPlacement
    let actions: SynopticActions
    @State private var hovering = false
    /// The insertion slot a plugin drag is aiming at (nil = none).
    @State private var dropIndex: Int? = nil
    @State private var dropHintID = UUID()

    private var send: SynopticSend { placement.send }
    private var isRouted: Bool { send.enabled && send.levelDb > sendMinDb && send.refusal == nil }

    /// The rect this view fills on the canvas: the box; with no plugin, the card plus the strip above
    /// it where the hover "+" shows.
    static func zone(of p: SynopticLayout.SendCardPlacement) -> CGRect {
        p.hasPlugins ? p.frame : p.frame.union(p.plusRect)
    }

    var body: some View {
        let zone = Self.zone(of: placement)
        let selection = actions.sendPluginSelection?(send.id) ?? []
        VStack(spacing: 0) {
            if placement.hasPlugins {
                ForEach(send.plugins) { p in
                    SendPluginRowView(
                        plugin: p,
                        isSelected: selection.contains(p.id),
                        onSelect: { actions.onSendPluginClick?(send.id, p.id, NSEvent.modifierFlags) },
                        // A refused send has no engine plugin: nothing to open.
                        onOpen: send.refusal == nil ? actions.onSendPluginOpen.map { f in { f(send.id, p.id) } } : nil,
                        onToggle: { actions.onSendPluginToggle?(send.id, p.id) },
                        onRemove: { actions.onSendPluginRemove?(send.id, p.id) },
                        dragProvider: actions.sendPluginDragProvider.map { f in { f(send.id, p.id) } })
                        .frame(height: SynopticLayout.sendPluginRowH)
                }
                plusRow.frame(height: SynopticLayout.sendPlusRowH)
            } else {
                // No box yet: the "+" only shows while the hand is over the card (the menu has the
                // same entry). Not hit-testable otherwise — the strip may lie over the card above.
                plusRow.frame(height: SynopticLayout.sendPlusRowH)
                    .opacity(hovering ? 1 : 0)
                    .allowsHitTesting(hovering)
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
        // The drop layer: a SIBLING behind the content, never an ancestor of the rows' drag sources
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
        .onHover { hovering = $0 }
        // A refused send: the whole box greyed, the reason as its tooltip (the card's own text).
        .opacity(placement.hasPlugins && send.refusal != nil ? 0.55 : 1)
        .helpIf(placement.hasPlugins ? send.refusal : nil)
    }

    /// The "+": the plugin picker, aimed at this send.
    private var plusRow: some View {
        HStack(spacing: 0) {
            Button { actions.onSendPluginAdd?(send.id) } label: {
                Image(systemName: "plus")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 16)
                    .background(RoundedRectangle(cornerRadius: 4)
                        .fill(Color(nsColor: .controlBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.secondary.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [2, 2])))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(actions.onSendPluginAdd == nil)
            .help(L("synoptic.send.plugin.add.help"))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
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

/// One plugin of a send's box: the bypass dot, the name (click = select, double click = editor, drag =
/// take it), the cross on hover. No link pastille — a send's plugin is never linked — and no VU.
struct SendPluginRowView: View {
    let plugin: SynopticSendPlugin
    let isSelected: Bool
    let onSelect: () -> Void
    var onOpen: (() -> Void)? = nil
    let onToggle: () -> Void
    let onRemove: () -> Void
    var dragProvider: (() -> NSItemProvider)? = nil
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onToggle) {
                Circle()
                    .fill(plugin.enabled ? Color.accentColor : Color.secondary.opacity(0.35))
                    .frame(width: 8, height: 8)
                    .frame(width: 16, height: SynopticLayout.sendPluginRowH)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("synoptic.bypass"))
            Text(plugin.name)
                .font(.system(size: 10))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(plugin.enabled ? .primary : .secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { (onOpen ?? onSelect)() }
                .onDragIf(dragProvider)
                .help(L("synoptic.openPlugin"))
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: SynopticLayout.sendPluginRowH)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0)
            .help(L("synoptic.send.plugin.remove.help"))
        }
        .padding(.horizontal, 5)
        .background(isSelected ? Color.accentColor.opacity(0.22) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .onHover { hovering = $0 }
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
