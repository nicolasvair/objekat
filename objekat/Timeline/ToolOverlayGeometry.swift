import Foundation

// MARK: - The Volume / Pan / Send / Stem overlays — their geometry and their rules, in ONE place
//
// Foundation only: no view, no model, no layout. It is a unit of its own for the reason
// `SendColumns` is one — a tool's overlay is READ by three kinds of consumer that MUST agree: the
// rich layers (`ToolVolumeLayer`, `ToolPanLayer`, `ToolSendLayer`), the gestures' hit-testing
// (`handleVolumeTap`, `handleVolumeDrag`, `handlePanDrag`, `toolZoneHelp`), and the Canvas drawing
// (@see ToolOverlayDrawing). A zone one can see and cannot press is what happens the day two of
// them drift, and each used to carry its own copy of the same 0.4 / 0.6 / 50 / 34 / 48.
//
// It is compiled alone and asserted with no screen (@see tools/test_tool_overlay_geometry.swift) —
// which is why the Send tool's dB floor comes in as a parameter instead of reading `sendMinDb`
// (a global of SoundObject.swift).
//
// WHAT IS NOT HERE: which tool draws over which veil. The mute veil of a clip is hidden under the
// Volume tool but a GROUP's is not; under Pan the mute veil sits ON TOP of the button; the
// automation lock is only ever drawn under Send. Those asymmetries are the BLOCKS' (SoundBlockView
// / GroupBlockView), and they stay there.

enum ToolOverlayGeometry {

    // MARK: - Narrow blocks

    /// A block narrower than this (px) gets the compact reading: the Volume tool shows its minimal
    /// veil whether it is selected or not, the Pan tool always shows its panel, and neither follows
    /// the exact scroll (a label a few pixels wide is not worth a re-evaluation per frame).
    static let narrowBlockWidth: Double = 50

    static func isNarrow(blockWidth: Double) -> Bool { blockWidth < narrowBlockWidth }

    // MARK: - Volume: three zones across the block's VISIBLE span

    /// The zones are fractions of the VISIBLE span's width (@see `visibleSpan`), left to right:
    /// mute 0…0.4, ± 1 dB 0.4…0.6, level drag 0.6…1.
    static let volumeMuteFraction: Double = 0.4
    static let volumeStepFraction: Double = 0.2
    static let volumeDragFraction: Double = 0.4
    /// Where the level zone starts. Spelled out, NOT `mute + step`: 0.4 + 0.2 is 0.6000000000000001
    /// in floating point, and a zone edge that moves by one ulp is a click that lands in the
    /// neighbour's zone on exactly the pixel that was aimed at.
    static let volumeDragStart: Double = 0.6

    enum VolumeZone: Equatable { case mute, step, drag }

    /// The zone under `localX` (px from the visible span's left edge), `spanWidth` being its width.
    static func volumeZone(localX: Double, spanWidth: Double) -> VolumeZone {
        if localX < spanWidth * volumeMuteFraction { return .mute }
        if localX < spanWidth * volumeDragStart { return .step }
        return .drag
    }

    /// The ± zone is split in two halves by the block's HEIGHT: the top one raises (+1), the bottom
    /// one lowers (−1). `localY` is measured from the block's top edge.
    static func volumeStepDirection(localY: Double, blockHeight: Double) -> Int {
        localY < blockHeight * 0.5 ? 1 : -1
    }

    /// The rich layer's columns, in px. The dividers are 1 px each and eat 2 px of the ± and the
    /// level columns, so the three add up to `spanWidth − 2` (the divider widths being the rest).
    static let volumeDividerWidth: Double = 1
    static func volumeMuteColumnWidth(spanWidth: Double) -> Double { spanWidth * volumeMuteFraction }
    static func volumeStepColumnWidth(spanWidth: Double) -> Double { spanWidth * volumeStepFraction - 2 }
    static func volumeDragColumnWidth(spanWidth: Double) -> Double { spanWidth * volumeDragFraction - 2 }

    /// What a block draws under the Volume tool. The minimal veil (just the level) shows on a
    /// selected block and on any narrow one; the full one (mute / ± / level) only under the hover,
    /// and never on a narrow block. `needsExactSpan` = the controls follow the exact scroll; a
    /// narrow block keeps the culling window's span instead.
    struct VolumePlan: Equatable {
        let showMinimal: Bool
        let showFull: Bool
        let needsExactSpan: Bool
    }

    static func volumePlan(blockWidth: Double, isSelected: Bool, isToolHovered: Bool) -> VolumePlan {
        let narrow = isNarrow(blockWidth: blockWidth)
        return VolumePlan(showMinimal: isSelected || narrow,
                          showFull: isToolHovered && !narrow,
                          needsExactSpan: !narrow && (isSelected || isToolHovered))
    }

    // MARK: - Pan

    /// The Pan tool's panel shows on a selected block, a hovered one, and any narrow one.
    struct PanPlan: Equatable {
        let shown: Bool
        let needsExactSpan: Bool
    }

    static func panPlan(blockWidth: Double, isSelected: Bool, isToolHovered: Bool) -> PanPlan {
        let narrow = isNarrow(blockWidth: blockWidth)
        let shown = isSelected || narrow || isToolHovered
        return PanPlan(shown: shown, needsExactSpan: !narrow && shown)
    }

    /// The knob's diameter: bounded by the block's visible width and by its height (less the room
    /// for the label), so as to stay readable from a tiny clip to a full-screen one.
    static func panKnobSize(visibleWidth: Double, height: Double) -> Double {
        max(14, min(34, min(visibleWidth - 8, height - 18)))
    }

    /// The width a vertical pan drag is scaled against: the visible span less the panel's margin
    /// (10 px each side). A wide block keeps a fine adjustment.
    static func panDragTrackWidth(spanWidth: Double) -> Double { max(spanWidth - 20, 1) }

    // MARK: - Send

    /// The columns' layout, ready to draw: `origin` / `width` are `sendColumnsLayout`'s (the span
    /// the columns share, set off after a crossfade's inset and inside the visible portion),
    /// `columnWidth` is one column's width (@see `sendColWidth`, which caps it at 60 px).
    static func sendLayout(blockWidth: Double, leadingInset: Double, count: Int,
                           visibleX: Double = 0, visibleWidth: Double? = nil)
        -> (origin: Double, width: Double, columnWidth: Double) {
        let lay = sendColumnsLayout(blockWidth: blockWidth, leadingInset: leadingInset, count: count,
                                    visibleX: visibleX, visibleWidth: visibleWidth)
        return (lay.origin, lay.width, sendColWidth(blockWidth: lay.width, count: count))
    }

    /// A column carries its name and its level (as text) only when it is wide AND tall enough.
    static func sendShowsText(columnWidth: Double, blockHeight: Double) -> Bool {
        columnWidth >= 34 && blockHeight >= 48
    }

    /// The knob's diameter: what the column leaves once the on/off zone and (if shown) the two
    /// text lines are taken off, within 11…26 px.
    static func sendKnobDiameter(columnWidth: Double, blockHeight: Double, showText: Bool) -> Double {
        max(11, min(columnWidth - 12, blockHeight - sendToggleZoneHeight - (showText ? 32 : 6), 26))
    }

    /// The bottom of a column is its on/off button (a click there flips the send, elsewhere it only
    /// focuses). `localY` is measured from the block's top edge; the 4 px are the zone's slack.
    static func sendToggleHit(localY: Double, blockHeight: Double) -> Bool {
        localY >= blockHeight - sendToggleZoneHeight - 4
    }

    /// Where a send's level lies on the knob's travel, 0…1 (clamped to `minDb…maxDb`).
    static func sendKnobFraction(level: Float, minDb: Float, maxDb: Float) -> Double {
        guard maxDb > minDb else { return 0 }
        return Double((min(max(level, minDb), maxDb) - minDb) / (maxDb - minDb))
    }

    // MARK: - Labels

    /// The Volume tool's level. The full veil says "-∞ dB"; the minimal one is shorter at the floor
    /// ("-∞") because its label is a few pixels wide.
    static func volumeLabel(db: Float, compact: Bool) -> String {
        if db <= -96 { return compact ? "-∞" : "-∞ dB" }
        return String(format: "%.0f dB", db)
    }

    /// The Pan tool's reading: "C", then "L n%" / "R n%" — the percentage TRUNCATED, not rounded.
    static func panLabel(pan: Float) -> String {
        if abs(pan) < 0.01 { return "C" }
        return pan < 0 ? "L \(Int(-pan * 100))%" : "R \(Int(pan * 100))%"
    }

    /// A send's level under its knob: the whole dB, "-∞" at the floor.
    static func sendLevelLabel(db: Float, minDb: Float) -> String {
        db <= minDb ? "-∞" : String(format: "%.0f", db)
    }

    // MARK: - Veils: the tools' own opacities

    /// The tools' veils. They are the numbers the rich layers carried, hoisted so that the Canvas
    /// drawing reads the very same ones.
    static let cornerRadius: Double = 4
    static let volumeFullVeilOpacity: Double = 0.80
    static let volumeMinimalVeilOpacity: Double = 0.65
    static let volumeMuteTintOpacity: Double = 0.22
    static let volumeMinimalMuteTintOpacity: Double = 0.20
    static let panVeilOpacity: Double = 0.80
    static let stemVeilOpacity: Double = 0.72
}
