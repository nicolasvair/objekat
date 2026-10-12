import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

// MARK: - FX link block (header card and mix box)

/// The card that straddles the top edge of a bin's block — a plugin card's sibling, built on
/// `SynopticCardView`'s model: an opaque body with square-edged on/off at the left (the bin's common
/// on/off), then the name (the drag handle: it moves the whole block; a double click renames it), the
/// link badge (solid = follows the bin, hollow = detached; a click flips it), the ✕ and a thin level
/// line under the name. The ✕ is a small menu rather than a delete, because a bin is shared: removing
/// it from THIS object, leaving it while keeping the plugins, and dissolving it everywhere are three
/// different gestures. The colour is the card's rim; there is no colour dot — "next colour" is in the
/// right-click menu.
struct FXBlockHeaderView: View {
    let link: SynopticFXLink
    let rect: CGRect
    let pluginCount: Int
    let actions: SynopticActions

    @State private var renaming = false
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool
    @State private var dropTargeted = false
    @State private var dropHintID = UUID()

    private let toggleW: CGFloat = 26
    private var help: String { Ln("fxlink.help.members", link.memberCount, link.memberCount) }

    var body: some View {
        HStack(spacing: 0) {
            // on/off — a REAL button, full height, square edges (the bin's colour = on)
            Button { actions.onFXToggleEnabled?(link.blockID) } label: {
                ZStack {
                    Rectangle().fill(link.isEnabled ? link.color : Color.secondary.opacity(0.18))
                    Image(systemName: "power")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(link.isEnabled ? .white : .secondary)
                }
                .frame(width: toggleW)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("fxlink.help.power"))

            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    if renaming {
                        TextField(noLabel, text: $draft)
                            .textFieldStyle(.plain)
                            .font(Font(SynopticLayout.cardNameFont))
                            .focused($fieldFocused)
                            .onSubmit { commitRename() }
                            .onExitCommand { renaming = false }
                            .onChange(of: fieldFocused) { _, focused in if !focused { commitRename() } }
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(link.name)
                            .font(Font(SynopticLayout.cardNameFont))
                            .foregroundStyle(link.isEnabled ? Color.primary : Color.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { beginRename() }
                            .onDragIf(actions.dragProvider.map { f in { f(link.blockID) } }) {
                                FXBlockDragPreview(link: link, pluginCount: pluginCount)
                            }
                            .help(help)
                    }

                    // 🔗 — solid: follows the bin; hollow: detached. A click flips it. The same badge
                    // (size and look) as a plugin card's.
                    Button { actions.onFXToggleDetach?(link.blockID) } label: {
                        Image(systemName: "link")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(link.isDetached ? link.color.opacity(0.8) : .white)
                            .padding(3)
                            .background {
                                if link.isDetached {
                                    Circle().strokeBorder(link.color.opacity(0.55), lineWidth: 1.5)
                                } else {
                                    Circle().fill(link.color)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .help(link.isDetached ? L("fxlink.help.detached") : L("fxlink.help.attached"))

                    // ✕ — a small menu: remove from this object / leave and keep the plugins / dissolve.
                    Menu {
                        Button(L("fxlink.menu.remove")) { actions.onFXRemove?(link.blockID) }
                        Button(L("fxlink.menu.release")) { actions.onFXRelease?(link.blockID) }
                        Button(L("fxlink.menu.delete"), role: .destructive) { actions.onFXDelete?(link.blockID) }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 12, height: 14)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help(L("fxlink.help.close"))
                }

                Spacer(minLength: 0)

                // A thin level line under the name, like a card's — the track only for now: the bin has
                // no level of its own to read yet.
                Capsule()
                    .fill(Color.secondary.opacity(0.2))
                    .frame(height: 2)
            }
            .padding(.horizontal, 8)
            .padding(.top, 5)
            .padding(.bottom, 4)
        }
        .frame(width: rect.width, height: rect.height, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor))   // OPAQUE: it straddles the body's edge
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(link.color.opacity(link.isDetached ? 0.6 : 1), lineWidth: 1.5)
        )
        // A bin that is OFF reads like a card of a disabled container: greyed and dimmed.
        .saturation(link.isEnabled ? 1 : 0.25)
        .opacity(link.isEnabled ? 1 : 0.6)
        .contentShape(RoundedRectangle(cornerRadius: 8))
        // A plugin let go on the header goes to the END of the bin; a place where nothing would happen
        // does not light up (@see PluginDropDelegate). The drop layer is a SIBLING behind the content,
        // like the cards': the name carrying the `.onDrag` is a descendant of this view.
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.accentColor, lineWidth: dropTargeted ? 2 : 0)
        )
        .background(dropLayer)
        .contextMenu { menuItems }
    }

    @ViewBuilder private var dropLayer: some View {
        if let onDrop = actions.onDrop {
            let target = SynopticDropTarget.blockEnd(link.blockID)
            Color.clear
                .contentShape(Rectangle())
                .onDrop(of: [.plainText],
                        delegate: PluginDropDelegate(isTargeted: $dropTargeted,
                                                     hintKey: "header:\(dropHintID.uuidString)",
                                                     outcome: { actions.dropOutcome?(target, $0) },
                                                     onDrop: { payload, flags in onDrop(target, payload, flags) }))
        }
    }

    @ViewBuilder private var menuItems: some View {
        Button(L("fxlink.menu.rename")) { beginRename() }
        Button(L("fxlink.menu.next_color")) { actions.onFXCycleColor?(link.blockID) }
        Button(link.isDetached ? L("fxlink.menu.reattach") : L("fxlink.menu.detach")) {
            actions.onFXToggleDetach?(link.blockID)
        }
        Divider()
        Button(L("fxlink.menu.release")) { actions.onFXRelease?(link.blockID) }
        Button(L("fxlink.menu.remove")) { actions.onFXRemove?(link.blockID) }
        Button(L("fxlink.menu.delete"), role: .destructive) { actions.onFXDelete?(link.blockID) }
    }

    private func beginRename() {
        draft = link.name
        renaming = true
        fieldFocused = true
    }

    private func commitRename() {
        guard renaming else { return }
        renaming = false
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty, name != link.name { actions.onFXRename?(link.blockID, name) }
    }
}

/// The image under the pointer while a bin's block is dragged by its header: its name, its colour and
/// how many plugins it carries. Same constraint as `PluginDragPreview` — rendered outside the view
/// hierarchy, so explicit colours throughout.
struct FXBlockDragPreview: View {
    let link: SynopticFXLink
    let pluginCount: Int

    private var width: CGFloat { SynopticLayout.fxHeaderW(name: link.name) }

    var body: some View {
        VStack(spacing: 1) {
            Text(link.name)
                .font(Font(SynopticLayout.cardNameFont))
                .foregroundStyle(Color.primary)
                .lineLimit(1)
            Text(Ln("fxlink.drag.plugins", pluginCount, pluginCount))
                .font(.system(size: 10))
                .foregroundStyle(Color.secondary)
        }
        .padding(.horizontal, 10)
        .frame(width: width, height: SynopticLayout.fxHeaderCardH)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(link.color, lineWidth: 1.5))
    }
}

/// The bin's OUTPUT SECTION, as a rounded box nested at the foot of its block — pan · volume · mute,
/// left to right, in the order and the style of the 'clip' zone (@see ClipMixZoneView) but with no title:
/// the box has nothing to name, the block already does. While the block follows the bin these are the
/// bin's (every member moves together); once detached they are the block's own. The wire stops at the
/// box's head and starts again at its foot, so the controls sit on a plain background.
struct FXBlockMixView: View {
    let link: SynopticFXLink
    let block: SynopticLayout.FXBlockPlacement
    let actions: SynopticActions

    private func panLabel(_ p: Double) -> String {
        if abs(p) < 0.01 { return "C" }
        return p < 0 ? "L \(Int((-p * 100).rounded()))%" : "R \(Int((p * 100).rounded()))%"
    }

    /// A slot's centre in the box's own coordinates.
    private func local(_ slot: CGRect) -> CGPoint {
        CGPoint(x: slot.midX - block.mixRect.minX, y: slot.midY - block.mixRect.minY)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Flush with the body's bottom edge: the bottom corners are the body's own radius.
            UnevenRoundedRectangle(topLeadingRadius: SynopticLayout.fxMixTopCorner,
                                   bottomLeadingRadius: SynopticLayout.fxBodyCorner,
                                   bottomTrailingRadius: SynopticLayout.fxBodyCorner,
                                   topTrailingRadius: SynopticLayout.fxMixTopCorner)
                .fill(Color.secondary.opacity(0.06))
                .overlay(UnevenRoundedRectangle(topLeadingRadius: SynopticLayout.fxMixTopCorner,
                                                bottomLeadingRadius: SynopticLayout.fxBodyCorner,
                                                bottomTrailingRadius: SynopticLayout.fxBodyCorner,
                                                topTrailingRadius: SynopticLayout.fxMixTopCorner)
                    .strokeBorder(Color.secondary.opacity(0.35), lineWidth: 1))

            DragValueBox(value: Double(link.pan),
                         format: { panLabel($0) },
                         range: -1...1, pointsPerStep: 80, snap: false, width: block.panSlot.width,
                         keyStep: 0.1,
                         parse: { Double($0.replacingOccurrences(of: ",", with: ".")).map { $0 / 100 } },
                         help: L("help.drag.pan"),
                         onBegin: { actions.onFXBeginEdit?() },
                         onChange: { actions.onFXSetPan?(link.blockID, Float($0)) },
                         onReset: { actions.onFXBeginEdit?(); actions.onFXSetPan?(link.blockID, 0) })
                .position(local(block.panSlot))

            GainDbControl(dB: link.gainDb, minDb: -96, maxDb: 40,
                          onBegin: { actions.onFXBeginEdit?() }) { newDB in
                actions.onFXSetGain?(link.blockID, newDB)
            }
            .position(local(block.volumeSlot))

            muteButton
                .position(local(block.muteSlot))
        }
        .frame(width: block.mixRect.width, height: block.mixRect.height)
        .opacity(link.isEnabled ? 1 : 0.5)
    }

    /// The same button as the 'clip' zone's (@see ClipMixZoneView.muteButton).
    private var muteButton: some View {
        Button {
            actions.onFXBeginEdit?()
            actions.onFXToggleMute?(link.blockID)
        } label: {
            Image(systemName: link.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(link.muted ? Color.red : Color.secondary)
                .frame(width: block.muteSlot.width, height: block.muteSlot.height)
                .background(RoundedRectangle(cornerRadius: 4)
                    .fill(link.muted ? Color.red.opacity(0.18) : Color.secondary.opacity(0.18)))
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .strokeBorder((link.muted ? Color.red : Color.secondary).opacity(0.45)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("common.mute"))
    }
}
