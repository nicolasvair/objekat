import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

// MARK: - Plugin card

struct SynopticCardView: View {
    let plugin: SynopticPlugin
    let isSelected: Bool
    let onSelect: () -> Void
    var onOpenEditor: (() -> Void)? = nil
    let onToggleBypass: () -> Void
    let onRemove: () -> Void
    var dragProvider: (() -> NSItemProvider)? = nil
    /// How many plugins this drag actually carries — the same count `dragProvider`'s own payload
    /// carries (a card taken FROM the selection drags the whole selection, one taken from outside
    /// drags itself alone), so the preview's "+N-1" badge never disagrees with what a drop receives.
    var dragCount: Int = 1
    /// What a release on this card would do, for the cursor and the band (@see PluginDropOutcome).
    var dropOutcome: (_ flags: NSEvent.ModifierFlags) -> PluginDropOutcome? = { _ in nil }
    /// Dropping ANOTHER plugin on this card (the branch's axis): the payload and the modifiers held at the
    /// release. nil = the card does not receive (the demo).
    var onDropPlugin: ((_ payload: PluginDragPayload, _ flags: NSEvent.ModifierFlags) -> Void)? = nil
    /// A send card let go on this card (just before it, in its series).
    var onDropSend: ((_ payload: SendDragPayload) -> Void)? = nil
    /// Unlinks this instance from its group (nil = the card cannot be driven, e.g. the demo).
    var onUnlink: (() -> Void)? = nil
    var onRelink: (() -> Void)? = nil
    /// The number of linked instances (for the tooltip). 0 if unlinked.
    var linkSiblingCount: Int = 0
    /// This plugin's sidechain key, said in a tooltip behind a small glyph (nil = none).
    var sidechainBadge: SidechainBadge? = nil

    @State private var dropTargeted = false
    @State private var dropHintID = UUID()

    /// nil = sized on its own name (@see SynopticLayout.cardWidth); the MIDI zone's instrument
    /// slot passes its fixed width.
    var width: CGFloat? = nil
    /// Non-nil = this card is the ARA SOURCE of the object (Melodyne), not an FX: the SAME card as any
    /// plugin's (on/off column, name, ✕, VU line), minus what a source has no business with — no link, no
    /// drag, no selection, nothing dropped on it — plus an "ARA" tag and, while the plugin analyses the
    /// audio, a spinner. The power button switches the source off WITHOUT losing its retouches (the
    /// object then plays its dry file; @see `EditViewModel.setARAEnabled`); the ✕ takes the source off for
    /// good. The VU line is the one every card has: a plugin's level, still 0 for a source.
    var ara: SynopticARA? = nil
    private var isARA: Bool { ara != nil }
    private var cardW: CGFloat { width ?? SynopticLayout.cardWidth(for: plugin) }
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
            .help(isARA ? L("synoptic.ara.bypass") : L("synoptic.bypass"))

            // Content: NAME (the drag area) · ✕  +  a thin VU meter
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    // NAME — the ONLY drag area (reorder / move) plus a double click for the editor
                    Text(plugin.name)
                        .font(Font(SynopticLayout.cardNameFont))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(plugin.isEnabled ? .primary : .secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { (onOpenEditor ?? onSelect)() }
                        .onDragIf(dragProvider) {
                            PluginDragPreview(plugin: plugin, dragCount: dragCount)
                        }
                        .help(isARA ? L("synoptic.ara.open") : L("synoptic.openPlugin"))

                    // 🔗 — the link toggle. Linked: a solid badge, tinted by the group's colour.
                    // DETACHED: the badge REMAINS, hollow and in the same tint — the group left is
                    // therefore recognisable by eye, and a click takes it back (@see relinkPlugin).
                    // Never inside a bin's block: the block's header carries the link.
                    if plugin.showsLinkBadge {
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

                    // Melodyne is still reading the audio: the editor will open once it is done.
                    if let ara, ara.analysing {
                        ProgressView().controlSize(.mini)
                            .help(L("synoptic.ara.analysing"))
                    }

                    // ✕ — remove the fx (always visible)
                    Button(action: onRemove) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(isARA ? L("synoptic.ara.remove") : L("synoptic.removePlugin"))
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
                .strokeBorder(isSelected ? Color.accentColor : plugin.color.opacity(plugin.showsLinkedStyle ? 1 : 0.7),
                              lineWidth: isSelected ? 2 : (plugin.showsLinkedStyle ? 2 : 1))
        )
        .shadow(color: plugin.showsLinkedStyle ? plugin.color.opacity(0.6) : .clear,
                radius: plugin.showsLinkedStyle ? 5 : 0)
        .opacity(plugin.isEnabled ? 1 : 0.5)
        // A card of a bin that is switched OFF: its own state (on / off) and its identity colours
        // stay, but the whole card is greyed and dimmed — the look of a state inherited from a
        // disabled container. A plugin that is itself off is already at half opacity with a grey
        // button, so the two remain tellable apart: on-and-greyed keeps a filled button.
        .saturation(plugin.greyedByBlock ? 0.25 : 1)
        .opacity(plugin.greyedByBlock ? 0.6 : 1)
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
        // The sidechain key, OUTSIDE the card: a small tag hanging above its top-left corner, in the
        // gap of the series (the wire arrives at the card's centre). Orange when the key is refused.
        .overlay(alignment: .topLeading) {
            if let badge = sidechainBadge {
                HStack(spacing: 3) {
                    Image(systemName: "waveform.path")
                        .font(.system(size: 8, weight: .bold))
                    Text(verbatim: badge.text)
                        .font(.system(size: 9, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .foregroundStyle(badge.active ? plugin.color : Color.orange)
                .padding(.horizontal, 5)
                .frame(height: 13)
                .frame(maxWidth: cardW / 2 - 8, alignment: .leading)
                .background(Capsule().fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(Capsule().strokeBorder((badge.active ? plugin.color : Color.orange).opacity(0.6), lineWidth: 1))
                .fixedSize(horizontal: false, vertical: true)
                .offset(x: 4, y: -15)
                .help(badge.text)
            }
        }
        // The ARA source's tag: the sidechain's capsule, in the same spot above the top-left corner.
        .overlay(alignment: .topLeading) {
            if isARA {
                Text(verbatim: "ARA")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(plugin.color)
                    .padding(.horizontal, 5)
                    .frame(height: 13)
                    .background(Capsule().fill(Color(nsColor: .controlBackgroundColor)))
                    .overlay(Capsule().strokeBorder(plugin.color.opacity(0.6), lineWidth: 1))
                    .fixedSize()
                    .offset(x: 4, y: -15)
                    .help(L("synoptic.ara.source"))
            }
        }
    }

    @ViewBuilder private var dropLayer: some View {
        if let onDropPlugin {
            Color.clear
                .contentShape(Rectangle())
                .onDrop(of: [.plainText],
                        delegate: PluginDropDelegate(isTargeted: $dropTargeted,
                                                     hintKey: "card:\(dropHintID.uuidString)",
                                                     outcome: dropOutcome,
                                                     onDrop: onDropPlugin,
                                                     onSendDrop: onDropSend))
        }
    }
}

/// The image AppKit shows under the pointer while a plugin card is being dragged, in place of its
/// default "grabbed view" snapshot — the bare name cropped to its own label frame, which said
/// nothing about what letting go does. Rendered OUTSIDE the view hierarchy (AppKit snapshots it
/// once, off to the side), hence explicit colours throughout rather than anything that leans on
/// an ancestor's environment.
struct PluginDragPreview: View {
    let plugin: SynopticPlugin
    var dragCount: Int = 1

    /// The size of the card being carried (its name whole, @see SynopticLayout.cardWidth),
    /// nothing more — the modifiers are explained by the band at the bottom of the timeline.
    private var width: CGFloat { SynopticLayout.cardWidth(for: plugin) }
    /// Shared with the drop targets' link badge, which must be laid OUTSIDE this card: the drag
    /// image is drawn by the system above every window, so nothing of ours can sit on top of it.
    static let height: CGFloat = 32

    var body: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(plugin.color, lineWidth: 1.5)
                )

            Text(plugin.name)
                .font(Font(SynopticLayout.cardNameFont))
                .foregroundStyle(Color.primary)
                .lineLimit(1)
                .padding(.horizontal, dragCount > 1 ? 30 : 10)   // symmetric: clear of the +N-1 badge, still centred
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)

            if dragCount > 1 {
                Text(verbatim: "+\(dragCount - 1)")   // the OTHER plugins carried along, not N copies of this one
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(plugin.color))
                    .padding(6)
            }
        }
        .frame(width: width, height: Self.height)
    }
}

/// A drop target covering the CABLE of a branch/series (a band rendered UNDER the cards):
/// dropping a plugin on the axis inserts it into that branch — an EMPTY parallel branch
/// included. A discreet highlight on hover. `onDrop` closes over the zone's (seriesID, insertIndex).
struct CableDropView: View {
    let rect: CGRect          // the DETECTION zone (wide, transparent)
    let previewFrame: CGRect  // the PREVIEW shown on hover (card-sized, on the cable)
    /// What a release here would do, for the cursor and the band (@see PluginDropOutcome).
    var outcome: (_ flags: NSEvent.ModifierFlags) -> PluginDropOutcome? = { _ in nil }
    let onDrop: (_ payload: PluginDragPayload, _ flags: NSEvent.ModifierFlags) -> Void
    /// A send card let go on this cable (nil = ignored).
    var onSendDrop: ((_ payload: SendDragPayload) -> Void)? = nil
    @State private var targeted = false
    @State private var dropHintID = UUID()

    var body: some View {
        // The target covers the whole `rect` (easy to aim at) but stays invisible; only a
        // card-sized rectangle, laid on the cable at `previewFrame`, lights up on hover —
        // a preview of exactly where the plugin will land.
        Color.clear
            .frame(width: rect.width, height: rect.height)
            .contentShape(Rectangle())
            .onDrop(of: [.plainText],
                    delegate: PluginDropDelegate(isTargeted: $targeted,
                                                 hintKey: "cable:\(dropHintID.uuidString)",
                                                 outcome: outcome,
                                                 onDrop: onDrop,
                                                 onSendDrop: onSendDrop))
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

/// A fixed slot of the sends as a drop target: invisible, a send card let go in the band takes that
/// position. Only a send card is received (a plugin dropped here is refused by the cursor: the band
/// across the trunk is for sends). The preview is a card-sized rectangle at the slot's anchor.
struct SendSlotDropView: View {
    let zone: SynopticLayout.SendSlotDrop
    var outcome: () -> PluginDropOutcome? = { nil }
    let onSendDrop: (_ payload: SendDragPayload) -> Void
    @State private var targeted = false
    @State private var dropHintID = UUID()

    var body: some View {
        Color.clear
            .frame(width: zone.rect.width, height: zone.rect.height)
            .contentShape(Rectangle())
            .onDrop(of: [.plainText],
                    delegate: PluginDropDelegate(isTargeted: $targeted,
                                                 hintKey: "sendslot:\(dropHintID.uuidString)",
                                                 outcome: { _ in outcome() },
                                                 onDrop: { _, _ in },
                                                 onSendDrop: onSendDrop))
            .overlay(alignment: .topLeading) {
                if targeted {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.accentColor.opacity(0.12))
                        .overlay(RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [4, 3])))
                        .frame(width: zone.previewFrame.width, height: zone.previewFrame.height)
                        .offset(x: zone.previewFrame.minX - zone.rect.minX,
                                y: zone.previewFrame.minY - zone.rect.minY)
                }
            }
            .position(x: zone.rect.midX, y: zone.rect.midY)
    }
}

/// Reliable delivery of a plugin drop (on a card's axis, on a branch's cable or on a bin's header). We go
/// through a `DropDelegate` — for the card, laid on a `.background` layer, because an `.onDrop` laid on
/// an ANCESTOR of an `.onDrag` view is not delivered by macOS.
///
/// The CURSOR and the band say what a release would do NOW: `outcome` asks the resolver
/// (@see EditViewModel.pluginDropOutcome) about the drag in flight (@see PluginDragSession), which is the
/// only way a target can answer "forbidden" before the hand lets go. A forbidden place does not light up,
/// does not show the band and shows the refusing cursor. With no drag in flight to read (nil) the legacy
/// reading holds: ⌥ copies, anything else moves.
struct PluginDropDelegate: DropDelegate {
    let isTargeted: Binding<Bool>
    /// This target's key for the band at the bottom of the timeline (@see PluginDropHint):
    /// one per card / cable, since neighbours overlap their enter and exit.
    let hintKey: String
    var outcome: (_ flags: NSEvent.ModifierFlags) -> PluginDropOutcome? = { _ in nil }
    let onDrop: (_ payload: PluginDragPayload, _ flags: NSEvent.ModifierFlags) -> Void
    /// A SEND card let go here (it does not decode as a plugin payload). nil = this target ignores it.
    var onSendDrop: ((_ payload: SendDragPayload) -> Void)? = nil

    private func carriesPlugin(_ info: DropInfo) -> Bool {
        info.itemProviders(for: [.plainText]).contains(where: PluginDrop.carries)
    }

    func validateDrop(info: DropInfo) -> Bool { carriesPlugin(info) }

    /// Reads the drag in flight: lights the target and speaks on the band when the release would DO
    /// something, withdraws both when it would not. Returns the cursor's proposal.
    private func present() -> DropProposal {
        let flags = NSEvent.modifierFlags
        guard let o = outcome(flags) else {
            isTargeted.wrappedValue = true
            PluginDropHint.shared.present(hintKey, context: .sameChain)
            return DropProposal(operation: flags.contains(.option) ? .copy : .move)
        }
        guard let ctx = o.hintContext(plainContext: .sameChain) else {
            isTargeted.wrappedValue = false
            PluginDropHint.shared.leave(hintKey)
            return DropProposal(operation: .forbidden)
        }
        // A refused send speaks on the band (why) but does not light the target.
        isTargeted.wrappedValue = !o.isRefusal
        PluginDropHint.shared.present(hintKey, context: ctx)
        return DropProposal(operation: o.operation)
    }

    func dropEntered(info: DropInfo) {
        guard carriesPlugin(info) else { return }
        _ = present()
    }
    func dropExited(info: DropInfo) {
        isTargeted.wrappedValue = false
        PluginDropHint.shared.leave(hintKey)
    }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard carriesPlugin(info) else {
            isTargeted.wrappedValue = false
            PluginDropHint.shared.leave(hintKey)
            return DropProposal(operation: .forbidden)
        }
        return present()
    }
    func performDrop(info: DropInfo) -> Bool {
        isTargeted.wrappedValue = false
        PluginDropHint.shared.leave(hintKey)
        guard let p = info.itemProviders(for: [.plainText]).first(where: PluginDrop.carries) else { return false }
        // The modifiers are read NOW: the provider answers later, when the hand has let go of them.
        let flags = NSEvent.modifierFlags
        PluginDragSession.shared.end()
        SendDragSession.shared.end()
        let onSendDrop = self.onSendDrop
        p.loadDataRepresentation(forTypeIdentifier: UTType.plainText.identifier) { data, _ in
            guard let data else { return }
            if let payload = try? JSONDecoder().decode(PluginDragPayload.self, from: data) {
                DispatchQueue.main.async { onDrop(payload, flags) }
            } else if let send = try? JSONDecoder().decode(SendDragPayload.self, from: data) {
                DispatchQueue.main.async { onSendDrop?(send) }
            }
        }
        return true
    }
}
