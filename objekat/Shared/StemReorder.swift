import Foundation
import CoreGraphics

/// The arithmetic behind dragging a stem's strip past its neighbours to reorder the toolbar's
/// bar of buses — no model behind it, so it can be compiled and asserted alone
/// (`tools/test_stem_reorder.swift`), exactly like `SendColumns` / `SynopticMarquee` before it.
///
/// `frames` are the strips' X-ranges, FROZEN at the start of the drag (their widths can differ,
/// a longer stem name making a wider strip — reordering live as the pointer crosses a midpoint
/// would move the very frame the pointer is being compared against). `dragged` is the index (in
/// `frames`) of the strip actually being dragged.
enum StemReorder {
    /// The 0-based index the dragged strip would land at if released with the pointer at
    /// `pointerX` (in the bar's own coordinate space): 1 + how many of the OTHER strips (index
    /// `dragged` excluded) sit with their midpoint before the pointer. That count is already a
    /// RANK among the strips that stay put, so it doubles as the insertion index once the
    /// dragged strip has been removed from the array — no further off-by-one adjustment needed
    /// at the call site.
    ///
    /// Index 0 (the Main) is never a valid target and never moves: the result is clamped to
    /// `1...(frames.count - 1)`.
    static func targetIndex(pointerX: CGFloat, frames: [CGRect], dragged: Int) -> Int {
        guard frames.count > 1 else { return dragged }
        var count = 0
        for i in 1..<frames.count where i != dragged {
            if frames[i].midX < pointerX { count += 1 }
        }
        return max(1, min(frames.count - 1, 1 + count))
    }
}
