import Foundation

// MARK: - The object menu applied to a ZONE
//
// `.zone` scope of `performObjectMenuAction`: the action concerns the part of the objects inside
// the time selection and nothing else. There is NO branch for the depth of the object — the
// objects are isolated on the range's bounds (@see `isolateTimeSelection`) and the action then
// applies to the pieces that fall inside, top-level or inside a group alike.
//
// Undo, by kind of action:
//   • the ones that complete synchronously (dissolve, deconsolidate, colour, FX link) run
//     `isolate; action` inside ONE `singleUndoStep`: one ⌘Z gives the objects back whole;
//   • the ones that go on in the background or that the machine runs afterwards (consolidating,
//     scripts) cannot be wrapped — their own undo point comes later — so the isolation is a step
//     of its own, then the action: TWO ⌘Z. An accepted cost (decided with the request);
//   • 'wrap in a group', 'aux clip', 'MIDI clip' are the range's own entries and already take the
//     range (`createGroupFromTimeSelection`…) with their own cut and their own single undo.

extension EditViewModel {

    func performZoneMenuAction(_ action: ObjectMenuAction, clickedID: UUID?,
                               selection sel: TimeSelection) async {
        switch action {
        case .baking, .consolidateLinked:
            return   // informational / whole objects only: not offered on a zone
        case .groupSelection:
            createGroupFromTimeSelection(sel)
            return
        case .createAux:
            createAuxFromTimeSelection(sel)
            return
        case .createMidiClip:
            createMidiClipFromTimeSelection(sel)
            return
        default:
            break
        }

        // Where the clicked object stands BEFORE the cuts renumber it: its display row and an
        // instant inside both the object and the range, which is what finds its piece afterwards.
        let t1 = sel.timeRange.lowerBound, t2 = sel.timeRange.upperBound
        var anchor: (lane: Int, time: Double)? = nil
        if let id = clickedID, let e = laneEntry(forID: id) {
            let lo = max(e.absStart, t1), hi = min(e.absStart + e.item.duration, t2)
            anchor = (e.displayLane, (lo + max(lo, hi)) / 2)
        }
        func piece(of pieces: [UUID]) -> UUID? {
            let entries = pieces.compactMap { laneEntry(forID: $0) }
            if let anchor,
               let hit = entries.first(where: { $0.displayLane == anchor.lane
                                                && $0.absStart <= anchor.time + 1e-6
                                                && $0.absStart + $0.item.duration >= anchor.time - 1e-6 }) {
                return hit.item.id
            }
            return entries.first(where: { $0.displayLane == anchor?.lane })?.item.id ?? entries.first?.item.id
        }

        switch action {
        case .disbandGroup:
            singleUndoStep {
                let pieces = isolateTimeSelection(sel)
                if let id = piece(of: pieces) { disbandGroup(id: id) }
            }
        case .deconsolidate:
            singleUndoStep {
                let pieces = isolateTimeSelection(sel)
                if let id = piece(of: pieces) { deconsolidate(placementID: id) }
            }
        case .setColor(let index):
            singleUndoStep {
                let pieces = isolateTimeSelection(sel)
                setObjectColor(ids: Set(pieces), colorIndex: index)
            }
        case .createFXLink:
            singleUndoStep {
                let pieces = isolateTimeSelection(sel)
                _ = createFXLinkFromObjects(pieces)
            }
        case .consolidateGroup:
            let pieces = isolateTimeSelectionAsOneStep(sel)
            if let id = piece(of: pieces) { consolidate(groupID: id) }
        case .consolidateClip:
            let pieces = isolateTimeSelectionAsOneStep(sel)
            if let id = piece(of: pieces) { consolidateWrappingClip(clipID: id) }
        case .consolidateEach:
            isolateTimeSelectionAsOneStep(sel)
            await consolidateEachInSelection()    // reads the selection: the pieces
        case .runScript(let pluginID, let entryIndex):
            let pieces = isolateTimeSelectionAsOneStep(sel)
            runObjectScript(pluginID: pluginID, entryIndex: entryIndex, objectIDs: pieces)
        case .baking, .consolidateLinked, .groupSelection, .createAux, .createMidiClip:
            break   // handled above
        }
    }
}
