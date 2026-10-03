import Foundation
import CoreGraphics

/// Where a block's NAME stands when the block starts left of the viewport.
///
/// The name used to be laid at a fixed inset from the block's own left edge, so a long object
/// scrolled past its start lost its label: the part one could still see carried no name. It is
/// now ANCHORED TO THE START OF THE VISIBLE PART — clamped to the viewport's left edge for as long
/// as the block is still seen there and there is room left for it (the block's own clip then cuts
/// the text on its right, as it always did). Never LEFT of where it stood before: the clamp only
/// ever pushes a name rightwards, so a block wholly on screen draws exactly what it drew.
///
/// Pure (no view, no model), so the arithmetic can be asserted alone — `tools/test_sticky_label.swift`.
nonisolated enum StickyLabel {

    /// The gap kept between the viewport's edge and a clamped name (px).
    static let edgeInset: Double = 6
    /// A clamped name needs this much room left before the block's right limit, else it is not
    /// drawn there: a sliver that cannot show a glyph is noise, not a label.
    static let minVisiblePx: Double = 12
    /// Below this width a block's label is not worth following the scroll: what is left to read
    /// is a few glyphs, and the batched Canvas pays for every label it moves.
    static let minBlockWidth: Double = 40

    /// The label's left edge for a block whose name naturally starts at `natural`, given the
    /// viewport's EXACT left edge — nil if the name has been pushed (the viewport edge is past
    /// where it can still show) and no longer fits before `rightLimit`.
    static func x(natural: Double, viewportLeft: Double, rightLimit: Double) -> Double? {
        let clamped = viewportLeft + edgeInset
        guard clamped > natural else { return natural }
        return rightLimit - clamped >= minVisiblePx ? clamped : nil
    }

    /// The same rule as a LEADING padding inside a block (the rich views): `visibleX` is the start
    /// of the visible part in coordinates local to the block (`LiveVisibleSpan`). A clamp that
    /// leaves too little room falls back on the natural padding.
    static func leading(natural: Double, visibleX: Double, blockWidth: Double) -> Double {
        let clamped = visibleX + edgeInset
        guard clamped > natural else { return natural }
        return blockWidth - clamped >= minVisiblePx ? clamped : natural
    }

    /// Whether a label's place can DEPEND ON THE EXACT SCROLL, given only the culling notch the
    /// batched Canvas knows: the viewport's left edge lies somewhere in
    /// `[cullScrollX, cullScrollX + step)`, so a name that starts before `cullScrollX + step +
    /// edgeInset` MAY have to be pushed, and a block reaching into the window at all (`blockEnd >
    /// cullScrollX`) may be seen. Those labels are drawn by the sticky layer, which reads the exact
    /// scroll; the others (the vast majority) stay in the notch-driven Canvas.
    static func isLive(naturalX: Double, blockX: Double, blockWidth: Double,
                       cullScrollX: Double, step: Double) -> Bool {
        blockWidth >= minBlockWidth
            && naturalX < cullScrollX + step + edgeInset
            && blockX + blockWidth > cullScrollX
    }
}

/// What a Canvas pass knows about the two labels' regimes. `exactScrollX == nil` is the ORDINARY
/// pass (notch-driven): it draws every label the sticky layer does not own. A non-nil
/// `exactScrollX` is the STICKY pass: it draws only those, clamped on the exact viewport edge. The
/// two partition the labels by the same predicate (`StickyLabel.isLive`), so none is drawn twice
/// or not at all.
nonisolated struct StickyLabelPass: Sendable {
    let exactScrollX: CGFloat?
    let cullScrollX: CGFloat
    let step: CGFloat

    var isStickyPass: Bool { exactScrollX != nil }

    /// Where this pass draws a label whose natural left edge is `naturalX` in the block
    /// `[blockX, blockX + blockWidth]`, its text able to run up to `rightLimit` — nil = not in this pass.
    func placement(naturalX: Double, blockX: Double, blockWidth: Double, rightLimit: Double) -> Double? {
        let live = StickyLabel.isLive(naturalX: naturalX, blockX: blockX, blockWidth: blockWidth,
                                      cullScrollX: Double(cullScrollX), step: Double(step))
        guard let exact = exactScrollX else { return live ? nil : naturalX }
        guard live else { return nil }
        return StickyLabel.x(natural: naturalX, viewportLeft: Double(exact), rightLimit: rightLimit)
    }
}
