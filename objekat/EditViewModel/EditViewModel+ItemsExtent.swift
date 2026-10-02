import Foundation

// The extent of the top-level objects — where the matter ends, and the lowest model lane — read by
// the timeline's body some twenty times per pass (`totalDuration`, `contentDuration`, `minZoom`,
// `canvasHeight`, the scroll bounds…).
//
// Each read used to be `items.map { … }.max()`: a copy of EVERY top-level object (a large struct,
// retained and released field by field) per call. With 600 objects on the top level that was ~20 % of
// the main thread's busy time during a zoom (`sample`, Release, E8 part 2) — for two numbers that only
// change when `items` does. They are worked out once per change of `items` and read from here.
//
// Same contract as `crossfadePartners` / `findIndex`: `items` is READ on every call, cache hit or not
// — that read is what registers the dependency for a view body — and the cache is @ObservationIgnored
// and emptied by `items.didSet`, so it can never be older than the array it describes.

extension EditViewModel {

    /// Where the project's matter really ends: the right edge of its last top-level object (0 when
    /// there is none). Exactly `items.map { $0.startTime + $0.duration }.max() ?? 0`.
    var contentEnd: Double { itemsExtent.end }

    /// The highest MODEL lane held by a top-level object (0 when there is none). Exactly
    /// `items.map(\.lane).max() ?? 0`.
    var maxOccupiedLane: Int { itemsExtent.maxLane }

    private var itemsExtent: (end: Double, maxLane: Int) {
        let roots = items
        if let cached = itemsExtentCache { return cached }
        let extent = (end: roots.map { $0.startTime + $0.duration }.max() ?? 0,
                      maxLane: roots.map(\.lane).max() ?? 0)
        itemsExtentCache = extent
        return extent
    }
}
