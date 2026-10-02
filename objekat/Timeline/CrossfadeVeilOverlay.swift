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
///
/// The shape of a curve is worked out ONCE, in the unit square, and cached by curve (@see
/// CrossfadeCurveSampling): a frame of a crossfade drag only changes the zone's position and width,
/// so what it asks of the curve is one affine transform, no `pow` at all in the steady state.
struct CrossfadeCurvePath: Shape {
    let curve: FadeCurve
    /// `.out` = the outgoing object, which comes DOWN across the zone; `.in` = the incoming one.
    let side: FadeSide

    private static let cache = CrossfadeCurveCache<Path>()

    /// The curve in the unit square (x across, y from the top), shared between frames and zones.
    static func unitPath(curve: FadeCurve, side: FadeSide, width: Double) -> Path {
        let n = CrossfadeCurveSampling.sampleCount(forWidth: width)
        // (a pattern, not `==`: `FadeSide`'s Equatable is main-actor isolated and this is nonisolated)
        let incoming: Bool
        switch side { case .in: incoming = true; case .out: incoming = false }
        return cache.value(for: .init(curve: curve, incoming: incoming, segments: n)) {
            var p = Path()
            for (i, pt) in CrossfadeCurveSampling.unitPoints(curve: curve, incoming: incoming,
                                                            segments: n).enumerated() {
                let q = CGPoint(x: pt.x, y: pt.y)
                if i == 0 { p.move(to: q) } else { p.addLine(to: q) }
            }
            return p
        }
    }

    /// The curve drawn into a box at (`x`, `y`), `w` × `h`: the cached unit path, stretched.
    static func path(curve: FadeCurve, side: FadeSide, x: Double, y: Double, w: Double, h: Double) -> Path {
        guard w > 0, h > 0 else { return Path() }
        return unitPath(curve: curve, side: side, width: w)
            .applying(CGAffineTransform(a: w, b: 0, c: 0, d: h, tx: x, ty: y))
    }

    func path(in rect: CGRect) -> Path {
        Self.path(curve: curve, side: side, x: rect.minX, y: rect.minY, w: rect.width, h: rect.height)
    }
}

/// One crossfade, resolved and ready to be drawn: a light ground so the shared span reads as one
/// thing, its two boundaries, and the two curves crossing over it. A VALUE, not a view — every
/// zone of the timeline is drawn into ONE Canvas (@see TimelineView.crossfadeCanvas), which is why
/// everything it needs (position, size, the two curves, the selection) is resolved by the body and
/// handed over here, nothing read from the model while drawing.
struct CrossfadeVeilDrawing {
    /// The zone's box in canvas coordinates.
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let outCurve: FadeCurve
    let inCurve:  FadeCurve
    /// Dimmed when something else is going on, so the X never competes with a gesture's own preview.
    var emphasis: Double = 1
    /// The zone is SELECTED: it is cerned, because ⌫ is about to act on it and one must be able to
    /// see which of several crossfades it will take.
    var isSelected: Bool = false

    func draw(in ctx: GraphicsContext) {
        let rect = CGRect(x: x, y: y, width: width, height: height)
        // The ground marks the SPAN, which no block can: each of them stops at its own edge,
        // and the zone is precisely the part they have in common. Selected, that ground turns
        // BLUE rather than merely paler: the zone is a thing one holds, and a thing one holds
        // in OBJEKAT wears the accent colour — a white veil a shade denser said nothing at all
        // over blocks that are already white.
        ctx.fill(Path(rect), with: .color(isSelected ? Color.accentColor.opacity(0.32)
                                                     : Color.white.opacity(0.05 * emphasis)))
        // The two boundaries of the zone: thin, so they read as the limits of a passage rather
        // than as two more object edges. Selected, the outline closes right round it — the
        // zone stops being a passage between two blocks and becomes the thing one is holding.
        if isSelected {
            // `strokeBorder` strokes INSIDE the box: the path is inset by half the line.
            let inner = width > 1.5 && height > 1.5 ? rect.insetBy(dx: 0.75, dy: 0.75) : rect
            ctx.stroke(Path(inner), with: .color(Color.accentColor.opacity(0.95)), lineWidth: 1.5)
        } else {
            var p = Path()
            p.move(to: CGPoint(x: x, y: y));         p.addLine(to: CGPoint(x: x, y: y + height))
            p.move(to: CGPoint(x: x + width, y: y)); p.addLine(to: CGPoint(x: x + width, y: y + height))
            ctx.stroke(p, with: .color(Color.white.opacity(0.28 * emphasis)), lineWidth: 1)
        }
        let curveInk = GraphicsContext.Shading.color(Color.white.opacity(0.85 * emphasis))
        ctx.stroke(CrossfadeCurvePath.path(curve: outCurve, side: .out, x: x, y: y, w: width, h: height),
                   with: curveInk, lineWidth: 1.5)
        ctx.stroke(CrossfadeCurvePath.path(curve: inCurve, side: .in, x: x, y: y, w: width, h: height),
                   with: curveInk, lineWidth: 1.5)
    }
}

// MARK: - Laying the X on the timeline

extension TimelineView {

    /// Every crossfade on screen, drawn over the blocks — plus the one the hand is in the middle of
    /// making, which does not exist in the model yet — resolved into drawings for ONE Canvas.
    ///
    /// It sits ABOVE the blocks on purpose and it is the only layer that may: a zone belongs to two
    /// objects at once, so no block can own it without one of them hiding the other's half.
    ///
    /// Only what the viewport shows is resolved: the zones come from the index through the
    /// culled reading (the rows and the time the cull window covers), so what a pass costs follows
    /// what is SHOWN and not how many crossfades the project holds. Each one is then kept only if
    /// its box really meets the window — the index works on whole rows and spans of time.
    func crossfadeDrawings() -> [CrossfadeVeilDrawing] {
        let pps = max(pixelsPerSecond, EditViewModel.minPixelsPerSecond)
        let cols = cullColumns
        let win = cullRows
        let rows = LaneCulling.rows(y0: win.y0, y1: win.y1, rulerHeight: rulerHeight,
                                    laneStep: laneStep, count: Int.max)
        let zones = displayedCrossfadeZones(lanes: rows, from: cols.x0 / pps, to: cols.x1 / pps)
        let sel = viewModel.selectedCrossfade
        // A crossfade drag draws the curves of ITS copies (the model holds the objects as they were
        // when the hand came down).
        let shadow = crossfadeDrag?.shadow
        var drawings: [CrossfadeVeilDrawing] = []
        for z in zones {
            let w = (z.end - z.start) * pixelsPerSecond
            guard w >= 1 else { continue }
            let x = z.start * pixelsPerSecond
            let y = rulerHeight + Double(z.lane) * laneStep
            guard x + w >= cols.x0, x <= cols.x1,
                  LaneCulling.meets(top: y, height: blockHeight, y0: win.y0, y1: win.y1) else { continue }
            drawings.append(CrossfadeVeilDrawing(
                x: x, y: y, width: w, height: blockHeight,
                outCurve: (shadow?.objects[z.leftID] ?? viewModel.find(id: z.leftID))?.fadeOutCurve ?? .linear,
                inCurve:  (shadow?.objects[z.rightID] ?? viewModel.find(id: z.rightID))?.fadeInCurve ?? .linear,
                isSelected: sel?.left == z.leftID && sel?.right == z.rightID))
        }
        // The zone a fade being pulled onto its neighbour is ABOUT to open. Without it the gesture
        // is mute until release — one pulls a fade out past an edge and nothing on screen says a
        // crossfade is being made, nor how wide, nor that the seam has given all it has.
        if let ghost = spillingCrossfadePreview {
            drawings.append(CrossfadeVeilDrawing(
                x: ghost.x, y: ghost.y, width: ghost.width, height: blockHeight,
                outCurve: ghost.outCurve, inCurve: ghost.inCurve, emphasis: 0.6))
        }
        return drawings
    }

    /// Every crossfade AS IT IS BEING SHOWN, the move under way already applied to it.
    ///
    /// A zone is the span two objects have in common, so displacing one of them changes it on the
    /// spot — and a move that only announced its zone on release would leave the blocks sliding
    /// under an X pinned where the objects used to be. The pairs are read off the model (which the
    /// drag has not touched yet), and each one is re-projected through the same arithmetic the
    /// commit will run, fed the geometry the hand is showing rather than the one the model holds.
    ///
    /// A pair the move BREAKS simply drops out of the list, which is what the release will do to
    /// it too: the X goes as the objects come apart, or as one starts swallowing the other.
    ///
    /// `lanes` / `t0` / `t1` bound the READING of the model's zones to a window (rows × absolute
    /// seconds), for the layer that only draws the viewport; the zones a gesture re-projects are
    /// few and are all returned (the caller keeps the ones its window meets).
    func displayedCrossfadeZones(lanes: Range<Int>, from t0: Double, to t1: Double)
        -> [(leftID: UUID, rightID: UUID, start: Double, end: Double, lane: Int)] {
        let model = viewModel.visibleCrossfadeZones(inLanes: lanes, from: t0, to: t1).map {
            (leftID: $0.leftID, rightID: $0.rightID, start: $0.start, end: $0.end, lane: $0.lane)
        }
        // A crossfade drag shows the zones as ITS copies leave them — the model has not been
        // written, and holds the zone as the hand found it.
        if let cd = crossfadeDrag, let shadow = cd.shadow {
            return shadowedCrossfadeZones(model: model, shadow: shadow, tracks: cd.tracks)
        }
        guard let ids = reshapingDragIDs else { return model }
        let pairs = viewModel.crossfadePairs(around: ids)
        guard !pairs.isEmpty else { return model }

        let touched = Set(pairs)
        var shown = model.filter {
            !touched.contains(EditViewModel.CrossfadePair(left: $0.leftID, right: $0.rightID))
        }
        for p in pairs {
            if let z = viewModel.projectedCrossfade(leftID: p.left, rightID: p.right,
                                                    placement: dragPlacement) {
                shown.append(z)
            }
        }
        return shown
    }

    /// The crossfade two objects form AS A CROSSFADE DRAG IS LEAVING THEM — its copies, and the
    /// model's own objects for whichever of the two it does not touch — in canvas coordinates.
    /// `nil` when they no longer form one (the zone shut under the hand): what the release will
    /// write is exactly what `isCrossfadePair` says of these two.
    func shadowedCrossfadeZone(_ a: UUID, _ b: UUID, shadow: CrossfadeShadow)
        -> (leftID: UUID, rightID: UUID, start: Double, end: Double, lane: Int)? {
        guard let x = shadow.objects[a] ?? viewModel.find(id: a),
              let y = shadow.objects[b] ?? viewModel.find(id: b),
              viewModel.isCrossfadePair(x, y) else { return nil }
        let (l, r) = x.startTime <= y.startTime ? (x, y) : (y, x)
        // The copies speak in the container's time; the canvas in absolute time — one offset, read
        // off the row the object is drawn on (the same conversion the spill's ghost makes).
        guard let e = viewModel.laneEntry(forID: l.id) else { return nil }
        let offset = e.absStart - e.item.startTime
        return (l.id, r.id, r.startTime + offset, l.startTime + l.duration + offset, e.displayLane)
    }

    /// The zones on screen while a crossfade drag is running: the model's, except the ones that
    /// touch an object of the gesture, which are read off the gesture's copies instead — the pairs
    /// the model holds around those objects (the zone as the hand found it, and its neighbours) and
    /// the pairs the gesture itself is driving.
    private func shadowedCrossfadeZones(
        model: [(leftID: UUID, rightID: UUID, start: Double, end: Double, lane: Int)],
        shadow: CrossfadeShadow, tracks: [CrossfadePairTrack])
        -> [(leftID: UUID, rightID: UUID, start: Double, end: Double, lane: Int)] {
        let ids = Set(shadow.order)
        var shown = model.filter { !ids.contains($0.leftID) && !ids.contains($0.rightID) }
        var candidates = viewModel.crossfadePairs(around: ids).map { ($0.left, $0.right) }
        for t in tracks { candidates.append((t.leftID, t.rightID)) }
        var seen = Set<Set<UUID>>()
        for (l, r) in candidates where seen.insert([l, r]).inserted {
            if let z = shadowedCrossfadeZone(l, r, shadow: shadow) { shown.append(z) }
        }
        return shown
    }

    /// The objects a gesture under way is RESHAPING — displacing or cropping — or `nil` when
    /// nothing is being reshaped. ⌥ copies rather than displaces, so its originals do not budge
    /// and neither do their zones.
    var reshapingDragIDs: Set<UUID>? {
        if let md = moveDrag, !md.isAltCopy, md.dt != 0 || md.dl != 0 { return md.ids }
        if let td = trimDrag,   td.dStart != 0 { return td.ids }
        if let rd = resizeDrag, rd.dDur   != 0 { return rd.ids }
        return nil
    }

    /// Where an object is being DRAWN and how long it is being drawn: its display row, its
    /// absolute time and its length, with the gesture's travel already added when it is one of the
    /// objects under the hand. The container is the one it is still in — neither a move nor a crop
    /// changes a parent.
    func dragPlacement(_ id: UUID) -> EditViewModel.Placement? {
        guard let e = viewModel.laneEntry(forID: id) else { return nil }
        var p: EditViewModel.Placement = (e.absStart, e.item.duration, e.displayLane, e.parentID)
        if let md = moveDrag, !md.isAltCopy, md.ids.contains(id) {
            p.start += md.dt
            p.lane   = max(0, p.lane + md.dl)
        }
        // A trim pins the END and moves the start; a resize pins the start and moves the end. Both
        // of them shift an edge, which is all a zone is made of.
        if let td = trimDrag, td.ids.contains(id) {
            p.start    += td.dStart
            p.duration -= td.dStart
        }
        if let rd = resizeDrag, rd.ids.contains(id) {
            p.duration += rd.dDur
        }
        return p
    }

    /// The fade a gesture under way is on its way to leave on one edge of `id` — the new zone's
    /// width while the pair survives, 0 the moment the gesture breaks it, `nil` when nothing being
    /// moved or cropped touches a zone of its.
    ///
    /// The X alone would not have been enough: a zone narrowed to half its width inside two veils
    /// still wearing their old one is a picture that contradicts itself. An edge engaged in a
    /// crossfade has no fade length of its own — the zone commands it — so when the zone follows
    /// the hand, the two veils follow with it.
    func reshapedCrossfadeFade(for id: UUID, side: FadeSide) -> Double? {
        guard let ids = reshapingDragIDs else { return nil }
        let onRight = side == .out
        // The partner IS the neighbour that forms a zone (@see EditViewModel.crossfadePartners):
        // read in O(1) where `seamNeighbour` + `crossfadeZone` walked every sibling, per block and
        // per frame — two thirds of a 600-object drag.
        guard let partners = viewModel.crossfadePartners(of: id),
              let n = onRight ? partners.right : partners.left,
              // The gesture has to hold one of the two, otherwise this pair is none of its
              // business — and every crossfade on screen would leave the batched canvas for the
              // duration of any drag at all.
              ids.contains(id) || ids.contains(n) else { return nil }
        guard let z = viewModel.projectedCrossfade(leftID: onRight ? id : n,
                                                   rightID: onRight ? n : id,
                                                   placement: dragPlacement) else { return 0 }
        return z.end - z.start
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
        // `seamSpill` answers nil for every id while the edge has not moved: asked once here, the
        // blocks layer's pass (which asks every visible block) no longer walks `fd.ids` for each.
        guard let fd = fadeDrag, fd.dEdge != 0 else { return nil }
        for held in fd.ids {
            guard let sp = seamSpill(fd, for: held),
                  held == id || sp.neighbour == id else { continue }
            let pair = fd.side == .out ? (held, sp.neighbour) : (sp.neighbour, held)
            guard case .success(let plan) = viewModel.plannedCrossfade(leftID: pair.0,
                                                                      rightID: pair.1,
                                                                      width: sp.width,
                                                                      anchor: sp.anchor,
                                                                      approach: sp.approach)
            else { return nil }
            return (plan, plan.leftID == id)
        }
        return nil
    }

    /// What a fade pulled outwards is asking of its seam, for one of the objects the gesture
    /// holds: the neighbour, the width of the zone it would open, the gap it is crossing to get
    /// there, and the edge the zone is built FROM. `nil` while the edge has not REACHED the
    /// neighbour — it is then a plain
    /// extension and nothing else, which is the whole difference between closing a gap and making
    /// a crossfade. One reading, so the preview and the commit cannot disagree about which of the
    /// two is happening.
    func seamSpill(_ fd: FadeDragState, for id: UUID)
        -> (neighbour: UUID, width: Double, approach: EditViewModel.SeamApproach,
            anchor: EditViewModel.ZonePin?)? {
        guard fd.dEdge != 0, let n = fd.seamNeighbours[id] else { return nil }
        let gap  = fd.seamGaps[id] ?? 0
        let over = abs(fd.dEdge) - gap
        guard over > EditViewModel.seamEpsilon else { return nil }
        // The zone is built FROM the fade the hand is pulling, and not shared out between the two
        // edges. The NEIGHBOUR's facing edge is where the zone is anchored — it does not move at
        // all — so the whole travel happens on the side the hand is on, and the fade one lets go
        // of is exactly as long as the one one drew. Shared out, half of that travel went into
        // backing the neighbour up, and the fade came out half the length the hand had given it.
        // An anchor and not a pin: where the pulled side has no file left, the clamp still takes
        // the difference out of the neighbour rather than stopping the gesture dead
        // (@see EditViewModel.openCrossfade).
        var anchor: EditViewModel.ZonePin? = nil
        if let other = viewModel.find(id: n) {
            anchor = fd.side == .out ? EditViewModel.ZonePin.start(other.startTime)
                                     : EditViewModel.ZonePin.end(other.startTime + other.duration)
        }
        return (n, (fd.zoneAnchors[id] ?? 0) + over,
                gap > 0 ? (fd.side == .out ? .leftGrows(gap) : .rightGrows(gap)) : .none,
                anchor)
    }

    /// The curve a spill is about to lay on ONE of the two sides of the X — the same rule as the
    /// commit, so the preview cannot promise another shape.
    ///
    /// The fade the hand is pulling keeps exactly what it drew, its own starting bend included: it
    /// is the source, and straightening it because the hand happened not to leave the row would be
    /// throwing away a shape nobody asked to lose. The facing one is its MIRROR — the reflection
    /// through the diagonal (@see FadeCurve.mirrored) — so the two halves of the X hand over to
    /// one another instead of both hanging back or both coming forward.
    func spillCurve(isLeft: Bool) -> FadeCurve {
        guard let fd = fadeDrag else { return .linear }
        let drawn = fd.curve(for: fd.grabbedID)
        // A fade-OUT pulled is the LEFT object's; a fade-in pulled is the right one's.
        return (fd.side == .out) == isLeft ? drawn : drawn.mirrored
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
        guard let fd = fadeDrag,
              let sp = seamSpill(fd, for: fd.grabbedID),
              let entry = viewModel.laneEntries.first(where: { $0.item.id == fd.grabbedID })
        else { return nil }
        let pair = fd.side == .out ? (fd.grabbedID, sp.neighbour) : (sp.neighbour, fd.grabbedID)
        guard case .success(let plan) = viewModel.plannedCrossfade(leftID: pair.0, rightID: pair.1,
                                                                  width: sp.width,
                                                                  anchor: sp.anchor,
                                                                  approach: sp.approach),
              plan.width * pixelsPerSecond >= 1
        else { return nil }
        // The plan speaks in the container's time; the canvas in absolute time. One offset, read
        // off the row the gesture started on — the same conversion the rest of the canvas makes.
        let offset = entry.absStart - entry.item.startTime
        return (x: (plan.start + offset) * pixelsPerSecond,
                y: rulerHeight + Double(entry.displayLane) * laneStep,
                width: plan.width * pixelsPerSecond,
                outCurve: spillCurve(isLeft: true), inCurve: spillCurve(isLeft: false))
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
        // The zone as it is being DRAWN and not as the model holds it: while a move is displacing
        // one of the pair the shared span is already shrinking, and the punched-out base has to
        // shrink with it or the neighbour's waveform would go on being hidden under nothing.
        // The partners come from a cache built once per change of the model (@see
        // crossfadePartners): this runs for every block on every frame.
        let partners = viewModel.crossfadePartners(of: item.id)
        // A crossfade drag holds its objects in copies: a zone one of them belongs to is read off
        // those (@see shadowedCrossfadeZone), the others as before.
        let shadow = crossfadeDrag?.shadow
        func zoneWidthPx(_ l: UUID, _ r: UUID) -> Double? {
            if let shadow, shadow.objects[l] != nil || shadow.objects[r] != nil {
                return shadowedCrossfadeZone(l, r, shadow: shadow).map { ($0.end - $0.start) * pixelsPerSecond }
            }
            return viewModel.projectedCrossfade(leftID: l, rightID: r, placement: dragPlacement)
                .map { ($0.end - $0.start) * pixelsPerSecond }
        }
        if let n = partners?.left, let w = zoneWidthPx(n, item.id) { lead = w }
        if let n = partners?.right, let w = zoneWidthPx(item.id, n) { trail = w }
        // A spill under way: the zone it is about to lay down wins over the one the model still
        // holds, on that side only — the other end may carry a crossfade of its own.
        if let sp = spillPlan(for: item.id) {
            if sp.isLeft { trail = sp.plan.width * pixelsPerSecond }
            else         { lead  = sp.plan.width * pixelsPerSecond }
        }
        return (lead, trail)
    }
}
