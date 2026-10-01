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
// `forceRichTools` — the same idea for the Volume / Pan / Aux / Stem tools. OFF (the default) is
// the production behaviour: a block stays a rich view under a tool only when it is aimed at, or
// when the tool draws on it and it follows the exact scroll (@see `ToolOverlayPartition`); the
// others are in the batched Canvas, the tool's overlay drawn there. ON puts the old regime back —
// every block a rich view under Volume / Pan / Aux, and under Stem a clip rich only when selected AND
// hovered (a group when hovered) — so the two can be compared on the same project:
//   • Volume: a selected block, a narrow one, the hovered one; a muted CLIP (no veil under this tool)
//     and a muted GROUP (the veil stays); a crossfade with both blocks selected (the veils add up);
//   • Pan: the same, the mute veil over the panel;
//   • Aux: the columns (names, levels, on/off button), a focused column, a locked (automated) knob,
//     a block cut by the viewport's edge while scrolling;
//   • Stem: the hovered block (clips: selected or not).
//
// Doors for `forceRichBlocks` (`forceRichTools` has the same two, with the key
// `objekat.debug.forceRichTools` and the command `debug.force_rich_tools`):
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
    static let forceRichToolsKey = "objekat.debug.forceRichTools"

    var forceRichBlocks: Bool
    /// Every block back on its rich view under the Volume / Pan / Aux tools (and the old Stem rule).
    var forceRichTools: Bool

    private init() {
        forceRichBlocks = UserDefaults.standard.bool(forKey: Self.forceRichBlocksKey)
        forceRichTools = UserDefaults.standard.bool(forKey: Self.forceRichToolsKey)
    }
}
#endif
