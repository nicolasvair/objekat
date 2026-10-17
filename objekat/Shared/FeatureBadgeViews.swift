import SwiftUI

// MARK: - The feature badges as views (the rich block views and the sound list)
//
// The batched `Canvas` draws the same glyphs inside its resolved name run (@see `CanvasLabelCache`);
// these are the SwiftUI side, read by `SoundBlockView`, `GroupBlockView`, `InfiniteBusBandView` and
// the sound list's rows. What the five readers share is the SYMBOL, the ORDER and the RULE that
// drops them; the size and the colour are each site's (they follow the meta's).

/// The badges themselves, in order, one glyph each. A tooltip and an accessibility label per glyph
/// (they only answer where the row takes the mouse — the timeline's blocks do not, the list does).
struct FeatureBadgeGlyphs: View {
    let badges: [FeatureBadge]
    let size: CGFloat
    let color: Color

    var body: some View {
        HStack(spacing: 2) {
            ForEach(badges, id: \.self) { badge in
                Image(systemName: badge.symbol)
                    .font(.system(size: size, weight: .semibold))
                    .foregroundStyle(color)
                    .help(L(badge.labelKey))
                    .accessibilityLabel(L(badge.labelKey))
            }
        }
        .fixedSize()
    }
}

/// The NAME with its badges at its right — and the rule that drops them: the name keeps priority.
/// When the name and the badges do not both fit whole in the room the row offers, the badges go and
/// the name alone is shown (truncated as it always was). No badge: the name, untouched.
struct NameWithFeatureBadges<Name: View>: View {
    let badges: [FeatureBadge]
    let size: CGFloat
    let color: Color
    var spacing: CGFloat = 3
    @ViewBuilder let name: () -> Name

    var body: some View {
        if badges.isEmpty {
            name()
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: spacing) {
                    name().fixedSize()
                    FeatureBadgeGlyphs(badges: badges, size: size, color: color)
                }
                name()
            }
        }
    }
}
