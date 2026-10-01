import Foundation

/// The vertical culling of the layers that walk lanes (bands, tints, masks, time selection,
/// carets…): which display rows a window `[y0, y1]` of the canvas touches.
///
/// A unit of its own, with no view and no model behind it, for the reason `SendColumns` and
/// `VerticalLaneSnap` are: it is the half of the work that can be compiled alone and asserted
/// (`tools/test_crossfade_zone_cache.swift`).
///
/// Geometry: row `l` occupies `[rulerHeight + l·laneStep, rulerHeight + (l+1)·laneStep)` of the
/// canvas — the row's own `laneStep`, gap included, which is how the old SwiftUI layers (a
/// `laneStep`-tall rectangle per row) filled it.
enum LaneCulling {

    /// The rows `0..<count` whose band meets `[y0, y1]` (canvas coordinates). Empty when none does.
    static func rows(y0: Double, y1: Double, rulerHeight: Double, laneStep: Double,
                     count: Int) -> Range<Int> {
        guard count > 0, laneStep > 0, y1 >= y0 else { return 0..<0 }
        let first = max(0, Int(((y0 - rulerHeight) / laneStep).rounded(.down)))
        // `y1` itself belongs to the row it falls in (a band whose top is exactly `y1` has not
        // started yet, and is simply drawn off the visible area: harmless, never missing).
        let lastInclusive = min(count - 1, Int(((y1 - rulerHeight) / laneStep).rounded(.down)))
        guard lastInclusive >= first else { return 0..<0 }
        return first..<(lastInclusive + 1)
    }

    /// True when the span `[top, top + height)` meets `[y0, y1]`.
    static func meets(top: Double, height: Double, y0: Double, y1: Double) -> Bool {
        top + height > y0 && top < y1
    }
}
