import SwiftUI

/// Hands its content the EXACT horizontal scroll, read in the body of this small view and nowhere
/// else — the one way a layer may follow the scroll to the pixel without dragging the timeline's
/// body along (@see TimelineScrollAnchor, StickyToViewportTop, LiveVisibleSpan). A frame of scroll
/// invalidates THIS view; what it builds from the value is what gets redrawn.
///
/// Used by the sticky pass of the blocks' Canvas (@see StickyLabel): the names that depend on the
/// exact viewport edge are drawn by a second Canvas of the same size, behind this reader, so the
/// notch-driven Canvas (the expensive one) is never redrawn by a scroll.
struct StickyScrollReader<Content: View>: View {
    let anchor: TimelineScrollAnchor
    @ViewBuilder let content: (CGFloat) -> Content

    var body: some View { content(anchor.x) }
}
