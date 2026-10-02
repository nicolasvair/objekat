import Foundation

// The hit-test's door onto `LaneEntryIndex` (@see Shared/LaneEntryIndex.swift for the contract:
// every answer is the one `laneEntries.first(where:)` would give, the model's order kept).
//
// FRESHNESS — the index is a function of `laneEntries` and of nothing else, and it is dropped in
// `rebuildLaneEntries` right before the list is replaced, so the two can never disagree: inside a
// `batchItemsMutation` both stay frozen, and the first read after the rebuild builds a new one.
// It is reached THROUGH the view model (a reference), never captured in a closure, so the NSEvent
// monitors and the gesture closures of a long-lived `TimelineView` copy always ask the current one
// (@see feedback_swiftui_stale_capture) — the geometry (zoom, row height) is passed per call.
//
// OBSERVATION — every accessor reads `laneEntries` first, even on a cache hit: it is what registers
// the dependency, so a SwiftUI body that used to read the list through `first(where:)` is still
// invalidated when the list changes. (The cache itself is @ObservationIgnored.)
extension EditViewModel {

    private func laneEntryIndex(for entries: [LaneEntry]) -> LaneEntryIndex {
        if let cached = laneEntryIndexCache, cached.count == entries.count { return cached }
        let index = LaneEntryIndex(
            boxes: entries.map { LaneEntryIndex.Box(displayLane: $0.displayLane,
                                                    start: $0.absStart,
                                                    duration: $0.item.duration,
                                                    clipLo: $0.clipLo, clipHi: $0.clipHi) },
            ids: entries.map(\.item.id))
        laneEntryIndexCache = index
        return index
    }

    /// The first entry of the list whose block contains the point (canvas coordinates) — the
    /// predicate the hover sites share:
    /// `x ∈ [bx, bx + max(duration·pps, 2)]`, `y ∈ [by, by + blockHeight]`,
    /// `bx = absStart·pps`, `by = rulerHeight + displayLane·laneStep`.
    func laneEntry(atX x: Double, y: Double, pixelsPerSecond: Double,
                   rulerHeight: Double, laneStep: Double, blockHeight: Double) -> LaneEntry? {
        let entries = laneEntries
        guard let p = laneEntryIndex(for: entries).firstBlock(
            atX: x, y: y, pixelsPerSecond: pixelsPerSecond,
            rulerHeight: rulerHeight, laneStep: laneStep, blockHeight: blockHeight)
        else { return nil }
        return entries[p]
    }

    /// `laneEntries.contains { $0.displayLane == lane && t >= absStart + margin
    ///  && t <= absStart + duration - margin }`.
    func laneHasBlock(displayLane lane: Int, covering t: Double, margin: Double) -> Bool {
        let entries = laneEntries
        return laneEntryIndex(for: entries).laneCovers(displayLane: lane, at: t, margin: margin)
    }

    /// `laneEntries.first(where: { $0.item.id == id })`.
    func laneEntry(forID id: UUID) -> LaneEntry? {
        let entries = laneEntries
        guard let p = laneEntryIndex(for: entries).firstPosition(forID: id) else { return nil }
        return entries[p]
    }
}
