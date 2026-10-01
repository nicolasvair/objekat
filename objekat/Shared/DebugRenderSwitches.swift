#if DEBUG
import Foundation
import Observation

// DEBUG-only switches to compare two ways of drawing the same thing, side by side, at the screen.
// They exist in Debug builds ONLY: a Release build has no such switch, no read of it and no cost
// (every use is inside `#if DEBUG`).
//
// `forceRichBlocks` — the "everything rich" A/B switch of the batched-Canvas work. OFF (the
// default) is the production behaviour. ON puts back the SwiftUI drawing the Canvas replaced, for
// what has a Canvas path so far, so the two can be compared on the same project, pixel against
// pixel, by toggling it:
//   • every SELECTED clip goes back onto its rich view (`SoundBlockView`) — compare with the
//     clip selected;
//   • the BANDS of the OPEN groups (the tinted rows under a group, its rise under the block, the
//     '+' of its drop lane) go back to their old SwiftUI layers — compare with a group open,
//     nested open groups, a selected open group, a muted open group, light and dark.
//   • EVERY group block (selected or not) goes back onto its rich view (`GroupBlockView`) —
//     compare a closed group, an open one, a selected one, a muted one, one with a custom colour
//     band, one holding a missing file, a consolidated object open for editing.
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
