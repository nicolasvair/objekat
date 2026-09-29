import SwiftUI

// MARK: - A block's visible portion, read LIVE
//
// The blocks are handed `cullScrollX` (the scroll rounded down to a 512 px notch) and
// `cullViewportWidth` (the viewport plus that notch): the right values for CULLING, which must not
// re-evaluate the timeline at every frame of a scroll — and the wrong ones for anything that has to
// sit in the part of a block one can SEE. `visibleSpan` computed from them is off by up to a notch,
// so a label "centred in the visible portion" was centred in a window half a screen away, and the
// volume tool's controls were drawn where the gestures (which read the EXACT scroll,
// `TimelineView.scrollOffsetX`) no longer hit them.
//
// The remedy is the one the sticky ruler and the marker rows' header already use
// (`StickyToViewportTop`): read `TimelineScrollAnchor.x` in the body of a SMALL view of its own, so
// that a frame of scroll invalidates that view and not the block, still less the timeline.
//
// And even that view only reads the anchor when it has to. A block that lies entirely inside the
// window the scroll is GUARANTEED to be showing — whatever the exact scroll is within the current
// notch — has a visible portion equal to itself, so it reads nothing and is never invalidated. Only
// the blocks a viewport edge can cut, within that notch (`LiveScroll.spanIsInvariant`), follow the
// scroll. `needed` lets a caller that has nothing to place at the moment (a tool layer whose
// controls are not shown) opt out of even that.

/// What a block needs to know the scroll exactly. Built by `TimelineView` (which owns the anchor)
/// and handed down untouched, like `RenderProgressStore`: holding it reads nothing.
struct LiveScroll {
    let anchor: TimelineScrollAnchor
    /// The REAL viewport width — not the culling window's, which carries a notch more.
    let viewportWidth: CGFloat
    /// The culling window's origin, and the notch it moves by: together they bound where the exact
    /// scroll can be (`[cullScrollX, cullScrollX + cullStepPx)`).
    let cullScrollX: CGFloat
    let cullStepPx: CGFloat

    /// True if the block's visible portion is the SAME for every exact scroll the current notch
    /// allows, so that nothing has to be read: either the block is wholly on screen, or wholly off
    /// it (`visibleSpan` then answers the block itself, as it does when nothing is visible). It
    /// stops being so only for a block one of the viewport's two edges can cut — the edge lies
    /// somewhere in `[cullScrollX, cullScrollX + cullStepPx)` on the left and that much further
    /// right. Conservative on purpose: false only costs a read.
    func spanIsInvariant(blockX: Double, blockWidth: Double) -> Bool {
        let blockEnd = blockX + blockWidth
        let left  = Double(cullScrollX), leftEnd = Double(cullScrollX + cullStepPx)
        let right = Double(cullScrollX + viewportWidth), rightEnd = Double(cullScrollX + viewportWidth + cullStepPx)
        let leftEdgeMayCut  = blockX <= leftEnd  && blockEnd >= left
        let rightEdgeMayCut = blockX <= rightEnd && blockEnd >= right
        return !leftEdgeMayCut && !rightEdgeMayCut
    }
}

/// Hands its content the block's visible portion — `x` LOCAL to the block, `width` — read from the
/// exact scroll (@see LiveScroll). Without `live` (or with `needed` false) it answers what the
/// blocks always computed, from the culling window's values.
struct LiveVisibleSpan<Content: View>: View {
    let live: LiveScroll?
    /// The block's x and width in the canvas.
    let blockX: Double
    let blockWidth: Double
    /// The culling window's values, for the fallback.
    let scrollOffsetX: CGFloat
    let viewportWidth: CGFloat
    var needed: Bool = true
    @ViewBuilder let content: ((x: Double, width: Double)) -> Content

    var body: some View { content(span) }

    private var span: (x: Double, width: Double) {
        if needed, let live {
            if live.spanIsInvariant(blockX: blockX, blockWidth: blockWidth) {
                return (0, blockWidth)   // nothing read: this view is not invalidated by the scroll
            }
            // The one read of the anchor, HERE and not in the block. @see TimelineScrollAnchor
            let s = visibleSpan(blockX: blockX, blockWidth: blockWidth,
                                scrollOffsetX: live.anchor.x, viewportWidth: live.viewportWidth)
            return (s.x - blockX, s.width)
        }
        let s = visibleSpan(blockX: blockX, blockWidth: blockWidth,
                            scrollOffsetX: scrollOffsetX, viewportWidth: viewportWidth)
        return (s.x - blockX, s.width)
    }
}

/// Lays its content in the block's VISIBLE portion (the block's whole height, `alignment` inside
/// that window): the consolidation's progress ring, a label. It must sit in a
/// `ZStack(alignment: .leading)` the size of the block, as the blocks' own bodies are.
struct VisibleSpanCentered<Content: View>: View {
    let live: LiveScroll?
    let blockX: Double
    let blockWidth: Double
    let blockHeight: Double
    let scrollOffsetX: CGFloat
    let viewportWidth: CGFloat
    var alignment: Alignment = .center
    @ViewBuilder let content: () -> Content

    var body: some View {
        LiveVisibleSpan(live: live, blockX: blockX, blockWidth: blockWidth,
                        scrollOffsetX: scrollOffsetX, viewportWidth: viewportWidth) { span in
            content()
                .frame(width: span.width, height: blockHeight, alignment: alignment)
                .offset(x: span.x)
        }
    }
}
