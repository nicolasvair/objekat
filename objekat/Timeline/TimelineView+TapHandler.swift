import SwiftUI
import AppKit

extension TimelineView {

    func handleCanvasTap(at point: CGPoint) {
        // A hand back in the timeline takes the keyboard back from the signal view: ⌫ ⌘C ⌘V ⌘D
        // stop aiming at plugin cards and aim at objects again. It is the OTHER half of the claim
        // made in `setPluginSelection`, and it lives at the door of the gesture rather than in the
        // dozen branches below — a single one of them forgetting it would leave ⌫ deleting a
        // plugin while the hand was pointing at a clip.
        viewModel.clearPluginSelection()
        KeyboardClaim.shared.revoke()

        // ... and it leaves any inline rename open elsewhere. Clicking away is how one normally
        // leaves a field, and the ONE rename nothing else closes is a marker ROW's name: the
        // annotation selection carries the others out with it (@see EditViewModel.selectedAnnotation),
        // but a row is not an annotation and its field stayed open under every later click. Here
        // rather than in the dozen branches below, and BEFORE them: the marker band's own double
        // click sets it again a few lines down. Leaving is not cancelling — what was typed is
        // committed on the way out (@see MarkerRenameField).
        viewModel.renamingID = nil

        // The time ruler: it moves the cursor and changes nothing else. It takes priority over
        // everything — whatever the active tool, the ruler does not edit the content.
        if rulerBandContains(point) {
            moveCursorFromRuler(atX: point.x)
            return
        }

        // The marker band, under the ruler. It has its own gestures and none of the canvas's: no
        // caret, no time selection, no tool. Even the Cut tool leaves it alone — a marker names an
        // instant, and there is nothing there to cut.
        if markerBandContains(point) {
            handleMarkerBandTap(at: point)
            return
        }

        // With 's' held: the click no longer selects, it composes what is heard — each object aimed at
        // (a clip, a group, an aux, a child of an open group) goes into or out of the solo. Neither the
        // selection nor the transport moves: we stay on what we were listening to, and s + ⏎ then
        // freezes the result. It takes priority over any other reading of a click in the lanes.
        if viewModel.soloKeyHeld {
            if let id = soloHitTest(at: point) { viewModel.toggleHeldSolo(objectID: id) }
            return
        }

        // The 'assign stem' tool: the click assigns the object aimed at to the target stem
        // (with priority over any other canvas interaction). We climb up to the top-level
        // ancestor because a child has no stem of its own (it follows its group).
        if viewModel.activeTool == .toolStemAssign,
           let n = viewModel.stemAssignIndex, n >= 1, n <= viewModel.stems.count {
            if let hitID = stemPaintHitTest(at: point) {
                var targetID = hitID
                while let parent = viewModel.parentGroup(for: targetID) { targetID = parent.id }
                let stemID = viewModel.stems[n - 1].id
                viewModel.edit { viewModel.assignStem(objectID: targetID, stemID: stemID) }
            }
            return
        }

        let now = Date()
        let isDoubleTap = now.timeIntervalSince(lastTapInfo.time) < 0.35
            && hypot(point.x - lastTapInfo.location.x, point.y - lastTapInfo.location.y) < 20
        lastTapInfo = (now, point)

        // The 'objects / automations' hem of an object that has both to show. Resolved BEFORE the
        // band guards: on an infinite bus the band covers the whole timeline and the hem falls
        // inside it — the guard would have swallowed it.
        if viewModel.activeTool == .toolSelection, let b = automationBezelHit(at: point) {
            viewModel.timeSelection = nil
            viewModel.applyAutomationSelector(b.hit, id: b.id)
            return
        }

        // Clicks inside an open piano roll are handled by PianoRollView: do not lay a caret
        // there or move the cursor through the canvas.
        if openPianoRollBandContains(point) { return }
        // The automation bands are owned by AutomationBandView: the canvas lays neither a caret nor a
        // selection there. It answers the click itself — it selects its object and moves the
        // cursor (@see AutomationBandView.handleTap) — which is why nothing here has to.
        if openAutomationBandContains(point) { return }
        // Past that guard the click is OUTSIDE every band, and that is the only place the automation
        // point selection may be let go of. NOT at the door with `clearPluginSelection` above,
        // deliberately: the bands own their clicks but nothing guarantees the order in which
        // SwiftUI delivers a band's tap and the canvas's, so a purge laid before the guard could
        // wipe, one frame later, the very selection the band had just made.
        viewModel.clearAutomationPointSelection()
        // A real click in the timeline → we leave the piano-roll context (⌘A goes back to selecting
        // clips).
        viewModel.focusedMidiClipID = nil

        if viewModel.activeTool == .toolCut {
            handleCutTap(at: point)
            return
        }
        if viewModel.activeTool == .toolVolume {
            handleVolumeTap(at: point)
            return
        }
        if viewModel.activeTool == .toolPan {
            handlePanTap(at: point)
            return
        }
        if viewModel.activeTool == .toolAux {
            handleSendTap(at: point)
            return
        }
        guard viewModel.activeTool == .toolSelection else { return }
        guard point.y > rulerHeight else { return }

        // The cancel button (✕) of the open sound object: the top-right zone of the placement
        // being edited. The block being pure presentation, the click is resolved geometrically
        // here (with priority over the selection). See SoundBlockView/GroupBlockView (`isEditing`).
        if let pid = viewModel.editingPlacementID,
           let e = viewModel.laneEntries.first(where: { $0.item.id == pid }) {
            let bx = e.absStart * pixelsPerSecond
            let bw = max(e.item.duration * pixelsPerSecond, 2)
            let by = rulerHeight + Double(e.displayLane) * laneStep
            let btn = CGRect(x: bx + bw - 26, y: by + 1, width: 25, height: 24)
            if btn.contains(point) {
                viewModel.cancelObjectEdit()
                return
            }
        }

        // The annotations laid over the lanes: a comment, then a marker carried by an object. They
        // are asked BEFORE the fades and the blocks, because they are drawn ON TOP of them and a
        // mark one can see but not click is a mark one can never delete. Neither costs the block
        // much: a marker only takes the top strip of it, and a comment is a thing one puts where
        // there is room to read it.
        //
        // Double click = rename here as everywhere: the same gesture on a marker's name, on a
        // comment's text and on an object's name.
        if let hit = commentHit(at: point) ?? objectMarkerHit(at: point) {
            viewModel.selectAnnotation(hit)
            if isDoubleTap { viewModel.renamingID = hit.markerID }
            return
        }

        // A double click inside a CROSSFADE zone resets the zone, before the fade below can claim
        // it: the zone IS two fade triangles, and letting the fade branch have it would erase one
        // side and leave the other lying over its neighbour.
        // ⌥ + double click is the automation band's, everywhere and on every object: it is left
        // alone here rather than swallowed by the zone.
        if isDoubleTap, !NSEvent.modifierFlags.contains(.option),
           handleCrossfadeDoubleTap(at: point) { return }

        // A double click on a fade (its handle or its triangle) → the fade is reset. The counterpart
        // of the gesture: you pull to set a fade, you double-click to erase it.
        //
        // The SHAPE goes with the length, and that is the whole point of it being here: a bend is
        // laid down by a hand that leaves the row and moved from where it already was
        // (@see FadeDragState.curve(for:)), so nothing in the drag ever brings a curve back to the
        // straight line except crossing it from the other side. Wiping the length while leaving
        // the bend would also leave it lying in wait, ready to reappear the next time the fade is
        // pulled out of an edge one had just cleared. One double click, one fade, gone whole.
        if isDoubleTap, let (hover, item) = selectionZoneHover(at: point),
           hover.zone == .fadeIn || hover.zone == .fadeOut,
           // A sound object's double click (open / close) still takes priority.
           !item.isObjectInstance, viewModel.editingPlacementID != item.id {
            viewModel.edit {
                if hover.zone == .fadeIn {
                    viewModel.updateFadeIn(id: hover.id, fadeIn: 0)
                    viewModel.updateFadeCurve(id: hover.id, fadeIn: .linear)
                } else {
                    viewModel.updateFadeOut(id: hover.id, fadeOut: 0)
                    viewModel.updateFadeCurve(id: hover.id, fadeOut: .linear)
                }
            }
            // The hover was resolved on the OLD triangle: with no mouse to refresh it, the veil
            // would stay laid on a fade that no longer exists. We replay it on the same point,
            // once the model is up to date — the zone aimed at becomes the handle.
            DispatchQueue.main.async {
                editZoneHover = selectionZoneHover(at: point)?.hover
            }
            return
        }

        // A plain click on the BODY of a crossfade (its bare bottom triangle) selects the zone —
        // the thing itself, not its two objects — which is what gives ⌫ something to take. The
        // other three parts fall through: they are gestures, and a click that merely lands on one
        // has asked for nothing.
        if let hit = crossfadeHit(at: point), hit.part == .move {
            viewModel.selectCrossfade(left: hit.zone.leftID, right: hit.zone.rightID)
            return
        }

        // A plain click on a FADE falls THROUGH, deliberately, and it took a wrong turn to learn
        // why. A fade handle sits in the block's upper half, which is time like any other: a click
        // there is a click on the timeline, and it lays the cursor where it was aimed. Swallowing
        // it (16 September, on the reading that "a click landing on a gesture is not an order")
        // took away the one thing a click means everywhere else on the canvas, over a strip of
        // pixels nothing announces as special. The gesture is safe without that: the fade drag is
        // a `DragGesture(minimumDistance: 3)` and `onTapGesture` fires only when the hand did NOT
        // travel that far — so PULLING a fade never moves the cursor, and only a hand that
        // changed nothing gets the plain click's answer. The crossfade's parts above are a
        // different case and keep their return: they carry a SELECTION of their own.

        let cmd     = NSEvent.modifierFlags.contains(.command)
        let shift   = NSEvent.modifierFlags.contains(.shift)
        let lane    = max(0, Int((point.y - rulerHeight) / laneStep))
        let tapTime = viewModel.snapTime(max(0, point.x / pixelsPerSecond))

        // The caret, ⇧ and ⌘ are not this file's rules any more: they are shared with the
        // automation band, which has a time selection of exactly the same kind on lanes of exactly
        // the same numbering (@see EditViewModel.handleTimeSelectionClick). `inUpperZone` is read
        // further down, so the call is made there, after the hit tests have found it.

        // Clip hit: top-level leaf objects (a clip OR an aux; not groups). An infinite bus
        // (an aux) is selected over its whole lane (0 → the content's width), not at its real position.
        let hitClip = viewModel.items.first { obj in
            if case .group = obj.kind { return false }
            let by = laneY(for: obj.lane)
            guard point.y >= by && point.y <= by + blockHeight else { return false }
            if obj.isInfiniteBus {
                return point.x >= 0 && point.x <= contentWidth
            }
            let bx = obj.startTime * pixelsPerSecond
            let bw = max(obj.duration * pixelsPerSecond, 2)
            return point.x >= bx && point.x <= bx + bw
        }

        // Group hit: only if there is no clip (an infinite bus = the whole lane, like the aux).
        let hitGroup: SoundObject? = hitClip == nil ? viewModel.items.first(where: { grp in
            guard case .group = grp.kind else { return false }
            let by = laneY(for: grp.lane)
            guard point.y >= by && point.y <= by + blockHeight else { return false }
            if grp.isInfiniteBus {
                return point.x >= 0 && point.x <= contentWidth
            }
            let bx = grp.startTime * pixelsPerSecond
            let bw = max(grp.duration * pixelsPerSecond, 2)
            return point.x >= bx && point.x <= bx + bw
        }) : nil

        // A child of an expanded group (only if no top-level item was touched).
        // Unified on laneEntries → it handles nested subgroups too (depth ≥ 2).
        var hitChild: SoundObject? = nil
        var hitChildAbsStart: Double = 0
        var hitChildBy: Double = 0
        if hitClip == nil && hitGroup == nil {
            if let entry = viewModel.laneEntries.first(where: { e in
                guard e.depth > 0 else { return false }
                let bx = e.absStart * pixelsPerSecond
                let bw = max(e.item.duration * pixelsPerSecond, 2)
                let by = rulerHeight + Double(e.displayLane) * laneStep
                return point.x >= bx && point.x <= bx + bw
                    && point.y >= by && point.y <= by + blockHeight
            }) {
                hitChild         = entry.item
                hitChildAbsStart = entry.absStart
                hitChildBy       = rulerHeight + Double(entry.displayLane) * laneStep
            }
        }

        let inUpperZone: Bool
        if let clip = hitClip {
            inUpperZone = (point.y - laneY(for: clip.lane)) < blockHeight * 0.50
        } else if let group = hitGroup {
            inUpperZone = (point.y - laneY(for: group.lane)) < blockHeight * 0.50
        } else if hitChild != nil {
            inUpperZone = (point.y - hitChildBy) < blockHeight * 0.50
        } else {
            inUpperZone = true
        }

        // The caret, ⇧ and ⌘ — one call, the rules being shared with the automation band
        // (@see EditViewModel.handleTimeSelectionClick). It lays the caret whatever happens and
        // answers true only when it has made a RANGE; a plain click falls through to the hit tests
        // below, exactly as it always did.
        if viewModel.handleTimeSelectionClick(lane: lane, time: tapTime, shift: shift, cmd: cmd,
                                              allowsRange: inUpperZone,
                                              onMoveCursor: { onMoveCursor($0) }) {
            return
        }

        // ⌥ + double click = OPEN / CLOSE the automation band, on ANY object.
        // It is the ONLY path for a sound object instance, whose bare double click is already
        // taken (it opens the object, see just below) and which, folded, shows no selector at
        // all. Elsewhere it is a shortcut: it saves opening the content only to reach the
        // selector afterwards.
        if isDoubleTap, NSEvent.modifierFlags.contains(.option),
           let ho = hitChild ?? hitClip ?? hitGroup {
            viewModel.timeSelection = nil
            viewModel.toggleAutomation(id: ho.id)
            return
        }

        // A sound object TAKES PRIORITY (a design decision): a double click = OPEN the object;
        // a double click again on the open object = CLOSE (a new bake). Uniform top-level / child,
        // and with priority over unfolding a group / the MIDI piano roll. The children keep their
        // double click once the object is open (we fall through further down).
        if isDoubleTap, let ho = hitChild ?? hitClip ?? hitGroup {
            if viewModel.editingPlacementID == ho.id {
                viewModel.timeSelection = nil
                viewModel.closeObject()
                return
            }
            if ho.isObjectInstance {
                viewModel.timeSelection = nil
                viewModel.openObject(viaPlacementID: ho.id)
                return
            }
        }

        if let child = hitChild {
            // A double click on a child MIDI clip → opens/closes its inline piano roll.
            if child.isMIDI && isDoubleTap {
                viewModel.timeSelection = nil
                viewModel.togglePianoRoll(id: child.id)
                return
            }
            // An audio clip / a child aux: nothing was using its double click, so it opens the
            // automations. A child group keeps its own (unfolding), and flips afterwards through
            // the selector.
            if isDoubleTap, !child.isGroup {
                viewModel.timeSelection = nil
                viewModel.toggleAutomation(id: child.id)
                return
            }
            if (point.y - hitChildBy) < blockHeight * 0.50 {
                viewModel.clearSelection()
                onMoveCursor(tapTime)
            } else {
                viewModel.timeSelection = nil
                if case .group = child.kind, isDoubleTap {
                    viewModel.toggleGroupExpansion(id: child.id)
                } else if cmd {
                    if viewModel.selectedIDs.contains(child.id) {
                        viewModel.selectedIDs.remove(child.id)
                    } else {
                        viewModel.selectedIDs.insert(child.id)
                    }
                } else if shift {
                    extendSelectionTo(child.id)
                } else {
                    viewModel.select(child.id, additive: false)
                    let t = max(0, hitChildAbsStart)
                    if !isPlaying { viewModel.engine?.seek(to: t) }
                    onMoveCursor(t)
                }
            }
            return
        }

        guard let clip = hitClip else {
            if let group = hitGroup {
                let localY = point.y - laneY(for: group.lane)
                if localY < blockHeight * 0.50 {
                    viewModel.clearSelection()
                    onMoveCursor(tapTime)
                } else {
                    viewModel.timeSelection = nil
                    if isDoubleTap {
                        viewModel.toggleGroupExpansion(id: group.id)
                    } else if cmd {
                        viewModel.select(group.id, additive: true)
                    } else if shift {
                        extendSelectionTo(group.id)
                    } else {
                        viewModel.select(group.id, additive: false)
                        if !isPlaying { viewModel.engine?.seek(to: group.startTime) }
                        onMoveCursor(group.startTime)
                    }
                }
                return
            }
            viewModel.clearSelection()
            onMoveCursor(tapTime)
            return
        }

        // A double click on a MIDI clip → opens/closes the inline piano roll (under the clip).
        if clip.isMIDI && isDoubleTap {
            viewModel.timeSelection = nil
            viewModel.togglePianoRoll(id: clip.id)
            return
        }

        // A double click on an audio clip or an aux → opens/closes its AUTOMATION band.
        // `hitClip` never holds a group (groups go through `hitGroup`, where the double click is
        // still the unfolding): so the only case left is an object with no content to show, whose
        // double click was free.
        if isDoubleTap {
            viewModel.timeSelection = nil
            viewModel.toggleAutomation(id: clip.id)
            return
        }

        let localY = point.y - laneY(for: clip.lane)
        if localY < blockHeight * 0.50 {
            viewModel.clearSelection()
            onMoveCursor(tapTime)
        } else {
            viewModel.timeSelection = nil

            if cmd {
                let prevMin = viewModel.items
                    .filter { viewModel.selectedIDs.contains($0.id) }
                    .map(\.startTime).min() ?? Double.infinity
                if viewModel.selectedIDs.contains(clip.id) {
                    viewModel.selectedIDs.remove(clip.id)
                    if let newMin = viewModel.items
                        .filter({ viewModel.selectedIDs.contains($0.id) })
                        .map(\.startTime).min(), newMin != prevMin {
                        let t = max(0, newMin)
                        if !isPlaying { viewModel.engine?.seek(to: t) }
                        onMoveCursor(t)
                    }
                } else {
                    viewModel.selectedIDs.insert(clip.id)
                    if clip.startTime < prevMin {
                        let t = max(0, clip.startTime)
                        if !isPlaying { viewModel.engine?.seek(to: t) }
                        onMoveCursor(t)
                    }
                }
            } else if shift {
                extendSelectionTo(clip.id)
            } else {
                viewModel.select(clip.id, additive: false)
                let t = max(0, clip.startTime)
                if !isPlaying { viewModel.engine?.seek(to: t) }
                onMoveCursor(t)
            }
        }
    }

    // MARK: - Listening on click ('s' held): hit-testing

    /// The visible object under the point, for the click-to-solo. Like `stemPaintHitTest`, but an
    /// infinite bus (an aux) answers over its WHOLE lane — that is how it is aimed at everywhere else.
    func soloHitTest(at point: CGPoint) -> UUID? {
        guard point.y > rulerHeight else { return nil }
        for e in viewModel.laneEntries {
            let by = rulerHeight + Double(e.displayLane) * laneStep
            guard point.y >= by && point.y <= by + blockHeight else { continue }
            if e.item.isInfiniteBus {
                if point.x >= 0 && point.x <= contentWidth { return e.item.id }
                continue
            }
            let bx = e.absStart * pixelsPerSecond
            let bw = max(e.item.duration * pixelsPerSecond, 2)
            if point.x >= bx && point.x <= bx + bw { return e.item.id }
        }
        return nil
    }

    // MARK: - Stem assignment 'on the fly': hit-testing

    /// The visible object under the point (a clip, a group or a nested child), through the flat
    /// display list. nil if the click falls in empty space or in the ruler.
    func stemPaintHitTest(at point: CGPoint) -> UUID? {
        guard point.y > rulerHeight else { return nil }
        for e in viewModel.laneEntries {
            let bx = e.absStart * pixelsPerSecond
            let bw = max(e.item.duration * pixelsPerSecond, 2)
            let by = rulerHeight + Double(e.displayLane) * laneStep
            if point.x >= bx && point.x <= bx + bw
                && point.y >= by && point.y <= by + blockHeight {
                return e.item.id
            }
        }
        return nil
    }

    // MARK: - Extended selection (shift)

    /// Extends the selection to the item clicked, in display-lane × absolute-time space
    /// (laneEntries): it works for clips, groups and nested children.
    func extendSelectionTo(_ id: UUID) {
        let entries = viewModel.laneEntries
        guard let target = entries.first(where: { $0.item.id == id }) else { return }

        let selectedEntries = entries.filter { viewModel.selectedIDs.contains($0.item.id) }
        guard !selectedEntries.isEmpty else {
            viewModel.select(id, additive: false)
            let t = max(0, target.absStart)
            if !isPlaying { viewModel.engine?.seek(to: t) }
            onMoveCursor(t)
            return
        }

        let prevMin = selectedEntries.map(\.absStart).min()!
        let timeMin = min(prevMin, target.absStart)
        let timeMax = max(selectedEntries.map { $0.absStart + $0.item.duration }.max()!,
                          target.absStart + target.item.duration)
        let laneMin = min(selectedEntries.map(\.displayLane).min()!, target.displayLane)
        let laneMax = max(selectedEntries.map(\.displayLane).max()!, target.displayLane)

        viewModel.selectedIDs = Set(
            entries.filter { e in
                e.absStart < timeMax
                && e.absStart + e.item.duration > timeMin
                && e.displayLane >= laneMin
                && e.displayLane <= laneMax
            }.map(\.item.id)
        )
        if target.absStart < prevMin {
            let t = max(0, target.absStart)
            if !isPlaying { viewModel.engine?.seek(to: t) }
            onMoveCursor(t)
        }
    }

    // MARK: - Cut tap

    /// A plain click = a split. The hit-testing (top-level objects AND children of groups, 10 dead
    /// px at each end, a multiple selection) is shared with the drag cut gesture — see
    /// `cutTargets`.
    func handleCutTap(at point: CGPoint) {
        guard let hit = cutTargets(at: point), !hit.ids.isEmpty else { return }
        viewModel.cut(ids: hit.ids, atTime: hit.time, keeping: nil)
    }

    // MARK: - Volume tap (mute / +1dB / -1dB)

    func handleVolumeTap(at point: CGPoint) {
        guard point.y > rulerHeight else { return }

        var hitClip: SoundObject? = viewModel.items.first { obj in
            let bx = obj.startTime * pixelsPerSecond
            let bw = max(obj.duration * pixelsPerSecond, 2)
            let by = laneY(for: obj.lane)
            return point.x >= bx && point.x <= bx + bw
                && point.y >= by && point.y <= by + blockHeight
        }
        var hitAbsStart = hitClip?.startTime ?? 0
        var hitByY      = hitClip.map { laneY(for: $0.lane) } ?? 0

        if hitClip == nil {
            if let e = viewModel.laneEntries.first(where: { e in
                guard e.depth > 0 else { return false }
                let bx = e.absStart * pixelsPerSecond
                let bw = max(e.item.duration * pixelsPerSecond, 2)
                let by = rulerHeight + Double(e.displayLane) * laneStep
                return point.x >= bx && point.x <= bx + bw
                    && point.y >= by && point.y <= by + blockHeight
            }) {
                hitClip     = e.item
                hitAbsStart = e.absStart
                hitByY      = rulerHeight + Double(e.displayLane) * laneStep
            }
        }

        guard let clip = hitClip else { return }
        if !viewModel.selectedIDs.contains(clip.id) {
            viewModel.select(clip.id, additive: false)
        }

        let bx     = hitAbsStart * pixelsPerSecond
        let bw     = max(clip.duration * pixelsPerSecond, 2)
        // The zones (mute / ± / level) bounded by the block's visible portion — aligned on
        // ToolVolumeLayer's clamped rendering (see visibleSpan).
        let span   = visibleSpan(blockX: bx, blockWidth: bw,
                                 scrollOffsetX: scrollOffsetX, viewportWidth: viewportWidth)
        let localX = point.x - span.x
        let localY = point.y - hitByY

        if localX < span.width * 0.4 {
            viewModel.edit { viewModel.toggleMuteSelected() }
            return
        }
        // Touching a parameter means GRABBING it: aiming at an object's level is enough to make it
        // its 'future automation' row, without having to knock it off its value first. The same rule
        // as the signal view's and the inspector's value boxes (@see DragValueBox.onTouch). Mute, on
        // the other hand, is not automatable: its zone names nothing.
        recordToolTouch(.volume)
        if localX < span.width * 0.6 {
            if localY < blockHeight * 0.5 {
                viewModel.edit { viewModel.adjustVolumeDB(1) }
            } else {
                viewModel.edit { viewModel.adjustVolumeDB(-1) }
            }
        }
    }

    // MARK: - Tooltip of the hovered tool zone

    /// What the zone under the pointer says, or nil if there is nothing to say. The Volume tool's
    /// three zones are the SAME as `handleVolumeTap`'s and the drag's (0…40 % mute,
    /// 40…60 % ± 1 dB, 60…100 % level) — hence sharing `visibleSpan`.
    ///
    /// Resolved geometrically, like everything else: no sublayer of the timeline is hit-testable
    /// (everything is `allowsHitTesting(false)`), so a `.help` laid on a block layer would never
    /// show. It is the canvas that carries the tooltip, and its text follows the hover.
    ///
    func toolZoneHelp(at point: CGPoint) -> String? {
        let tool = viewModel.activeTool
        guard tool == .toolVolume || tool == .toolPan || tool == .toolCut,
              point.y > rulerHeight else { return nil }
        guard let e = viewModel.laneEntries.first(where: { e in
            let bx = e.absStart * pixelsPerSecond
            let bw = max(e.item.duration * pixelsPerSecond, 2)
            let by = rulerHeight + Double(e.displayLane) * laneStep
            return point.x >= bx && point.x <= bx + bw && point.y >= by && point.y <= by + blockHeight
        }) else { return nil }

        // Cut: two zones only, the dead band at the edges and everything else. The 10 px are
        // those of `cutTargets`, in the block's ABSOLUTE coordinates (not the visible portion).
        if tool == .toolCut {
            let bx = e.absStart * pixelsPerSecond
            let bw = max(e.item.duration * pixelsPerSecond, 2)
            let dx = point.x - bx
            if dx < 10 || dx > bw - 10 {
                return L("help.cut.impossible")
            }
            return L("help.cut.zone")
        }

        // Pan has no zones: drag and mouse wheel act anywhere on the block.
        if tool == .toolPan {
            return L("help.pan.zone")
        }

        let span = visibleSpan(blockX: e.absStart * pixelsPerSecond,
                               blockWidth: max(e.item.duration * pixelsPerSecond, 2),
                               scrollOffsetX: scrollOffsetX, viewportWidth: viewportWidth)
        let localX = point.x - span.x
        if localX < span.width * 0.4 { return L("help.mute.zone") }
        if localX < span.width * 0.6 { return L("help.volume.clickZone") }
        return L("help.volume.dragZone")
    }

    // MARK: - Pan tap (grabbing the parameter)

    /// A click with the PAN tool: it changes nothing (pan is set by a vertical drag), it NAMES.
    /// The object aimed at goes into the selection and its pan becomes the 'future automation' row
    /// — exactly what a click on the signal view's knob does.
    func handlePanTap(at point: CGPoint) {
        guard point.y > rulerHeight else { return }
        guard let entry = viewModel.laneEntries.first(where: { e in
            let bx = e.absStart * pixelsPerSecond
            let bw = max(e.item.duration * pixelsPerSecond, 2)
            let by = rulerHeight + Double(e.displayLane) * laneStep
            return point.x >= bx && point.x <= bx + bw && point.y >= by && point.y <= by + blockHeight
        }) else { return }

        if !viewModel.selectedIDs.contains(entry.item.id) {
            viewModel.select(entry.item.id, additive: false)
        }
        recordToolTouch(.pan)
    }

    /// Remembers a parameter being touched over the WHOLE selection: the volume / pan tools act on
    /// all of it, so the row offered has to open on each of its objects.
    func recordToolTouch(_ ref: ParamRef) {
        for id in viewModel.selectedIDs { viewModel.recordAutomationTouch(id, ref) }
    }

    // MARK: - Send tap (on/off plus focus)

    func handleSendTap(at point: CGPoint) {
        guard point.y > rulerHeight else { return }
        guard let hit = sendRowHit(at: point) else { return }
        viewModel.sendToolFocus = SendFocus(objectID: hit.clipID, auxID: hit.auxID)
        // The bottom of the column = the on/off button; elsewhere = merely focusing.
        let localY = point.y - hit.by
        if localY >= blockHeight - sendToggleZoneHeight - 4 {
            // A clip grabbed inside a multiple selection → it flips the send of every object
            // overlapping that aux (mute-style: if one is left off, turn them all on).
            if viewModel.selectedIDs.count > 1 && viewModel.selectedIDs.contains(hit.clipID) {
                let senders = viewModel.selectedSenders(toAux: hit.auxID)
                let target = senders.contains { !viewModel.isSendEnabled(from: $0, to: hit.auxID) }
                viewModel.edit { viewModel.setSendEnabledSelected(toAux: hit.auxID, enabled: target) }
            } else {
                let on = viewModel.isSendEnabled(from: hit.clipID, to: hit.auxID)
                viewModel.edit { viewModel.setSendEnabled(from: hit.clipID, to: hit.auxID, enabled: !on) }
            }
        }
    }
}

// MARK: - The marker band

extension TimelineView {

    /// A click in the band: it selects a mark, and that is all it does. Nothing here moves the
    /// cursor, lays a caret or traces a range — the band is a margin, not a surface one edits.
    ///
    /// Creation is the right click's (@see markerBandMenu): a click that merely LANDS somewhere has
    /// asked for nothing, and a band that laid a marker at every click would fill with marks nobody
    /// meant. Double click renames, as everywhere else.
    func handleMarkerBandTap(at point: CGPoint) {
        let now = Date()
        let isDoubleTap = now.timeIntervalSince(lastTapInfo.time) < 0.35
            && hypot(point.x - lastTapInfo.location.x, point.y - lastTapInfo.location.y) < 20
        lastTapInfo = (now, point)

        guard let hit = markerBandHit(at: point) else {
            viewModel.selectedAnnotation = nil
            return
        }
        viewModel.selectAnnotation(hit)
        if isDoubleTap { viewModel.renamingID = hit.markerID }
    }
}
