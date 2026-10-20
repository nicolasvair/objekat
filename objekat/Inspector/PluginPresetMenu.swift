import AppKit
import SwiftUI

/// The preset menu at the right of a plugin editor's title bar — the JUCE window of an AU / VST3
/// (@see OBJEngineCore `setPluginEditorTitleAccessoryProvider:`) and the NSWindow of a built-in
/// (@see BuiltInPluginEditorWindowController). Its label is the preset last laid or saved in this
/// session, with a "•" once a parameter moved since; its items are the type's OBJEKAT presets, the
/// plugin's own programs (read-only), and what one does with the library. Every action is the view
/// model's (@see EditViewModel+Presets): this view only asks for a name and confirms a deletion.
struct PluginPresetMenu: View {
    let viewModel: EditViewModel
    let plugin: UUID

    static let width: CGFloat = 200
    static let height: CGFloat = 20

    var body: some View {
        let status = viewModel.pluginPresetStatus[plugin]
        Menu {
            menuContent(status)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "slider.horizontal.below.square.and.square.filled")
                Text(verbatim: label(status))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.system(size: 11))
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: Self.width, alignment: .trailing)
        .help(L("preset.menu.help"))
    }

    private func label(_ s: PluginPresetStatus?) -> String {
        guard let s else { return L("preset.menu.none") }
        return s.isModified ? s.name + " •" : s.name
    }

    @ViewBuilder
    private func menuContent(_ status: PluginPresetStatus?) -> some View {
        let presets = viewModel.presets(for: plugin)
        let def = viewModel.defaultPresetName(for: plugin)
        if presets.isEmpty {
            Text(L("preset.menu.empty"))
        }
        ForEach(presets, id: \.name) { p in
            let title = p.name == def ? L("preset.menu.defaultTag", p.name) : p.name
            Button {
                run { try viewModel.loadPreset(pluginID: plugin, name: p.name) }
            } label: {
                if status?.name == p.name && status?.isFactory == false {
                    Label(title, systemImage: "checkmark")
                } else {
                    Text(verbatim: title)
                }
            }
        }
        let factory = viewModel.factoryPrograms(for: plugin)
        if !factory.isEmpty {
            Divider()
            Menu(L("preset.menu.factory")) {
                ForEach(Array(factory.enumerated()), id: \.offset) { i, name in
                    Button {
                        run { try viewModel.loadFactoryProgram(pluginID: plugin, index: i) }
                    } label: { Text(verbatim: name) }
                }
            }
        }
        Divider()
        let current = (status?.isFactory == false) ? status?.name : nil
        if let current, presets.contains(where: { $0.name == current }) {
            Button(L("preset.menu.save", current)) {
                run { try viewModel.savePreset(pluginID: plugin, name: current) }
            }
        }
        Button(L("preset.menu.saveAs")) { saveAs(suggested: status?.name) }
        if let current, presets.contains(where: { $0.name == current }) {
            if def != current {
                Button(L("preset.menu.setDefault", current)) {
                    run { try viewModel.setDefaultPreset(pluginID: plugin, name: current) }
                }
            }
            Button(L("preset.menu.delete", current)) { confirmDelete(current) }
        }
        Divider()
        // One default per plugin type, the last chosen wins: a preset named above, or the state
        // the plugin has right now, with no name.
        Button(L("preset.menu.setCurrentDefault")) {
            run { try viewModel.setCurrentStateAsDefault(pluginID: plugin) }
        }
        if viewModel.defaultKind(for: plugin) != .none {
            Button(L("preset.menu.restoreDefault")) {
                run { try viewModel.restoreDefaultState(pluginID: plugin) }
            }
            Button(L("preset.menu.clearDefault")) {
                run { try viewModel.setDefaultPreset(pluginID: plugin, name: nil) }
            }
        }
        Divider()
        Button(L("export.reveal")) { revealFolder() }
    }

    // MARK: Actions

    private func run(_ f: () throws -> Void) {
        do { try f() } catch {
            viewModel.notify(L("preset.error.title"), String(describing: error))
        }
    }

    private func saveAs(suggested: String?) {
        let pluginName = viewModel.presetTarget(plugin)?.plugin.name ?? ""
        let alert = NSAlert()
        alert.messageText = L("preset.saveAs.title")
        alert.informativeText = L("preset.saveAs.message", pluginName)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 22))
        field.stringValue = suggested ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: L("preset.saveAs.ok"))
        alert.addButton(withTitle: L("common.cancel"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn,
              let name = PluginPresetLibrary.normalisedName(field.stringValue) else { return }
        if viewModel.presets(for: plugin).contains(where: {
            PluginPresetLibrary.fileStem($0.name).lowercased() == PluginPresetLibrary.fileStem(name).lowercased()
        }) {
            let ask = NSAlert()
            ask.messageText = L("preset.saveAs.replace", name)
            ask.addButton(withTitle: L("preset.saveAs.replaceOk"))
            ask.addButton(withTitle: L("common.cancel"))
            guard ask.runModal() == .alertFirstButtonReturn else { return }
        }
        run { try viewModel.savePreset(pluginID: plugin, name: name) }
    }

    private func confirmDelete(_ name: String) {
        let alert = NSAlert()
        alert.messageText = L("preset.delete.title", name)
        alert.informativeText = L("preset.delete.message")
        alert.addButton(withTitle: L("preset.delete.ok"))
        alert.addButton(withTitle: L("common.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        run {
            try viewModel.deletePreset(pluginID: plugin, name: name)
            viewModel.pluginPresetStatus[plugin] = nil
        }
    }

    /// The type's folder in the library (made if it does not exist yet, so the Finder has something to show).
    private func revealFolder() {
        guard let t = viewModel.presetTarget(plugin) else { return }
        let lib = PluginPresetLibrary.shared
        let dir = lib.folder(for: viewModel.presetKey(of: t.plugin), pluginName: t.plugin.name)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }

    // MARK: Hosting

    /// The menu as an AppKit view for the JUCE title bar, which is dark whatever the app's appearance.
    static func titleBarView(viewModel: EditViewModel, plugin: UUID) -> NSView {
        let view = NSHostingView(rootView: PluginPresetMenu(viewModel: viewModel, plugin: plugin)
            .environment(\.colorScheme, .dark))
        view.appearance = NSAppearance(named: .darkAqua)
        view.frame = NSRect(x: 0, y: 0, width: width, height: height)
        return view
    }
}
