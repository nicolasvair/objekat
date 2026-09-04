import SwiftUI

// What is left of the old plugin rack: the inspector's Plugins column shows the signal view
// (`SynopticBoundView`), and the rack views that used to live here (`PluginChipView`,
// `PluginPickerButton`) were no longer called by anyone. What remains are the two pieces still
// used elsewhere: the drag payload (timeline and signal view) and the plugin browser, opened
// from the signal view.

// MARK: - Drag payload for LINKING instances

/// The payload of a plugin drag (JSON in an NSItemProvider under `public.plain-text` — an
/// undeclared custom type is not instantiated by the pasteboard). Received by the timeline's
/// `.onDrop`, identified by decoding successfully. Modifiers: nothing=move ⌥=copy ⌘=copy+link.
struct PluginDragPayload: Codable {
    let sourceObjectID: UUID
    let pluginID: UUID
}

// MARK: - Plugin browser

struct PluginPickerPopover: View {
    var viewModel: EditViewModel
    let objectID: UUID
    @Binding var searchText: String
    let dismiss: () -> Void
    /// If supplied, it replaces the default addition (an append) — inserting at a precise index
    /// from the signal view, say. Otherwise: the historical behaviour (addPlugin at the end).
    var onSelect: ((AvailablePlugin) -> Void)? = nil
    /// An optional extra filter (instruments only, say, for the instrument area of a MIDI clip).
    /// nil = no restriction.
    var filter: ((AvailablePlugin) -> Bool)? = nil

    private var filtered: [AvailablePlugin] {
        var base = viewModel.availablePlugins
        if let filter { base = base.filter(filter) }
        guard !searchText.isEmpty else { return base }
        return base.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.manufacturer.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.tertiary).font(.system(size: 11))
                TextField(L("common.search"), text: $searchText)
                    .textFieldStyle(.plain).font(.system(size: 12))
            }
            .padding(8)

            Divider()

            if viewModel.availablePlugins.isEmpty {
                VStack(spacing: 6) {
                    if viewModel.isScanning {
                        ProgressView().controlSize(.small)
                        Text(L("plugins.scanning")).font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(L("plugins.none"))
                            .font(.caption).foregroundStyle(.secondary)
                        Button(L("plugins.scan")) { viewModel.scanPlugins() }
                            .controlSize(.small)
                    }
                }
                .padding()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        let builtIns = filtered.filter(\.isBuiltIn)
                        let externals = filtered.filter { !$0.isBuiltIn }

                        if !builtIns.isEmpty {
                            sectionHeader(L("plugins.section.builtIn"))
                            ForEach(builtIns) { plugin in pluginRow(plugin) }
                        }
                        if !externals.isEmpty {
                            sectionHeader(L("plugins.section.external"))
                            ForEach(externals) { plugin in pluginRow(plugin) }
                        }
                    }
                }
                .frame(maxHeight: 280)
            }
        }
        .frame(width: 240)
        .safeAreaInset(edge: .bottom) {
            Divider()
            HStack(spacing: 12) {
                Button(viewModel.isScanning ? L("plugins.scanningShort") : L("plugins.rescan")) {
                    viewModel.rescanPlugins()
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .buttonStyle(.plain)
                .disabled(viewModel.isScanning)

                Button(L("plugins.diagnostic")) {
                    viewModel.diagnosticScanPlugins()
                }
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .buttonStyle(.plain)
            }
            .padding(6)
        }
        .onAppear {
            if viewModel.availablePlugins.isEmpty && !viewModel.isScanning {
                viewModel.scanPlugins()
            }
            // The browser has to be readable over the open editors. Those are floating windows (a
            // level above any ordinary window of the app): a popover cannot get past them, so we
            // lower them again for the length of the selection.
            viewModel.setPluginEditorsFloating(false)
        }
        .onDisappear { viewModel.setPluginEditorsFloating(true) }
    }

    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 2)
    }

    @ViewBuilder
    private func pluginRow(_ plugin: AvailablePlugin) -> some View {
        Button {
            if let onSelect { onSelect(plugin) }
            else { viewModel.addPlugin(objectID: objectID, available: plugin) }
            dismiss()
        } label: {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(plugin.name)
                        .font(.system(size: 11))
                        .foregroundStyle(.primary)
                    Text(plugin.manufacturer)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Text(plugin.formatLabel)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color.clear)
        Divider()
    }
}
