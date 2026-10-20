import Foundation

// MARK: - The FX tool's strip: an object's chain, plugins only

extension EditViewModel {

    /// What the FX tool's strip shows for one object (@see FXStripLayout): the instruments first,
    /// then the chain's top level in order — a plugin as a box, a gain stage as a box with no
    /// power button, a parallel block as ONE box naming its branch count, an FX link's block as a
    /// framed group of its own plugins. A send's place on the trunk is not a plugin: it is skipped.
    /// Read only for the hovered object, so its cost is one walk of one chain.
    func fxStripModel(objectID: UUID) -> FXStripModel {
        guard let obj = find(id: objectID) else { return FXStripModel() }
        var m = FXStripModel()
        for inst in obj.instruments {
            m.entries.append(FXStripEntry(id: inst.id, kind: .instrument, name: inst.name,
                                          isEnabled: inst.isEnabled, bin: nil))
        }
        func leaf(_ p: ObjectPlugin, bin: Int?) -> FXStripEntry? {
            if p.isSendMarker { return nil }
            if let rack = p.rack {
                // Named by what its branches hold (a rack's own name is a glyph, "//"): the box
                // says "∥ 2" already; the names say which.
                let names = rack.voices.map { v in Self.flattenLeaves(v).map(\.name).joined(separator: " › ") }
                return FXStripEntry(id: p.id, kind: .rack(branches: rack.voices.count),
                                    name: names.filter { !$0.isEmpty }.joined(separator: " ∥ "),
                                    isEnabled: p.isEnabled, bin: bin, detail: names)
            }
            if p.isContainer { return nil }
            return FXStripEntry(id: p.id, kind: p.isGainStage ? .gainStage : .plugin, name: p.name,
                                isEnabled: p.isEnabled, bin: bin)
        }
        for p in obj.plugins {
            if let block = p.fxBlock {
                let index = m.bins.count
                m.bins.append(FXStripBin(id: p.id, name: fxLink(block.linkID)?.name ?? p.name,
                                         isDetached: block.isDetached))
                for q in block.plugins { if let e = leaf(q, bin: index) { m.entries.append(e) } }
            } else if let e = leaf(p, bin: nil) {
                m.entries.append(e)
            }
        }
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
