import SwiftUI

// A clip with its OWN colour (`SoundObject.colorIndex`) has a two-zone background in its rich view
// (`SoundBlockView.body`): over a white base, the top band — the one carrying the NAME, 20 % of the
// block's height and at least 3 pt — takes the custom colour, and the body keeps the stem's. The
// border (and the loop's grips) follow the custom colour as well.
//
// The batched Canvas (`TimelineView.plainBlocksCanvas`, phase 1) draws it from these two values so
// the rule lives in ONE place: the batch key says WHICH colours, the batch accumulates the three
// paths (whole block, band, body) the four fills / strokes of a (custom, stem) pair are made of.
// No view, no model: pure geometry, hence assertable alone (`tools/test_custom_color_batch.swift`).

/// What two clips must share to be drawn by the same four operations.
nonisolated struct CustomColorKey: Hashable {
    let custom: Color
    let stem: Color
}

/// The paths of every block of one (custom colour, stem colour) pair.
nonisolated struct CustomColorBatch {
    /// The whole rounded rectangle: the white base and the border.
    var full = Path()
    /// The top band, rounded at its two top corners only (`UnevenRoundedRectangle` in the rich view).
    var band = Path()
    /// The rest of the block, rounded at its two bottom corners only.
    var body = Path()

    /// The band's height in a block `blockHeight` tall: 20 %, never under 3 pt, never over the block.
    static func bandHeight(blockHeight: Double) -> Double {
        min(blockHeight, max(3, blockHeight * 0.20))
    }

    /// Lays one block. `rect.height` is the block's height (the band is measured against it, as the
    /// rich view measures it against its `blockHeight`).
    mutating func add(_ rect: CGRect, radius r: Double, blockHeight: Double) {
        let bandH = Self.bandHeight(blockHeight: blockHeight)
        let bandRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: bandH)
        let bodyRect = CGRect(x: rect.minX, y: rect.minY + bandH,
                              width: rect.width, height: max(0, rect.height - bandH))
        full.addPath(RoundedRectangle(cornerRadius: r).path(in: rect))
        band.addPath(UnevenRoundedRectangle(topLeadingRadius: r, topTrailingRadius: r).path(in: bandRect))
        body.addPath(UnevenRoundedRectangle(bottomLeadingRadius: r, bottomTrailingRadius: r).path(in: bodyRect))
    }
}
