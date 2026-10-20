import Foundation

// MARK: - The FX tool's strip: an object's chain, plugins only

extension EditViewModel {

    /// What the FX tool's mini signal view shows for one object (@see FXStripLayout): the
    /// instruments first, then the chain as a tree — a plugin and a gain stage as leaves, a
    /// parallel block as its carrier plus one series per branch (its plugins are leaves of their
    /// own), an FX link's block as a run of its plugins sharing a `bin`. A send's place on the
    /// trunk is not a plugin: it is skipped. Read only for the hovered object, so its cost is one
    /// walk of one chain.
    func fxStripModel(objectID: UUID) -> FXStripModel {
        guard let obj = find(id: objectID) else { return FXStripModel() }
        var m = FXStripModel()
        for inst in obj.instruments {
            m.root.append(.leaf(m.entries.count))
            m.entries.append(FXStripEntry(id: inst.id, kind: .instrument, name: inst.name,
                                          isEnabled: inst.isEnabled, bin: nil))
        }
        func series(_ plugins: [ObjectPlugin], bin: Int?, rack: Int?, branch: Int?) -> [FXStripNode] {
            var out: [FXStripNode] = []
            for p in plugins {
                if p.isSendMarker { continue }
                if let block = p.fxBlock {
                    let index = m.bins.count
                    m.bins.append(FXStripBin(id: p.id, name: fxLink(block.linkID)?.name ?? p.name,
                                             isDetached: block.isDetached))
                    out += series(block.plugins, bin: index, rack: rack, branch: branch)
                } else if let r = p.rack {
                    let names = r.voices.map { v in Self.flattenLeaves(v).map(\.name).joined(separator: " › ") }
                    let c = m.entries.count
                    m.entries.append(FXStripEntry(id: p.id, kind: .rack(branches: r.voices.count),
                                                  name: names.filter { !$0.isEmpty }.joined(separator: " ∥ "),
                                                  isEnabled: p.isEnabled, bin: bin, detail: names,
                                                  rack: rack, branch: branch))
                    let branches = r.voices.enumerated().map { series($0.element, bin: bin, rack: c, branch: $0.offset) }
                    out.append(.rack(c, branches))
                } else if p.isContainer {
                    continue
                } else {
                    out.append(.leaf(m.entries.count))
                    m.entries.append(FXStripEntry(id: p.id, kind: p.isGainStage ? .gainStage : .plugin,
                                                  name: p.name, isEnabled: p.isEnabled, bin: bin,
                                                  rack: rack, branch: branch))
                }
            }
            return out
        }
        m.root += series(obj.plugins, bin: nil, rack: nil, branch: nil)
        return m
    }

    /// The power button of a strip box: the signal view's own functions, hence the same undo point
    /// and, on an FX link's attached instance, the same rule (the gesture is the bin's).
    func toggleFXStripEntry(objectID: UUID, entry: FXStripEntry) {
        switch entry.kind {
        case .instrument: toggleInstrumentEnabled(objectID: objectID, pluginID: entry.id)
        case .plugin:     togglePluginEnabled(objectID: objectID, pluginID: entry.id)
        case .gainStage, .rack: break
        }
    }

    /// The double click on a strip box: the plugin's window, through the signal view's door
    /// (`togglePluginEditor`, which opens nothing without an interface).
    func openFXStripEditor(objectID: UUID, entryID: UUID) {
        let candidates = leafPlugins(objectID: objectID) + (find(id: objectID)?.instruments ?? [])
        guard let plug = candidates.first(where: { $0.id == entryID }), !plug.isGainStage else { return }
        togglePluginEditor(objectID: objectID, plug: plug)
    }
}
