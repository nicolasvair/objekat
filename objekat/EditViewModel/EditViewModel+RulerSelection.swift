import Foundation

// A drag in the time ruler selects TIME: a range over every object lane. The arithmetic is in
// `Shared/RulerSelection.swift`; this is the model-side half, which knows what "every lane" is.
extension EditViewModel {

    /// Every OBJECT display lane the timeline has right now, from row 0 to the last row it draws
    /// for the objects (one past the lowest one, everything unfolded above it counted — the same
    /// bound `stepTimeSelectionLanes` walks to). Automation rows are left out: a time selection
    /// holds one kind of lane, and the ruler's is the objects' (@see `confine`).
    func allObjectLanes() -> Set<Int> {
        let lastRow = displayLane(forBase: (items.map(\.lane).max() ?? 0) + 1)
        return RulerSelection.objectLanes(lastRow: lastRow, automationLanes: automationLanes)
    }
}
