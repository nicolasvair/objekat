import CoreGraphics

// Where the automation PENCIL sits — the write zone at the right end of each automation row
// (@see AutomationBandView, which draws it and owns its drag, and TimelineView's scroll monitor,
// which owns its wheel). ONE definition for the two: a pencil drawn in one place and answering
// the wheel in another would be a control one can see and cannot use.
//
// The pencil is pinned to the RIGHT END OF THE VISIBLE PART of the row, not to the row's end in
// time: it stays under the eye while the timeline scrolls, and a band longer than the window
// (an infinite bus spans the whole timeline) still shows one. The visible part is read from the
// EXACT scroll (@see LiveVisibleSpan); the hit-test reads the same exact scroll.
enum AutomationWritePencil {

    /// The pencil column's width (pt): the icon is centred in it.
    static let width: Double = 22
    /// The icon's side (pt), capped by the row's height. Only this square answers — hover, cursor,
    /// wheel, drag — never the whole column: writing by accident is not an option.
    static let iconSide: Double = 18
    /// Its clearance from the visible part's right edge (pt).
    static let rightInset: Double = 2
    /// Below this visible width the row shows no pencil: it would cover most of what it writes.
    static let minVisibleWidth: Double = 3 * width

    /// The pencil's ICON rectangle for `row`, in the BAND's local coordinates. `visibleX` / `visibleWidth`
    /// = the band's visible part, `visibleX` local to the band. nil when the visible part is too
    /// narrow, or the row does not exist.
    static func rect(row: Int, geo: AutomationBandGeometry,
                     visibleX: Double, visibleWidth: Double) -> CGRect? {
        guard geo.rows.indices.contains(row), visibleWidth >= minVisibleWidth else { return nil }
        let x = visibleX + visibleWidth - width - rightInset
        guard x >= 0 else { return nil }
        let side = min(iconSide, geo.rowHeight)
        return CGRect(x: x + (width - side) / 2, y: geo.rowTop(row) + (geo.rowHeight - side) / 2,
                      width: side, height: side)
    }

    /// The row whose pencil is under `p` (band-local), if any.
    static func row(at p: CGPoint, geo: AutomationBandGeometry,
                    visibleX: Double, visibleWidth: Double) -> Int? {
        guard let row = geo.rowIndex(atY: p.y),
              let r = rect(row: row, geo: geo, visibleX: visibleX, visibleWidth: visibleWidth),
              r.contains(p) else { return nil }
        return row
    }
}
