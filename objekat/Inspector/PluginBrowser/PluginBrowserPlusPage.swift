import SwiftUI

// MARK: - The plugin browser's "+" page: what each direction of the signal view's "+" asks for

/// The eight directions of a "+" laid out as a compass round it, each with its TWO slots side by side — near,
/// then further (beyond 80 pt of travel along the direction, @see PlusLevel). A click on a slot selects it; the
/// strip below edits the selected slot (a built-in action, a plugin of the catalogue by maker — effects only,
/// an instrument has no place in an FX chain — or nothing), and a click on a plugin of the list under the page
/// puts that plugin on the selected slot (@see PluginBrowserView, the list's rows in this page). Putting an
/// action on a slot that another slot held moves that other slot's action to where this one was (@see
/// PlusShortcutMap.assign — a SWAP, so nothing is lost by a slip of the hand). An empty far slot does what
/// the near one does. "Reset to defaults" brings the "+" back as it was designed.
///
/// The map is the APP's memory (`PlusShortcutStore`, UserDefaults), not the project's; this page is the one
/// door that edits it.
struct PluginBrowserPlusPage: View {
    /// The catalogue the plugin menus list (the one the browser shows).
    var viewModel: EditViewModel
    /// The slot the strip edits and a click in the list binds.
    @Binding var selected: PlusSlot

    private var store: PlusShortcutStore { .shared }

    /// The compass, row by row; nil = the "+" itself in the middle.
    private static let grid: [[PlusDirection?]] = [
        [.upLeft, .up, .upRight],
        [.left, nil, .right],
        [.downLeft, .down, .downRight],
    ]

    static let cellWidth: CGFloat = 164

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("pluginBrowser.plus.description"))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Grid(horizontalSpacing: 8, verticalSpacing: 6) {
                ForEach(Self.grid.indices, id: \.self) { row in
                    GridRow {
                        ForEach(Self.grid[row].indices, id: \.self) { col in
                            if let d = Self.grid[row][col] {
                                cell(d)
                            } else {
                                plusDisc
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)

            selectedStrip
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    /// The "+" the directions leave from.
    private var plusDisc: some View {
        Image(systemName: "plus.circle.fill")
            .font(.system(size: 20))
            .foregroundStyle(Color.accentColor)
            .frame(width: Self.cellWidth, height: 38)
    }

    /// One direction: its arrow and name, then its near and far slots.
    private func cell(_ d: PlusDirection) -> some View {
        VStack(spacing: 3) {
            Text(PlusShortcutText.directionLabel(d))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(spacing: 4) {
                chip(PlusSlot(d, .near))
                chip(PlusSlot(d, .far))
            }
        }
        .frame(width: Self.cellWidth, height: 38)
    }

    private func isMissing(_ action: PlusAction) -> Bool {
        action.pluginRef.map { viewModel.availablePlugin(for: $0) == nil } ?? false
    }

    /// What a slot's chip reads: the action, or for an empty FAR slot what it falls back on.
    private func chipText(_ slot: PlusSlot) -> (text: String, dimmed: Bool) {
        let action = store.map.action(slot)
        if slot.level == .far && action == .none {
            // Empty far = the near action at any distance; "—" when there is no near action either.
            return store.map.action(slot.direction, .near) == .none ? ("—", true)
                                                                    : (L("pluginBrowser.plus.sameAsNear"), true)
        }
        return (PlusShortcutText.actionName(action, missing: isMissing(action)), action == .none || isMissing(action))
    }

    /// One slot: a click selects it (the strip below then edits it, a click in the list binds a plugin there).
    private func chip(_ slot: PlusSlot) -> some View {
        let action = store.map.action(slot)
        let (text, dimmed) = chipText(slot)
        let isSelected = selected == slot
        let missing = isMissing(action)
        return Text(verbatim: text)
            .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
            .foregroundStyle(dimmed ? Color.secondary : Color.primary)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 5)
            .frame(maxWidth: .infinity)
            .frame(height: 20)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isSelected ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(missing ? 0.6 : 0),
                                  style: StrokeStyle(lineWidth: 1, dash: missing && !isSelected ? [3, 2] : []))
            )
            .contentShape(Rectangle())
            .onTapGesture { selected = slot }
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .help(PlusShortcutText.levelName(slot.level) + " — " + PlusShortcutText.helpDescription(action, missing: missing))
    }

    // MARK: The selected slot

    /// The selected slot named, its action as a menu, the hint for the list, and Reset.
    private var selectedStrip: some View {
        let action = store.map.action(selected)
        let missing = isMissing(action)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(verbatim: PlusShortcutText.directionLabel(selected.direction) + " · "
                               + PlusShortcutText.levelName(selected.level))
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Menu {
                    actionMenu(for: selected, current: action)
                } label: {
                    Text(verbatim: chipText(selected).text)
                }
                .menuStyle(.button)
                .controlSize(.small)
                .fixedSize()
                .help(PlusShortcutText.helpDescription(action, missing: missing))
                Spacer(minLength: 4)
                Button(L("pluginBrowser.plus.reset")) { store.reset() }
                    .controlSize(.small)
                    .disabled(store.map.isDefault)
            }
            Text(L("pluginBrowser.plus.pickHint"))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    /// The built-ins (for a far slot, "Nothing" reads "Same as near": that is what an empty far slot does),
    /// the plugin bound there if any (even when no longer installed, so the menu says what is there), and
    /// the catalogue's effects by maker.
    @ViewBuilder
    private func actionMenu(for slot: PlusSlot, current: PlusAction) -> some View {
        ForEach(PlusAction.builtIns, id: \.self) { a in
            let name = (slot.level == .far && a == .none) ? L("pluginBrowser.plus.sameAsNear")
                                                          : PlusShortcutText.actionName(a)
            Toggle(name, isOn: Binding(get: { current == a }, set: { _ in store.assign(a, to: slot) }))
        }
        Divider()
        if let ref = current.pluginRef {
            Toggle(PlusShortcutText.actionName(current, missing: viewModel.availablePlugin(for: ref) == nil),
                   isOn: .constant(true))
        }
        Menu(L("pluginBrowser.plus.pluginMenu")) {
            let groups = pluginsByMaker
            if groups.isEmpty {
                Text(L("pluginBrowser.plus.noCatalog"))
            } else {
                ForEach(groups, id: \.maker) { group in
                    Menu(group.maker) {
                        ForEach(group.plugins, id: \.id) { p in
                            let ref = PlusPluginRef(p)
                            Toggle(p.name + "  " + p.formatLabel,
                                   isOn: Binding(get: { current.pluginRef == ref },
                                                 set: { _ in store.assign(.plugin(ref), to: slot) }))
                        }
                    }
                }
            }
        }
    }

    /// The catalogue's effects, by maker then name (as the browser sorts them).
    private var pluginsByMaker: [(maker: String, plugins: [AvailablePlugin])] {
        let effects = viewModel.availablePlugins.filter(\.canBindToPlusDirection)
        let byMaker = Dictionary(grouping: effects) { $0.manufacturer.isEmpty ? "—" : $0.manufacturer }
        return byMaker.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }.map { maker in
            (maker, byMaker[maker]!.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })
        }
    }

    /// The slots `plugin` is bound to, as glyphs a row of the list shows (an arrow; doubled for a far slot).
    static func boundGlyphs(_ plugin: AvailablePlugin, map: PlusShortcutMap) -> String {
        let ref = PlusPluginRef(plugin)
        return PlusSlot.allCases.filter { map.action($0).pluginRef == ref }
            .map { $0.level == .far ? $0.direction.arrow + $0.direction.arrow : $0.direction.arrow }
            .joined(separator: " ")
    }
}
