import SwiftUI
import Observation

/// The plugin cards' VU levels (0...1), kept OUTSIDE `SynopticBoundView`'s `@State`.
///
/// Why a store of their own: a level refresh used to be a `@State` write on the bound view, so every
/// tick rebuilt the whole synoptic (`SynopticMapping.build`, the layout, every card) to move a 2-pt
/// line. Here only `SynopticCardVULine` reads `levels` (through the environment), so SwiftUI
/// invalidates those lines alone — the view that owns the store never reads it in its `body`.
@MainActor
@Observable
final class SynopticLevelStore {
    /// pluginID → level after the ballistics. A missing id reads 0.
    var levels: [UUID: Double] = [:]

    /// The last tick's time, to scale the release to the REAL interval. Not observed: a write to it
    /// must not invalidate anything.
    @ObservationIgnored var lastTick: CFTimeInterval = 0
}

private struct SynopticLevelStoreKey: EnvironmentKey {
    static let defaultValue: SynopticLevelStore? = nil
}

extension EnvironmentValues {
    /// The store the cards under a `SynopticBoundView` read their level from; nil elsewhere (the demo
    /// sheet, previews), where a card falls back on its own `vu`.
    var synopticLevels: SynopticLevelStore? {
        get { self[SynopticLevelStoreKey.self] }
        set { self[SynopticLevelStoreKey.self] = newValue }
    }
}
