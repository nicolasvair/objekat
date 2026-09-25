import Foundation
import CoreGraphics

/// The arithmetic behind dragging a project tab along the tab strip to reorder it — no model
/// behind it, so it can be compiled and asserted alone (`tools/test_tab_reorder.swift`), exactly
/// like `StemReorder` for the bar of buses.
///
/// It differs from `StemReorder` in one respect, and it is the point of the gesture: the dragged
/// tab FOLLOWS the hand (an `offset` of the pointer's travel) and its neighbours slide aside to
/// make room, rather than the order being reshuffled under a pointer that stays put. So what is
/// compared against the other tabs' midpoints is the dragged tab's own CENTRE — what the eye is
/// watching — and not the pointer, which can have grabbed the tab anywhere along its width.
///
/// `frames` are the tabs' X-ranges, FROZEN at the start of the drag, in strip order: their widths
/// differ (a name is as long as it is), and reading them live would compare the dragged tab
/// against neighbours that are themselves moving to make room for it. `dragged` is the index (in
/// `frames`) of the tab being dragged.
enum TabReorder {

    /// The 0-based index the dragged tab lands at if it is released with a horizontal travel of
    /// `dx`: how many of the OTHER tabs have their midpoint before the dragged tab's centre. That
    /// count is a rank among the tabs that stay put, so it is already the insertion index once
    /// the dragged tab has been taken out of the array — `Workspace.moveTab(_:to:)`'s own reading.
    /// Unlike the stems there is no fixed first entry: every tab can go anywhere.
    static func targetIndex(frames: [CGRect], dragged: Int, dx: CGFloat) -> Int {
        guard frames.indices.contains(dragged) else { return dragged }
        let centre = frames[dragged].midX + dx
        var count = 0
        for i in frames.indices where i != dragged && frames[i].midX < centre {
            count += 1
        }
        return count
    }

    /// How far a NEIGHBOUR at `index` slides aside while the dragged tab is aimed at `target`: by
    /// the dragged tab's own width plus the strip's `spacing` — the room it leaves behind on one
    /// side and needs on the other — leftwards for the tabs it has passed going right, rightwards
    /// for those it has passed going left, and not at all for the rest. The dragged tab itself
    /// answers 0: its offset is the hand's, not this.
    ///
    /// At the drop the array is reordered and every shift returns to 0 in the SAME transaction,
    /// so a neighbour's layout position and its offset move by equal and opposite amounts — it
    /// stays exactly where the preview had already put it.
    static func shift(of index: Int, dragged: Int, target: Int,
                      frames: [CGRect], spacing: CGFloat) -> CGFloat {
        guard index != dragged, frames.indices.contains(dragged) else { return 0 }
        let step = frames[dragged].width + spacing
        if dragged < index && index <= target { return -step }
        if target <= index && index < dragged { return step }
        return 0
    }
}
