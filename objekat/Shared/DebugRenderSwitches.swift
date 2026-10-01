#if DEBUG
import Foundation
import Observation

// DEBUG-only switches to compare two ways of drawing the same thing, side by side, at the screen.
// They exist in Debug builds ONLY: a Release build has no such switch, no read of it and no cost
// (every use is inside `#if DEBUG`).
//
// `forceRichBlocks` — the A/B switch of the "selected blocks in the batched Canvas" work. OFF (the
// default) is the production behaviour: a selected clip is drawn in the Canvas like any other. ON
// forces every SELECTED clip back onto the rich SwiftUI view it used to be drawn with
// (`SoundBlockView`), so the two can be compared on the same project, pixel against pixel, by
// toggling it with the clip selected. (Groups will join it when they get a batched path.)
//
// Two doors, and only these:
//   • the preference `objekat.debug.forceRichBlocks` (bool), read ONCE at launch — set it from a
//     terminal and relaunch:
//         defaults write org.labelpeche.objekat objekat.debug.forceRichBlocks -bool YES
//         defaults delete org.labelpeche.objekat objekat.debug.forceRichBlocks     (to go back)
//     (it can also be passed for one launch only, as `-objekat.debug.forceRichBlocks YES` — the
//     NSUserDefaults argument-domain syntax, a SINGLE dash, which is not the app's own `--key=value`)
//   • the command `debug.force_rich_blocks {enabled}` (`CommandAPI/Commands+Runtime.swift`), which
//     flips it live and VOLATILELY — it writes nothing into the user's settings, as a test must not.
//
// Why a tiny `@Observable` of its own and not a flag on `EditViewModel`: the timeline reads it ONCE
// per evaluation of its blocks layer (never per block), so the view depends on one Bool and
// nothing else, and flipping it re-evaluates exactly that layer.
@Observable
final class DebugRenderSwitches {
    static let shared = DebugRenderSwitches()

    static let forceRichBlocksKey = "objekat.debug.forceRichBlocks"

    var forceRichBlocks: Bool

    private init() {
        forceRichBlocks = UserDefaults.standard.bool(forKey: Self.forceRichBlocksKey)
    }
}
#endif
