import SwiftUI

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

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.missingFileCount > 0 {
                missingBadge
                Divider()
            }

            searchBar

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        // The relink menu is attached only when it has something to say. An
                        // `.contextMenu` whose builder yields nothing still opens an empty box on
                        // macOS, and a group row with nothing missing anywhere offers exactly
                        // nothing — so the modifier itself is what branches. The condition moves
                        // only when a file goes or comes back, which already rebuilds the row.
                        let plan = RelinkUI.MenuPlan(vm: viewModel, object: row.object)
                        if plan.isEmpty {
                            listRow(row)
                        } else {
                            listRow(row)
                                .contextMenu {
                                    RelinkContextMenuItems(viewModel: viewModel, object: row.object)
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
    let row: SoundListRow
    let isSelected: Bool
    let isMissing: Bool
    let isExpanded: Bool
    let stemColor: Color
    let filterText: String
    let onToggleExpand: () -> Void

    /// The 3 px strip down the left edge, the counterpart of the block's name band: the object's
    /// own colour when it has been given one, the stem's otherwise. It replaces the 6 px dot,
    /// which said the stem and never the object.
    private var edgeColor: Color { row.object.customColor ?? stemColor }

    /// The kind, at a glance. A "sound object" is a `.clip` that carries a `definitionID` — that
    /// is exactly what tells it from an ordinary sound, and nothing else does. A GROUP stays a
    /// folder even when it is a live placement: what one sees of it here is its content.
    private var iconName: String {
        let object = row.object
        if object.isGroup { return "folder" }
        if object.isAux   { return "arrow.down.right.circle" }   // the aux block's own glyph
        if object.isMIDI  { return "pianokeys" }
        if object.definitionID != nil { return "cube" }
        return "waveform"
    }

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(edgeColor)
                .frame(width: 3)

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
