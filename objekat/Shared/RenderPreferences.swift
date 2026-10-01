import Foundation
import Observation

/// Preferences that choose HOW the timeline draws a thing, readable in a Release build — unlike
/// `DebugRenderSwitches`, which exists in Debug only. They are fallbacks: the default (everything
/// off) is the production behaviour, and a switch exists only so that a regime can be put back
/// without rebuilding, the day a drawing turns out to differ from the view it replaced.
///
/// `richPreviews` — the gestures' previews (move, trim, resize, fade, spill, loop-bound drag) go
/// back onto the SwiftUI views (`SoundBlockView` / `GroupBlockView`), as they were before the
/// batched Canvas drew them. OFF (the default): the Canvas draws the previews itself, from the
/// same `BlockPreviewGeometry` the views read, so a 600-selected drag stays ONE draw call instead of
/// creating 600 views on its first frame.
///
/// Doors: the preference `objekat.timeline.richPreviews` (bool), read ONCE at launch —
///     defaults write org.labelpeche.objekat objekat.timeline.richPreviews -bool YES
///     defaults delete org.labelpeche.objekat objekat.timeline.richPreviews     (to go back)
/// or, for one launch only, `-objekat.timeline.richPreviews YES` (the NSUserDefaults argument
/// domain: a SINGLE dash, which is not the app's own `--key=value`). Debug builds can also flip it
/// live and volatilely with the command `debug.force_rich_previews`.
///
/// A tiny `@Observable` of its own, read ONCE per evaluation of the blocks layer (never per block):
/// the view then depends on one Bool and nothing else.
@Observable
final class RenderPreferences {
    static let shared = RenderPreferences()

    static let richPreviewsKey = "objekat.timeline.richPreviews"

    var richPreviews: Bool

    private init() {
        richPreviews = UserDefaults.standard.bool(forKey: Self.richPreviewsKey)
    }
}
