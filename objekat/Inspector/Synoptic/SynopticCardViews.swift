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

    /// The bound view's actions — read ONLY by a gain stage's faces (@see SynopticGainStageControls): its
    /// values (`gainStageValues`), its writes (`onSetGainStage`, `onBeginGainEdit`) and the automation row a
    /// touched box names (`onTouchParam`). nil = the stage's boxes show a dash and answer nothing. A plugin
    /// card has no use for it.
    var actions: SynopticActions? = nil

    @State private var dropTargeted = false
    @State private var dropHintID = UUID()
    /// The pointer is over the card — only a gain stage uses it (its ✕ shows on hover).
    @State private var hovering = false

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
        Group {
            if let face = plugin.gainStage {
                SynopticGainStageControls(plugin: plugin, face: face, hovering: hovering,
                                          dragProvider: dragProvider, dragCount: dragCount,
                                          onRemove: onRemove, actions: actions)
            } else {
                pluginContent
            }
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
        .onHover { inside in if plugin.gainStage != nil { hovering = inside } }
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
        // The trims, OUTSIDE the card: a tag under its bottom-left corner, only when one is not neutral.
        .overlay(alignment: .bottomLeading) {
            if plugin.trimInDb != 0 || plugin.trimOutDb != 0 {
                Text(verbatim: PluginExpertBar.dbText(plugin.trimInDb) + " / " + PluginExpertBar.dbText(plugin.trimOutDb))
                    .font(.system(size: 8, weight: .semibold).monospacedDigit())
                    .foregroundStyle(plugin.color)
                    .padding(.horizontal, 5)
                    .frame(height: 12)
                    .background(Capsule().fill(Color(nsColor: .controlBackgroundColor)))
                    .overlay(Capsule().strokeBorder(plugin.color.opacity(0.6), lineWidth: 1))
                    .fixedSize()
                    .offset(x: 4, y: 14)
                    .help(L("synoptic.card.trims.help", PluginExpertBar.dbText(plugin.trimInDb),
                            PluginExpertBar.dbText(plugin.trimOutDb)))
            }
        }
        // The sidechain key, OUTSIDE the card: a small tag hanging above its top-left corner, in the
        // gap of the series (the wire arrives at the card's centre). Orange when the key is refused.
        .overlay(alignment: .topLeading) {
            if let badge = sidechainBadge {
                HStack(spacing: 3) {
                    Image(systemName: FeatureIcons.sidechainReception)
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

    /// The ordinary face: on/off · name · link badge · ✕, and the VU line.
    private var pluginContent: some View {
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
                            Image(systemName: FeatureIcons.fxLink)
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
                SynopticCardVULine(pluginID: plugin.id, fallback: plugin.vu)
            }
            .padding(.horizontal, 8)
            .padding(.top, 5)
            .padding(.bottom, 4)
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

/// A card's VU meter: a very thin horizontal line, right at the bottom (a plugin's level, 0...1).
///
/// It READS its level itself, from the store of the `SynopticBoundView` above it (environment), so a
/// refresh invalidates this line and nothing else. With no store above (the demo sheet) it draws
/// `fallback`, the plugin's made-up `vu`.
struct SynopticCardVULine: View {
    let pluginID: UUID
    var fallback: Double = 0
    @Environment(\.synopticLevels) private var store

    var body: some View {
        let vu = store.map { $0.levels[pluginID] ?? 0 } ?? fallback
        Capsule()
            .fill(Color.secondary.opacity(0.2))
            .frame(height: 2)
            .overlay(alignment: .leading) {
                GeometryReader { g in
                    // Each ZONE of the lit part takes its own colour (green, then yellow past -18 dBFS,
                    // orange past -6, red past 0): only the portion over a threshold changes, never the
                    // whole bar.
                    let w = g.size.width
                    let lit = max(0, min(1, vu))
                    ZStack(alignment: .leading) {
                        ForEach(VUScale.zones.indices, id: \.self) { i in
                            let z = VUScale.zones[i]
                            let from = z.from, to = min(z.to, lit)
                            if to > from {
                                Rectangle().fill(z.color)
                                    .frame(width: (to - from) * w)
                                    .offset(x: from * w)
                            }
                        }
                    }
                    .frame(width: w, alignment: .leading)
                    .clipShape(Capsule())
                }
            }
    }
}

// MARK: - Gain-stage faces (docs/plan_synoptic_rework.md §B.4)

/// The inside of a GAIN STAGE's card — the card itself (frame, halo, selection, drop layer, drag image) is
/// `SynopticCardView`'s, so a stage sits in a chain like any plugin. Two faces, no power button (a stage has
/// no bypass of its own; a bin's common on/off still takes it with the rest of the bin) and no editor:
///
///  - `.gain`: grip · the dB box · ✕ (on hover);
///  - `.gainPanMute`: grip · pan · dB box · mute · ✕ (on hover) — the old FX link output section, as a card.
///
/// The grip is the drag handle (the boxes keep their own drags: a value box and a card drag cannot share
/// a view). The boxes are the signal view's usual `DragValueBox`: drag ↑/↓, a click then ↑/↓, a digit to type,
/// ⌫ or a double click = back to neutral. The gain's range is the stage's ENGINE range (±24 dB,
/// `GainStageValues.gainRange`); a stored value outside it is shown as it is. The values are READ from the
/// engine at every render and every half second (`actions.gainStageValues`: an undo, a linked instance's
/// edit or an automation moves them without this view being told) and WRITTEN through
/// `actions.onSetGainStage`, the undo point being `actions.onBeginGainEdit` at the start of each gesture.
/// A parameter driven by a curve greys its box; touching a box names the 'future automation' row
/// (`actions.onTouchParam`).
struct SynopticGainStageControls: View {
    let plugin: SynopticPlugin
    let face: SynopticGainStageFace
    /// The pointer is over the card: the ✕ shows.
    let hovering: Bool
    var dragProvider: (() -> NSItemProvider)? = nil
    var dragCount: Int = 1
    let onRemove: () -> Void
    var actions: SynopticActions? = nil

    /// Bumped after each write and by the refresh timer: the values live in the engine, which nothing
    /// observes, so a re-read has to be provoked.
    @State private var rev = 0
    private let refresh = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    private static let gainRange = Double(GainStageValues.gainRange.lowerBound)...Double(GainStageValues.gainRange.upperBound)
    private static let panRange = Double(GainStageValues.panRange.lowerBound)...Double(GainStageValues.panRange.upperBound)

    private var values: SynopticGainStageValues? {
        _ = rev
        return actions?.gainStageValues?(plugin.id)
    }
    private var canWrite: Bool { actions?.onSetGainStage != nil }

    // MARK: Body

    var body: some View {
        let v = values
        VStack(spacing: 0) {
            HStack(spacing: face == .gain ? 4 : 3) {
                grip
                if face == .gain { Spacer(minLength: 0) }
                if face == .gainPanMute { panBox(v) }
                gainBox(v)
                if face == .gainPanMute { muteButton(v) }
                if face == .gain { Spacer(minLength: 0) }
                removeButton
            }
            .padding(.horizontal, face == .gain ? 8 : 4)
            .padding(.top, 5)

            Spacer(minLength: 0)

            SynopticCardVULine(pluginID: plugin.id, fallback: plugin.vu)
                .padding(.horizontal, face == .gain ? 8 : 4)
                .padding(.bottom, 4)
        }
        .onReceive(refresh) { _ in rev &+= 1 }
    }

    // MARK: Pieces

    /// A 2 × 3 grid of dots: the drag handle (reorder / move; ⌥ copies, ⌘ links across objects, like a
    /// plugin's name).
    private var grip: some View {
        HStack(spacing: 2) {
            ForEach(0..<2, id: \.self) { _ in
                VStack(spacing: 2) {
                    ForEach(0..<3, id: \.self) { _ in
                        Circle().fill(Color.secondary.opacity(0.7)).frame(width: 2.5, height: 2.5)
                    }
                }
            }
        }
        .frame(width: 10, height: 18)
        .contentShape(Rectangle())
        .onDragIf(dragProvider) { PluginDragPreview(plugin: plugin, dragCount: dragCount) }
        .help(L("synoptic.gainStage.grip"))
    }

    /// ✕ — remove the stage. Always laid (so the boxes do not shift), visible and clickable on hover only.
    private var removeButton: some View {
        Button(action: onRemove) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 10, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(hovering ? 1 : 0)
        .allowsHitTesting(hovering)
        .help(L("synoptic.gainStage.remove"))
    }

    private func dbLabel(_ x: Double) -> String { x == 0 ? "0 dB" : String(format: "%+.0f dB", x) }

    private func panLabel(_ p: Double) -> String {
        if abs(p) < 0.01 { return "C" }
        return p < 0 ? "L \(Int((-p * 100).rounded()))%" : "R \(Int((p * 100).rounded()))%"
    }

    private func touch(_ paramID: String) {
        actions?.onTouchParam?(.plugin(pluginKey: plugin.id, paramID: paramID))
    }

    private func write(gain: Float? = nil, pan: Float? = nil, muted: Bool? = nil) {
        actions?.onSetGainStage?(plugin.id, gain, pan, muted)
        rev &+= 1
    }

    private func gainBox(_ v: SynopticGainStageValues?) -> some View {
        DragValueBox(value: Double(v?.gainDb ?? 0),
                     format: { v == nil ? "–" : dbLabel($0) },
                     range: Self.gainRange,
                     pointsPerStep: 6, snap: true, width: face == .gain ? 46 : 44,
                     keyStep: 1,
                     help: L("help.drag.volume"),
                     onTouch: { touch(GainStageValues.gainParamID) },
                     onBegin: { actions?.onBeginGainEdit?() },
                     onChange: { write(gain: Float($0)) },
                     onReset: { actions?.onBeginGainEdit?(); write(gain: 0) })
            .automationLocked(v?.gainAutomated == true)
            .disabled(v == nil || !canWrite)
    }

    private func panBox(_ v: SynopticGainStageValues?) -> some View {
        DragValueBox(value: Double(v?.pan ?? 0),
                     format: { v == nil ? "–" : panLabel($0) },
                     range: Self.panRange,
                     pointsPerStep: 80, snap: false, width: 46,
                     keyStep: 0.1,
                     parse: { Double($0.replacingOccurrences(of: ",", with: ".")).map { $0 / 100 } },
                     help: L("help.drag.pan"),
                     onTouch: { touch(GainStageValues.panParamID) },
                     onBegin: { actions?.onBeginGainEdit?() },
                     onChange: { write(pan: Float($0)) },
                     onReset: { actions?.onBeginGainEdit?(); write(pan: 0) })
            .automationLocked(v?.panAutomated == true)
            .disabled(v == nil || !canWrite)
    }

    /// The same button as the 'clip' zone's (@see ClipMixZoneView.muteButton).
    private func muteButton(_ v: SynopticGainStageValues?) -> some View {
        let muted = v?.muted ?? false
        return Button {
            touch(GainStageValues.muteParamID)
            actions?.onBeginGainEdit?()
            write(muted: !muted)
        } label: {
            Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(muted ? Color.red : Color.secondary)
                .frame(width: 18, height: 18)
                .background(RoundedRectangle(cornerRadius: 4)
                    .fill(muted ? Color.red.opacity(0.18) : Color.secondary.opacity(0.18)))
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .strokeBorder((muted ? Color.red : Color.secondary).opacity(0.45)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("common.mute"))
        .automationLocked(v?.muteAutomated == true)
        .disabled(v == nil || !canWrite)
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
