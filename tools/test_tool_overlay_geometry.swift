// The Volume / Pan / Send tools' overlay geometry — the zones, the knob sizes, the narrow-block
// rule and the labels, asserted with no screen.
//
// `ToolOverlayGeometry` depends on nothing but `SendColumns` (which depends on nothing at all):
// the rich layers, the gestures' hit-testing and the Canvas drawing all read it, and a zone one can
// SEE and cannot PRESS is what happens the day two readings drift. The numbers asserted here are
// the ones the layers and the handlers each carried a copy of before it existed (0.4 / 0.6 / 50 /
// 34 / 48 …), so a failure means a behaviour changed, not just a test.
//
//     swiftc -parse-as-library \
//         ../objekat/Timeline/SendColumns.swift ../objekat/Timeline/ToolOverlayGeometry.swift \
//         test_tool_overlay_geometry.swift -o /tmp/tooloverlay && /tmp/tooloverlay
//
// Exit: 0 if every assertion passes, 1 otherwise.

import Foundation

var fails: [String] = []
var total = 0

func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    total += 1
    if ok { print("ok    " + label) }
    else { fails.append(label); print("FAIL  \(label)  \(detail)") }
}

typealias G = ToolOverlayGeometry

@main
enum ToolOverlayGeometryTest {
  static func main() {

    // MARK: - Narrow blocks

    check("49.99 px is narrow", G.isNarrow(blockWidth: 49.99))
    check("50 px is not narrow (the rule is strictly under 50)", !G.isNarrow(blockWidth: 50))
    check("2 px (the minimum block) is narrow", G.isNarrow(blockWidth: 2))

    // MARK: - Volume zones: 0…0.4 mute, 0.4…0.6 step, 0.6…1 drag

    // A 100 px span makes every boundary a whole number.
    check("0 px → mute", G.volumeZone(localX: 0, spanWidth: 100) == .mute)
    check("39.999 px → mute", G.volumeZone(localX: 39.999, spanWidth: 100) == .mute)
    check("40 px → step (the boundary belongs to the next zone)",
          G.volumeZone(localX: 40, spanWidth: 100) == .step)
    check("59.999 px → step", G.volumeZone(localX: 59.999, spanWidth: 100) == .step)
    check("60 px → drag, EXACTLY (not 60.000000000000007)",
          G.volumeZone(localX: 60, spanWidth: 100) == .drag,
          "0.4 + 0.2 is 0.6000000000000001 — the edge is spelled out for that reason")
    check("100 px → drag", G.volumeZone(localX: 100, spanWidth: 100) == .drag)

    // The same boundaries on a width where the products are not whole.
    for w in [37.0, 133.3, 900.0, 4321.5] {
        let zero = G.volumeZone(localX: w * 0.4, spanWidth: w)
        let six  = G.volumeZone(localX: w * 0.6, spanWidth: w)
        check("width \(w): the 0.4 edge is the step's first pixel", zero == .step)
        check("width \(w): the 0.6 edge is the drag's first pixel", six == .drag)
    }

    // The drag gesture's guard used to read `localX >= span.width * 0.6`; the zone must agree
    // with it on every pixel, including the ones just either side.
    var agree = true
    for w in [50.0, 99.0, 250.0, 1234.5] {
        var x = 0.0
        while x <= w {
            let legacyDrag = x >= w * 0.6
            if (G.volumeZone(localX: x, spanWidth: w) == .drag) != legacyDrag { agree = false }
            let legacyMute = x < w * 0.4
            if (G.volumeZone(localX: x, spanWidth: w) == .mute) != legacyMute { agree = false }
            x += 0.25
        }
    }
    check("the zone agrees with the legacy inline tests at quarter-pixel steps", agree)

    // The ± zone: top half raises, bottom half lowers.
    check("± zone, top of the block → +1", G.volumeStepDirection(localY: 0, blockHeight: 80) == 1)
    check("± zone, just above the middle → +1", G.volumeStepDirection(localY: 39.9, blockHeight: 80) == 1)
    check("± zone, the middle itself → −1", G.volumeStepDirection(localY: 40, blockHeight: 80) == -1)
    check("± zone, bottom → −1", G.volumeStepDirection(localY: 80, blockHeight: 80) == -1)

    // The rich layer's columns.
    check("mute column is 40 % of the span", G.volumeMuteColumnWidth(spanWidth: 200) == 80)
    check("± column is 20 % less the two divider px", G.volumeStepColumnWidth(spanWidth: 200) == 38)
    check("drag column is 40 % less the two divider px", G.volumeDragColumnWidth(spanWidth: 200) == 78)
    check("the three columns plus two 1 px dividers fill the span less 2",
          G.volumeMuteColumnWidth(spanWidth: 200) + G.volumeStepColumnWidth(spanWidth: 200)
          + G.volumeDragColumnWidth(spanWidth: 200) + 2 * G.volumeDividerWidth == 198)

    // MARK: - Volume plan: who shows what

    func vp(_ w: Double, sel: Bool, hov: Bool) -> G.VolumePlan {
        G.volumePlan(blockWidth: w, isSelected: sel, isToolHovered: hov)
    }
    check("wide, idle: nothing", vp(200, sel: false, hov: false) == .init(showMinimal: false, showFull: false, needsExactSpan: false))
    check("wide, selected: the minimal veil, exact scroll",
          vp(200, sel: true, hov: false) == .init(showMinimal: true, showFull: false, needsExactSpan: true))
    check("wide, hovered: the full veil, exact scroll",
          vp(200, sel: false, hov: true) == .init(showMinimal: false, showFull: true, needsExactSpan: true))
    check("wide, selected AND hovered: both (the full one is drawn over the minimal)",
          vp(200, sel: true, hov: true) == .init(showMinimal: true, showFull: true, needsExactSpan: true))
    check("narrow, idle: the minimal veil anyway, no exact scroll",
          vp(30, sel: false, hov: false) == .init(showMinimal: true, showFull: false, needsExactSpan: false))
    check("narrow, hovered: STILL no full veil, no exact scroll",
          vp(30, sel: false, hov: true) == .init(showMinimal: true, showFull: false, needsExactSpan: false))
    check("narrow, selected: the minimal veil, no exact scroll",
          vp(30, sel: true, hov: true) == .init(showMinimal: true, showFull: false, needsExactSpan: false))
    check("exactly 50 px counts as wide",
          vp(50, sel: true, hov: false) == .init(showMinimal: true, showFull: false, needsExactSpan: true))

    // MARK: - Pan plan and knob

    func pp(_ w: Double, sel: Bool, hov: Bool) -> G.PanPlan {
        G.panPlan(blockWidth: w, isSelected: sel, isToolHovered: hov)
    }
    check("pan, wide, idle: nothing", pp(200, sel: false, hov: false) == .init(shown: false, needsExactSpan: false))
    check("pan, wide, selected: shown, exact scroll", pp(200, sel: true, hov: false) == .init(shown: true, needsExactSpan: true))
    check("pan, wide, hovered: shown, exact scroll", pp(200, sel: false, hov: true) == .init(shown: true, needsExactSpan: true))
    check("pan, narrow, idle: ALWAYS shown, no exact scroll", pp(20, sel: false, hov: false) == .init(shown: true, needsExactSpan: false))

    check("knob: a roomy block caps at 34", G.panKnobSize(visibleWidth: 400, height: 200) == 34)
    check("knob: the floor is 14", G.panKnobSize(visibleWidth: 10, height: 200) == 14)
    check("knob: the width less 8 bounds it", G.panKnobSize(visibleWidth: 30, height: 200) == 22)
    check("knob: the height less 18 (room for the label) bounds it", G.panKnobSize(visibleWidth: 400, height: 40) == 22)
    check("knob: a short block still has its floor", G.panKnobSize(visibleWidth: 400, height: 20) == 14)

    check("pan drag track: the span less the 20 px margin", G.panDragTrackWidth(spanWidth: 220) == 200)
    check("pan drag track: never under 1", G.panDragTrackWidth(spanWidth: 5) == 1)

    // MARK: - Send

    // The layout is `sendColumnsLayout` + `sendColWidth`, composed: no crossfade, whole block visible.
    let l0 = G.sendLayout(blockWidth: 300, leadingInset: 0, count: 3)
    check("send layout: origin 0, width 300, column 60 (the ceiling)",
          l0.origin == 0 && l0.width == 300 && l0.columnWidth == 60)
    let l1 = G.sendLayout(blockWidth: 90, leadingInset: 0, count: 3)
    check("send layout: a narrow block splits its width", l1.columnWidth == 30)
    let l2 = G.sendLayout(blockWidth: 300, leadingInset: 40, count: 2)
    check("send layout: a crossfade inset pushes the origin and eats the width",
          l2.origin == 40 && l2.width == 260 && l2.columnWidth == 60)
    let l3 = G.sendLayout(blockWidth: 1000, leadingInset: 0, count: 4, visibleX: 700, visibleWidth: 200)
    check("send layout: the columns share the VISIBLE portion",
          l3.origin == 700 && l3.width == 200 && l3.columnWidth == 50)
    // And it agrees with the hit-test's own function, since both read the same one.
    let hit = sendColumnIndex(localX: 701, blockWidth: 1000, leadingInset: 0, count: 4,
                              visibleX: 700, visibleWidth: 200)
    check("send layout: the hit-test lands in the first visible column", hit == 0)
    check("send layout: …and the last visible column ends at origin + count × column width",
          sendColumnIndex(localX: 899, blockWidth: 1000, leadingInset: 0, count: 4,
                          visibleX: 700, visibleWidth: 200) == 3
          && sendColumnIndex(localX: 901, blockWidth: 1000, leadingInset: 0, count: 4,
                             visibleX: 700, visibleWidth: 200) == nil)

    // Text: a column wide AND tall enough.
    check("send text: 34 px wide, 48 px tall is the minimum",
          G.sendShowsText(columnWidth: 34, blockHeight: 48))
    check("send text: 33.9 px wide hides it", !G.sendShowsText(columnWidth: 33.9, blockHeight: 48))
    check("send text: 47.9 px tall hides it", !G.sendShowsText(columnWidth: 60, blockHeight: 47.9))

    // Knob diameter: within 11…26, the toggle zone (22) and the text lines (32 / 6) taken off.
    check("send knob: a big column caps at 26",
          G.sendKnobDiameter(columnWidth: 60, blockHeight: 200, showText: true) == 26)
    check("send knob: the column less 12 bounds it",
          G.sendKnobDiameter(columnWidth: 34, blockHeight: 200, showText: true) == 22)
    check("send knob: the height less toggle zone less text bounds it (with text)",
          G.sendKnobDiameter(columnWidth: 60, blockHeight: 70, showText: true) == 16)   // 70 − 22 − 32
    check("send knob: …and less 6 without text",
          G.sendKnobDiameter(columnWidth: 20, blockHeight: 70, showText: false) == 11)  // min(8, 42, 26) → floor 11
    check("send knob: the floor is 11", G.sendKnobDiameter(columnWidth: 10, blockHeight: 20, showText: false) == 11)

    // The on/off button: the bottom 22 px of a column plus 4 px of slack.
    check("send toggle: 26 px up from the bottom is in", G.sendToggleHit(localY: 54, blockHeight: 80))
    check("send toggle: 26.1 px up from the bottom is out", !G.sendToggleHit(localY: 53.9, blockHeight: 80))
    check("send toggle: the very bottom is in", G.sendToggleHit(localY: 80, blockHeight: 80))

    // The knob's travel.
    check("send fraction: the floor is 0", G.sendKnobFraction(level: -60, minDb: -60, maxDb: 12) == 0)
    check("send fraction: the ceiling is 1", G.sendKnobFraction(level: 12, minDb: -60, maxDb: 12) == 1)
    check("send fraction: the middle is a half", G.sendKnobFraction(level: -24, minDb: -60, maxDb: 12) == 0.5)
    check("send fraction: clamped below", G.sendKnobFraction(level: -100, minDb: -60, maxDb: 12) == 0)
    check("send fraction: clamped above", G.sendKnobFraction(level: 40, minDb: -60, maxDb: 12) == 1)
    check("send fraction: an empty range is 0, not a division by zero",
          G.sendKnobFraction(level: 0, minDb: 5, maxDb: 5) == 0)

    // MARK: - Labels

    check("volume label, full: the floor", G.volumeLabel(db: -96, compact: false) == "-∞ dB")
    check("volume label, compact: the floor drops the unit", G.volumeLabel(db: -96, compact: true) == "-∞")
    check("volume label: below the floor is still the floor", G.volumeLabel(db: -120, compact: false) == "-∞ dB")
    check("volume label: 0 dB", G.volumeLabel(db: 0, compact: false) == "0 dB")
    check("volume label, compact keeps the unit above the floor", G.volumeLabel(db: -3, compact: true) == "-3 dB")
    check("volume label: +40", G.volumeLabel(db: 40, compact: false) == "40 dB")
    check("volume label: a half dB rounds like %.0f does", G.volumeLabel(db: 2.4, compact: false) == "2 dB")
    check("volume label: -95.9 is not the floor", G.volumeLabel(db: -95.9, compact: false) == "-96 dB")

    check("pan label: centre", G.panLabel(pan: 0) == "C")
    check("pan label: under 1 % is still centre", G.panLabel(pan: 0.009) == "C" && G.panLabel(pan: -0.009) == "C")
    check("pan label: 1 % is not", G.panLabel(pan: 0.01) == "R 1%")
    check("pan label: full left", G.panLabel(pan: -1) == "L 100%")
    check("pan label: full right", G.panLabel(pan: 1) == "R 100%")
    check("pan label: the percentage is TRUNCATED, not rounded (0.699 → 69)",
          G.panLabel(pan: 0.699) == "R 69%" && G.panLabel(pan: -0.699) == "L 69%")
    check("pan label: left half", G.panLabel(pan: -0.5) == "L 50%")

    // The set of distinct pan labels is the cache's bound (≈201): C, L 1…100, R 1…100.
    var panLabels = Set<String>()
    for i in -100...100 { panLabels.insert(G.panLabel(pan: Float(i) / 100)) }
    check("pan labels over every whole percent: at most 201 distinct", panLabels.count <= 201,
          "got \(panLabels.count)")

    var dbLabels = Set<String>()
    for i in -96...40 {
        dbLabels.insert(G.volumeLabel(db: Float(i), compact: false))
        dbLabels.insert(G.volumeLabel(db: Float(i), compact: true))
    }
    check("volume labels over every whole dB, both forms: bounded (≈140 + the compact floor)",
          dbLabels.count <= 140, "got \(dbLabels.count)")

    check("send label: the floor", G.sendLevelLabel(db: -60, minDb: -60) == "-∞")
    check("send label: above the floor", G.sendLevelLabel(db: -59, minDb: -60) == "-59")
    check("send label: 0", G.sendLevelLabel(db: 0, minDb: -60) == "0")

    // MARK: - The veils' numbers

    check("veil opacities are the ones the layers carried",
          G.volumeFullVeilOpacity == 0.80 && G.volumeMinimalVeilOpacity == 0.65
          && G.volumeMuteTintOpacity == 0.22 && G.volumeMinimalMuteTintOpacity == 0.20
          && G.panVeilOpacity == 0.80 && G.stemVeilOpacity == 0.72 && G.cornerRadius == 4)

    print("")
    if fails.isEmpty {
        print("ALL PASS — \(total) assertions")
        exit(0)
    } else {
        print("\(fails.count) FAILED of \(total):")
        for f in fails { print("  - " + f) }
        exit(1)
    }
  }
}
