import SwiftUI
// `MemberImportVisibility` is on for this target: NSWorkspace is named here, so AppKit is imported here.
import AppKit

/// The left panel's sound list: the project's TABLE OF CONTENTS.
///
/// It has neither columns nor sort headers any more. A sort one can change is a sort one has to
/// re-establish, and the three columns it offered (track, time, length) said in figures what the
/// timeline already says in pixels — one row further right. What is left is the one order that
/// needs no explaining, the order in which things HAPPEN, and the one shape the project really
/// has: the tree of its groups. Everything read here — the fold, the selection, the colours — is
/// the timeline's own state, seen from the side. Two views, never two truths.
struct SoundObjectListView: View {
    @Bindable var viewModel: EditViewModel
    @FocusState private var searchFocused: Bool

    /// "Show only what is missing". A state of the VIEW and not of the document: it is a way of
    /// LOOKING at the project, it changes nothing in it, and it has no business surviving a save
    /// or reaching any other view.
    @State private var showOnlyMissing = false

    /// The rows actually drawn.
    ///
    /// The text filter is applied inside `soundListRows` (it reads `filterText`, which belongs to
    /// the model); the missing-files filter is applied HERE, because its switch is this view's own
    /// state. Two filters, two places — and both keep the hierarchy by the same rule: a row
    /// survives for its descendants' sake (@see `subtreeHasMissingFile`).
    private var rows: [SoundListRow] {
        // The badge is the only way back out of this filter, and it is only drawn while something
        // is missing. Relink the last missing file with the filter on and one would be left
        // staring at an empty list with no switch to turn off — so the filter answers to the
        // badge's own condition rather than to the flag alone.
        guard showOnlyMissing, viewModel.missingFileCount > 0 else { return viewModel.soundListRows }
        return viewModel.soundListRows.filter { viewModel.subtreeHasMissingFile($0.object) }
    }

    /// The ONE row the panel should bring into view, or nil to leave the scroll alone.
    ///
    /// Nil for an empty selection and nil for a MULTIPLE one: several objects have no single row
    /// to show, and choosing one of them would be choosing for the user. Nil too when the object
    /// is not currently listed — a child of a folded group is not a row, and `scrollTo` on an id
    /// that is not there does nothing anyway; saying so here keeps the reason in writing rather
    /// than leaving it to a silent no-op.
    private var rowToReveal: UUID? {
        guard viewModel.selectedIDs.count == 1, let id = viewModel.selectedIDs.first else { return nil }
        return rows.contains(where: { $0.id == id }) ? id : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.missingFileCount > 0 {
                missingBadge
                Divider()
            }

            searchBar

            Divider()

            ScrollViewReader { scroller in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        // The relink menu is attached only when it has something to say. An
                        // `.contextMenu` whose builder yields nothing still opens an empty box on
                        // macOS, and a group row with nothing missing anywhere offers exactly
                        // nothing — so the modifier itself is what branches. The condition moves
                        // only when a file goes or comes back, which already rebuilds the row.
                        let plan = RelinkUI.MenuPlan(vm: viewModel, object: row.object)
                        let revealable = Self.revealablePath(row.object) != nil
                        if plan.isEmpty && !revealable {
                            listRow(row)
                        } else {
                            listRow(row)
                                .contextMenu {
                                    RelinkContextMenuItems(viewModel: viewModel, object: row.object)
                                    revealItem(row.object, afterRelinkItems: !plan.isEmpty)
                                }
                        }
                        Divider()
                    }
                }
            }
            .simultaneousGesture(TapGesture().onEnded {
                searchFocused = false
                NSApp.keyWindow?.makeFirstResponder(nil)
            })
            // SELECTING AN OBJECT ANYWHERE BRINGS IT INTO VIEW HERE. A table of contents that
            // does not follow the hand stops being one: with a project taller than the panel, a
            // click in the timeline highlighted a row nobody could see, and the list said less
            // the more there was in it.
            //
            // Three things this deliberately does NOT do. It does not scroll on every change of
            // `selectedIDs` but only when the object one should be looking at CHANGES
            // (`rowToReveal`), so extending a selection with ⇧ or ⌘ leaves the view where the eye
            // is. It does not scroll for a selection of SEVERAL objects — there is no one row to
            // show, and picking one would be picking for the user. And it never steals the view
            // while one is typing in the search field, where the rows under the hand are the
            // result of the search and not of any selection.
            .onChange(of: rowToReveal) { _, id in
                guard let id, !searchFocused else { return }
                // `.center` rather than the nearest edge: a row revealed flush against the top or
                // the bottom of the panel is a row with no neighbours shown, and what one wants
                // of a table of contents is precisely what sits around the thing one selected.
                withAnimation(.easeOut(duration: 0.18)) { scroller.scrollTo(id, anchor: .center) }
            }
            }
        }
        .frame(minWidth: 240)
    }

    // MARK: - One row, with its gestures

    /// The row and what a hand may do to it, pulled out of the `ForEach` so that the relink menu
    /// can be attached or withheld without the two branches repeating the whole thing.
    private func listRow(_ row: SoundListRow) -> some View {
        SoundListRowView(
            row: row,
            isSelected: viewModel.isSelected(row.id),
            isMissing: viewModel.isMissing(row.object),
            isExpanded: row.object.isExpanded,
            isOpenObject: viewModel.isInObjectEditStack(row.id),
            stemColor: viewModel.stemColor(for: row.id),
            filterText: viewModel.filterText,
            onToggleExpand: { viewModel.toggleGroupExpansion(id: row.id) }
        )
        .contentShape(Rectangle())
        .onTapGesture {
            searchFocused = false
            viewModel.select(row.id, additive: false)
        }
        .simultaneousGesture(
            TapGesture(count: 2).onEnded { activate(row) }
        )
    }

    // MARK: - Header

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.tertiary)
                .font(.system(size: 11))
            TextField(L("objectList.filter"), text: $viewModel.filterText)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .focused($searchFocused)
            if !viewModel.filterText.isEmpty {
                Button {
                    viewModel.filterText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// The "N missing files" badge, at the very top of the panel and shown ONLY while something is
    /// missing: a permanent row saying "nothing is missing" would be one more thing to read every
    /// day for the sake of an exception. A click narrows the list down to what is broken — an
    /// accident comes by the handful, and repairing is done in one pass rather than by hunting one
    /// red name at a time down a list of hundreds.
    private var missingBadge: some View {
        Button {
            showOnlyMissing.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                Text(Ln("soundList.missing.count",
                        viewModel.missingFileCount, viewModel.missingFileCount))
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                // The filter's own state, said on the badge itself: it is the switch, so it is
                // also the lamp. A crossed-out eye = the rest of the project is being hidden.
                Image(systemName: showOnlyMissing ? "eye.slash" : "eye")
                    .font(.system(size: 9))
                    .opacity(0.7)
            }
            .foregroundStyle(MissingFileLabel.color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(MissingFileLabel.color.opacity(showOnlyMissing ? 0.22 : 0.10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("soundList.missing.help"))
    }

    // MARK: - Gestures

    /// A double click ACTIVATES a row, and what that means depends on what the row is. A single
    /// click only ever selects — as it does in the timeline.
    /// The file a row can show in the Finder, or nil.
    ///
    /// A GROUP, an aux and a MIDI clip own no file, so they are not offered the entry rather than
    /// being offered one that does nothing. A file that is MISSING is not offered either, and
    /// that is the case worth stating: the Finder would open on the folder that no longer holds
    /// it, which reads as "it is there" at the exact moment the app is saying it is not — the
    /// relink entries just above are the answer to a missing file, and this one would contradict
    /// them.
    static func revealablePath(_ object: SoundObject) -> String? {
        guard case .clip(let fp, _, _, _, _) = object.kind, !fp.isEmpty else { return nil }
        return FileManager.default.fileExists(atPath: fp) ? fp : nil
    }

    /// Reuses the export bar's own key: it is the same sentence about the same gesture, and the
    /// three languages already carry it (@see `docs/glossary.md`).
    @ViewBuilder
    private func revealItem(_ object: SoundObject, afterRelinkItems: Bool) -> some View {
        if let path = Self.revealablePath(object) {
            if afterRelinkItems { Divider() }
            Button(L("export.reveal")) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
        }
    }

    private func activate(_ row: SoundListRow) {
        let object = row.object
        if object.isGroup {
            // "Entering" a group is unfolding it, and the list's chevron IS the timeline's fold:
            // one state, two views. Hence the very function the timeline's own fold calls — two
            // ways in, never two implementations. It also knows what this call site has no
            // business knowing: that a group showing its automation band must be given its
            // content back before anything is toggled at all.
            viewModel.toggleGroupExpansion(id: object.id)
        } else if object.definitionID != nil {
            // A sound object (a placement of a definition): entering it means EDITING it — it
            // leaves the baked regime for the live one and the other instances become mirrors of
            // this placement. The guards on what can be opened are inside `openObject`.
            viewModel.openObject(viaPlacementID: object.id)
        } else {
            // A plain sound: go and listen to it where it is.
            viewModel.engine?.seek(to: row.absStart)
        }
    }
}

// MARK: - One row

/// The red and the bold are NOT spelled here: they come from `MissingFileLabel`, the unit the
/// timeline's four drawings of a name already read. The same object is called broken in two
/// windows at once, so it is called broken in one voice — a red re-typed on this side is the
/// drift that unit exists to prevent.
///
/// The colours are the BLOCK's rule turned through 90°: what the timeline says from top to bottom
/// (the name band in the object's own colour, the body in the stem's) a row says from left to
/// right. @see SoundBlockView.effectiveColor — the reasoning and the opacities are its, to the
/// digit, so that a sound reads the same in both views.
private struct SoundListRowView: View {
    /// @see `edgeColor` for why it is this wide.
    static let edgeStripWidth: CGFloat = 16

    let row: SoundListRow
    let isSelected: Bool
    let isMissing: Bool
    let isExpanded: Bool
    /// Open for editing — @see `ObjectKindIcon.name(for:isOpenObject:)`.
    let isOpenObject: Bool
    let stemColor: Color
    let filterText: String
    let onToggleExpand: () -> Void

    /// The strip down the left edge, the counterpart of the block's name band: the object's own
    /// colour when it has been given one, the stem's otherwise. It replaces the 6 px dot, which
    /// said the stem and never the object.
    ///
    /// SIXTEEN pixels and not the three it started at. A 3 px hairline is enough to tell two
    /// adjacent rows apart, which is not what this is for: it has to name a colour one can
    /// recognise against the ten stems and the object pastels, and a colour is not identified on
    /// a hairline — least of all the pale ones, where 3 px of salmon and 3 px of pink are the
    /// same stripe. It is the row's most-read mark, so it is given the width of one.
    private var edgeColor: Color { row.object.customColor ?? stemColor }

    /// The kind, at a glance — ONE definition, shared with the four places the timeline draws a
    /// block's name (@see `ObjectKindIcon`), because tying this list to the timeline is the whole
    /// point of the glyph. `isOpenObject` is what keeps a sound object reading as one while it is
    /// open for editing, its `kind` having genuinely become `.group` for the duration.
    private var iconName: String {
        ObjectKindIcon.name(for: row.object, isOpenObject: isOpenObject)
    }

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(edgeColor)
                .frame(width: SoundListRowView.edgeStripWidth)

            HStack(spacing: 4) {
                chevron
                Image(systemName: iconName)
                    .font(.system(size: 10))
                    .frame(width: 13, alignment: .center)
                    .foregroundStyle(isMissing ? MissingFileLabel.color : Color.secondary)
                name
                Spacer(minLength: 0)
            }
            // The depth is drawn and not computed: one indent per level, from the strip.
            .padding(.leading, 5 + Double(row.depth) * 11)
            .padding(.trailing, 6)
            .padding(.vertical, 4)
        }
        .background(stemColor.opacity(isSelected ? 0.55 : 0.30))
    }

    @ViewBuilder
    private var chevron: some View {
        if row.hasChildren {
            Button(action: onToggleExpand) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 10, height: 10)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            // The same width whatever happens: without it the icons of a level would not line up,
            // and the indentation would stop saying anything.
            Color.clear.frame(width: 10, height: 10)
        }
    }

    /// The name. RED and BOLD when the file is missing — the one thing in this list that is not a
    /// matter of taste: the sound is not there, and it has to be seen without being looked for.
    private var name: some View {
        highlightedName
            .font(.system(size: 10, weight: isMissing ? MissingFileLabel.weight : .regular))
            .foregroundStyle(isMissing ? MissingFileLabel.color : Color.primary)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    @ViewBuilder
    private var highlightedName: some View {
        let text = row.object.displayName
        // The match is picked out in the accent colour — except on a missing file, where RED is
        // the message and a second colour inside the same word would blunt it.
        let hit: Color = isMissing ? MissingFileLabel.color : .accentColor
        if filterText.isEmpty {
            Text(text)
        } else if let range = text.range(of: filterText, options: .caseInsensitive) {
            Text(text[text.startIndex..<range.lowerBound])
            + Text(text[range]).bold().foregroundColor(hit)
            + Text(text[range.upperBound..<text.endIndex])
        } else {
            // Dimmed rather than absent: this row is a parent kept for a descendant that DOES
            // match (or an ancestor of one). Removing it would leave its children indented under
            // nothing — dimming it says "this is the way, not the destination".
            Text(text).opacity(0.45)
        }
    }
}
