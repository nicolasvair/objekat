import SwiftUI

// MARK: - Settings › "+ shortcuts": what each direction of a "+" of the signal view asks for

/// The eight directions of a "+" laid out as a compass round it, each with a menu of what it asks for: one
/// of the built-in actions, a plugin of the catalogue (effects only — an instrument has no place in an FX
/// chain), or nothing. Putting an action on a direction that another direction held moves that other
/// direction's action to where this one was (@see PlusShortcutMap.assign — a SWAP, so nothing is lost by a
/// slip of the hand). "Reset to defaults" brings the "+" back as it was designed.
///
/// The same map is edited from the plugin browser's right click (@see PluginBrowserView); both write
/// through `PlusShortcutStore`, an app preference (UserDefaults), not the project's.
struct PlusShortcutsPreferencesView: View {
    /// The catalogue the plugin menus list (the one the plugin browser shows).
    let viewModel: EditViewModel
    @State private var store = PlusShortcutStore.shared

    /// The compass, row by row; nil = the "+" itself in the middle.
    private static let grid: [[PlusDirection?]] = [
        [.upLeft, .up, .upRight],
        [.left, nil, .right],
        [.downLeft, .down, .downRight],
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("prefs.plus.description"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Grid(horizontalSpacing: 10, verticalSpacing: 10) {
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

            HStack {
                Spacer()
                Button(L("prefs.plus.reset")) { store.reset() }
                    .disabled(store.map.isDefault)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    /// The "+" the directions leave from.
    private var plusDisc: some View {
        Image(systemName: "plus.circle.fill")
            .font(.system(size: 26))
            .foregroundStyle(Color.accentColor)
            .frame(width: 150, height: 52)
    }

    /// One direction: its arrow and name, and the menu of what it asks for.
    private func cell(_ d: PlusDirection) -> some View {
        let action = store.map.action(d)
        let missing = action.pluginRef.map { viewModel.availablePlugin(for: $0) == nil } ?? false
        return VStack(spacing: 4) {
            Text(PlusShortcutText.directionLabel(d))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Menu {
                actionMenu(for: d, current: action)
            } label: {
                Text(PlusShortcutText.actionName(action, missing: missing))
                    .foregroundStyle(missing ? Color.secondary : (action == .none ? Color.secondary : Color.primary))
            }
            .menuStyle(.button)
            .help(missing ? L("plusAction.help.pluginMissing", action.pluginRef?.name ?? "")
                          : PlusShortcutText.helpDescription(action))
        }
        .frame(width: 150, height: 52)
    }

    @ViewBuilder
    private func actionMenu(for d: PlusDirection, current: PlusAction) -> some View {
        ForEach(PlusAction.builtIns, id: \.self) { a in
            Toggle(PlusShortcutText.actionName(a),
                   isOn: Binding(get: { current == a }, set: { _ in store.assign(a, to: d) }))
        }
        Divider()
        // The plugin it is bound to, even when no longer installed (so the menu says what is there).
        if let ref = current.pluginRef {
            Toggle(PlusShortcutText.actionName(current, missing: viewModel.availablePlugin(for: ref) == nil),
                   isOn: .constant(true))
        }
        Menu(L("prefs.plus.pluginMenu")) {
            let groups = pluginsByMaker
            if groups.isEmpty {
                Text(L("prefs.plus.noCatalog"))
            } else {
                ForEach(groups, id: \.maker) { group in
                    Menu(group.maker) {
                        ForEach(group.plugins, id: \.id) { p in
                            let ref = PlusPluginRef(p)
                            Toggle(p.name + "  " + p.formatLabel,
                                   isOn: Binding(get: { current.pluginRef == ref },
                                                 set: { _ in store.assign(.plugin(ref), to: d) }))
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
}
