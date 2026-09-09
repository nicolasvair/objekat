import SwiftUI

// MARK: - The X of a crossfade
//
// Drawing the veil twice would not have been enough, and that is the whole reason this file
// exists. In a crossfade the two objects OCCUPY THE SAME PIXELS — that is what a shared zone is —
// so their blocks are stacked and the upper one simply hides the lower, veil included. Whatever
// each block draws inside the zone, only one of them is ever seen.
//
// So the zone is drawn ONCE, above both blocks, and it draws what neither block can: the two
// curves at the same time, crossing. The outgoing one comes down as the incoming one climbs, and
// the X they make is the only thing on screen that says "these two are not fighting over this
// span, they are handing over across it".
//
// The curves come from `FadeCurve.gain`, the same function the veil's edge and the engine's
// envelope read. There is no second definition of a fade's shape anywhere, which is what makes
// "is it only the display?" always answerable with no.

/// The two facing curves of one crossfade, in the zone's own coordinates.
struct CrossfadeCurvePath: Shape {
    let curve: FadeCurve
    /// `.out` = the outgoing object, which comes DOWN across the zone; `.in` = the incoming one.
    let side: FadeSide

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width, h = rect.height
        guard w > 0, h > 0 else { return p }
        // One sample per pixel, capped: the same budget as the block veils, and these are rebuilt
        // per frame while a crossfade is being dragged.
        let n = max(2, min(Int(w.rounded()), 512))
        for i in 0...n {
            // `alpha` is the fade's PROGRESS, 0 = silence and 1 = full level, for both edges
            // (@see FadeCurve) — so the OUTGOING one is read right to left and one single family
            // of formulas serves both. It is also why the two curves of an equal-gain crossfade
            // are exact mirrors and meet in the middle.
            let a = Double(i) / Double(n)
            let x = side == .in ? a * w : w - a * w
            let y = h * (1 - curve.gain(a))
            if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
        }
        return p
    }
}

/// The overlay laid on one crossfade zone: a light ground so the shared span reads as one thing,
/// and the two curves crossing over it.
struct CrossfadeVeilOverlay: View {
    let outCurve: FadeCurve
    let inCurve:  FadeCurve
    let width:    Double
    let height:   Double
    /// Dimmed when something else is going on, so the X never competes with a gesture's own preview.
    var emphasis: Double = 1
    /// The zone is SELECTED: it is cerned, because ⌫ is about to act on it and one must be able to
    /// see which of several crossfades it will take.
    var isSelected: Bool = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            // The ground marks the SPAN, which no block can: each of them stops at its own edge,
            // and the zone is precisely the part they have in common.
            Rectangle()
                .fill(Color.white.opacity((isSelected ? 0.12 : 0.05) * emphasis))
            // The two boundaries of the zone: thin, so they read as the limits of a passage rather
            // than as two more object edges. Selected, the outline closes right round it — the
            // zone stops being a passage between two blocks and becomes the thing one is holding.
            if isSelected {
                Rectangle()
                    .strokeBorder(Color.accentColor.opacity(0.95), lineWidth: 1.5)
            } else {
                Path { p in
                    p.move(to: .zero);              p.addLine(to: CGPoint(x: 0, y: height))
                    p.move(to: CGPoint(x: width, y: 0)); p.addLine(to: CGPoint(x: width, y: height))
                }
                .stroke(Color.white.opacity(0.28 * emphasis), lineWidth: 1)
            }

            CrossfadeCurvePath(curve: outCurve, side: .out)
                .stroke(Color.white.opacity(0.85 * emphasis), lineWidth: 1.5)
            CrossfadeCurvePath(curve: inCurve, side: .in)
                .stroke(Color.white.opacity(0.85 * emphasis), lineWidth: 1.5)
        }
        .frame(width: width, height: height)
        .allowsHitTesting(false)
    }
}

// MARK: - Laying the X on the timeline

extension TimelineView {

    /// Every crossfade on screen, drawn over the blocks — plus the one the hand is in the middle of
    /// making, which does not exist in the model yet.
    ///
    /// It sits ABOVE the blocks on purpose and it is the only layer that may: a zone belongs to two
    /// objects at once, so no block can own it without one of them hiding the other's half.
    @ViewBuilder
    var crossfadeLayer: some View {
        let zones = viewModel.visibleCrossfadeZones()
        ForEach(Array(zones.enumerated()), id: \.offset) { _, z in
            let x = z.start * pixelsPerSecond
            let y = rulerHeight + Double(z.lane) * laneStep
            let w = z.width * pixelsPerSecond
            if w >= 1 {
                let sel = viewModel.selectedCrossfade
                CrossfadeVeilOverlay(
                    outCurve: viewModel.find(id: z.leftID)?.fadeOutCurve ?? .linear,
                    inCurve:  viewModel.find(id: z.rightID)?.fadeInCurve ?? .linear,
                    width: w, height: blockHeight,
                    isSelected: sel?.left == z.leftID && sel?.right == z.rightID)
                .offset(x: x, y: y)
            }
        }
        // The zone a fade being pulled onto its neighbour is ABOUT to open. Without it the gesture
        // is mute until release — one pulls a fade out past an edge and nothing on screen says a
        // crossfade is being made, nor how wide, nor that the seam has given all it has.
        if let ghost = spillingCrossfadePreview {
            CrossfadeVeilOverlay(outCurve: ghost.outCurve, inCurve: ghost.inCurve,
                                 width: ghost.width, height: blockHeight, emphasis: 0.6)
                .offset(x: ghost.x, y: ghost.y)
        }
    }

    /// The crossfade a spilling fade drag is about to lay down, for EITHER of the two objects it
    /// concerns — the one whose fade is being pulled and the neighbour it is spilling onto.
    ///
    /// It exists because a spill moves BOTH blocks and the fade preview knew about neither. The
    /// block went on drawing its own fade growing from its own edge while the ghost X drew the
    /// zone somewhere else, and the neighbour did not move at all until the mouse came up. Both
    /// now read the plan `openCrossfade` will apply, so the drag shows the result and not a
    /// rehearsal of it.
    func spillPlan(for id: UUID) -> (plan: EditViewModel.CrossfadePlan, isLeft: Bool)? {
        guard let fd = fadeDrag, fd.dEdge != 0 else { return nil }
        for held in fd.ids {
            guard let neighbour = fd.seamNeighbours[held],
                  held == id || neighbour == id else { continue }
            let pair = fd.side == .out ? (held, neighbour) : (neighbour, held)
            let width = (fd.zoneAnchors[held] ?? 0) + abs(fd.dEdge)
            guard case .success(let plan) = viewModel.plannedCrossfade(leftID: pair.0,
                                                                      rightID: pair.1,
                                                                      width: width)
            else { return nil }
            return (plan, plan.leftID == id)
        }
        return nil
    }

    /// The curve a spill is about to lay on BOTH sides: the hand's if it bent anything, straight
    /// otherwise — the same rule as the commit, so the preview cannot promise another shape.
    var spillCurve: FadeCurve {
        guard let fd = fadeDrag, fd.overshootY != 0 else { return .linear }
        return fd.curve(for: fd.grabbedID)
    }

    /// The crossfade the fade drag under way would open if it were released now, in canvas
    /// coordinates. `nil` when no fade is spilling onto a neighbour.
    ///
    /// It goes through `plannedCrossfade`, which is the arithmetic `openCrossfade` itself runs:
    /// the ghost is not an approximation of the zone, it IS the zone, clamp included — so a hand
    /// that has reached the seam's limit sees the ghost stop moving instead of learning it on
    /// release.
    var spillingCrossfadePreview: (x: Double, y: Double, width: Double,
                                   outCurve: FadeCurve, inCurve: FadeCurve)? {
        guard let fd = fadeDrag, fd.dEdge != 0,
              let neighbour = fd.seamNeighbours[fd.grabbedID],
              let entry = viewModel.laneEntries.first(where: { $0.item.id == fd.grabbedID })
        else { return nil }
        let pair = fd.side == .out ? (fd.grabbedID, neighbour) : (neighbour, fd.grabbedID)
        let width = (fd.zoneAnchors[fd.grabbedID] ?? 0) + abs(fd.dEdge)
        guard case .success(let plan) = viewModel.plannedCrossfade(leftID: pair.0, rightID: pair.1,
                                                                  width: width),
              plan.width * pixelsPerSecond >= 1
        else { return nil }
        // The plan speaks in the container's time; the canvas in absolute time. One offset, read
        // off the row the gesture started on — the same conversion the rest of the canvas makes.
        let offset = entry.absStart - entry.item.startTime
        let curve = spillCurve
        return (x: (plan.start + offset) * pixelsPerSecond,
                y: rulerHeight + Double(entry.displayLane) * laneStep,
                width: plan.width * pixelsPerSecond,
                outCurve: curve, inCurve: curve)
    }
}

/// The mask that punches a block's opaque base out of the spans it SHARES with a crossfaded
/// neighbour. A flexible middle rather than a computed width: the block's own width never has to
/// be known here, and the mask follows it through every resize and every zoom.
struct OpaqueBaseMask: View {
    let leading:  Double
    let trailing: Double

    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: max(0, leading))
            Color.black
            Color.clear.frame(width: max(0, trailing))
        }
    }
}

extension TimelineView {

    /// How much of a block, at each end, is shared with a crossfaded neighbour — in px, and in the
    /// geometry the drag is showing rather than the one the model holds, so the punched-out base
    /// tracks the hand.
    func crossfadeSharedPx(for item: SoundObject) -> (leading: Double, trailing: Double) {
        var lead = 0.0, trail = 0.0
        if let n = viewModel.seamNeighbour(of: item.id, onRight: false),
           let z = viewModel.crossfadeZone(leftID: n, rightID: item.id) {
            lead = z.width * pixelsPerSecond
        }
        if let n = viewModel.seamNeighbour(of: item.id, onRight: true),
           let z = viewModel.crossfadeZone(leftID: item.id, rightID: n) {
            trail = z.width * pixelsPerSecond
        }
        // A spill under way: the zone it is about to lay down wins over the one the model still
        // holds, on that side only — the other end may carry a crossfade of its own.
        if let sp = spillPlan(for: item.id) {
            if sp.isLeft { trail = sp.plan.width * pixelsPerSecond }
            else         { lead  = sp.plan.width * pixelsPerSecond }
        }
        return (lead, trail)
    }
}
