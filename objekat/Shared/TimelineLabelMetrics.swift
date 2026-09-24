import Foundation

/// The sizes of a block's icon+name, shared by the four places one is drawn (`SoundBlockView`,
/// `GroupBlockView`, `InfiniteBusBandView`, and the batched `Canvas` of `TimelineView`) — bumped
/// +2 pt everywhere on 24 September 2026 (user decision: +2, not +1) for legibility. The NAME
/// size itself stays centralised in `MissingFileLabel.size` (it already fed all four readers
/// through `blockNameStyle` / the Canvas's own font call), and the Canvas icon size in
/// `ObjectKindIcon.canvasSize` — both bumped there. What is new here is the per-regime icon sizes
/// that used to be bare literals at each call site, and the leading inset a name starts at.
enum TimelineLabelMetrics {
    /// `SoundBlockView`'s icon: 11 → 13.
    static let clipIconSize: CGFloat = 13
    /// `GroupBlockView`'s icon: 10 → 12.
    static let groupIconSize: CGFloat = 12
    /// `InfiniteBusBandView`'s icon: 10 → 12.
    static let infiniteBusIconSize: CGFloat = 12

    /// Where a block's name starts, in px local to the block: 5 px past the end of the fade-in
    /// triangle so the icon+name never sit ON the fade's wash, 8 px with no fade at all (the old
    /// fixed inset), and never past `blockWidth - 36` — the room the meta summary, the mute badge
    /// and the trailing padding already claim, so a narrow block does not have its name pushed
    /// off the right edge by a long fade.
    static func leading(fadeInPx: Double, blockWidth: Double) -> Double {
        min(max(8, fadeInPx + 5), max(8, blockWidth - 36))
    }
}
