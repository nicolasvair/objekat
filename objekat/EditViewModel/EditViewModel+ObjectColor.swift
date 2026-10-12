import Foundation

// MARK: - An object's custom colour (clip / MIDI clip / group / aux)
//
// Independent of the stem. An object's colour has two storages (@see `ObjectColorValue`): a FREE
// colour, `SoundObject.colorHex` (0xRRGGBB — what the context menu offers: seven base colours and
// the ones the hand added), and the old pastel, `SoundObject.colorIndex` into
// `ObjectColorPalette.palette` (16 hues), which a project written before the free colours still
// carries and which the API's `color_index` still writes. An object holds ONE of the two:
// writing either clears the other, and `nil` clears both. See the context menu (TimelineKeyHandler)
// for the swatches, and SoundBlockView/GroupBlockView for the rendering (a 20 % name band in the
// object's colour, drawn at `ObjectColorChoice.bandOpacity`, over the stem's body).

extension EditViewModel {

    /// Assigns (or removes, if `colorIndex == nil`) one object's custom pastel.
    func setObjectColor(id: UUID, colorIndex: Int?) {
        setObjectColor(ids: [id], colorIndex: colorIndex)
    }

    /// The batch variant, pastel storage (the API's `color_index`).
    func setObjectColor(ids: Set<UUID>, colorIndex: Int?) {
        setObjectColor(ids: ids, value: colorIndex.map(ObjectColorValue.index))
    }

    /// The batch variant, free colour: `hex` is 0xRRGGBB, nil removes the colour.
    func setObjectColor(ids: Set<UUID>, hex: Int?) {
        setObjectColor(ids: ids, value: hex.map { ObjectColorValue.hex($0 & 0xFFFFFF) })
    }

    /// The one writer. Paints a multiple selection in one go. For a SHARED object the colour is
    /// SYNCHRONISED across every placement of the same definition (not per-instance the way
    /// position/fades/plugins are) — a visual landmark for spotting at a glance every instance
    /// linked to the others. One undo point; none if nothing would change.
    func setObjectColor(ids: Set<UUID>, value: ObjectColorValue?) {
        guard !ids.isEmpty else { return }
        var targets = ids
        for id in ids {
            guard let defID = find(id: id)?.consolidateID else { continue }
            targets.formUnion(placementIDs(forConsolidate: defID))
        }
        let (newIndex, newHex): (Int?, Int?)
        switch value {
        case .index(let i)?: (newIndex, newHex) = (i, nil)
        case .hex(let h)?:   (newIndex, newHex) = (nil, h)
        case nil:            (newIndex, newHex) = (nil, nil)
        }
        pushUndo()
        for id in targets {
            update(id: id) { $0.colorIndex = newIndex; $0.colorHex = newHex }
        }
        isDirty = true
    }
}
