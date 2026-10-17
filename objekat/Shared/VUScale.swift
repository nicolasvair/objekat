import SwiftUI

/// The plugin cards' VU scale: -60..+6 dBFS laid over the bar's width (the engine's
/// `audioLevelForPluginKey:` maps onto it, `plugin.level` turns it back into dB). The headroom past 0 dBFS
/// exists so the red zone can be seen at all: the engine is 32-bit float, a plugin can go over.
enum VUScale {
    static let floorDB = -60.0
    static let ceilingDB = 6.0

    /// The bar's 0...1 position of a level in dBFS.
    static func fraction(_ dB: Double) -> Double {
        max(0, min(1, (dB - floorDB) / (ceilingDB - floorDB)))
    }

    /// A 0...1 position turned back into dBFS (0 reads the floor).
    static func dB(_ fraction: Double) -> Double {
        floorDB + fraction * (ceilingDB - floorDB)
    }

    /// The colour zones, in bar positions: green up to -18 dBFS, yellow to -6, orange to 0, red past it.
    static let zones: [(from: Double, to: Double, color: Color)] = [
        (0, fraction(-18), .green),
        (fraction(-18), fraction(-6), .yellow),
        (fraction(-6), fraction(0), .orange),
        (fraction(0), 1, .red),
    ]
}
