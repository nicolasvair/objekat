import SwiftUI
import AppKit

// MARK: - The timeline's side of the recording zones
//
// The canvas resolves WHERE (a lane, an instant, the [ o ] under a point) and hands it to the view
// model, whose planner decides WHAT (@see RecordZonePlanner, EditViewModel+RecordZones). The blocks
// stay pure drawing: the [ o ] is drawn by `GroupBlocksCanvas` and hit-tested here, on `laneEntries`.

extension TimelineView {

    /// The lane and the (snapped) instant under a drop location, with the width of the view in
    /// seconds — the same reading the file drop makes (`placeDroppedEntries`).
    private func recordDropPoint(at loc: CGPoint) -> (lane: Int, time: Double, visibleSecs: Double) {
        let lane = max(0, Int((loc.y - rulerHeight) / laneStep))
        let time = max(0, viewModel.snappedTimePure(loc.x / pixelsPerSecond))
        return (lane, time, Double(viewportWidth) / pixelsPerSecond)
    }

    /// An input is hovering the timeline: lays the ghost and answers the cursor. nil when the drag in
    /// flight is not an input.
    func recordInputHover(at loc: CGPoint) -> DropOperation? {
        guard let ref = InputDragSession.shared.current else { return nil }
        let p = recordDropPoint(at: loc)
        let plan = viewModel.planRecordDrop(displayLane: p.lane, time: p.time,
                                            visibleSpanSecs: p.visibleSecs, pixelsPerSecond: pixelsPerSecond)
        let ghost = viewModel.recordDropGhost(for: plan, ref: ref, displayLane: p.lane, time: p.time)
        if viewModel.recordDropGhost != ghost { viewModel.recordDropGhost = ghost }
        return plan.isRefusal ? .forbidden : .copy
    }

    func endRecordInputHover() {
        if viewModel.recordDropGhost != nil { viewModel.recordDropGhost = nil }
    }

    /// The provider of a drop, when it carries an input: the zone is made (or the input assigned) at the
    /// lane and instant of the hand — read here, synchronously — once the payload is decoded.
    func receiveInputDrop(_ provider: NSItemProvider, at loc: CGPoint) {
        let p = recordDropPoint(at: loc)
        let pps = pixelsPerSecond
        let vm = viewModel
        InputDragSession.shared.end()
        InputDragSession.read(provider) { ref in
            guard let ref else { return }
            vm.dropRecordInput(ref, displayLane: p.lane, time: p.time,
                               visibleSpanSecs: p.visibleSecs, pixelsPerSecond: pps)
        }
    }

    /// The zone whose [ o ] is under `point` (canvas coordinates), when that [ o ] can be clicked: the
    /// input is on the card. An absent one is not a button, the click is the block's.
    func recordIconHit(at point: CGPoint) -> UUID? {
        let channels = AudioDeviceStatus.shared.snapshot.inputChannels
        for e in viewModel.laneEntries where e.item.recordInput != nil {
            guard let state = viewModel.recordZoneIcon(of: e.item, channels: channels), state != .absent,
                  let hit = RecordZoneIcon.hitRect(in: clipRect(for: e)), hit.contains(point) else { continue }
            return e.item.id
        }
        return nil
    }
}
