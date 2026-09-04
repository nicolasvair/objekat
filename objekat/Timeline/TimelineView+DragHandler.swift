import SwiftUI

struct MoveDragState {
    var ids: Set<UUID>
    var anchors: [UUID: (start: Double, lane: Int)]
    var grabbedID: UUID
    var dt: Double
    var dl: Int
    var isAltCopy: Bool = false
    var altFragmentObjects: [SoundObject]? = nil
    var timeSelectionAnchor: TimeSelection? = nil
    var sourceGroupID: UUID? = nil
}

struct ResizeDragState {
    var ids: Set<UUID>
    /// `room` = the source content still available AFTER the right edge, in timeline seconds
    /// (@see SoundObject.contentRoomAfter — it allows for reverse, where the two margins swap).
    /// `.infinity` = no content constraint. `looping` = the object is looping
    /// (@see SoundObject.loopEnabled): beyond the edge it REPEATS, so a dedicated cursor rather
    /// than the small 'content left' arrows (@see [[loop-item-plan]]).
    var anchors: [UUID: (start: Double, duration: Double, room: Double, looping: Bool)]
    var grabbedID: UUID
    var dDur: Double = 0
}

struct TrimDragState {
    var ids: Set<UUID>
    /// `room` = the content available BEFORE the left edge (@see SoundObject.contentRoomBefore).
    var anchors: [UUID: (start: Double, duration: Double, room: Double)]
    var grabbedID: UUID
    var dStart: Double = 0
}

struct TimeSelectionDragState {
    var anchorTime: Double
    var anchorLane: Int
    var currentTime: Double
    var currentLane: Int
    var existingSelection: TimeSelection? = nil

    var selection: TimeSelection {
        let lo = min(anchorLane, currentLane)
        let hi = max(anchorLane, currentLane)
        var tLo     = min(anchorTime, currentTime)
        var tHi     = max(anchorTime, currentTime)
        var laneMin = lo
        var laneMax = hi
        if let existing = existingSelection {
            tLo     = min(tLo,     existing.timeRange.lowerBound)
            tHi     = max(tHi,     existing.timeRange.upperBound)
            laneMin = min(laneMin, existing.lanes.min() ?? lo)
            laneMax = max(laneMax, existing.lanes.max() ?? hi)
        }
        return TimeSelection(timeRange: tLo...tHi, lanes: Set(laneMin...laneMax))
    }
}

enum FadeSide { case `in`, out }

enum LoopMarkerSide { case start, end }

/// Dragging a loop IN/OUT marker (@see SoundObject.loopMarkerLocalRange, [[loop-item-plan]]).
/// One object at a time (no multiple selection — each object has its own pattern). The bounds are
/// in seconds LOCAL TO THE BLOCK; V1 scope: the travel stays within the object's current
/// [0, duration] (a CLIP loop point can go beyond that range through `object.set_loop_range`,
/// but not by dragging yet — @see ClipEditZone.resolve, the `loopInPx`/`loopOutPx` documentation).
struct LoopRangeDragState {
    var id: UUID
    var side: LoopMarkerSide
    var anchorStart: Double
    var anchorEnd: Double
    /// The V1 bound on the travel: the object's current [0, duration] — @see the type's documentation.
    var maxLocal: Double
    /// The block's ABSOLUTE start: the bounds live locally, while snapping reasons in timeline
    /// time (the grid plus object edges) — this is the bridge between the two.
    var absStart: Double
    var dDrag: Double = 0

    /// The bound grabbed, locally, at the gesture's anchor.
    var anchorLocal: Double { side == .start ? anchorStart : anchorEnd }

    var finalStart: Double {
        guard side == .start else { return anchorStart }
        return max(0, min(anchorStart + dDrag, anchorEnd - 0.01))
    }
    var finalEnd: Double {
        guard side == .end else { return anchorEnd }
        return max(anchorStart + 0.01, min(maxLocal, anchorEnd + dDrag))
    }
}

struct FadeDragState {
    var ids: Set<UUID>
    var grabbedID: UUID
    var side: FadeSide
    var anchorFade: Double
    var globalMaxFade: Double
    var dFade: Double = 0

    /// The starting geometry of the objects concerned: it serves to EXTEND the sound when the fade
    /// has been entirely absorbed and one goes on pulling outwards (see `handleCanvasDrag`).
    var edgeAnchors: [UUID: (start: Double, duration: Double)] = [:]
    /// The edge travel available (in seconds, always ≥ 0): the smallest source-content margin in
    /// the selection — the same stop as trim / resize.
    var edgeRoom: Double = 0
    /// The edge movement applied (negative = to the left for a fade in).
    var dEdge: Double = 0

    /// The ceiling follows the edge's extension: the block grows by `|dEdge|`, so the fade can
    /// take up as much.
    var finalFade: Double { max(0, min(anchorFade + dFade, globalMaxFade + abs(dEdge))) }
}

/// Cutting by dragging (the Cut tool): the gesture's direction decides which side is KEPT.
/// A plain click = a plain split; dragging right = keep the left; dragging left = keep the right.
struct CutDragState {
    var ids: [UUID]
    var grabbedID: UUID
    var cutTime: Double
    /// The current horizontal translation (px).
    var dx: Double = 0

    /// The dead travel before a drag becomes a directed cut.
    static let engageThreshold: Double = 8

    var keep: CutKeepSide? {
        guard abs(dx) >= Self.engageThreshold else { return nil }
        return dx > 0 ? .left : .right
    }
}

/// ⌥ dragging inside a time selection: it slips the CONTENT of the clips inside their window
/// — the bounds do not move, only the source offset changes.
struct SlipDragState {
    /// `reversed`: the content always follows the mouse, but a reversed clip reads its range
    /// backwards — to slip it the same way, its offset moves in the OPPOSITE direction.
    var anchors: [UUID: (sourceOffset: Double, speedRatio: Double, reversed: Bool)]
    var minDt: Double
    var maxDt: Double
    var dt: Double = 0
}

struct VolumeDragState {
    var ids: Set<UUID>
    var anchors: [UUID: Float]
    var grabbedID: UUID
}

struct PanDragState {
    var ids: Set<UUID>
    var anchors: [UUID: Float]
    var grabbedID: UUID
    var trackWidth: Double
}

struct SendDragState {
    var auxID: UUID
    var grabbedID: UUID            // the clip grabbed (it serves the visual focus)
    var anchors: [UUID: Float]     // objectID → the send level at the start of the drag
}

enum DragPhase { case changed, ended }

extension TimelineView {

    func handleCanvasDrag(_ value: DragGesture.Value, phase: DragPhase) {
        // End of gesture: the block has moved, been trimmed, cut or ungrouped — the remembered hover
        // points at the place it was BEFORE. `defer` so as to cover this function's many early
        // returns, and `async` so as to let the gesture finish writing the model before rereading
        // the geometry (@see refreshHover).
        defer {
            if phase == .ended {
                let p = value.location
                DispatchQueue.main.async { refreshHover(at: p) }
            }
        }

        // A drag STARTED in the ruler: the cursor follows the mouse, and nothing else moves (the same
        // contract as the click — see moveCursorFromRuler). Once it has set off from the ruler, the
        // gesture goes on scrubbing even if the mouse comes down into the lanes.
        if rulerBandContains(value.startLocation) {
            moveCursorFromRuler(atX: value.location.x)
            return
        }

        // With 's' held: the mouse only serves to compose what is heard (see handleCanvasTap). We
        // ignore the drag, otherwise a slightly shaky click would move an object — or draw a range —
        // while one is setting what one hears.
        if viewModel.soloKeyHeld { return }

        if viewModel.activeTool == .toolVolume {
            handleVolumeDrag(value, phase: phase)
            return
        }
        if viewModel.activeTool == .toolPan {
            handlePanDrag(value, phase: phase)
            return
        }
        if viewModel.activeTool == .toolAux {
            handleSendDrag(value, phase: phase)
            return
        }
        if viewModel.activeTool == .toolCut {
            handleCutDrag(value, phase: phase)
            return
        }
        guard viewModel.activeTool == .toolSelection else { return }

        // ── Initialising a new drag ───────────────────────────────────────────────
        if moveDrag == nil && resizeDrag == nil && trimDrag == nil
            && fadeDrag == nil && timeSelectionDrag == nil && slipDrag == nil && loopRangeDrag == nil {
            guard phase == .changed else { return }
            let p = value.startLocation
            guard p.y > rulerHeight else { return }
            // A drag started in an open piano roll → handled by PianoRollView (a rubber band / moving
            // notes); do not start a time selection on the canvas.
            if openPianoRollBandContains(p) { return }
            // The same inside an automation band: the canvas starts neither a time selection nor a move
            // there. At step 1 it has no gesture of its own yet — it is inert.
            if openAutomationBandContains(p) { return }
            // The hem sits in the LOWER half of the block, which is otherwise the `.move` zone:
            // without this guard, aiming at the selector would move the object.
            if automationBezelHit(at: p) != nil { return }

            // Hit-testing unified on viewModel.items (clips AND groups). An infinite bus has no
            // start/end: its clickable surface is its whole lane (0 → the content's width).
            let hitEntry = viewModel.laneEntries.first { e in
                let by = rulerHeight + Double(e.displayLane) * laneStep
                guard p.y >= by && p.y <= by + blockHeight else { return false }
                if e.item.isInfiniteBus {
                    return p.x >= 0 && p.x <= contentWidth
                }
                let bx = e.absStart * pixelsPerSecond
                let bw = max(e.item.duration * pixelsPerSecond, 2)
                return p.x >= bx && p.x <= bx + bw
            }
            let hitItem = hitEntry?.item

            // An infinite bus: clicking the band = selection only (no move or resize — it has neither
            // a start nor an end). ⇧ = adding to the selection, like a clip.
            if let inf = hitItem, inf.isInfiniteBus {
                let additive = NSEvent.modifierFlags.contains(.shift)
                if additive {
                    if viewModel.selectedIDs.contains(inf.id) { viewModel.selectedIDs.remove(inf.id) }
                    else { viewModel.selectedIDs.insert(inf.id) }
                } else if !viewModel.selectedIDs.contains(inf.id) {
                    viewModel.selectIDs([inf.id])
                }
                return
            }
            let hitAbsStart: Double = hitEntry?.absStart ?? 0
            let hitDL: Int = hitEntry?.displayLane ?? 0
            let hitSourceGroupID: UUID? = hitEntry?.parentID

            // The editing zone aimed at inside the block — the SAME carve-up as the hover and the double
            // click (`ClipEditZone.resolve`): a fade that is set is grabbed by its whole triangle.
            let hitZone: ClipEditZone? = hitItem.map { item in
                let bx     = hitAbsStart * pixelsPerSecond
                let bw     = max(item.duration * pixelsPerSecond, 2)
                let loopLocal = item.loopMarkerLocalRange
                let loopInPx  = loopLocal.flatMap { r -> Double? in
                    let px = r.start * pixelsPerSecond
                    return (0...bw).contains(px) ? px : nil
                }
                let loopOutPx = loopLocal.flatMap { r -> Double? in
                    let px = r.end * pixelsPerSecond
                    return (0...bw).contains(px) ? px : nil
                }
                return ClipEditZone.resolve(
                    localX: p.x - bx,
                    localY: p.y - (rulerHeight + Double(hitDL) * laneStep),
                    blockWidth: bw, blockHeight: blockHeight,
                    handleW: handleWidth(blockWidth: bw),
                    fadeInPx:  min(item.fadeIn  * pixelsPerSecond, bw),
                    fadeOutPx: min(item.fadeOut * pixelsPerSecond, bw),
                    loopInPx: loopInPx, loopOutPx: loopOutPx)
            }

            // TimeSelection: an empty canvas OR the top-centre zone of the hit
            let startsTimeSelection: Bool = hitZone.map { $0 == .timeSelect } ?? true

            if startsTimeSelection {
                let shift = NSEvent.modifierFlags.contains(.shift)
                let t0 = viewModel.snapTime(max(0, p.x / pixelsPerSecond))
                let l0 = max(0, Int((p.y - rulerHeight) / laneStep))
                // ⌥ on the RANGE itself — a bare canvas or a block's upper band, inside the
                // rectangle: it is the range one grabs, hence a slip. An object's body, on the other
                // hand, stays an object's body: ⌥ copies the object there, whether the range covers it
                // or not (@see further down). Without that, the gesture's nature depended on whether a
                // time selection existed instead of depending on what one grabs.
                if NSEvent.modifierFlags.contains(.option),
                   !NSEvent.modifierFlags.contains(.command),
                   beginSlipDrag(clips: slipGrab(at: p, zone: hitZone, item: hitItem)) {
                    return
                }
                var existingForDrag: TimeSelection? = nil
                if shift {
                    existingForDrag = viewModel.baseTimeSelection()
                    if existingForDrag != nil { viewModel.selectedIDs = [] }
                }
                var state = TimeSelectionDragState(
                    anchorTime: t0, anchorLane: l0,
                    currentTime: t0, currentLane: l0,
                    existingSelection: existingForDrag
                )
                let endX = p.x + value.translation.width
                let endY = p.y + value.translation.height
                state.currentTime = viewModel.snapTime(max(0, endX / pixelsPerSecond))
                state.currentLane = max(0, Int((endY - rulerHeight) / laneStep))
                viewModel.caretLane = nil
                viewModel.timeSelection = state.selection
                timeSelectionDrag = state
                return
            }

            guard let item = hitItem, let zone = hitZone else { return }

            let clickTime = max(0, p.x / pixelsPerSecond)

            // TimeSelection interaction (display lanes — top-level AND children of groups).
            if let sel = viewModel.timeSelection {
                let clickInRect = sel.lanes.contains(hitDL)
                    && clickTime >= sel.timeRange.lowerBound
                    && clickTime <= sel.timeRange.upperBound

                if clickInRect {
                    if zone == .move {
                        if hypot(value.translation.width, value.translation.height) < 5 { return }

                        let alt = NSEvent.modifierFlags.contains(.option)
                        let t1  = sel.timeRange.lowerBound
                        let t2  = sel.timeRange.upperBound

                        // A range that is set decides EVERYTHING one grabs inside it:
                        // without ⌥ it moves (cut plus lay down), with ⌥ it is COPIED — the original
                        // material stays in place, which is what tells a copy from a move. So ⌥ no
                        // longer copies the WHOLE object when the click falls inside the range: outside
                        // it (the common case), it still does.
                        // The slip keeps a grip of its own: the UPPER band (@see slipGrab).
                        if alt {
                            // A copy: recursive fragments (clips, groups, children),
                            // an absolute startTime plus lane = the display lane (the clipboard convention).
                            let fragments = viewModel.makeTimeSelectionFragments(
                                lo: t1, hi: t2, lanes: sel.lanes)
                            guard !fragments.isEmpty else { return }
                            viewModel.pushUndo()

                            let grabbed = fragments.first { frag in
                                frag.lane == hitDL
                                && frag.startTime <= clickTime
                                && clickTime <= frag.startTime + frag.duration
                            } ?? fragments[0]

                            let anchors = Dictionary(uniqueKeysWithValues:
                                fragments.map { ($0.id, (start: $0.startTime, lane: $0.lane)) }
                            )
                            moveDrag = MoveDragState(
                                ids: Set(fragments.map(\.id)),
                                anchors: anchors,
                                grabbedID: grabbed.id,
                                dt: 0, dl: 0,
                                isAltCopy: true,
                                altFragmentObjects: fragments,
                                timeSelectionAnchor: sel
                            )
                        } else {
                            // A move: nothing to do if the range covers nothing.
                            let hasOverlap = viewModel.laneEntries.contains { e in
                                sel.lanes.contains(e.displayLane)
                                    && e.absStart < t2
                                    && e.absStart + e.item.duration > t1
                            }
                            guard hasOverlap else { return }

                            viewModel.pushUndo()
                            let inside = viewModel.prepareTimeSelectionTranslate(sel)
                            guard !inside.isEmpty else {
                                _ = viewModel.undoStack.popLast()
                                return
                            }
                            viewModel.selectedIDs = Set(inside.map(\.item.id))

                            let grabbed = inside.first { e in
                                e.displayLane == hitDL
                                && e.absStart <= clickTime
                                && clickTime <= e.absStart + e.item.duration
                            } ?? inside[0]

                            // lane = the original DISPLAY lane: the final placement is done
                            // cut/paste style through placeClip (moveTranslatedItems).
                            let anchors = Dictionary(uniqueKeysWithValues:
                                inside.map { ($0.item.id, (start: $0.absStart, lane: $0.displayLane)) }
                            )
                            moveDrag = MoveDragState(
                                ids: Set(inside.map(\.item.id)),
                                anchors: anchors,
                                grabbedID: grabbed.item.id,
                                dt: 0, dl: 0,
                                timeSelectionAnchor: sel
                            )
                        }
                        return
                    } else {
                        selectInDisplayLanes(sel)
                    }
                } else {
                    viewModel.timeSelection = nil
                }
            }

            switch zone {
            case .fadeIn, .fadeOut:
                if !viewModel.selectedIDs.contains(item.id) {
                    viewModel.select(item.id, additive: false)
                }
                // Fade/trim/resize: operations independent per clip → the whole
                // selection, as at top level (children of groups included).
                let ids: Set<UUID> = viewModel.selectedIDs.union([item.id])
                let objs = ids.compactMap { viewModel.find(id: $0) }
                let globalMaxFade = objs.map(\.duration).min() ?? item.duration
                let side: FadeSide = zone == .fadeIn ? .in : .out
                // The source-content margin available beyond the edge: once the fade is absorbed, going on
                // pulling outwards EXTENDS the sound (the same stops as trim/resize).
                let room = objs.map { obj -> Double in
                    side == .in ? min(obj.startTime, obj.contentRoomBefore)
                                : obj.contentRoomAfter
                }.min() ?? 0
                fadeDrag = FadeDragState(
                    ids: ids, grabbedID: item.id, side: side,
                    anchorFade: side == .in ? item.fadeIn : item.fadeOut,
                    globalMaxFade: globalMaxFade,
                    edgeAnchors: Dictionary(uniqueKeysWithValues:
                        objs.map { ($0.id, (start: $0.startTime, duration: $0.duration)) }),
                    edgeRoom: max(0, room)
                )

            case .trimLeft:
                if !viewModel.selectedIDs.contains(item.id) {
                    viewModel.select(item.id, additive: false)
                }
                let ids: Set<UUID> = viewModel.selectedIDs.union([item.id])
                let anchors = Dictionary(uniqueKeysWithValues:
                    ids.compactMap { viewModel.find(id: $0) }.map { obj in
                        // A group / aux / MIDI: no source content → `.infinity`, hence
                        // minDStart = -startTime (@see SoundObject.contentRoomBefore).
                        (obj.id, (start: obj.startTime, duration: obj.duration,
                                  room: obj.contentRoomBefore))
                    }
                )
                trimDrag = TrimDragState(ids: ids, anchors: anchors, grabbedID: item.id)

            case .resizeRight:
                if !viewModel.selectedIDs.contains(item.id) {
                    viewModel.select(item.id, additive: false)
                }
                let ids: Set<UUID> = viewModel.selectedIDs.union([item.id])
                let anchors = Dictionary(uniqueKeysWithValues:
                    ids.compactMap { viewModel.find(id: $0) }.map { obj in
                        (obj.id, (start: obj.startTime, duration: obj.duration,
                                  room: obj.contentRoomAfter, looping: obj.loopEnabled))
                    }
                )
                resizeDrag = ResizeDragState(ids: ids, anchors: anchors, grabbedID: item.id)

            case .timeSelect:
                return   // already handled above (startsTimeSelection)

            case .loopIn, .loopOut:
                if !viewModel.selectedIDs.contains(item.id) {
                    viewModel.select(item.id, additive: false)
                }
                guard let local = item.loopMarkerLocalRange else { return }
                loopRangeDrag = LoopRangeDragState(
                    id: item.id, side: zone == .loopIn ? .start : .end,
                    anchorStart: local.start, anchorEnd: local.end, maxLocal: item.duration,
                    absStart: hitAbsStart)

            case .move:
                let alt = NSEvent.modifierFlags.contains(.option)
                if !viewModel.selectedIDs.contains(item.id) {
                    viewModel.select(item.id, additive: false)
                }
                let ids: Set<UUID>
                if let sgID = hitSourceGroupID {
                    // Selected children of the SAME source group: it preserves the sourceGroupID
                    // invariant of the reparent/eject/move-in-group functions downstream.
                    ids = viewModel.selectedIDs
                        .filter { viewModel.parentGroup(for: $0)?.id == sgID }
                        .union([item.id])
                } else {
                    ids = viewModel.effectiveSelectedIDs.union([item.id])
                }
                let anchors = Dictionary(uniqueKeysWithValues:
                    ids.compactMap { viewModel.find(id: $0) }
                        .map { ($0.id, (start: $0.startTime, lane: $0.lane)) }
                )
                moveDrag = MoveDragState(ids: ids, anchors: anchors,
                                         grabbedID: item.id, dt: 0, dl: 0,
                                         isAltCopy: alt,
                                         sourceGroupID: hitSourceGroupID)
            }
        }

        // ── TimeSelection drag ────────────────────────────────────────────────────
        if var state = timeSelectionDrag {
            let endX = value.startLocation.x + value.translation.width
            let endY = value.startLocation.y + value.translation.height
            state.currentTime = viewModel.snapTime(max(0, endX / pixelsPerSecond))
            state.currentLane = max(0, Int((endY - rulerHeight) / laneStep))
            viewModel.caretLane = nil

            if phase == .ended {
                viewModel.timeSelection = state.selection
                selectInDisplayLanes(state.selection)
                onMoveCursor(max(0, state.selection.timeRange.lowerBound))
                timeSelectionDrag = nil
            } else {
                viewModel.timeSelection = state.selection
                timeSelectionDrag = state
            }
            return
        }

        // ── Slip (⌥ inside a time selection) ─────────────────────────────────────
        // The content slides INSIDE the clips' window: startTime/length unchanged, only the
        // source offset moves. Applied live so that the waveform follows the hand.
        if var state = slipDrag {
            let rawDt = Double(value.translation.width) / pixelsPerSecond
            state.dt = max(state.minDt, min(state.maxDt, rawDt))
            for (id, a) in state.anchors {
                // The content follows the mouse; in reverse, the source range moves the other way
                // to achieve that (it is read from its end towards its start).
                viewModel.setSourceOffset(id: id,
                                          to: a.sourceOffset + (a.reversed ? 1 : -1) * state.dt * a.speedRatio)
            }
            if phase == .ended {
                // A null gesture (⌥ plus a micro-movement): do not leave an empty undo on the stack.
                if state.dt == 0 { _ = viewModel.undoStack.popLast() }
                slipDrag = nil
            } else {
                slipDrag = state
            }
            return
        }

        // ── Fade ─────────────────────────────────────────────────────────────────
        // Inwards: the fade grows. Outwards: it is absorbed first, then — past a dead travel of
        // `fadeEdgeDeadZonePx` that guarantees one can always set a fade to exactly zero — the EDGE
        // follows the hand and extends the sound, with the same source-content stops as trim and
        // resize.
        if var state = fadeDrag {
            let rawDx    = Double(value.translation.width) / pixelsPerSecond
            let deadZone = Self.fadeEdgeDeadZonePx / pixelsPerSecond
            let outward  = state.side == .in ? -rawDx : rawDx   // the travel outwards from the block
            if outward <= 0 {
                state.dFade = -outward
                state.dEdge = 0
            } else {
                let consumed  = min(state.anchorFade, outward)
                let overshoot = min(max(0, outward - consumed - deadZone), state.edgeRoom)
                // The sound gained by the extension is FADED over its whole length: the point where the
                // sound reaches full level does not move, only the material revealed before it is added
                // — the gesture lengthens the fade instead of sticking a hard edge on.
                state.dFade = -consumed + overshoot
                state.dEdge = state.side == .in ? -overshoot : overshoot
            }

            if phase == .ended {
                viewModel.pushUndo()
                let final = state.finalFade
                for id in state.ids {
                    if state.dEdge != 0, let a = state.edgeAnchors[id] {
                        switch state.side {
                        case .in:  viewModel.updateTrim(id: id,
                                                        newStart: a.start + state.dEdge,
                                                        newDuration: a.duration - state.dEdge)
                        case .out: viewModel.updateDuration(id: id, duration: a.duration + state.dEdge)
                        }
                    }
                    switch state.side {
                    case .in:  viewModel.updateFadeIn(id: id, fadeIn: final)
                    case .out: viewModel.updateFadeOut(id: id, fadeOut: final)
                    }
                }
                if state.dEdge != 0 {
                    for id in state.ids { viewModel.resolveOverlaps(for: id) }
                }
                fadeDrag = nil
            } else {
                fadeDrag = state
            }
            return
        }

        // ── Loop IN/OUT marker ───────────────────────────────────────────────────
        if var state = loopRangeDrag {
            let rawDt = Double(value.translation.width) / pixelsPerSecond
            // Snapping: a marker lands like a block edge — the same grid, the same object edges, the same
            // visual guide. `snapTime` reasons in TIMELINE time while the bounds live local to the block,
            // hence the round trip through `absStart`. Nothing is excluded from the snap: hooking the OUT
            // onto the right edge of its own block is precisely useful.
            let snappedAbs = viewModel.snapTime(state.absStart + state.anchorLocal + rawDt)
            state.dDrag = snappedAbs - state.absStart - state.anchorLocal
            TimelineCursorKeeper.set(NSCursor.resizeLeftRight)

            if phase == .ended {
                viewModel.objectSnapGuide = nil
                viewModel.pushUndo()
                let (s, e) = (state.finalStart, state.finalEnd)
                if e > s, let obj = viewModel.find(id: state.id) {
                    let stored = obj.loopRangeFromLocal(start: s, end: e)
                    viewModel.updateLoopRange(id: state.id, start: stored.start, end: stored.end)
                } else {
                    _ = viewModel.undoStack.popLast()
                }
                loopRangeDrag = nil
            } else {
                loopRangeDrag = state
            }
            return
        }

        // ── Right resize ──────────────────────────────────────────────────────────
        if var state = resizeDrag {
            let grabbed = state.anchors[state.grabbedID]!
            let rawDt   = Double(value.translation.width) / pixelsPerSecond
            let snappedEnd = viewModel.snapTime(grabbed.start + grabbed.duration + rawDt,
                                                excluding: Set(state.anchors.keys))
            var dDur = snappedEnd - grabbed.start - grabbed.duration

            let minDDur = state.anchors.values.map { 0.01 - $0.duration }.max() ?? -.infinity
            // The source content available beyond the right edge, as a timeline length.
            let maxDDur = state.anchors.values.map(\.room).min() ?? .infinity
            dDur = max(minDDur, min(maxDDur, dDur))
            state.dDur = dDur
            // The cursor says live how much travel is left on each side — or, while looping, that the
            // travel is unbounded and REPEATS instead of revealing new content.
            if grabbed.looping {
                TimelineCursorKeeper.set(TimelineCursors.loopEdge(open: false))
            } else {
                setEdgeCursor(open: false, room: (dDur - minDDur, maxDDur - dDur))
            }

            if phase == .ended {
                viewModel.objectSnapGuide = nil
                viewModel.pushUndo()
                for (id, anchor) in state.anchors {
                    viewModel.updateDuration(id: id, duration: anchor.duration + dDur)
                }
                for id in state.anchors.keys { viewModel.resolveOverlaps(for: id) }
                resizeDrag = nil
            } else {
                resizeDrag = state
            }
            return
        }

        // ── Left trim ─────────────────────────────────────────────────────────────
        if var state = trimDrag {
            let grabbed = state.anchors[state.grabbedID]!
            let rawDt   = Double(value.translation.width) / pixelsPerSecond
            let snappedStart = viewModel.snapTime(grabbed.start + rawDt,
                                                  excluding: Set(state.anchors.keys))
            var dStart = snappedStart - grabbed.start

            // The left limit: timeline 0, and the end of the source content available before the edge.
            let minDStart: Double = state.anchors.values.map { max(-$0.start, -$0.room) }.max() ?? -.infinity
            let maxDStart = state.anchors.values.map { $0.duration - 0.01 }.min() ?? .infinity
            dStart = max(minDStart, min(maxDStart, dStart))
            state.dStart = dStart
            setEdgeCursor(open: true, room: (dStart - minDStart, maxDStart - dStart))

            if phase == .ended {
                viewModel.objectSnapGuide = nil
                viewModel.pushUndo()
                for (id, anchor) in state.anchors {
                    viewModel.updateTrim(id: id,
                                        newStart: anchor.start + dStart,
                                        newDuration: anchor.duration - dStart)
                }
                for id in state.anchors.keys { viewModel.resolveOverlaps(for: id) }
                trimDrag = nil
            } else {
                trimDrag = state
            }
            return
        }

        // ── Move ──────────────────────────────────────────────────────────────────
        guard var state = moveDrag, let grabbedAnchor = state.anchors[state.grabbedID]
        else { return }

        // ⌥ reread on EVERY frame (not only at the start): it allows flipping move/copy during the
        // gesture. Drags that come from a TimeSelection prepare their state (fragments, slip)
        // according to ⌥⌘ AT THE START — we do not touch it, and isAltCopy stays frozen there.
        if state.timeSelectionAnchor == nil {
            state.isAltCopy = NSEvent.modifierFlags.contains(.option)
        }

        let rawDt = Double(value.translation.width) / pixelsPerSecond
        let rawDl = Int((Double(value.translation.height) / laneStep).rounded())

        let grabbedDur = viewModel.find(id: state.grabbedID)?.duration ?? 0
        let rawStart   = grabbedAnchor.start + rawDt
        let clipEndRaw = rawStart + grabbedDur
        let excl       = Set(state.anchors.keys)

        let candStart  = viewModel.snapTime(rawStart,   excluding: excl)
        let guideStart = viewModel.objectSnapGuide
        let candEnd    = viewModel.snapTime(clipEndRaw, excluding: excl)
        let guideEnd   = viewModel.objectSnapGuide

        let useEnd       = abs(candEnd - clipEndRaw) < abs(candStart - rawStart)
        let snappedStart = useEnd ? candEnd - grabbedDur : candStart
        viewModel.objectSnapGuide = useEnd ? guideEnd : guideStart

        var dt = snappedStart - grabbedAnchor.start
        var dl = rawDl

        let minStart = state.anchors.values.map { $0.start }.min() ?? 0
        dt = max(dt, -minStart)
        // dl is a DISPLAY lane delta: clamped in display space (not in base lanes, otherwise it
        // would be impossible to climb above the children of an expanded group).
        if state.timeSelectionAnchor != nil {
            // Translate: the anchors already store DISPLAY lanes.
            let minDisplayLane = state.anchors.values.map(\.lane).min() ?? 0
            dl = max(dl, -minDisplayLane)
        } else if state.sourceGroupID == nil {
            let minDisplayLane = state.anchors
                .filter { viewModel.parentGroup(for: $0.key) == nil }
                .map { displayLane(for: $0.value.lane) }
                .min() ?? 0
            dl = max(dl, -minDisplayLane)
        }

        state.dt = dt
        state.dl = dl

        if let anchor = state.timeSelectionAnchor {
            viewModel.caretLane = nil
            viewModel.timeSelection = TimeSelection(
                timeRange: (anchor.timeRange.lowerBound + dt)...(anchor.timeRange.upperBound + dt),
                lanes: Set(anchor.lanes.map { $0 + dl })
            )
        }

        if phase == .ended {
            viewModel.objectSnapGuide = nil

            let grabbedFinalAbsDL: Int
            if let sgID = state.sourceGroupID,
               let sgDL = viewModel.laneEntries.first(where: { $0.item.id == sgID })?.displayLane {
                grabbedFinalAbsDL = sgDL + 1 + grabbedAnchor.lane + dl
            } else {
                grabbedFinalAbsDL = displayLane(for: grabbedAnchor.lane) + dl
            }
            // dl is in display space; dActual converts to the real lanes
            let dActual: Int = state.sourceGroupID == nil
                ? (viewModel.laneEntries.first { $0.displayLane == max(0, grabbedFinalAbsDL) }?.item.lane ?? viewModel.baseLaneForDisplay(max(0, grabbedFinalAbsDL))) - grabbedAnchor.lane
                : dl

            // The target group = the INNERMOST expanded group whose child range holds the drop's
            // display lane. It allows clips AND groups; it rules out any group that would be
            // itself/a descendant of a moved object (the cycle guard).
            let groupDropEntry: LaneEntry? = (!state.isAltCopy || state.sourceGroupID != nil)
                && state.timeSelectionAnchor == nil
                ? viewModel.laneEntries
                    .filter { e in
                        guard e.item.showsChildrenInline,
                              !state.ids.contains(where: { viewModel.isSelfOrDescendant(e.item.id, of: $0) })
                        else { return false }
                        let cl = grabbedFinalAbsDL - e.displayLane - 1
                        return cl >= 0 && cl < e.item.childLaneCount
                    }
                    .max(by: { $0.displayLane < $1.displayLane })   // the INNERMOST one
                : nil
            let groupDropTarget = groupDropEntry?.item

            // A drop onto a moved group's own subtree (a zone the cycle guard rules out):
            // cancel the movement rather than route it to a bogus lane.
            // (Not for the translate: moveTranslatedItems has its own cycle guard.)
            let droppedOnOwnSubtree = state.timeSelectionAnchor == nil
                && groupDropTarget == nil && viewModel.laneEntries.contains { e in
                guard e.item.showsChildrenInline,
                      state.ids.contains(where: { viewModel.isSelfOrDescendant(e.item.id, of: $0) })
                else { return false }
                let cl = grabbedFinalAbsDL - e.displayLane - 1
                return cl >= 0 && cl < e.item.childLaneCount
            }
            if droppedOnOwnSubtree {
                viewModel.objectSnapGuide = nil
                moveDrag = nil
                return
            }

            if let sgID = state.sourceGroupID {
                viewModel.pushUndo()
                let newRelLane = grabbedAnchor.lane + dl

                if state.isAltCopy {
                    if let target = groupDropTarget, target.id != sgID {
                        let gDL = groupDropEntry!.displayLane
                        viewModel.selectedIDs = viewModel.altReparentChildBetweenGroups(
                            childIDs: state.ids, sourceGroupID: sgID, targetGroupID: target.id,
                            anchors: state.anchors, grabbedID: state.grabbedID,
                            grabbedChildLane: grabbedFinalAbsDL - gDL - 1, dt: dt)
                    } else if let sg = viewModel.find(id: sgID),
                              (newRelLane < 0 || newRelLane >= sg.childLaneCount) && groupDropTarget == nil {
                        let baseLane = viewModel.laneEntries.first { $0.displayLane == max(0, grabbedFinalAbsDL) }?.item.lane ?? viewModel.baseLaneForDisplay(max(0, grabbedFinalAbsDL))
                        viewModel.selectedIDs = viewModel.altEjectFromGroup(
                            childIDs: state.ids, groupID: sgID,
                            anchors: state.anchors, grabbedID: state.grabbedID,
                            dt: dt, baseLane: baseLane)
                    } else {
                        viewModel.selectedIDs = viewModel.altCopyChildrenInGroup(
                            childIDs: state.ids, groupID: sgID,
                            anchors: state.anchors, grabbedID: state.grabbedID,
                            dt: dt, dl: dl)
                    }
                } else {
                    if let target = groupDropTarget, target.id != sgID {
                        let gDL = groupDropEntry!.displayLane
                        viewModel.reparentChildBetweenGroups(
                            childIDs: state.ids, sourceGroupID: sgID, targetGroupID: target.id,
                            anchors: state.anchors, grabbedID: state.grabbedID,
                            grabbedChildLane: grabbedFinalAbsDL - gDL - 1, dt: dt)
                    } else if let sg = viewModel.find(id: sgID),
                              (newRelLane < 0 || newRelLane >= sg.childLaneCount) && groupDropTarget == nil {
                        let baseLane = viewModel.laneEntries.first { $0.displayLane == max(0, grabbedFinalAbsDL) }?.item.lane ?? viewModel.baseLaneForDisplay(max(0, grabbedFinalAbsDL))
                        viewModel.ejectFromGroup(
                            childIDs: state.ids, groupID: sgID,
                            anchors: state.anchors, grabbedID: state.grabbedID, dt: dt,
                            baseLane: baseLane)
                    } else {
                        for (id, anchor) in state.anchors {
                            let newStart = max(0, anchor.start + dt)
                            viewModel.update(id: id) { item in
                                let d = newStart - item.startTime
                                item.startTime = newStart
                                if case .group(var children, let isExpanded) = item.kind, d != 0 {
                                    EditViewModel.shiftStartTimes(&children, by: d)
                                    item.kind = .group(children: children, isExpanded: isExpanded)
                                }
                            }
                            viewModel.updateLane(id: id, lane: max(0, anchor.lane + dl))
                            if let obj = viewModel.find(id: id) { viewModel.syncPosition(obj) }
                        }
                        for id in state.anchors.keys { viewModel.resolveOverlaps(for: id) }
                    }
                }
            } else if let group = groupDropTarget {
                let gDL = groupDropEntry!.displayLane
                viewModel.pushUndo()
                viewModel.reparentToGroup(
                    clipIDs: state.ids, groupID: group.id,
                    anchors: state.anchors, grabbedID: state.grabbedID,
                    grabbedChildLane: grabbedFinalAbsDL - gDL - 1, dt: dt)
            } else if state.isAltCopy {
                if state.timeSelectionAnchor == nil { viewModel.pushUndo() }
                if let frags = state.altFragmentObjects {
                    // Translate-alt fragments: an absolute startTime, lane = the display lane
                    // → placement through placeClip (top-level OR the target expanded group).
                    viewModel.selectedIDs = viewModel.placeTranslatedFragments(frags, dt: dt, dl: dl)
                } else {
                    var copies: [SoundObject] = []
                    for (id, anchor) in state.anchors {
                        guard let obj = viewModel.find(id: id) else { continue }
                        copies.append(viewModel.makeAltCopy(obj,
                                                            startTime: anchor.start + dt,
                                                            lane: max(0, anchor.lane + dActual)))
                    }
                    for obj in copies { viewModel.add(obj) }
                    for obj in copies where { if case .clip = obj.kind { return true }; return false }() {
                        viewModel.resolveOverlaps(for: obj.id)
                    }
                    viewModel.selectedIDs = Set(copies.map(\.id))
                }
            } else if state.timeSelectionAnchor != nil {
                // Translate: the final placement cut/paste style (display lanes, placeClip)
                // — it changes lane, enters a group or leaves one freely.
                viewModel.moveTranslatedItems(state.anchors, dt: dt, dl: dl)
            } else {
                viewModel.pushUndo()
                for (id, anchor) in state.anchors {
                    viewModel.updateStartTime(id: id, newStart: anchor.start + dt)
                    viewModel.updateLane(id: id, lane: max(0, anchor.lane + dActual))
                }
                for id in state.anchors.keys { viewModel.resolveOverlaps(for: id) }
            }
            moveDrag = nil
        } else {
            moveDrag = state
        }
    }

    /// Refreshes the edge cursor during a drag: the hover no longer produces an event once the
    /// button is down, so it is here that the arrows go out when a stop is reached. `room` = the
    /// travel still possible (left, right), in seconds.
    func setEdgeCursor(open: Bool, room: (left: Double, right: Double)) {
        let eps = max(0.001, 0.5 / max(pixelsPerSecond, 1))
        TimelineCursorKeeper.set(TimelineCursors.edge(open: open,
                                                      canLeft: room.left > eps,
                                                      canRight: room.right > eps))
    }

    // MARK: - Slip (⌥ on the upper band: a time selection OR a block's upper half)

    /// The clips an ⌥ plus a drag would SLIP from `point` — empty if the gesture would do
    /// something else there. A single definition for the CURSOR and for the GESTURE, the same
    /// principle as `ClipEditZone.resolve`: the ↔ never shows where the drag would not slip, and
    /// that is what makes the mode readable before engaging the hand.
    /// `zone` / `item`: the editing zone resolved under the point and the block carrying it (both
    /// nil on the bare canvas).
    func slipGrab(at point: CGPoint, zone: ClipEditZone?, item: SoundObject?) -> [SoundObject] {
        // The WINDOW is grabbed on the bare canvas or on a block's upper band; the lower half
        // belongs to the object, where ⌥ copies.
        guard zone == nil || zone == .timeSelect else { return [] }
        let dl = max(0, Int((point.y - rulerHeight) / laneStep))
        let t  = max(0, point.x / pixelsPerSecond)
        // A time selection under the point: THAT is the window — the slip covers everything it
        // covers, over all its lanes.
        if let sel = viewModel.timeSelection, sel.lanes.contains(dl),
           t >= sel.timeRange.lowerBound, t <= sel.timeRange.upperBound {
            return viewModel.slippableClips(inLanes: sel.lanes,
                                            from: sel.timeRange.lowerBound,
                                            to: sel.timeRange.upperBound)
        }
        // Outside the range (or with no range at all): it is the GRABBED BLOCK that acts as the window.
        // So slipping needs NO prior selection — an object's upper band is enough, and that is the
        // common case. If the object is part of the object selection, the whole selection slips with
        // it, like trim / fade / resize.
        guard let item else { return [] }
        let ids: Set<UUID> = viewModel.selectedIDs.contains(item.id)
            ? viewModel.selectedIDs : [item.id]
        var seen = Set<UUID>()
        return ids.compactMap { viewModel.find(id: $0) }
            .flatMap { viewModel.slippableClips(in: $0) }
            .filter { seen.insert($0.id).inserted }   // a group AND its child selected
    }

    /// Arms the sliding of the CONTENT inside the window of `clips` (the blocks' bounds unchanged,
    /// only the source offset moves — @see slipGrab for what names them). It returns false if
    /// nothing can be slipped: the caller then resumes its normal course (drawing a new range).
    /// The gesture is taken on the UPPER band: a bare canvas or a block's upper half. ⌥ on an
    /// object's BODY is still a copy of that object — what one grabs decides.
    func beginSlipDrag(clips: [SoundObject]) -> Bool {
        guard !clips.isEmpty else { return false }
        viewModel.pushUndo()
        var anchors: [UUID: (sourceOffset: Double, speedRatio: Double, reversed: Bool)] = [:]
        var minDt = -Double.infinity
        var maxDt =  Double.infinity
        for c in clips {
            let sp = max(c.speedRatio, 0.0001)
            anchors[c.id] = (c.sourceOffset, sp, c.isReversed)
            // Pulling the content to the right consumes what is available BEFORE the left edge,
            // and the other way round — both margins already know how to swap in reverse
            // (@see contentRoomBefore/After).
            maxDt = min(maxDt, c.contentRoomBefore)
            minDt = max(minDt, -c.contentRoomAfter)
        }
        slipDrag = SlipDragState(anchors: anchors, minDt: minDt, maxDt: maxDt)
        return true
    }

    // MARK: - Preview helpers (clips and groups unified)

    func previewOffset(for object: SoundObject) -> (dx: Double, dy: Double)? {
        guard let md = moveDrag, md.ids.contains(object.id) else { return nil }
        if md.isAltCopy { return nil }
        return (md.dt * pixelsPerSecond, Double(md.dl) * laneStep)
    }

    var altDragGhosts: [(object: SoundObject, dx: Double, dy: Double)] {
        guard let md = moveDrag, md.isAltCopy else { return [] }
        let dx = md.dt * pixelsPerSecond
        let dragDy = Double(md.dl) * laneStep

        if let frags = md.altFragmentObjects {
            // frag.lane is a DISPLAY lane: lane 0 plus a Y carried by dy (as below),
            // otherwise soundBlock would convert the display lane into a display lane again.
            return frags.map { frag in
                var disp = frag
                disp.lane = 0
                if case .group(let children, _) = disp.kind {
                    disp.kind = .group(children: children, isExpanded: false)
                }
                return (disp, dx, Double(frag.lane) * laneStep + dragDy)
            }
        }

        // Each moved object → a simple block (a group = folded), positioned at its current
        // display lane through laneEntries (robust to nesting); all the Y is carried by dy
        // (lane = 0 ⇒ displayLane(for: 0) = 0, consistent between the block and the '+' badge).
        let entries = viewModel.laneEntries
        return md.ids.compactMap { id -> (SoundObject, Double, Double)? in
            guard let e = entries.first(where: { $0.item.id == id }) else { return nil }
            var disp = e.item
            disp.lane = 0
            if case .group(let children, _) = disp.kind {
                disp.kind = .group(children: children, isExpanded: false)
            }
            return (disp, dx, Double(e.displayLane) * laneStep + dragDy)
        }
    }

    func previewResizeDX(for object: SoundObject) -> Double {
        if let rd = resizeDrag, rd.ids.contains(object.id) { return rd.dDur * pixelsPerSecond }
        // A fade out pulled beyond the edge: the block grows live, like a resize.
        if let fd = fadeDrag, fd.side == .out, fd.dEdge != 0, fd.ids.contains(object.id) {
            return fd.dEdge * pixelsPerSecond
        }
        return 0
    }

    /// The LEFT edge's offset during a trim (or a fade pulled beyond the edge), in WHOLE
    /// pixels. The pixel alignment is done HERE, once: the block's position, its width, a clip's
    /// source offset, a group's composite and the out-of-range masks all derive from it, so the
    /// block and its content move together and the content stays anchored in absolute terms — a
    /// trim reveals, it does not move the sound.
    ///
    /// Rounding further down, on the content's side alone (which is what `effectiveSourceOffset`
    /// and `effectiveStartTime` did), left the block at its exact position and the content at
    /// ±0.5 px: the waveform slid inside its block during the gesture then settled back on
    /// release. Very visible when the edge comes up against t = 0, where it stops against the
    /// timeline's origin — the small jump then has nothing moving to be confused with.
    func previewTrimDX(for object: SoundObject) -> Double {
        if let td = trimDrag, td.ids.contains(object.id) {
            return (td.dStart * pixelsPerSecond).rounded()
        }
        // A fade in pulled beyond the edge: the start of the sound is revealed live, like a trim.
        if let fd = fadeDrag, fd.side == .in, fd.dEdge != 0, fd.ids.contains(object.id) {
            return (fd.dEdge * pixelsPerSecond).rounded()
        }
        return 0
    }

    func previewFadeIn(for object: SoundObject) -> Double? {
        guard let fd = fadeDrag, fd.ids.contains(object.id), fd.side == .in else { return nil }
        return fd.finalFade
    }

    func previewFadeOut(for object: SoundObject) -> Double? {
        guard let fd = fadeDrag, fd.ids.contains(object.id), fd.side == .out else { return nil }
        return fd.finalFade
    }

    /// The loop's IN/OUT bounds in preview while a marker is dragged (in seconds LOCAL to the
    /// block, @see SoundObject.loopMarkerLocalRange) — otherwise the bounds as they are set.
    /// `nil` if the object does not loop. @see [[loop-item-plan]]
    func previewLoopRange(for object: SoundObject) -> (start: Double, end: Double)? {
        if let ld = loopRangeDrag, ld.id == object.id { return (ld.finalStart, ld.finalEnd) }
        return object.loopMarkerLocalRange
    }

    // MARK: - Cut drag (a directed cut)

    /// The dead travel, in pixels, before a fade pulled outwards starts moving the sound's edge:
    /// without it, one could no longer set a fade to exactly zero.
    static let fadeEdgeDeadZonePx: Double = 20

    /// The objects to cut under a point, with the cut instant snapped. The 10 px at each end stay
    /// dead (a cut flush with the edge produces nothing useful). In a multiple selection, a click
    /// on a selected object cuts ALL the selected objects the instant crosses.
    func cutTargets(at point: CGPoint) -> (ids: [UUID], time: Double, entry: LaneEntry)? {
        guard point.y > rulerHeight else { return nil }
        guard let entry = viewModel.laneEntries.first(where: { e in
            let bx = e.absStart * pixelsPerSecond
            let bw = max(e.item.duration * pixelsPerSecond, 2)
            let by = rulerHeight + Double(e.displayLane) * laneStep
            return point.x >= bx && point.x <= bx + bw && point.y >= by && point.y <= by + blockHeight
        }) else { return nil }

        let bx = entry.absStart * pixelsPerSecond
        let bw = max(entry.item.duration * pixelsPerSecond, 2)
        guard (point.x - bx) >= 10 && (point.x - bx) <= bw - 10 else { return nil }

        let t = viewModel.snapTime(max(0, point.x / pixelsPerSecond))
        return (viewModel.cutTargetIDs(hit: entry.item.id, atTime: t), t, entry)
    }

    /// Cutting by dragging: the gesture's direction decides which side is kept (right = keep the
    /// left). With no clear direction, it is the click's plain cut.
    func handleCutDrag(_ value: DragGesture.Value, phase: DragPhase) {
        if cutDrag == nil {
            guard phase == .changed else { return }
            guard let hit = cutTargets(at: value.startLocation), !hit.ids.isEmpty else { return }
            cutDrag = CutDragState(ids: hit.ids, grabbedID: hit.entry.item.id, cutTime: hit.time)
        }
        guard var state = cutDrag else { return }
        state.dx = Double(value.translation.width)

        if phase == .ended {
            viewModel.cut(ids: state.ids, atTime: state.cutTime, keeping: state.keep)
            cutDrag = nil
        } else {
            cutDrag = state
        }
    }

    /// The portions that would disappear if one released now (a preview of the cut gesture).
    var cutDragDoomedRects: [CGRect] {
        guard let cd = cutDrag, let keep = cd.keep else { return [] }
        let cutX = cd.cutTime * pixelsPerSecond
        return cd.ids.compactMap { id -> CGRect? in
            guard let e = viewModel.laneEntries.first(where: { $0.item.id == id }) else { return nil }
            let bx = e.absStart * pixelsPerSecond
            let bw = max(e.item.duration * pixelsPerSecond, 2)
            let by = rulerHeight + Double(e.displayLane) * laneStep
            let x0 = keep == .left ? cutX : bx
            let x1 = keep == .left ? bx + bw : cutX
            guard x1 > x0 else { return nil }
            return CGRect(x: x0, y: by, width: x1 - x0, height: blockHeight)
        }
    }

    // MARK: - Volume drag

    func handleVolumeDrag(_ value: DragGesture.Value, phase: DragPhase) {
        if volumeDrag == nil {
            guard phase == .changed else { return }
            let p = value.startLocation
            guard p.y > rulerHeight else { return }

            // Top level: clips AND groups
            var hitItem: SoundObject? = viewModel.items.first { obj in
                let bx = obj.startTime * pixelsPerSecond
                let bw = max(obj.duration * pixelsPerSecond, 2)
                let by = laneY(for: obj.lane)
                return p.x >= bx && p.x <= bx + bw && p.y >= by && p.y <= by + blockHeight
            }
            var hitAbsStart = hitItem?.startTime ?? 0

            // Descendants of expanded groups (clips AND subgroup headers) —
            // unified on laneEntries.
            if hitItem == nil {
                if let e = viewModel.laneEntries.first(where: { e in
                    guard e.depth > 0 else { return false }
                    let bx = e.absStart * pixelsPerSecond
                    let bw = max(e.item.duration * pixelsPerSecond, 2)
                    let by = rulerHeight + Double(e.displayLane) * laneStep
                    return p.x >= bx && p.x <= bx + bw && p.y >= by && p.y <= by + blockHeight
                }) {
                    hitItem = e.item; hitAbsStart = e.absStart
                }
            }

            guard let item = hitItem else { return }
            let bx = hitAbsStart * pixelsPerSecond
            let bw = max(item.duration * pixelsPerSecond, 2)
            // The drag zone (the right 40%) bounded by the visible portion — aligned on the clamped rendering.
            let span = visibleSpan(blockX: bx, blockWidth: bw,
                                   scrollOffsetX: scrollOffsetX, viewportWidth: viewportWidth)
            guard (p.x - span.x) >= span.width * 0.6 else { return }

            // The same logic as the volume scroll: we act on the whole selection
            // (top-level clips AND children of groups), not only on the clip grabbed.
            if !viewModel.selectedIDs.contains(item.id) {
                viewModel.select(item.id, additive: false)
            }
            let ids = viewModel.selectedIDs
            let anchors = Dictionary(uniqueKeysWithValues:
                ids.compactMap { viewModel.find(id: $0) }.map { ($0.id, $0.volume) }
            )
            // GRABBING already names the 'future automation' row, before the first dB
            // travelled (@see recordToolTouch).
            recordToolTouch(.volume)
            // The undo is pushed BEFORE the first change (like moving / trimming): pushed at the end,
            // the snapshot captured the state ALREADY changed, and the first ⌘Z gave nothing back — the
            // next one then went back to the action before (a deleted object came back at the same time
            // as the volume). Removed on release if nothing moved.
            viewModel.pushUndo()
            volumeDrag = VolumeDragState(ids: ids, anchors: anchors, grabbedID: item.id)
        }

        guard let state = volumeDrag else { return }
        let dDB = Float(-value.translation.height / 10.0)
        for (id, anchorDB) in state.anchors {
            let newDB = (anchorDB + dDB).clamped(to: -96 ... min(40, anchorDB + 12))
            viewModel.updateVolume(id: id, volume: newDB)
        }
        if phase == .ended {
            let unchanged = state.anchors.allSatisfy { viewModel.find(id: $0.key)?.volume == $0.value }
            if unchanged { _ = viewModel.undoStack.popLast() }
            volumeDrag = nil
        }
    }

    // MARK: - Pan drag

    func handlePanDrag(_ value: DragGesture.Value, phase: DragPhase) {
        if panDrag == nil {
            guard phase == .changed else { return }
            let p = value.startLocation
            guard p.y > rulerHeight else { return }

            // Top level: clips AND groups
            var hitItem: SoundObject? = viewModel.items.first { obj in
                let bx = obj.startTime * pixelsPerSecond
                let bw = max(obj.duration * pixelsPerSecond, 2)
                let by = laneY(for: obj.lane)
                return p.x >= bx && p.x <= bx + bw && p.y >= by && p.y <= by + blockHeight
            }
            var hitAbsStart = hitItem?.startTime ?? 0
            // Descendants of expanded groups (clips AND subgroup headers) —
            // unified on laneEntries.
            if hitItem == nil {
                if let e = viewModel.laneEntries.first(where: { e in
                    guard e.depth > 0 else { return false }
                    let bx = e.absStart * pixelsPerSecond
                    let bw = max(e.item.duration * pixelsPerSecond, 2)
                    let by = rulerHeight + Double(e.displayLane) * laneStep
                    return p.x >= bx && p.x <= bx + bw && p.y >= by && p.y <= by + blockHeight
                }) {
                    hitItem = e.item; hitAbsStart = e.absStart
                }
            }

            guard let item = hitItem else { return }
            // Pan is independent per clip → the whole selection (children of groups included),
            // like the pan scroll.
            if !viewModel.selectedIDs.contains(item.id) {
                viewModel.select(item.id, additive: false)
            }
            let ids = viewModel.selectedIDs
            let anchors = Dictionary(uniqueKeysWithValues:
                ids.compactMap { viewModel.find(id: $0) }.map { ($0.id, $0.pan) }
            )
            recordToolTouch(.pan)
            // The track's width = the visible panel − the margin (padding.horizontal 10 × 2) — aligned on
            // ToolPanLayer's clamped rendering.
            let bx = hitAbsStart * pixelsPerSecond
            let bw = max(item.duration * pixelsPerSecond, 2)
            let span = visibleSpan(blockX: bx, blockWidth: bw,
                                   scrollOffsetX: scrollOffsetX, viewportWidth: viewportWidth)
            // The undo before the first change (see handleVolumeDrag).
            viewModel.pushUndo()
            panDrag = PanDragState(ids: ids, anchors: anchors, grabbedID: item.id,
                                   trackWidth: max(span.width - 20, 1))
        }

        guard let state = panDrag else { return }
        // A VERTICAL gesture (up = to the right), like the wheel, the arrows and the inspector:
        // since pan is shown as a knob, it is set everywhere by the same movement. The travel stays
        // set on the block's visible width — a wide block keeps a fine adjustment.
        let dPan = Float(-value.translation.height / state.trackWidth * 2.0)
        for (id, anchorPan) in state.anchors {
            viewModel.updatePan(id: id, pan: (anchorPan + dPan).clamped(to: -1...1))
        }
        if phase == .ended {
            let unchanged = state.anchors.allSatisfy { viewModel.find(id: $0.key)?.pan == $0.value }
            if unchanged { _ = viewModel.undoStack.popLast() }
            panDrag = nil
        }
    }

    // MARK: - Send drag

    /// The clip (a leaf, not an aux) under a point, in canvas coordinates. It also returns its
    /// geometry for the hit-testing of the knob rows. Top level AND a child of a group.
    func sendClipHit(at p: CGPoint) -> (id: UUID, bx: Double, by: Double, bw: Double)? {
        // Clips AND groups (a group can feed an aux), top level…
        if let obj = viewModel.items.first(where: { o in
            guard !o.isAux else { return false }
            let bx = o.startTime * pixelsPerSecond
            let bw = max(o.duration * pixelsPerSecond, 2)
            let by = laneY(for: o.lane)
            return p.x >= bx && p.x <= bx + bw && p.y >= by && p.y <= by + blockHeight
        }) {
            return (obj.id, obj.startTime * pixelsPerSecond,
                    laneY(for: obj.lane), max(obj.duration * pixelsPerSecond, 2))
        }
        // …and descendants of expanded groups (clips AND subgroups).
        if let e = viewModel.laneEntries.first(where: { e in
            guard e.depth > 0, !e.item.isAux else { return false }
            let bx = e.absStart * pixelsPerSecond
            let bw = max(e.item.duration * pixelsPerSecond, 2)
            let by = rulerHeight + Double(e.displayLane) * laneStep
            return p.x >= bx && p.x <= bx + bw && p.y >= by && p.y <= by + blockHeight
        }) {
            return (e.item.id, e.absStart * pixelsPerSecond,
                    rulerHeight + Double(e.displayLane) * laneStep,
                    max(e.item.duration * pixelsPerSecond, 2))
        }
        return nil
    }

    /// The knob column (aux) under a point: it resolves the clip then the column by its width.
    func sendRowHit(at p: CGPoint) -> (clipID: UUID, auxID: UUID, bx: Double, by: Double, bw: Double)? {
        guard let hit = sendClipHit(at: p) else { return nil }
        let rows = viewModel.sendRows(for: hit.id)
        guard !rows.isEmpty else { return nil }
        let colW = sendColWidth(blockWidth: hit.bw, count: rows.count)
        let localX = p.x - hit.bx
        let idx = Int(localX / colW)
        guard idx >= 0 && idx < rows.count else { return nil }
        return (hit.id, rows[idx].auxID, hit.bx, hit.by, hit.bw)
    }

    func handleSendDrag(_ value: DragGesture.Value, phase: DragPhase) {
        if sendDrag == nil {
            guard phase == .changed else { return }
            guard let hit = sendRowHit(at: value.startLocation) else { return }
            // The clip grabbed joins/forms the selection (like the Vol/Pan drag): the send then
            // applies to the whole selection overlapping that aux.
            if !viewModel.selectedIDs.contains(hit.clipID) {
                viewModel.select(hit.clipID, additive: false)
            }
            let anchors = Dictionary(uniqueKeysWithValues:
                viewModel.selectedSenders(toAux: hit.auxID).map {
                    ($0, viewModel.sendLevel(from: $0, to: hit.auxID))
                })
            // The undo before the first change (see handleVolumeDrag).
            viewModel.pushUndo()
            sendDrag = SendDragState(auxID: hit.auxID, grabbedID: hit.clipID, anchors: anchors)
        }
        guard let state = sendDrag else { return }
        // Reasserted on every step: the hover must not put the accent out during the drag.
        viewModel.sendToolFocus = SendFocus(objectID: state.grabbedID, auxID: state.auxID)
        let dDB = Float(-value.translation.height / 10.0)   // 10 px ≈ 1 dB, upwards = +
        for (id, anchor) in state.anchors {
            viewModel.setSendLevel(from: id, to: state.auxID, levelDb: anchor + dDB)
        }
        if phase == .ended {
            let unchanged = state.anchors.allSatisfy {
                viewModel.sendLevel(from: $0.key, to: state.auxID) == $0.value
            }
            if unchanged { _ = viewModel.undoStack.popLast() }
            sendDrag = nil
        }
    }
}
