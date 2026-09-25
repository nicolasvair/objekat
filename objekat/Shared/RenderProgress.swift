import SwiftUI

// MARK: - How far a consolidated render has got
//
// A consolidation (a bake of a group into its wave, a commit re-baking an open object, a cascade
// re-baking a definition whose dependency moved) runs on the engine's own thread for as long as
// the material lasts — seconds, sometimes a minute for a long group full of AU. It was shown by a
// SPINNER, which says "something is happening" and nothing about the one thing a hand waiting on
// it wants to know: whether to wait or to go and do something else. The engine already knows the
// answer — the `EditRenderer` counts its progress for the export, and a bake goes through the very
// same renderer (@see OBJEngineCore `renderProgressForObject:`) — so the circle FILLS now, a pie
// growing clockwise from twelve o'clock, as a kitchen timer does the other way round.
//
// Why a separate observable object rather than a property of the view-model: the value moves ten
// times a second for as long as a render runs, and the timeline's body reads the view-model in
// hundreds of places. A dictionary on the view-model would be read by `TimelineView` itself
// (that is where the blocks are told what they show), so every tick would re-evaluate the WHOLE
// timeline. Here the view-model holds the store as a plain `let` — reading it registers nothing —
// and only `RenderProgressRing`'s own body touches `fractions`: a tick invalidates the one or two
// rings on screen and nothing else. The same arrangement as `TimelineScrollAnchor`, for the same
// reason.

/// The fraction (0…1) each render indicator on screen shows, keyed by what the INDICATOR is keyed
/// by: the object's id for a bake (the block that wears the veil, @see EditViewModel.bakingIDs),
/// the DEFINITION's id for an automatic re-bake (every instance of it wears the same small
/// circle, @see EditViewModel.recomputingConsolidateIDs). Object ids and definition ids are both
/// fresh UUIDs, so the two never collide in one dictionary.
///
/// Written by one place only, `EditViewModel.pollRenderProgress`, and only when something changed:
/// an equal dictionary reassigned every tick would invalidate the rings for nothing.
@Observable final class RenderProgressStore {
    private(set) var fractions: [UUID: Double] = [:]

    /// nil = nothing known yet for this key (the engine has not started the job, or no render of
    /// it is running at all). The ring then reads it as an empty circle.
    func fraction(for key: UUID) -> Double? { fractions[key] }

    func replace(with next: [UUID: Double]) {
        if next != fractions { fractions = next }
    }
}

/// A circle that fills as a render advances. Drawn in white over whatever is beneath it — the
/// bake's dark veil, or an instance's own band for a re-bake — with a faint dark disc behind the
/// pie so the empty part still reads as a circle over a bright waveform.
///
/// No text, on purpose: a percentage in a 14 pt glyph is unreadable, and "how much is left" is a
/// proportion the eye takes from a pie at a glance — which is the whole request.
struct RenderProgressRing: View {
    let store: RenderProgressStore
    let key: UUID
    var diameter: CGFloat = 14

    var body: some View {
        // The one read of the store, HERE and not in the block that hosts this view: it is what
        // keeps a tick from reaching further than this small subtree. @see RenderProgressStore
        let fraction = store.fraction(for: key) ?? 0
        ZStack {
            Circle()
                .fill(Color.black.opacity(0.25))
            RenderProgressPie(fraction: fraction)
                .fill(Color.white.opacity(0.9))
            Circle()
                .strokeBorder(Color.white.opacity(0.9), lineWidth: 1.2)
        }
        .frame(width: diameter, height: diameter)
    }
}

/// The filled sector: from twelve o'clock, clockwise, `fraction` of a full turn. Empty at 0 (no
/// sliver of a path, which would draw a hairline from the centre), a whole disc at 1.
///
/// Not animated between two readings: the poll ticks at 10 Hz, which on a 14 pt circle is a step
/// of a few degrees at most, and a render lasting seconds reads as continuous without it.
struct RenderProgressPie: Shape {
    let fraction: Double

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let f = min(1, max(0, fraction))
        guard f > 0 else { return p }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        p.move(to: center)
        // `clockwise: false` in SwiftUI's flipped space (y grows downwards) is CLOCKWISE on
        // screen — which is the direction a clock hand, and so a timer, is read in.
        p.addArc(center: center, radius: radius,
                 startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * f),
                 clockwise: false)
        p.closeSubpath()
        return p
    }
}
