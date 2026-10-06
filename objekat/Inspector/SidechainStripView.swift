import AppKit
import SwiftUI

/// The strip at the bottom of a plugin's editor window, for a plugin that has a sidechain input:
/// which source keys it (a picker: none, the stems, the objects playing at the same time as a tree
/// of groups) and "Choose object", which arms a click on the timeline. Shown under the native UI of
/// an AU/VST3 (hosted by `OBJEditorHolder`, @see OBJEngineCore.mm) and under a built-in's editor.
struct SidechainStripView: View {
    let viewModel: EditViewModel
    let host: UUID
    let plugin: UUID

    static let height: CGFloat = 30

    @State private var pickerShown = false

    private var picking: Bool { viewModel.sidechainPick == SidechainPick(host: host, plugin: plugin) }

    var body: some View {
        let current = viewModel.sidechainCurrent(host: host, plugin: plugin)
        HStack(spacing: 8) {
            Image(systemName: "waveform.path")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)
            Text(L("plugin.sidechain.menu"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            Button { pickerShown.toggle() } label: {
                HStack(spacing: 4) {
                    Text(verbatim: current?.name ?? L("plugin.sidechain.none"))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(current?.inactiveReason == nil ? Color.primary : Color.orange)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 11))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .frame(maxWidth: 220, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.08)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(current?.inactiveReason.map { L("plugin.sidechain.inactive", $0) } ?? L("sidechain.strip.source.help"))
            .popover(isPresented: $pickerShown, arrowEdge: .bottom) {
                SidechainSourcePicker(viewModel: viewModel, host: host, plugin: plugin) { pickerShown = false }
            }

            Spacer(minLength: 4)

            Button { viewModel.beginSidechainPick(host: host, plugin: plugin) } label: {
                Label(picking ? L("sidechain.strip.choosing") : L("sidechain.strip.choose"), systemImage: "scope")
                    .font(.system(size: 11))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5)
                        .fill(picking ? Color.accentColor : Color.primary.opacity(0.08)))
                    .foregroundStyle(picking ? Color.white : Color.primary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("sidechain.strip.choose.help"))
        }
        .padding(.horizontal, 10)
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .top) { Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1) }
    }
}

/// The strip under a built-in's editor, re-asked at every render: the host is found from the plugin,
/// and nothing is shown for a plugin with no sidechain input.
struct SidechainStripIfAny: View {
    let viewModel: EditViewModel
    let plugin: UUID

    var body: some View {
        if let host = viewModel.chainHost(ofPlugin: plugin), viewModel.showsSidechainStrip(host: host, plugin: plugin) {
            SidechainStripView(viewModel: viewModel, host: host, plugin: plugin)
        }
    }
}

/// The source picker: "None", then the stems, then the objects as a tree. A group is chosen by a
/// click on its NAME; its chevron opens its children (a native menu could not do both: a submenu's
/// title is not clickable on macOS). Refused entries stay visible, greyed, their reason as help.
struct SidechainSourcePicker: View {
    let viewModel: EditViewModel
    let host: UUID
    let plugin: UUID
    let dismiss: () -> Void

    @State private var expanded: Set<UUID> = []
    @State private var stemsOpen = false
    @State private var objectsOpen = true
    @State private var seeded = false

    var body: some View {
        let tree = viewModel.sidechainSourceTree(host: host, plugin: plugin)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let tree {
                    row(name: L("plugin.sidechain.none"), depth: 0, checked: tree.current == nil, refusal: nil) {
                        choose(nil)
                    }
                    Divider().padding(.vertical, 3)
                    section(L("plugin.sidechain.stems"), open: $stemsOpen)
                    if stemsOpen {
                        if tree.stems.isEmpty { empty(L("sidechain.picker.noStems")) }
                        ForEach(tree.stems) { s in
                            row(name: s.name, depth: 1, checked: tree.current == s.id, refusal: s.refusal) { choose(s.id) }
                        }
                    }
                    section(L("sidechain.picker.objects"), open: $objectsOpen)
                    if objectsOpen {
                        if tree.objects.isEmpty { empty(L("sidechain.picker.noObjects")) }
                        nodes(tree.objects, depth: 1, current: tree.current)
                    }
                }
            }
            .padding(6)
        }
        .frame(width: 280)
        .frame(maxHeight: 420)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { seed(tree) }
    }

    /// Opens the section and the groups that lead to the current key, once.
    private func seed(_ tree: SidechainSourceTree?) {
        guard !seeded, let tree, let current = tree.current else { return }
        seeded = true
        if tree.stems.contains(where: { $0.id == current }) { stemsOpen = true }
        func open(_ list: [SidechainSourceTree.Node]) {
            for n in list where SidechainSourceTree.contains(current, under: n) {
                expanded.insert(n.id); open(n.children)
            }
        }
        open(tree.objects)
    }

    private func choose(_ source: UUID?) {
        try? viewModel.setSidechain(host: host, plugin: plugin, source: source)
        dismiss()
    }

    private func nodes(_ list: [SidechainSourceTree.Node], depth: Int, current: UUID?) -> AnyView {
        AnyView(ForEach(list) { n in
            VStack(alignment: .leading, spacing: 0) {
                row(name: n.name, depth: depth, checked: current == n.id, refusal: n.refusal,
                    expandable: !n.children.isEmpty, isExpanded: expanded.contains(n.id),
                    toggle: { if expanded.contains(n.id) { expanded.remove(n.id) } else { expanded.insert(n.id) } }) {
                    choose(n.id)
                }
                if expanded.contains(n.id) { nodes(n.children, depth: depth + 1, current: current) }
            }
        })
    }

    private func section(_ title: String, open: Binding<Bool>) -> some View {
        Button { open.wrappedValue.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: open.wrappedValue ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 12)
                Text(title).font(.system(size: 11, weight: .semibold))
                Spacer()
            }
            .foregroundStyle(.secondary)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func empty(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .padding(.leading, 30)
            .padding(.vertical, 3)
    }

    private func row(name: String, depth: Int, checked: Bool, refusal: BridgeScope.Refusal?,
                     expandable: Bool = false, isExpanded: Bool = false, toggle: (() -> Void)? = nil,
                     action: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            // The chevron: opens / closes a group's children; it never chooses.
            Group {
                if expandable, let toggle {
                    Button(action: toggle) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .frame(width: 14, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(L("sidechain.picker.children"))
                } else {
                    Color.clear.frame(width: 14, height: 18)
                }
            }
            // The name: chooses this source (a group whole, when it is one).
            Button(action: action) {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .opacity(checked ? 1 : 0)
                    Text(verbatim: name)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(SidechainRowStyle())
            .disabled(refusal != nil)
            .help(refusal.map { EditViewModel.sidechainReasonText($0) } ?? "")
        }
        .padding(.leading, CGFloat(depth) * 14)
    }
}

/// A picker row: highlighted under the pointer like a menu item, greyed when disabled.
private struct SidechainRowStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 4)
            .foregroundStyle(isEnabled ? (hovered ? Color.white : Color.primary) : Color.secondary.opacity(0.6))
            .background(RoundedRectangle(cornerRadius: 4)
                .fill(isEnabled && hovered ? Color.accentColor : Color.clear))
            .onHover { hovered = $0 }
    }
}
