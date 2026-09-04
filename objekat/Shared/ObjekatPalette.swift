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
    static let stems: [Color] = [
        Color(hex: 0x0070EC),   // 0 blue    (Main)
        Color(hex: 0x6C2DFC),   // 1 purple
        Color(hex: 0xE50080),   // 2 pink
        Color(hex: 0xB09300),   // 3 yellow
        Color(hex: 0x50A600),   // 4 green
        Color(hex: 0x0093B5),   // 5 cyan
        Color(hex: 0xEB0E00),   // 6 red
        Color(hex: 0x009873),   // 7 emerald
        Color(hex: 0xC200E3),   // 8 magenta
        Color(hex: 0xE27000)    // 9 amber
    ]

    static let objects: [Color] = [
        Color(hex: 0xFFA1AA),
        Color(hex: 0xFFAA86),
        Color(hex: 0xFFB966),
        Color(hex: 0xFFCC3E),
        Color(hex: 0xF5E322),
        Color(hex: 0xC9F045),
        Color(hex: 0x9AF57F),
        Color(hex: 0x72EFAC),
        Color(hex: 0x49ECD0),
        Color(hex: 0x4CEBF6),
        Color(hex: 0x6DD8FF),
        Color(hex: 0x8DC6FF),
        Color(hex: 0xA2B4FF),
        Color(hex: 0xCBB3FF),
        Color(hex: 0xF0A9FF),
        Color(hex: 0xFDA5D8)
    ]

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

    static let stemNames: [String] = ["blue", "purple", "pink", "yellow", "green", "cyan", "red", "emerald", "magenta", "amber"]

    static func stem(_ i: Int) -> Color   { stems[((i % stems.count) + stems.count) % stems.count] }
    static func object(_ i: Int) -> Color { objects[((i % objects.count) + objects.count) % objects.count] }
    static func plugin(_ i: Int) -> Color { plugins[((i % plugins.count) + plugins.count) % plugins.count] }
    static func pluginHex(_ i: Int) -> Int { pluginsHex[((i % pluginsHex.count) + pluginsHex.count) % pluginsHex.count] }
    static func stemName(_ i: Int) -> String { stemNames[((i % stemNames.count) + stemNames.count) % stemNames.count] }
}
