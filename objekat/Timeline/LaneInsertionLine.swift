import Perception
import SwiftUI

/// The line drawn in the gap between two rows where something is about to be INSERTED (@see
/// LaneInsertion): 3 px of accent in the middle of the 4 px between the two rows. One view for the two
/// gestures that insert — a block of the canvas carried across the lanes, and files dragged in from
/// outside (the Finder, the library) — so that they read the same.
///
/// Laid in the canvas's coordinate space (top-leading), like everything else the canvas stacks.
struct LaneInsertionLine: View {
    /// The line stands before this DISPLAY row.
    let boundaryRow: Int
    let rulerHeight: Double
    let laneStep: Double
    let laneGap: Double
    let x: Double
    let width: Double

    /// The ordinate of the line's centre: the middle of the gap above row `boundaryRow`.
    static func centreY(boundaryRow: Int, rulerHeight: Double, laneStep: Double, laneGap: Double) -> Double {
        rulerHeight + Double(boundaryRow) * laneStep - laneGap / 2
    }

    /// Where the line spans horizontally: the whole timeline on the root; inside a group, only over
    /// the group's own span — which is what says WHICH group the objects will enter. An infinite bus
    /// has no span of its own and keeps the full width.
    @MainActor
    static func extent(of plan: LaneInsertion.Plan, in viewModel: EditViewModel,
                       pixelsPerSecond: Double, fullWidth: Double) -> (x: Double, width: Double) {
        if let gid = plan.parentID,
           let e = viewModel.laneEntries.first(where: { $0.item.id == gid }),
           !e.item.isInfiniteBus {
            return (e.absStart * pixelsPerSecond, e.item.duration * pixelsPerSecond)
        }
        return (0, fullWidth)
    }

    var body: some View { WithPerceptionTracking { perceivedBody } }

    @ViewBuilder private var perceivedBody: some View {
        Capsule()
            .fill(Color.accentColor)
            .frame(width: width, height: 3)
            .offset(x: x, y: Self.centreY(boundaryRow: boundaryRow, rulerHeight: rulerHeight,
                                          laneStep: laneStep, laneGap: laneGap) - 1.5)
    }
}
