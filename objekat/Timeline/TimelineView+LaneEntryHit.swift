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

    /// The ONE probe of a point on the lanes (@see `LaneClickHit`): what lies under it at ANY depth
    /// — a top-level block, a child of an open group, a sub-group's child —, which half of the block
    /// it is in, the display row and the instant. Read by the left click (`handleCanvasTap`) and
    /// the right click (the context menu), which is what keeps them from disagreeing about what is
    /// under the hand — and from having a top-level reading and an inside-a-group reading.
    ///
    /// Found on the flat display list (`laneEntries`), in the model's order. An INFINITE BUS is its
    /// whole lane (0 → the content's width), wherever it sits; every other block answers only on its
    /// rectangle and outside the out-of-range veil of its ancestors' windows (`isUnmasked`). The zone
    /// is `ContextMenuPlan.BlockZone`'s 50 % line.
    ///
    /// `rulerHeight` is passed in and not read from `self`: the marker band makes the header grow,
    /// and the AppKit right-click monitor works from a copy of this struct taken at registration —
    /// it hands over the height it reads LIVE.
    func lanePointProbe(at point: CGPoint, rulerHeight rulerH: Double) -> LaneClickHit {
        let pps  = pixelsPerSecond
        let bh   = blockHeight
        let step = laneStep
        let width = contentWidth
        var topY = 0.0
        let entry = viewModel.laneEntries.first { e in
            let by = rulerH + Double(e.displayLane) * step
            guard point.y >= by && point.y <= by + bh else { return false }
            topY = by
            // An infinite bus: its surface is its whole lane (0 → the content's width).
            if e.item.isInfiniteBus { return point.x >= 0 && point.x <= width }
            let bx = e.absStart * pps
            let bw = max(e.item.duration * pps, 2)
            return point.x >= bx && point.x <= bx + bw
                && e.isUnmasked(atX: point.x, pixelsPerSecond: pps)
        }
        return LaneClickHit(
            entry: entry,
            zone: entry.map { _ in ContextMenuPlan.BlockZone.zone(localY: point.y - topY, blockHeight: bh) },
            lane: entry?.displayLane ?? max(0, Int((point.y - rulerH) / step)),
            time: max(0, point.x / pps))
    }
}
