import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

// MARK: - FX link block (header card)

/// The card that straddles the top edge of a bin's block — a plugin card's sibling, built on
/// `SynopticCardView`'s model: an opaque body with square-edged on/off at the left (the bin's common
/// on/off), then a chevron (fold / unfold), the name (the drag handle: it moves the whole block), the
/// link badge (solid = follows the bin, hollow = detached; a click flips it), the ✕ and a thin level
/// line under the name. The ✕ is a small menu rather than a delete, because a bin is shared: removing
/// it from THIS object, leaving it while keeping the plugins, and dissolving it everywhere are three
/// different gestures. The colour is the card's rim; there is no colour dot — "next colour" is in the
/// right-click menu.
///
/// FOLDING (docs/plan_synoptic_rework.md §B.7): the chevron AND a double click anywhere on the header
/// (its name included) fold / unfold the block. The double click no longer renames: renaming is ⌘R or the
/// menu's "Rename", both of which end up in `SynopticUIState.renamingFXLinkID`, the one thing that turns
/// the name into a field. A folded block keeps its header; the line "3 plugins" under it is written by
/// THIS view (it hangs below the header card, beside the wire), so the canvas only draws the body.
struct FXBlockHeaderView: View {
    let link: SynopticFXLink
    let rect: CGRect
    let pluginCount: Int
    let actions: SynopticActions

    /// The session's fold / rename memory (read here so that a ⌘R from outside turns the name into a field).
    private let ui = SynopticUIState.shared
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool
    @State private var dropTargeted = false
    @State private var dropHintID = UUID()

    private var isRenaming: Bool { ui.renamingFXLinkID == link.stateKey }
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
                    // ▾ / ▸ — fold / unfold the block (the double click on the header does the same).
                    Button(action: toggleFold) {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(link.isFolded ? -90 : 0))
                            .frame(width: 12, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(link.isFolded ? L("fxlink.help.unfold") : L("fxlink.help.fold"))

                    if isRenaming {
                        TextField(noLabel, text: $draft)
                            .textFieldStyle(.plain)
                            .font(Font(SynopticLayout.cardNameFont))
                            .focused($fieldFocused)
                            .onSubmit { endRename(commit: true) }
                            .onExitCommand { endRename(commit: false) }
                            .onChange(of: fieldFocused) { _, focused in if !focused { endRename(commit: true) } }
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(link.name)
                            .font(Font(SynopticLayout.cardNameFont))
                            .foregroundStyle(link.isEnabled ? Color.primary : Color.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
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
            // A double click ANYWHERE on the header's body (the name included) folds / unfolds the block.
            // The buttons above take their own clicks first; there is no single-click handler, so nothing
            // waits for a second click. While the name is a field the gesture is off: its clicks stay its own.
            .contentShape(Rectangle())
            .gesture(TapGesture(count: 2).onEnded { toggleFold() },
                     including: isRenaming ? .subviews : .all)
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
        // The one line of a FOLDED block, written under the header card (outside its frame, after the clip).
        .overlay(alignment: .topLeading) { foldedSummary }
        .onChange(of: isRenaming, initial: true) { _, on in
            guard on else { return }
            draft = link.name
            DispatchQueue.main.async { fieldFocused = true }
        }
        // Leaving the screen with the field open (another object shown, the block gone) drops the request:
        // it must not come back, by itself, on the next header with the same key.
        .onDisappear { if ui.renamingFXLinkID == link.stateKey { ui.renamingFXLinkID = nil } }
    }

    // MARK: Folded body

    /// "3 plugins", written BESIDE the wire that runs through a folded block's one-line body (@see
    /// SynopticLayout.place: the same rectangle as `FXBlockPlacement.foldedSummaryRect`, in this view's
    /// coordinates — the header and the body share their x and their width). A double click on it
    /// unfolds, like the header's.
    @ViewBuilder private var foldedSummary: some View {
        if link.isFolded {
            let x = rect.width / 2 + 8
            Text(Ln("fxlink.drag.plugins", pluginCount, pluginCount))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: max(0, rect.width - SynopticLayout.fxPad - x),
                       height: SynopticLayout.fxFoldedBodyH - 4, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { toggleFold() }
                .offset(x: x, y: rect.height + 2)
        }
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
        Button(link.isFolded ? L("fxlink.menu.unfold") : L("fxlink.menu.fold")) { toggleFold() }
        Button(L("fxlink.menu.next_color")) { actions.onFXCycleColor?(link.blockID) }
        Button(link.isDetached ? L("fxlink.menu.reattach") : L("fxlink.menu.detach")) {
            actions.onFXToggleDetach?(link.blockID)
        }
        Divider()
        Button(L("fxlink.menu.release")) { actions.onFXRelease?(link.blockID) }
        Button(L("fxlink.menu.remove")) { actions.onFXRemove?(link.blockID) }
        Button(L("fxlink.menu.delete"), role: .destructive) { actions.onFXDelete?(link.blockID) }
    }

    // MARK: Fold and rename

    /// Folds / unfolds this block: the bound view's closure when it is wired, the session memory itself
    /// otherwise (the layout reads `SynopticUIState`, so the memory IS the state).
    private func toggleFold() {
        if let f = actions.onToggleFXFold { f(link.blockID) } else { ui.toggleFXFold(link.stateKey) }
    }

    /// Asks for the inline field (the menu's "Rename"; ⌘R asks the same way from outside).
    private func beginRename() {
        if let f = actions.onRenameFXLink { f(link.blockID) } else { ui.renamingFXLinkID = link.stateKey }
    }

    private func endRename(commit: Bool) {
        guard isRenaming else { return }
        ui.renamingFXLinkID = nil
        guard commit else { return }
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

/// RETIRED — the bin's output section (pan · volume · mute) is gone (docs/plan_synoptic_rework.md §B.8): an
/// FX link has no pan / volume / mute of its own any more, and a gain on a bin is a gain stage dragged out of
/// the bin's own "+" (@see SynopticCardView's gain-stage faces). This empty shell draws NOTHING; it stays
/// ONLY so that `SynopticView.swift` (lot L4's) still compiles on the branches that have not dropped its
/// call yet. It is deleted, with that call and the `onFXSetGain` / `onFXSetPan` / `onFXToggleMute` /
/// `onFXBeginEdit` actions, by the integration lot (L8).
struct FXBlockMixView: View {
    let link: SynopticFXLink
    let block: SynopticLayout.FXBlockPlacement
    let actions: SynopticActions

    var body: some View { EmptyView() }
}
