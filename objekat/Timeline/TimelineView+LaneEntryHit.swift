import SwiftUI

extension TimelineView {
    /// The first entry of the flat display list whose block holds `pos` — what every hover site used
    /// to find with `viewModel.laneEntries.first(where: <the block's rectangle>)`, now through the
    /// spatial index (@see Shared/LaneEntryIndex.swift): same answer, the model's order and the
    /// crossfade / overlap / nesting rules included, in O(log N) instead of a walk of the list.
    ///
    /// ⚠️ That is the MODEL's first, not the one the canvas draws on top: selected blocks are drawn
    /// above the others while this still answers the first of the list. A separate decision, left
    /// as it always was.
    func blockEntry(at pos: CGPoint) -> LaneEntry? {
        viewModel.laneEntry(atX: pos.x, y: pos.y, pixelsPerSecond: pixelsPerSecond,
                            rulerHeight: rulerHeight, laneStep: laneStep, blockHeight: blockHeight)
    }
}
