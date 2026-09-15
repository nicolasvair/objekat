import Foundation

// MARK: - The Send tool's knob columns — where they are, and nothing else
//
// The geometry of the columns, and only the geometry: no view, no model, no layout. It is a unit
// of its own for the reason `SynopticMarquee` is one — this is the half of the Send tool that has
// nothing behind it, and put here it can be compiled alone and asserted with no screen
// (@see tools/test_send_columns.swift).
//
// Two readings depend on it and MUST agree: the display (`ToolSendLayer`) and the gestures'
// hit-testing (`sendRowHit` → `handleSendTap` / `handleSendDrag`). A knob one can see and cannot
// turn is what happens the day they drift, and that is exactly the bug the inset below fixes.

/// The width of a send knob column, for a block width already stripped of what it shares with a
/// crossfaded neighbour (@see `sendColumnIndex`). The columns are laid out left to right: with many
/// auxes they get thin — it is enough to zoom in horizontally to make them bigger.
func sendColWidth(blockWidth: Double, count: Int) -> Double {
    guard count > 0 else { return blockWidth }
    return min(blockWidth / Double(count), 60)
}

/// The height of the on/off button's clickable area (at the BOTTOM of each column).
let sendToggleZoneHeight: Double = 22

/// Which column a point falls in, `localX` being measured from the block's LEFT EDGE. `nil` = none.
///
/// `leadingInset` is the span of that edge a CROSSFADE holds — the width the block shares with the
/// neighbour it fades into. The columns set off after it, and that is the whole point: a crossfade
/// zone belongs to TWO objects at once, so knobs drawn inside it were drawn over pixels the
/// neighbour occupies too, and the click landed on whichever of the pair the hit-test reached
/// first. Past the inset, every pixel belongs to this object alone.
///
/// What is left of the block carries the columns, so a heavily crossfaded edge makes them thinner
/// rather than pushing them off the end.
func sendColumnIndex(localX: Double, blockWidth: Double, leadingInset: Double, count: Int) -> Int? {
    guard count > 0 else { return nil }
    let inset = max(0, leadingInset)
    let colW = sendColWidth(blockWidth: max(0, blockWidth - inset), count: count)
    guard colW > 0 else { return nil }
    let x = localX - inset
    guard x >= 0 else { return nil }
    let idx = Int(x / colW)
    return idx < count ? idx : nil
}
