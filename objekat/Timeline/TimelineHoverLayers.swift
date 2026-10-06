import SwiftUI

// The leaves that read the pointer's hover (@see `TimelineHoverStore`). Each one is a view of its
// own ON PURPOSE, on the model of `FileDropGhostOverlay`: what it reads is tracked by ITS body, so
// a movement of the pointer re-evaluates this leaf and not the timeline's. The parent decides
// whether the leaf exists (the tool, a gesture under way — values it reads anyway); the leaf
// decides what it shows.

/// The hovered cut position under the Cut tool: a thin line across the block, on the snap.
/// The parent only mounts it under the Cut tool, with no cut drag under way.
struct CutHoverLine: View {
    let store: TimelineHoverStore
    let viewModel: EditViewModel
    let pixelsPerSecond: Double
    let rulerHeight: Double
    let laneStep: Double
    let blockHeight: Double

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let hover = store.cutHover,
               let entry = viewModel.laneEntry(forID: hover.id) {
                let absX = entry.absStart * pixelsPerSecond + hover.localX
                let by   = rulerHeight + Double(entry.displayLane) * laneStep
                Rectangle()
                    .fill(Color.yellow.opacity(0.85))
                    .frame(width: 1.5, height: blockHeight)
                    .offset(x: absX - 0.75, y: by)
                    .allowsHitTesting(false)
            }
        }
    }
}

/// The hovered block's editing zone under the selection tool: the veil over the zone that would
/// answer the click (@see `ClipEditZonesOverlay`). The parent only mounts it under the selection
/// tool, outside any gesture — once a drag is engaged its own preview says what is happening.
///
/// The veil's PIXELS are re-derived here, at every render, from the block's lane entry and the
/// current zoom (@see `EditZoneHover.relaid`) — exactly as `CutHoverLine` does — and never taken
/// from the rect stored at hover time: a zoom moves no mouse, and that frozen rect drifted off its
/// block as a dark band. The store keeps WHICH block and WHICH zone; the geometry is the model's.
struct EditZoneVeilLayer: View {
    let store: TimelineHoverStore
    let viewModel: EditViewModel
    let pixelsPerSecond: Double
    let rulerHeight: Double
    let laneStep: Double
    let blockHeight: Double

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let hover = store.editZoneHover,
               let entry = viewModel.laneEntry(forID: hover.id) {
                ClipEditZonesOverlay(hover: hover.relaid(on: entry,
                                                         pixelsPerSecond: pixelsPerSecond,
                                                         rulerHeight: rulerHeight,
                                                         laneStep: laneStep,
                                                         blockHeight: blockHeight))
            }
        }
    }
}

/// The tooltip of the hovered tool zone, laid on the canvas. A modifier rather than a view: the
/// tooltip belongs to the canvas itself (the timeline's only hit-testable layer), and a
/// `ViewModifier`'s body is tracked on its own, apart from the view it modifies.
struct TimelineHoverHelp: ViewModifier {
    let store: TimelineHoverStore

    func body(content: Content) -> some View {
        content.helpIf(store.toolZoneHelpText)
    }
}

extension View {
    /// `.helpIf` carrying the timeline's hover tooltip, read from the store by the modifier alone.
    func timelineHoverHelp(_ store: TimelineHoverStore) -> some View {
        modifier(TimelineHoverHelp(store: store))
    }
}
