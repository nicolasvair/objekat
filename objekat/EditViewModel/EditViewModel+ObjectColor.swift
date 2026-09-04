import Foundation

// MARK: - An object's custom colour (clip / MIDI clip / group / aux)
//
// Independent of the stem: `SoundObject.colorIndex` points into `ObjectColorPalette.palette`
// (16 hues). See the context menu (TimelineKeyHandler) for the swatches, and
// SoundBlockView/GroupBlockView for the rendering (a 10% stem / 90% custom colour band).

extension EditViewModel {

    /// Assigns (or removes, if `colorIndex == nil`) one object's custom colour.
    func setObjectColor(id: UUID, colorIndex: Int?) {
        setObjectColor(ids: [id], colorIndex: colorIndex)
    }

    /// The batch variant (painting a multiple selection in one go). For a SHARED object the
    /// colour is SYNCHRONISED across every placement of the same definition (not per-instance
    /// the way position/fades/plugins are) — a visual landmark for spotting at a glance every
    /// instance linked to the others.
    func setObjectColor(ids: Set<UUID>, colorIndex: Int?) {
        guard !ids.isEmpty else { return }
        var targets = ids
        for id in ids {
            guard let defID = find(id: id)?.definitionID else { continue }
            targets.formUnion(placementIDs(forDefinition: defID))
        }
        pushUndo()
        for id in targets {
            update(id: id) { $0.colorIndex = colorIndex }
        }
        isDirty = true
    }
}
