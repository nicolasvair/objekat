import SwiftUI

// MARK: - Separate palettes for stems / objects / plugins
//
// The Tailwind v4 chromatic envelope (17 families published in OKLCh), resampled at
// positions equidistant in CAM16-UCS perceptual arc length.
//
//   stems   (10)  step 600  strong   L 0.53–0.67
//   objects (16)  step 300  pastel   L 0.78–0.90
//   plugins (16)  step 900  dark     L 0.37–0.42
//
// min ΔE  between: stem↔object 20.57 · object↔plugin 46.75 · stem↔plugin 19.19
//         within : stem 20.46 · object 10.06 · plugin 9.48

private extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red:   Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >>  8) & 0xFF) / 255,
                  blue:  Double( hex        & 0xFF) / 255,
                  opacity: 1)
    }
}

/// Separate palettes shared by the whole app: `stems` (bus identity, a strong tint),
/// `objects` (an object's custom colour, pastel) and `plugins` (the identity of a plugin
/// instance, dark). Three separate regimes rather than one generic palette: a recoloured
/// object and the stem carrying it must never be visually confused.
enum ObjekatPalette {

    // A chosen order (not the natural order of the colour wheel): Main = blue, then purple/
    // pink/yellow/green imposed, then the rest spread out so that no pair of neighbouring hues
    // on the colour wheel follow one another — stems take their colour automatically in this
    // order as they are created, so two stems created one after the other must never look alike.
    //
    // Drawn in Display P3 (@see `displayP3`): the sRGB values below are what the palette was
    // clipped to, and stay its identity (names, docs, tests).
    static let stemsHex: [Int] = [
        0x0070EC,   // 0 blue    (Main)
        0x6C2DFC,   // 1 purple
        0xE50080,   // 2 pink
        0xB09300,   // 3 yellow
        0x50A600,   // 4 green
        0x0093B5,   // 5 cyan
        0xEB0E00,   // 6 red
        0x009873,   // 7 emerald
        0xC200E3,   // 8 magenta
        0xE27000    // 9 amber
    ]

    static let stems: [Color] = stemsHex.map { color(rgb: $0) }

    // MARK: Display P3
    //
    // Nearly every stem and base colour sits ON the edge of sRGB (the Tailwind v4 envelope they come
    // from is defined in OKLCh, wider than sRGB, and the hex values are its sRGB clip). On a P3
    // screen they are drawn wider: same OKLCh lightness and hue, the chroma pushed so the colour
    // stands at the same relative distance from the P3 edge as it did from the sRGB edge. Same
    // lightness, so the ink chosen from the sRGB channels (`ObjectColorChoice`) stays right; on an
    // sRGB screen the system clips them back to about the old values.
    //
    // Keyed by the sRGB 0xRRGGBB, which stays the stored identity (`SoundObject.colorHex`, the
    // menu's palette): only the DRAWING changes. A free colour that is not in this table is drawn
    // exactly as typed, in sRGB. Plugins (the native editor window, tinted on the JUCE side from
    // `pluginsHex`) and the legacy pastels are left in sRGB.
    static let displayP3: [Int: (Double, Double, Double)] = [
        // stems
        0x0070EC: (0.027, 0.400, 1.000),
        0x6C2DFC: (0.395, 0.133, 0.988),
        0xE50080: (0.857, 0.000, 0.495),
        0xB09300: (0.686, 0.577, 0.000),
        0x50A600: (0.369, 0.655, 0.000),
        0x0093B5: (0.000, 0.578, 0.752),
        0xEB0E00: (0.881, 0.074, 0.000),
        0x009873: (0.000, 0.612, 0.442),
        0xC200E3: (0.711, 0.000, 0.886),
        0xE27000: (0.860, 0.439, 0.000),
        // the object base colours (`ObjectColorChoice.baseHex`; black, grey and white need nothing)
        0xFF2D2D: (0.991, 0.000, 0.091),
        0xFF8A00: (0.973, 0.541, 0.000),
        0x00FF5A: (0.387, 1.000, 0.380),
        0x00C8FF: (0.305, 0.776, 1.000)
    ]

    /// The 16 pastels in 0xRRGGBB — what a project written before the free colours still points
    /// at (`SoundObject.colorIndex`). They are no longer OFFERED for an object (the menu now opens
    /// on `ObjectColorChoice.baseHex`), but they are still READ, and the band's ink is chosen
    /// from their channels, hence the numbers beside the `Color`s.
    static let objectsHex: [Int] = [
        0xFFA1AA, 0xFFAA86, 0xFFB966, 0xFFCC3E, 0xF5E322, 0xC9F045, 0x9AF57F, 0x72EFAC,
        0x49ECD0, 0x4CEBF6, 0x6DD8FF, 0x8DC6FF, 0xA2B4FF, 0xCBB3FF, 0xF0A9FF, 0xFDA5D8
    ]

    static let objects: [Color] = objectsHex.map { Color(hex: UInt32($0)) }

    static let plugins: [Color] = [
        Color(hex: 0x890C2E),
        Color(hex: 0x802112),
        Color(hex: 0x793606),
        Color(hex: 0x6B4200),
        Color(hex: 0x574B00),
        Color(hex: 0x3E5202),
        Color(hex: 0x175427),
        Color(hex: 0x004F3F),
        Color(hex: 0x024F57),
        Color(hex: 0x044C6C),
        Color(hex: 0x054282),
        Color(hex: 0x2B3189),
        Color(hex: 0x481C97),
        Color(hex: 0x611586),
        Color(hex: 0x771170),
        Color(hex: 0x830E50)
    ]

    /// The same values as `plugins`, in 0xRRGGBB — needed to tint the native editor window
    /// (JUCE/AppKit, on the OBJEngineCore side) which cannot consume a SwiftUI `Color`.
    static let pluginsHex: [Int] = [
        0x890C2E, 0x802112, 0x793606, 0x6B4200, 0x574B00, 0x3E5202, 0x175427, 0x004F3F,
        0x024F57, 0x044C6C, 0x054282, 0x2B3189, 0x481C97, 0x611586, 0x771170, 0x830E50
    ]

    /// The plugin hues a notch lighter, for the plugin browser's CATEGORIES (a dot on a row, a tab,
    /// a swatch of the menu): the card colours are made to sit under white text, and are too dark
    /// to be told apart as 7 pt dots. Same indices as `plugins`.
    static let pluginCategoriesHex: [Int] = pluginsHex.map { rgb in
        func lift(_ c: Int) -> Int { c + Int((Double(255 - c) * 0.30).rounded()) }
        return (lift((rgb >> 16) & 0xFF) << 16) | (lift((rgb >> 8) & 0xFF) << 8) | lift(rgb & 0xFF)
    }
    static func pluginCategoryHex(_ i: Int) -> Int {
        pluginCategoriesHex[((i % pluginCategoriesHex.count) + pluginCategoriesHex.count) % pluginCategoriesHex.count]
    }
    static func pluginCategory(_ i: Int) -> Color { color(rgb: pluginCategoryHex(i)) }

    static let stemNames: [String] = ["blue", "purple", "pink", "yellow", "green", "cyan", "red", "emerald", "magenta", "amber"]

    static func stem(_ i: Int) -> Color   { stems[((i % stems.count) + stems.count) % stems.count] }
    static func object(_ i: Int) -> Color { objects[((i % objects.count) + objects.count) % objects.count] }
    static func objectHex(_ i: Int) -> Int { objectsHex[((i % objectsHex.count) + objectsHex.count) % objectsHex.count] }
    /// An opaque colour from 0xRRGGBB (an object's free colour, `SoundObject.colorHex`): its Display P3
    /// version when it is a palette colour (@see `displayP3`), otherwise the sRGB value as typed.
    static func color(rgb: Int) -> Color {
        let v = rgb & 0xFFFFFF
        if let p = displayP3[v] { return Color(.displayP3, red: p.0, green: p.1, blue: p.2, opacity: 1) }
        return Color(hex: UInt32(truncatingIfNeeded: v))
    }
    static func plugin(_ i: Int) -> Color { plugins[((i % plugins.count) + plugins.count) % plugins.count] }
    static func pluginHex(_ i: Int) -> Int { pluginsHex[((i % pluginsHex.count) + pluginsHex.count) % pluginsHex.count] }
    static func stemName(_ i: Int) -> String { stemNames[((i % stemNames.count) + stemNames.count) % stemNames.count] }
}
