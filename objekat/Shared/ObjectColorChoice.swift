import Foundation

// MARK: - An object's own colour: the choice offered, the layout of its menu, the ink of its name
//
// Everything about an object's custom colour that needs no view and no model, in ONE place so a
// test can compile it alone (`tools/test_object_color_choice.swift`):
//
//   • the BASE row the context menu opens on (seven strong colours, then a "+"),
//   • how that row is laid out once the hand has ADDED colours of its own (the "+" always comes
//     LAST, and wraps to the next row when the row is full),
//   • the grid of hues the "+" opens (8 hues × 5 lightnesses), from which one click picks AND adds,
//   • the #RRGGBB text form of a colour (the session file's, the API's),
//   • and the two readings of a colour the drawing needs — its luminance, and so whether the NAME
//     written over it must be white or black once the band's opacity has been laid over white.
//
// An object's colour is stored as `SoundObject.colorHex` (0xRRGGBB). The 16 pastels of
// `ObjekatPalette.objects` (`SoundObject.colorIndex`) are what a project written before the
// colours became free still carries: they are READ, never offered any more, never migrated.

/// A colour an object can carry, in either of its two storages. `nil` (where an optional appears)
/// means "no colour of its own" — the stem's.
nonisolated enum ObjectColorValue: Equatable, Sendable {
    /// An index into the 16 pastels (the old storage, still written by `color_index` in the API).
    case index(Int)
    /// A free colour, 0xRRGGBB.
    case hex(Int)
}

nonisolated enum ObjectColorChoice {

    // MARK: The base row

    /// The seven colours the menu always offers, in this order: black, grey, white, red, orange,
    /// a fluorescent green (the kind a clip launcher uses) and a cyan blue.
    static let baseHex: [Int] = [0x000000, 0x808080, 0xFFFFFF, 0xFF2D2D, 0xFF8A00, 0x00FF5A, 0x00C8FF]

    /// The menu's width, in swatches: seven colours and the "+" fit one row exactly.
    static let columns = 8

    // MARK: How an object's band is drawn

    /// The opacity of an object's own colour over its name band. The old pastels were drawn at
    /// 0.30; the stronger colours need to read for what they are, so the band is drawn at 60 %
    /// (a user decision, 11 October 2026). Shared by the four drawings of a block — the rich clip
    /// and group views, the clips' Canvas and the groups' Canvas — and by the sound list's strip.
    static let bandOpacity: Double = 0.60

    /// The same, for a SELECTED object. It used to be 0.55 (against 0.30 unselected, nearly twice
    /// as strong); with the unselected band at 0.60 the old figure would be BELOW it, so selecting
    /// would have paled the band. 0.85 keeps the step visible — and the border (0.3 → 0.9) says
    /// the rest. The stem's body keeps its own 0.30 / 0.55.
    static let bandOpacitySelected: Double = 0.85

    static func bandOpacity(selected: Bool) -> Double { selected ? bandOpacitySelected : bandOpacity }

    // MARK: #RRGGBB

    /// "#RRGGBB" → 0xRRGGBB. The "#" is optional, case does not matter, and anything that is not
    /// exactly six hexadecimal digits is refused (no shorthand, no alpha: a colour here is opaque).
    static func parse(_ text: String) -> Int? {
        var s = text.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, s.allSatisfy(\.isHexDigit), let v = Int(s, radix: 16) else { return nil }
        return v
    }

    /// 0xRRGGBB → "#RRGGBB", in capitals. Only the low 24 bits are read.
    static func format(_ rgb: Int) -> String {
        let v = rgb & 0xFFFFFF
        let s = String(v, radix: 16, uppercase: true)
        return "#" + String(repeating: "0", count: 6 - s.count) + s
    }

    // MARK: Reading a colour

    /// The channels, 0…255.
    static func channels(_ rgb: Int) -> (r: Int, g: Int, b: Int) {
        ((rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF, rgb & 0xFF)
    }

    /// WCAG relative luminance, 0 (black) … 1 (white).
    static func luminance(_ rgb: Int) -> Double {
        func lin(_ c: Int) -> Double {
            let s = Double(c) / 255
            return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        }
        let c = channels(rgb)
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
    }

    /// What `rgb` looks like drawn at `alpha` over `background` (white by default: every name
    /// band sits on a white base).
    static func composite(_ rgb: Int, alpha: Double, over background: Int = 0xFFFFFF) -> Int {
        let a = min(1, max(0, alpha))
        let f = channels(rgb), b = channels(background)
        func mix(_ x: Int, _ y: Int) -> Int { Int((a * Double(x) + (1 - a) * Double(y)).rounded()) }
        return (mix(f.r, b.r) << 16) | (mix(f.g, b.g) << 8) | mix(f.b, b.b)
    }

    /// True if a name written over the band `rgb` drawn at `alpha` must be WHITE: the colour is
    /// judged as it LOOKS, composed over white — black at 60 % is a dark grey, not black, and the
    /// black text it used to take has to turn white. The threshold is the one at which white and
    /// black text have the same contrast ratio (L = 0.179).
    static func prefersLightInk(_ rgb: Int, alpha: Double) -> Bool {
        luminance(composite(rgb, alpha: alpha)) < 0.179
    }

    // MARK: The grid of hues

    /// Eight hues, five lightnesses, row by row: the "+" menu's choice. A hue is a row of the
    /// grid's columns; the lightness goes from deep (top) to pale (bottom).
    static let hueColumns = 8
    static let lightnessRows = 5
    static let hues: [Double] = [0, 28, 54, 130, 175, 205, 255, 310]
    static let lightnesses: [Double] = [0.30, 0.42, 0.54, 0.68, 0.82]
    static let hueSaturation: Double = 0.95

    /// The 40 colours of the grid, row-major: `hueGrid[row * hueColumns + column]`.
    static let hueGrid: [Int] = {
        var out: [Int] = []
        for l in lightnesses {
            for h in hues { out.append(fromHSL(hue: h, saturation: hueSaturation, lightness: l)) }
        }
        return out
    }()

    /// HSL → 0xRRGGBB (hue in degrees).
    static func fromHSL(hue: Double, saturation s: Double, lightness l: Double) -> Int {
        let c = (1 - abs(2 * l - 1)) * s
        let hp = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
        let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
        let (r1, g1, b1): (Double, Double, Double)
        switch hp {
        case ..<1: (r1, g1, b1) = (c, x, 0)
        case ..<2: (r1, g1, b1) = (x, c, 0)
        case ..<3: (r1, g1, b1) = (0, c, x)
        case ..<4: (r1, g1, b1) = (0, x, c)
        case ..<5: (r1, g1, b1) = (x, 0, c)
        default:   (r1, g1, b1) = (c, 0, x)
        }
        let m = l - c / 2
        func byte(_ v: Double) -> Int { Int(((v + m) * 255).rounded()) }
        return (byte(r1) << 16) | (byte(g1) << 8) | byte(b1)
    }

    // MARK: The layout of the menu's row

    /// One cell of the menu: a colour, or the "+".
    struct Cell: Equatable {
        enum Kind: Equatable { case color(Int), plus }
        let kind: Kind
        let column: Int
        let row: Int
    }

    struct SwatchLayout: Equatable {
        /// The colours first (base, then the hand's), the "+" LAST.
        let cells: [Cell]
        let columns: Int
        let rowCount: Int

        var plusCell: Cell { cells[cells.count - 1] }
        /// The colours, in cell order (without the "+").
        var colors: [Int] {
            cells.compactMap { if case .color(let v) = $0.kind { return v } else { return nil } }
        }
        func cell(column: Int, row: Int) -> Cell? {
            cells.first { $0.column == column && $0.row == row }
        }
    }

    /// The base colours, then the ones the hand added, then the "+": `columns` to a row, the "+"
    /// moving on to the next row when the row is full. A colour the hand added that is already in
    /// the base (or already added) is shown once.
    static func swatchLayout(base: [Int], custom: [Int], columns: Int = ObjectColorChoice.columns) -> SwatchLayout {
        let cols = max(1, columns)
        var colors: [Int] = []
        for v in base + custom where !colors.contains(v) { colors.append(v) }
        var cells: [Cell] = colors.enumerated().map {
            Cell(kind: .color($0.element), column: $0.offset % cols, row: $0.offset / cols)
        }
        let n = colors.count
        cells.append(Cell(kind: .plus, column: n % cols, row: n / cols))
        return SwatchLayout(cells: cells, columns: cols, rowCount: (n + 1 + cols - 1) / cols)
    }

    // MARK: The geometry of a swatch grid (the menu's view and its hit-test)

    struct Geometry: Equatable {
        var swatch: Double = 18
        var spacing: Double = 6
        var padding: Double = 8

        func size(columns: Int, rows: Int) -> (width: Double, height: Double) {
            (padding * 2 + Double(columns) * swatch + Double(max(0, columns - 1)) * spacing,
             padding * 2 + Double(rows) * swatch + Double(max(0, rows - 1)) * spacing)
        }
        /// The swatch's square, top-left origin.
        func origin(column: Int, row: Int) -> (x: Double, y: Double) {
            (padding + Double(column) * (swatch + spacing), padding + Double(row) * (swatch + spacing))
        }
        /// The cell under a point (top-left origin), within `slop` points of its swatch — nil in the gaps
        /// and past the grid.
        func hit(_ layout: SwatchLayout, x: Double, y: Double, slop: Double = 2) -> Cell? {
            for cell in layout.cells {
                let o = origin(column: cell.column, row: cell.row)
                if x >= o.x - slop, x <= o.x + swatch + slop, y >= o.y - slop, y <= o.y + swatch + slop {
                    return cell
                }
            }
            return nil
        }
    }

    // MARK: The hand's added colours (the list, without its storage)

    /// `list` with `rgb` appended, unless it is already there or is one of the base colours.
    /// Returns nil if nothing would change.
    static func adding(_ rgb: Int, to list: [Int]) -> [Int]? {
        let v = rgb & 0xFFFFFF
        guard !baseHex.contains(v), !list.contains(v) else { return nil }
        return list + [v]
    }
}
