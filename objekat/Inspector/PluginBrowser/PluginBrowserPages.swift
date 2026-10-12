import SwiftUI
import AppKit

// MARK: - The two pages of the plugin browser that are not plugin lists

// Both exist only for an insertion point of an FX chain (@see PluginBrowserModel.extraPages): the "+" of
// the signal view says WHERE, and what is chosen here lands exactly there.

// MARK: FX link

/// One bin the host could join, as the page lists it.
struct PluginBrowserFXLinkRow: Identifiable, Equatable {
    let id: UUID
    let name: String
    /// An index into `ObjekatPalette.plugins`: the bin's own colour.
    let colorIndex: Int
    let pluginNames: [String]
    /// The hosts whose block follows the bin (detached ones excluded).
    let memberCount: Int
}

extension EditViewModel {
    /// The bins `host` does not hold yet, with what the page shows of each. Read when the page is drawn
    /// (a handful of bins: no cache).
    func joinableFXLinkRows(host: UUID) -> [PluginBrowserFXLinkRow] {
        joinableFXLinks(host: host).compactMap { joinable in
            guard let link = fxLink(joinable.id) else { return nil }
            return PluginBrowserFXLinkRow(id: link.id, name: link.name, colorIndex: link.colorIndex,
                                          pluginNames: link.plugins.map(\.name),
                                          memberCount: fxLinkAttachedMembers(link.id).count)
        }
    }
}

/// "FX link": a NEW, empty bin laid at the insertion point, then the existing bins this host does not
/// hold yet. A click acts at once and closes the browser (ONE undo point, taken by the model).
struct PluginBrowserFXLinkPage: View {
    var viewModel: EditViewModel
    let objectID: UUID
    let insertion: PluginBrowserInsertion
    let dismiss: () -> Void

    var body: some View {
        let rows = viewModel.joinableFXLinkRows(host: objectID)
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                PluginBrowserCard(action: createEmpty) {
                    HStack(spacing: 7) {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 9)
                        Text(L("pluginBrowser.fxLink.new"))
                            .font(.system(size: 11, weight: .semibold))
                        Spacer(minLength: 4)
                    }
                }
                .help(L("pluginBrowser.fxLink.new.help"))

                Text(L("pluginBrowser.fxLink.join"))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 2)
                    .padding(.top, 6)

                if rows.isEmpty {
                    Text(L("pluginBrowser.fxLink.none"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 2)
                        .padding(.top, 2)
                } else {
                    ForEach(rows) { row in
                        PluginBrowserCard(action: { join(row.id) }) {
                            HStack(spacing: 7) {
                                Circle().fill(ObjekatPalette.plugin(row.colorIndex)).frame(width: 9, height: 9)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(row.name)
                                        .font(.system(size: 11, weight: .semibold))
                                        .lineLimit(1)
                                    Text(row.pluginNames.isEmpty ? L("pluginBrowser.fxLink.emptyBin")
                                                                 : row.pluginNames.joined(separator: " · "))
                                        .font(.system(size: 9))
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                }
                                Spacer(minLength: 4)
                                Text(L("pluginBrowser.fxLink.members", row.memberCount))
                                    .font(.system(size: 9))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .help(L("pluginBrowser.fxLink.join.help"))
                    }
                }
            }
            .padding(10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var place: (SeriesLocation, Int) { (insertion.location, insertion.index) }

    private func createEmpty() {
        if viewModel.createEmptyFXLink(on: objectID, at: place) != nil { dismiss() } else { NSSound.beep() }
    }

    private func join(_ linkID: UUID) {
        if viewModel.attachFXLink(linkID, to: objectID, at: place) != nil { dismiss() } else { NSSound.beep() }
    }
}

// MARK: Send

/// "Send": the targets of a send taken at the clicked "+", with the same tiers and the same reasons the
/// native "Send to…" menu gives (@see SendTargetMenuPresenter), plus "Choose an object on the timeline…".
/// A send hangs on the TRUNK: from a "+" inside a parallel branch or a bin the page is shown greyed, and
/// says so.
struct PluginBrowserSendPage: View {
    var viewModel: EditViewModel
    let objectID: UUID
    let insertion: PluginBrowserInsertion
    let dismiss: () -> Void

    /// The sections cost a topology of the project (`sendRefusals`): read ONCE, when the page appears,
    /// never in the body (which redraws on every keystroke of the sheet and every meter tick).
    @State private var sections: [SendTargetMenu.Section]? = nil

    private var usable: Bool { insertion.isOnTrunk }
    private var slot: SendPosition { EditViewModel.sendPosition(of: .chain(insertion.index)) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                if !usable {
                    Text(L("pluginBrowser.send.notTrunk"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 2)
                        .padding(.bottom, 4)
                }
                if let sections {
                    if sections.isEmpty {
                        Text(L("send.menu.none"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 2)
                    }
                    ForEach(sections, id: \.tier) { section in
                        Text(L(section.titleKey))
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 2)
                            .padding(.top, 4)
                        ForEach(section.entries, id: \.id) { entry in
                            PluginBrowserCard(enabled: usable && entry.isEnabled, action: { create(entry.id) }) {
                                HStack(spacing: 7) {
                                    Text(entry.name)
                                        .font(.system(size: 11))
                                        .foregroundStyle(entry.isEnabled ? .primary : .tertiary)
                                        .lineLimit(1)
                                    Spacer(minLength: 4)
                                    if let reason = entry.disabledReason {
                                        Text(reason)
                                            .font(.system(size: 9))
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                    }
                                }
                            }
                            .opacity(usable ? 1 : 0.45)
                            .helpIf(entry.disabledReason)
                        }
                    }
                }
                PluginBrowserCard(enabled: usable, action: chooseOnTimeline) {
                    HStack(spacing: 7) {
                        Text(L("send.menu.choose"))
                            .font(.system(size: 11, weight: .semibold))
                        Spacer(minLength: 4)
                    }
                }
                .opacity(usable ? 1 : 0.45)
                .padding(.top, 8)
            }
            .padding(10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { sections = viewModel.sendTargetSections(for: objectID) }
    }

    private func create(_ aux: UUID) {
        if viewModel.createSendFromHand(from: objectID, to: aux, at: slot) { dismiss() }
    }

    private func chooseOnTimeline() {
        dismiss()
        viewModel.beginSendPick(sender: objectID, position: slot)
    }
}
