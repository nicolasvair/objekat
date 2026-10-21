// An object's own colour — the choice, the layout of its menu, the ink of its name — asserted with
// no screen.
//
// `ObjectColorChoice` (`Shared/ObjectColorChoice.swift`) is pure: the seven base colours, the
// layout of the row the context menu shows (the "+" always last, wrapping to the next row when the
// row is full), the hit-test on it, "#RRGGBB" parsing, luminance, and which ink a name needs over a
// band drawn at the shared opacity. The last block is the MODEL's half: the Codable of
// `SoundObject.colorHex` against an old session that only has `colorIndex` (so it pulls in
// `SoundObject.swift`'s dependency chain, the same list as `test_cross_project_import.swift`), and
// the editable palette (`UserObjectColors`, ephemeral under `--no-recent`).
//
//     swiftc -parse-as-library \
//         ../objekat/Shared/ObjectColorChoice.swift \
//         ../objekat/Shared/UserObjectColors.swift \
//         ../objekat/SoundObject/SoundObject.swift \
//         ../objekat/Inspector/Synoptic/SynopticGraph.swift \
//         ../objekat/Inspector/Synoptic/SynopticWidthFlow.swift \
//         ../objekat/SoundObject/ChannelPick.swift \
//         ../objekat/Shared/SendChain.swift \
//         ../objekat/SoundObject/Automation.swift \
//         ../objekat/SoundObject/AutomationCurveMath.swift \
//         ../objekat/SoundObject/AutomationCurveShape.swift \
//         ../objekat/SoundObject/Marker.swift \
//         ../objekat/SoundObject/ChannelMode.swift \
//         ../objekat/Shared/LaneEntryIndex.swift \
//         ../objekat/Timeline/ClipEditZonesOverlay.swift \
//         ../objekat/SoundObject/ConsolidateDefinition.swift \
//         ../objekat/SoundObject/FadeCurve.swift \
//         ../objekat/SoundObject/ComposedName.swift \
//         ../objekat/SoundObject/FXLink.swift \
//         ../objekat/SoundObject/SendPosition.swift \
//         ../objekat/SoundObject/SendMarkerAudit.swift \
//         ../objekat/Shared/ObjekatPalette.swift \
//         ../objekat/Shared/Localization.swift \
//         ../objekat/SoundObject/GainStage.swift \
//         ../objekat/SoundObject/LegacyGainMigration.swift \
//         ../objekat/EditViewModel/EditViewModel+Types.swift \
//         ../objekat/EditViewModel/SessionSchema.swift \
//         ../objekat/App/LaunchArguments.swift \
//         ../objekat/SoundObject/PluginIDUniqueness.swift \
//         ../objekat/Shared/BridgeScope.swift \
//         ../objekat/Shared/ScriptCanvasMemory.swift \
//         test_object_color_choice.swift \
//         -o /tmp/occ && /tmp/occ --no-recent
//
// Exit: 0 if every assertion passes, 1 otherwise.

import Foundation
import SwiftUI

var fails: [String] = []
var total = 0

func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    total += 1
    if ok { print("ok    " + label) }
    else { fails.append(label); print("FAIL  \(label)  \(detail)") }
}

typealias C = ObjectColorChoice

@main
enum ObjectColorChoiceTest {
  static func main() {

    // MARK: - The base row

    check("seven base colours", C.baseHex.count == 7)
    check("the base colours, in order",
          C.baseHex == [0x000000, 0x808080, 0xFFFFFF, 0xFF2D2D, 0xFF8A00, 0x00FF5A, 0x00C8FF])
    check("eight columns", C.columns == 8)

    let one = C.swatchLayout(base: C.baseHex, custom: [])
    check("7 + the plus fit ONE row of 8", one.rowCount == 1 && one.cells.count == 8, "\(one.rowCount) rows, \(one.cells.count) cells")
    check("the plus is the last cell", one.plusCell == one.cells.last)
    check("the plus sits at column 7 of row 0", one.plusCell.column == 7 && one.plusCell.row == 0)
    check("the seven colours come first, in order", one.colors == C.baseHex)
    check("the plus is a plus", one.plusCell.kind == .plus)

    let added1 = C.swatchLayout(base: C.baseHex, custom: [0x123456])
    check("1 added: the first row is FULL", added1.cells.filter { $0.row == 0 }.count == 8)
    check("1 added: the plus is ALONE on row 2", added1.plusCell.row == 1 && added1.plusCell.column == 0
          && added1.cells.filter { $0.row == 1 }.count == 1)
    check("1 added: two rows", added1.rowCount == 2)
    check("1 added: its colour is the 8th, at row 0 column 7",
          added1.cell(column: 7, row: 0)?.kind == .color(0x123456))

    let added8 = C.swatchLayout(base: C.baseHex, custom: (1...8).map { 0x100000 + $0 })
    check("8 added: the plus ends row 2 (column 7)", added8.plusCell.row == 1 && added8.plusCell.column == 7 && added8.rowCount == 2)

    let added9 = C.swatchLayout(base: C.baseHex, custom: (1...9).map { 0x100000 + $0 })
    check("9 added: three rows", added9.rowCount == 3, "\(added9.rowCount)")
    check("9 added: the plus alone on row 3", added9.plusCell.row == 2 && added9.plusCell.column == 0)
    check("9 added: 16 colours + the plus", added9.cells.count == 17 && added9.colors.count == 16)

    let dup = C.swatchLayout(base: C.baseHex, custom: [0xFFFFFF, 0x123456, 0x123456])
    check("an added colour already in the base, or added twice, is shown once",
          dup.colors == C.baseHex + [0x123456], "\(dup.colors)")
    let narrow = C.swatchLayout(base: C.baseHex, custom: [], columns: 4)
    check("another width: 4 columns hold 7 + plus on two rows", narrow.rowCount == 2 && narrow.plusCell.column == 3 && narrow.plusCell.row == 1)
    let zero = C.swatchLayout(base: C.baseHex, custom: [], columns: 0)
    check("a nonsense width does not crash (clamped to one column)", zero.columns == 1 && zero.rowCount == 8)

    // MARK: - Hit-test

    let geo = C.Geometry()
    let size = geo.size(columns: 8, rows: 1)
    check("grid size: 8 columns of 18 pt, 6 pt apart, 8 pt of padding", abs(size.width - (16 + 144 + 42)) < 1e-9 && abs(size.height - (16 + 18)) < 1e-9, "\(size)")
    let po = geo.origin(column: one.plusCell.column, row: one.plusCell.row)
    check("a click on the plus's centre hits the plus",
          geo.hit(one, x: po.x + 9, y: po.y + 9)?.kind == .plus)
    check("a click 2 pt outside the plus's swatch still hits it (the view's slop)",
          geo.hit(one, x: po.x + 18 + 2, y: po.y + 9)?.kind == .plus)
    check("a click 3 pt outside does not", geo.hit(one, x: po.x + 18 + 3, y: po.y + 9) == nil)
    let o0 = geo.origin(column: 0, row: 0)
    check("a click on the first swatch hits black", geo.hit(one, x: o0.x + 9, y: o0.y + 9)?.kind == .color(0x000000))
    check("a click in the gap between two swatches hits nothing",
          geo.hit(one, x: o0.x + 18 + 3, y: o0.y + 9) == nil)
    check("a click on the padding hits nothing", geo.hit(one, x: 2, y: 2) == nil)
    let po2 = geo.origin(column: added1.plusCell.column, row: added1.plusCell.row)
    check("a plus on the second row is hit there, not on the first",
          geo.hit(added1, x: po2.x + 9, y: po2.y + 9)?.kind == .plus && po2.y > o0.y)
    check("below the grid hits nothing", geo.hit(one, x: po.x + 9, y: size.height + 5) == nil)

    // MARK: - #RRGGBB

    check("parse #FF2D2D", C.parse("#FF2D2D") == 0xFF2D2D)
    check("parse without #", C.parse("00c8ff") == 0x00C8FF)
    check("parse lower case, spaces around", C.parse("  #00c8ff ") == 0x00C8FF)
    check("parse black", C.parse("#000000") == 0)
    check("parse refuses the shorthand #FFF", C.parse("#FFF") == nil)
    check("parse refuses 8 digits (alpha)", C.parse("#FF2D2DFF") == nil)
    check("parse refuses non-hex", C.parse("#GGGGGG") == nil)
    check("parse refuses empty", C.parse("") == nil && C.parse("#") == nil)
    check("parse refuses a sign", C.parse("+FF2D2D") == nil && C.parse("-FF2D2D") == nil)
    check("format pads and capitalises", C.format(0) == "#000000" && C.format(0x00C8FF) == "#00C8FF" && C.format(0xFF2D2D) == "#FF2D2D")
    check("format reads only the low 24 bits", C.format(0x1FF2D2D) == "#FF2D2D")
    check("format then parse is the identity on every base colour",
          C.baseHex.allSatisfy { C.parse(C.format($0)) == $0 })

    // MARK: - Luminance and ink

    check("luminance of black is 0, of white is 1",
          C.luminance(0x000000) == 0 && abs(C.luminance(0xFFFFFF) - 1) < 1e-9)
    check("luminance of #808080 is ~0.216", abs(C.luminance(0x808080) - 0.2159) < 0.001, "\(C.luminance(0x808080))")
    check("green is brighter than red, red brighter than blue",
          C.luminance(0x00FF00) > C.luminance(0xFF0000) && C.luminance(0xFF0000) > C.luminance(0x0000FF))
    check("composite: black at 60 % over white is #666666", C.composite(0x000000, alpha: 0.6) == 0x666666,
          C.format(C.composite(0x000000, alpha: 0.6)))
    check("composite: alpha 1 is the colour, alpha 0 is the background",
          C.composite(0xFF2D2D, alpha: 1) == 0xFF2D2D && C.composite(0xFF2D2D, alpha: 0) == 0xFFFFFF)
    check("composite clamps alpha", C.composite(0x000000, alpha: 3) == 0x000000 && C.composite(0x000000, alpha: -1) == 0xFFFFFF)
    check("bandOpacity is 0.60, selected 0.85, and selected is the stronger",
          C.bandOpacity == 0.60 && C.bandOpacitySelected == 0.85 && C.bandOpacity(selected: true) > C.bandOpacity(selected: false))

    func light(_ rgb: Int, selected: Bool = false) -> Bool {
        C.prefersLightInk(rgb, alpha: C.bandOpacity(selected: selected))
    }
    check("BLACK at 60 %: a dark grey, so the name turns WHITE", light(0x000000))
    check("black selected (85 %): white", light(0x000000, selected: true))
    check("grey #808080 at 60 %: black ink", !light(0x808080))
    check("white: black ink", !light(0xFFFFFF))
    check("red #FF2D2D: black ink", !light(0xFF2D2D) && !light(0xFF2D2D, selected: true))
    check("orange: black ink", !light(0xFF8A00))
    check("fluorescent green: black ink", !light(0x00FF5A))
    check("cyan: black ink", !light(0x00C8FF))
    check("a deep navy at 60 % reads dark: white ink", light(0x101060))
    check("the seven base colours: only black asks for white", C.baseHex.filter { light($0) } == [0x000000])

    // MARK: - The grid of hues

    check("the hue grid is 8 x 5", C.hueGrid.count == 40 && C.hueColumns == 8 && C.lightnessRows == 5)
    check("every hue colour fits 24 bits", C.hueGrid.allSatisfy { (0...0xFFFFFF).contains($0) })
    check("the hue grid has no duplicate", Set(C.hueGrid).count == 40, "\(Set(C.hueGrid).count) distinct")
    check("the first row is deeper than the last (lightness grows downwards)",
          C.luminance(C.hueGrid[0]) < C.luminance(C.hueGrid[32]) && C.luminance(C.hueGrid[3]) < C.luminance(C.hueGrid[35]))
    check("HSL: pure red at 50 % is #FF0000", C.fromHSL(hue: 0, saturation: 1, lightness: 0.5) == 0xFF0000)
    check("HSL: hue 120 is green, 240 is blue",
          C.fromHSL(hue: 120, saturation: 1, lightness: 0.5) == 0x00FF00 && C.fromHSL(hue: 240, saturation: 1, lightness: 0.5) == 0x0000FF)
    check("HSL: lightness 0 is black, 1 is white",
          C.fromHSL(hue: 77, saturation: 1, lightness: 0) == 0 && C.fromHSL(hue: 77, saturation: 1, lightness: 1) == 0xFFFFFF)
    check("a hue grid colour is never one of the base colours (a pick would always add something)",
          C.hueGrid.allSatisfy { !C.baseHex.contains($0) })

    // MARK: - The list of added colours

    check("adding a new colour appends it", C.adding(0x123456, to: [0xABCDEF]) == [0xABCDEF, 0x123456])
    check("adding a base colour changes nothing", C.adding(0xFF2D2D, to: []) == nil)
    check("adding a colour already added changes nothing", C.adding(0x123456, to: [0x123456]) == nil)
    check("adding masks to 24 bits", C.adding(0xAA123456, to: []) == [0x123456])

    // The binary must be launched with --no-recent (see the header), or these lines would write
    // into the real defaults: refuse to touch them otherwise.
    check("the store is ephemeral in this run (launch with --no-recent)", UserObjectColors.isEphemeral)
    guard UserObjectColors.isEphemeral else {
        print("\nFAILED: re-run as `/tmp/occ --no-recent`"); exit(1)
    }
    // MARK: - The editable palette (pure)

    check("the default palette is the base row", C.defaultPalette() == C.baseHex)
    check("the default palette appends the first version's added colours, each once",
          C.defaultPalette(custom: [0x123456, 0xFFFFFF, 0x123456]) == C.baseHex + [0x123456])
    check("appending a new colour puts it last", C.palette([0x111111], appending: 0x222222) == [0x111111, 0x222222])
    check("appending a colour already there changes nothing", C.palette([0x111111], appending: 0x111111) == nil)
    check("a base colour removed can be appended again",
          C.palette(C.baseHex.filter { $0 != 0xFF2D2D }, appending: 0xFF2D2D)?.last == 0xFF2D2D)
    check("removing a base colour works", C.palette(C.baseHex, removing: 0x000000) == Array(C.baseHex.dropFirst()))
    check("removing an absent colour changes nothing", C.palette([0x111111], removing: 0x222222) == nil)
    check("removing masks to 24 bits", C.palette([0x111111], removing: 0xFF111111) == [])
    let emptyRow = C.swatchLayout(base: [], custom: [])
    check("an empty palette still shows the \"+\" alone", emptyRow.cells.count == 1 && emptyRow.plusCell.kind == .plus && emptyRow.rowCount == 1)

    // MARK: - The store (ephemeral)

    UserObjectColors.reset()
    check("(ephemeral store) starts as the base row", UserObjectColors.load() == C.baseHex && UserObjectColors.isDefault)
    check("(ephemeral store) add returns true and appends in order",
          UserObjectColors.add(0x123456) && UserObjectColors.add(0x654321)
          && UserObjectColors.load() == C.baseHex + [0x123456, 0x654321] && !UserObjectColors.isDefault)
    check("(ephemeral store) a repeat is refused", !UserObjectColors.add(0x123456) && UserObjectColors.load().count == 9)
    check("(ephemeral store) a BASE colour can be removed",
          UserObjectColors.remove(0xFF2D2D) && !UserObjectColors.load().contains(0xFF2D2D))
    check("(ephemeral store) removing it again is refused", !UserObjectColors.remove(0xFF2D2D))
    check("(ephemeral store) it comes back at the end through \"+\"",
          UserObjectColors.add(0xFF2D2D) && UserObjectColors.load().last == 0xFF2D2D)
    for v in UserObjectColors.load() { UserObjectColors.remove(v) }
    check("(ephemeral store) every colour can go: an empty palette stays empty", UserObjectColors.load().isEmpty)
    UserObjectColors.resetToDefault()
    check("(ephemeral store) restoring the default gives the base row back",
          UserObjectColors.load() == C.baseHex && UserObjectColors.isDefault)
    // MARK: - SoundObject: Codable and colour resolution

    func clip(colorIndex: Int? = nil, colorHex: Int? = nil) -> SoundObject {
        SoundObject(startTime: 1, duration: 2, lane: 0, colorIndex: colorIndex, colorHex: colorHex,
                    kind: .clip(filePath: "a.wav", sourceOffset: 0, fileDuration: 2, speedRatio: 1, isReversed: false))
    }
    func roundTrip(_ o: SoundObject) -> (SoundObject, String)? {
        guard let data = try? JSONEncoder().encode(o),
              let back = try? JSONDecoder().decode(SoundObject.self, from: data) else { return nil }
        return (back, String(decoding: data, as: UTF8.self))
    }

    if let (back, json) = roundTrip(clip(colorHex: 0xFF2D2D)) {
        check("colorHex survives a round trip", back.colorHex == 0xFF2D2D)
        check("colorHex is written as \"#RRGGBB\"", json.contains("\"colorHex\":\"#FF2D2D\""), json)
        check("a colorHex-only object has no colorIndex key", !json.contains("colorIndex"))
    } else { check("colorHex round trip", false, "encode/decode failed") }

    if let (back, json) = roundTrip(clip(colorIndex: 3)) {
        check("colorIndex alone survives a round trip", back.colorIndex == 3 && back.colorHex == nil)
        check("an old object writes no colorHex key", !json.contains("colorHex"))
    } else { check("colorIndex round trip", false, "encode/decode failed") }

    if let (back, json) = roundTrip(clip()) {
        check("no colour at all: neither key, no colour", back.colorIndex == nil && back.colorHex == nil
              && !json.contains("colorIndex") && !json.contains("colorHex") && back.customColorRGB == nil && back.customColor == nil)
    } else { check("plain round trip", false, "encode/decode failed") }

    // An OLD session's JSON: written by a build that knew only `colorIndex`.
    if let (_, json) = roundTrip(clip(colorIndex: 9)) {
        let data = Data(json.utf8)
        let old = try? JSONDecoder().decode(SoundObject.self, from: data)
        check("an old JSON (colorIndex, no colorHex) decodes with the pastel", old?.colorIndex == 9 && old?.colorHex == nil)
        check("…and its customColorRGB is that pastel (F5E322 is index 4, C9F045 index 5, 6DD8FF index 10)",
              old?.customColorRGB == ObjekatPalette.objectHex(9), "\(String(describing: old?.customColorRGB))")
    }
    // A hand-edited file: both keys, and some malformed values.
    func decode(_ extra: String) -> SoundObject? {
        guard let (_, json) = roundTrip(clip()) else { return nil }
        let patched = json.replacingOccurrences(of: "{", with: "{" + extra + ",", options: [], range: json.range(of: "{"))
        return try? JSONDecoder().decode(SoundObject.self, from: Data(patched.utf8))
    }
    let both = decode("\"colorIndex\":3,\"colorHex\":\"#00C8FF\"")
    check("both keys present: colorHex wins", both?.customColorRGB == 0x00C8FF && both?.colorIndex == 3)
    check("a plain integer colorHex is tolerated", decode("\"colorHex\":65535")?.colorHex == 65535)
    check("an out-of-range integer colorHex is dropped, the load survives", decode("\"colorHex\":99999999") != nil && decode("\"colorHex\":99999999")?.colorHex == nil)
    check("a malformed colorHex is dropped, the load survives", decode("\"colorHex\":\"banana\"") != nil && decode("\"colorHex\":\"banana\"")?.colorHex == nil)

    // customColor / colorValue / ink
    check("customColorRGB prefers the free colour", clip(colorIndex: 2, colorHex: 0x123456).customColorRGB == 0x123456)
    check("colorValue: hex wins, then index, then nil",
          clip(colorIndex: 2, colorHex: 0x123456).colorValue == .hex(0x123456)
          && clip(colorIndex: 2).colorValue == .index(2) && clip().colorValue == nil)
    check("a black object wants light ink, unselected and selected",
          clip(colorHex: 0).bandWantsLightInk(selected: false) && clip(colorHex: 0).bandWantsLightInk(selected: true))
    check("a white object, a pastel and an object with no colour keep the black ink",
          !clip(colorHex: 0xFFFFFF).bandWantsLightInk(selected: false)
          && !clip(colorIndex: 0).bandWantsLightInk(selected: false)
          && !clip().bandWantsLightInk(selected: false))
    check("every old pastel keeps the black ink at 60 % and at 85 %",
          (0..<16).allSatisfy { !clip(colorIndex: $0).bandWantsLightInk(selected: false) && !clip(colorIndex: $0).bandWantsLightInk(selected: true) })
    check("derivedCopy keeps the free colour",
          clip(colorHex: 0xFF8A00).derivedCopy(startTime: 0, duration: 1, lane: 0, fadeIn: 0, fadeOut: 0,
                                               plugins: [], kind: clip().kind).colorHex == 0xFF8A00)
    // THE invariant of the editable palette: editing it never recolours an object. An object stores its
    // own 0xRRGGBB, or an index into the FIXED pastel table — neither reads the menu's list.
    let painted = clip(colorHex: 0x00C8FF), pastel = clip(colorIndex: 4)
    let before = (painted.customColorRGB, pastel.customColorRGB)
    UserObjectColors.resetToDefault()
    UserObjectColors.remove(0x00C8FF); UserObjectColors.add(0xABCDEF)
    for v in UserObjectColors.load() { UserObjectColors.remove(v) }
    check("emptying / reordering the palette changes no object's colour (free colour and old pastel)",
          painted.customColorRGB == before.0 && pastel.customColorRGB == before.1
          && before.0 == 0x00C8FF && before.1 == ObjekatPalette.objectHex(4))
    UserObjectColors.resetToDefault()
    check("the session format moved to 24 for it (25 since the gain stages)", SessionSchema.formatVersion >= 24)
    check("the notice describes colorHex", SessionSchema.note.contains { $0.hasPrefix("colorHex") })

    print("\n\(total - fails.count)/\(total) assertions passed")
    if !fails.isEmpty { print("FAILED: \(fails)"); exit(1) }
  }
}
