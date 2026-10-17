import Foundation

// MARK: - The glyphs of the app's features — one definition, every reader
//
// Read beside `ObjectKindIcon`, and for the same reason. An FX link, a send to an aux and the two
// ends of a sidechain are each drawn in several places — the signal view's cards and frames, the
// inspector, the timeline's HUDs and veils, the drag badges, and the feature badges a block and a
// sound-list row carry after the object's name (@see `ObjectFeatureBadges`). A glyph typed at each
// of them is one more chance for the same feature to read as two different things depending on
// where the eye is; so every one of them names the symbol through THIS enum, and changing a
// feature's glyph is one line here.
//
// What is NOT here, on purpose: the object KINDS (`ObjectKindIcon`), and the glyphs that only
// LOOK like one of these but say something else — the "choose object" mode's `scope` (a pick
// action, not the sidechain).
nonisolated enum FeatureIcons {
    /// An object carrying effects (at least one real plugin in its chain).
    static let fx = "fx"
    /// An FX link (a bin of plugins several objects share) and the legacy ⌘-link of plugins:
    /// the link badges, the bin's frame, the drag hint.
    static let fxLink = "personalhotspot"
    /// A send to an aux — outgoing or received, a send card, a row, the Aux tool.
    static let auxSend = "point.topleft.down.curvedto.point.bottomright.up"
    /// The object is the KEY SOURCE of some plugin's sidechain (its sound goes out as a key).
    static let sidechainSend = "arrow.up.right.circle"
    /// The object has a plugin whose sidechain input is keyed (a key comes in).
    static let sidechainReception = "arrow.down.left.circle"
    /// A parameter an automation curve drives (its static control greyed out, no longer answering
    /// the hand): the send knob under the Aux tool, the signal view's locked controls — and the
    /// feature badge of an object carrying at least one curve (@see `ObjectFeatureBadges`).
    static let automated = "chart.xyaxis.line"
}
