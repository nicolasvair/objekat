import Foundation

// MARK: - Cross-project paste (tabs INC2)

/// The applying half of `CrossProjectImport` (@see `SoundObject/CrossProjectImport.swift` for the
/// PURE planning half, and `project_multi_project_tabs_plan` in memory for the whole design).
/// `EditViewModel` knows nothing about tabs — `Workspace` is the one that decides a paste is
/// cross-project at all (@see `crossProjectPasteHook`, `EditViewModel.swift`) and hands over the
/// already-hoisted, already-frozen clipboard. This file only ever PLACES what `plan()` already
/// computed, through the SAME primitives `paste()` itself uses (`add`/`addChild`/`resyncAllSends`/
/// `resolveOverlaps`) — so the two paths stay visibly siblings rather than two independent
/// placement engines that could drift apart.
extension EditViewModel {

    /// Places a cross-project paste. Called from `crossProjectPasteHook`, itself called at the TOP
    /// of `paste()` — so this runs inside whatever undo wrapper the CALLER of `paste()` already
    /// pushed (`vm.edit { vm.paste() }` for the keyboard, `undo: .bus` for `clipboard.paste`),
    /// exactly as intra-project `paste()` itself never calls `pushUndo()` on its own. One call in,
    /// one undo point out.
    func pasteCrossProjectPlan(_ clipboard: CrossProjectImport.Clipboard) {
        let snapshot = laneEntries

        // The SAME kind of anchor `paste()` computes (time selection, else cursor + caret) — only
        // the ORIGIN lane it is measured against comes from the hoisted clipboard rather than from
        // `self.clipboard` (a different project's `originLane` means nothing here).
        let pasteTime: Double
        let pasteLane: Int
        if let sel = timeSelection {
            pasteTime = sel.timeRange.lowerBound
            pasteLane = sel.lanes.min() ?? clipboard.originLane
        } else {
            pasteTime = cursorPosition
            pasteLane = caretLane ?? clipboard.originLane
        }

        let target = CrossProjectImport.PasteTarget(pasteTime: pasteTime, pasteLane: pasteLane)
        let result = CrossProjectImport.plan(clipboard, target: target)
        guard !result.clips.isEmpty else { return }

        // New consolidated definitions and where their wave actually lives (the source project's
        // OWN folder — media is never copied, @see `consolidateFallbackDirs`) are registered
        // BEFORE the objects that reference them are added, so the very first sync finds them.
        for def in result.newConsolidateDefinitions {
            consolidateDefinitions[def.id] = def
        }
        for (id, folder) in result.consolidateOriginFolders {
            consolidateOriginFolders[id] = folder
        }

        typealias Placement = (copy: SoundObject, groupID: UUID?, lane: Int)
        var targets: [Placement] = []
        var maxAbsEnd = pasteTime

        for copy in result.clips {
            let targetDL = copy.lane
            if let gEntry = snapshot
                .filter({ e in
                    guard e.item.showsChildrenInline else { return false }
                    return targetDL >= e.displayLane + 1 && targetDL <= e.displayLane + e.item.childLaneCount
                })
                .max(by: { $0.displayLane < $1.displayLane }) {
                targets.append((copy, gEntry.item.id, targetDL - (gEntry.displayLane + 1)))
            } else {
                targets.append((copy, nil, baseLaneForDisplay(targetDL)))
            }
            maxAbsEnd = max(maxAbsEnd, copy.startTime + copy.duration)
        }

        var allPasted: [SoundObject] = []
        batchItemsMutation {
            for (copy, groupID, lane) in targets {
                var placed = copy
                placed.lane = lane
                if let gid = groupID { addChild(placed, toGroupID: gid) } else { add(placed) }
                allPasted.append(placed)
            }
        }

        if !result.comments.isEmpty {
            comments += result.comments
        }

        // A sender added before the aux it aims at could not be wired along the way — the same
        // idempotent catch-up `paste()` relies on; every send here is ALREADY remapped or dropped
        // by `plan()`, so no `remappingSends`/idMap step is needed on this side at all.
        resyncAllSends()
        sanitizeInfiniteConflicts(newlyPlaced: allPasted.map(\.id))
        for obj in allPasted { resolveOverlaps(for: obj.id) }

        selectedIDs = Set(allPasted.map(\.id))
        seekRequest = maxAbsEnd
        timeSelection = nil
        isDirty = true
    }
}
