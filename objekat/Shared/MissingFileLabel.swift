import SwiftUI

// MARK: - The look of a name whose file is missing
//
// A clip whose source file cannot be found says so by its NAME going red and bold — the same
// statement the sound list makes on its side, and out of the SAME predicate
// (@see EditViewModel.isMissing / containsMissingDescendant, pure dictionary reads that may be
// called from a view body precisely because they never touch the disk).
//
// The look lives HERE, in one place, because a block's name is drawn in FOUR: `SoundBlockView`,
// `GroupBlockView`, `InfiniteBusBandView` (which replaces a group's block once the bus is
// infinite) and the batched `Canvas` of `TimelineView` (the regime every plain, unselected clip
// falls into past a hundred objects). Four copies of one colour is four chances for the red to
// appear or disappear with the number of objects on screen — the repo's recurring lesson
// (`fittedMarkerLabel`, `SendColumns`, `FadeCurve` ↔ `curveGain`).
// It sits in `Shared/` and not beside one of its four drawings for the fifth reader: the sound
// list's own rows, on the other side of the window, make the very same statement about the very
// same object. A red defined in the timeline and re-typed in the panel is the drift this unit
// exists to prevent, one window further along.
enum MissingFileLabel {
    /// The repo's one colour for a fault or a refusal: the infinite bus's refusal band, the mute
    /// badge, the sound list's own red. Nothing new is invented here — `ObjekatPalette` carries
    /// IDENTITIES (stems, objects, plugins), never a state, so it has no entry to borrow.
    static let color = Color.red
    /// The alarm is the ordinary size in bold, not a bigger glyph: the name band is 20 % of a
    /// block's height, and a larger size would be clipped rather than read. Bumped 10 → 12 on
    /// 24 September 2026 (+2 pt everywhere, a user decision) — still well inside the band at the
    /// project's default block height (121.5 pt × 0.20 ≈ 24 pt).
    static let size: CGFloat = 12
    static let weight: Font.Weight = .bold
    static let normalWeight: Font.Weight = .medium

    /// WHY the red needs a halo, and it is the one thing about this that is not obvious. A name
    /// band is never a neutral ground: it is white plus a tint at 0.30 (0.55 when selected), and
    /// that tint is either the STEM's — strong, and one of the ten IS red (`ObjekatPalette
    /// .stems[6]`) — or a custom OBJECT colour, whose pastels include salmon and pink. Red text on
    /// the red stem's band comes out at about 1.3:1, which is not a poor contrast but no contrast
    /// at all. What IS guaranteed whatever the tint is that the band's base is WHITE, so a white
    /// glow always has something to separate the glyphs against. It is also the only remedy that
    /// costs no layout: a pill behind the name would push the meta summary and the mute badge
    /// along the row.
    static let haloColor = Color.white
    static let haloRadius: CGFloat = 1.5
}

extension View {
    /// The look of a block's NAME, in both states, for the three places one is drawn as a VIEW.
    /// One modifier rather than the same ternary repeated at each site: the ordinary look and the
    /// alarm are decided together, here. The `Canvas` resolves its own `Text` and cannot use this,
    /// so it reads the constants above instead — same values, one definition.
    func blockNameStyle(missingFile: Bool) -> some View {
        self
            .font(.system(size: MissingFileLabel.size,
                          weight: missingFile ? MissingFileLabel.weight
                                              : MissingFileLabel.normalWeight))
            .foregroundStyle(missingFile ? MissingFileLabel.color : Color.black)
            // `.clear` at radius 0 rather than an `if`: a conditional branch would change the
            // label's view identity the moment a file came back, so SwiftUI would rebuild the text
            // instead of merely recolouring it.
            .shadow(color: missingFile ? MissingFileLabel.haloColor : .clear,
                    radius: missingFile ? MissingFileLabel.haloRadius : 0)
    }
}
