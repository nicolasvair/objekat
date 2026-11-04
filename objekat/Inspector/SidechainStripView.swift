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
            Image(systemName: FeatureIcons.sidechainReception)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)

            // KEY → sidechain PLUGIN / RECEIVER: the key is the control, the rest says where it goes.
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
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.08)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .layoutPriority(2)
            .help(current?.inactiveReason.map { L("plugin.sidechain.inactive", $0) } ?? L("sidechain.strip.source.help"))
            .popover(isPresented: $pickerShown, arrowEdge: .bottom) {
                SidechainSourcePicker(viewModel: viewModel, host: host, plugin: plugin) { pickerShown = false }
            }

            Text(verbatim: "→")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(L("sidechain.strip.receiver",
                   viewModel.sidechainPickPluginName(SidechainPick(host: host, plugin: plugin)),
                   viewModel.sidechainHostName(host)))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)

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
/// The list and the popover are `TreePickerPopover`'s (Shared/), shared with the audio menu; this
/// type only turns the view-model's `SidechainSourceTree` into rows and a click into a key.
struct SidechainSourcePicker: View {
    let viewModel: EditViewModel
    let host: UUID
    let plugin: UUID
    let dismiss: () -> Void

    /// The id of the « None » row; every other row carries its object's or stem's UUID string.
    private static let noneID = "none"

    var body: some View {
        TreePickerPopover(sections: { Self.sections(viewModel.sidechainSourceTree(host: host, plugin: plugin)) },
                          closesOnChoose: true,
                          onChoose: { choose($0) },
                          dismiss: dismiss)
    }

    /// Pure: the picker's content, as the shared component lists it.
    static func sections(_ tree: SidechainSourceTree?) -> [TreePickerSection] {
        guard let tree else { return [] }
        func node(_ n: SidechainSourceTree.Node, _ current: UUID?) -> TreePickerNode {
            TreePickerNode(id: n.id.uuidString, name: n.name, checked: current == n.id,
                           disabledReason: n.refusal.map { EditViewModel.sidechainReasonText($0) },
                           children: n.children.map { node($0, current) })
        }
        return [
            TreePickerSection(id: "none", nodes: [TreePickerNode(id: noneID, name: L("plugin.sidechain.none"),
                                                                 checked: tree.current == nil)],
                              dividerAfter: true),
            TreePickerSection(id: "stems", title: L("plugin.sidechain.stems"),
                              nodes: tree.stems.map { node($0, tree.current) }, initiallyOpen: false,
                              emptyText: L("sidechain.picker.noStems")),
            TreePickerSection(id: "objects", title: L("sidechain.picker.objects"),
                              nodes: tree.objects.map { node($0, tree.current) }, initiallyOpen: true,
                              emptyText: L("sidechain.picker.noObjects")),
        ]
    }

    private func choose(_ id: String) {
        try? viewModel.setSidechain(host: host, plugin: plugin, source: id == Self.noneID ? nil : UUID(uuidString: id))
    }
}
