import Foundation

// MARK: - A click on an object's body, and what a right click makes of it
//
// The left click and the right click on the LOWER half of a block do the same first thing — they
// select the object (range cleared, cursor on its start). It is written once, here, so the two
// cannot drift: @see TimelineView.handleCanvasTap (the left click) and
// TimelineView.registerRightClickMonitor (the right one, which decides WHETHER to select through
// `ContextMenuPlan`).

extension EditViewModel {

    /// A plain click on an object's BODY (the lower half of its block): the time selection goes,
    /// the object becomes THE selection, and the cursor — and the engine's position, unless it is
    /// playing — goes to the object's start. `cursorAt` is the object's ABSOLUTE start (a child of
    /// an open group is not at its own `startTime`).
    func selectOnBodyClick(_ id: UUID, cursorAt start: Double, isPlaying: Bool,
                           onMoveCursor: (Double) -> Void) {
        if timeSelection != nil { timeSelection = nil }   // already nil on the left click's path: no second `didSet`
        select(id, additive: false)
        let t = max(0, start)
        if !isPlaying { engine?.seek(to: t) }
        onMoveCursor(t)
    }

    /// What a right click on the lanes decides (@see ContextMenuPlan). `displayLane` and `time` are
    /// the point's, the instant NOT snapped (the range's bounds are compared as the drag compares
    /// them); `objectID` / `zone` are nil when no block lies under it.
    func contextClickPlan(objectID: UUID?, displayLane: Int, time: Double,
                          zone: ContextMenuPlan.BlockZone?) -> ContextMenuPlan.Decision {
        let inRange = timeSelection.map {
            ContextMenuPlan.contains(lane: displayLane, time: time, lanes: $0.lanes, range: $0.timeRange)
        } ?? false
        return ContextMenuPlan.decide(pointInTimeSelection: inRange, hasTimeSelection: timeSelection != nil,
                                      zone: zone,
                                      objectAlreadySelected: objectID.map { selectedIDs.contains($0) } ?? false)
    }

    /// The selection a right click on an object's body makes BEFORE its menu is built: the object
    /// is selected as a left click would, so the menu speaks about it — unless it is already part
    /// of the selection, in which case nothing at all changes (the multiple selection is what the
    /// menu is about: 'Consolidate N linked', the FX link). Like a left click it hands the
    /// keyboard back to the objects (a selected plugin card would otherwise keep ⌫).
    func selectForContextClick(_ entry: LaneEntry, isPlaying: Bool,
                               onMoveCursor: (Double) -> Void) {
        guard !selectedIDs.contains(entry.item.id) else { return }
        clearPluginSelection()
        KeyboardClaim.shared.revoke()
        selectOnBodyClick(entry.item.id, cursorAt: entry.absStart, isPlaying: isPlaying,
                          onMoveCursor: onMoveCursor)
    }
}
