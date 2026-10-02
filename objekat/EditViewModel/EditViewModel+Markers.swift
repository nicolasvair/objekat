import Foundation

// MARK: - Markers, regions, comments
//
// Everything here is PURELY VISUAL: not one of these functions touches the engine, the stems, the
// plugins or the render. They name moments and lay down text. That is what makes them cheap — and
// what makes their undo cheap too, since `applySnapshot` has nothing to reconcile on the engine's
// side for them.
//
// UNDO IS PUSHED HERE, inside each user-facing operation ("internal undo push", the same
// convention as `deleteTimeSelection` / `rippleDeleteSelectedObjects`): these have two callers each
// — a gesture and a command of the API — and leaving the push to the caller is how one of the two
// ends up without it.

/// A comment resolved for the SCREEN: where it really starts and which row it is really drawn on,
/// its frame (the timeline, or the group holding it) already counted. The counterpart of
/// `LaneEntry` for the annotation layer, and it exists for the same reason: the drawing, the
/// hit-testing and the drag must not each do that arithmetic (@see EditViewModel.visibleComments).
struct PlacedComment: Identifiable {
    let comment: TimelineComment
    var id: UUID { comment.id }
    let absStart: Double
    let displayLane: Int

    var absEnd: Double { absStart + comment.duration }
}

extension EditViewModel {

    // MARK: Rows of the band

    /// The rows actually drawn, in order. Hiding a row keeps its content and gives its pixels back
    /// (@see MarkerLane.isVisible) — the band's height follows this list.
    var visibleMarkerLanes: [MarkerLane] { markerLanes.filter(\.isVisible) }

    /// The same count, without building the array. The two AppKit event monitors read it on every
    /// scroll notch and every right click to work out where the lanes begin, and an allocation per
    /// notch is a poor way to answer "how many rows".
    var visibleMarkerLaneCount: Int { markerLanes.reduce(0) { $0 + ($1.isVisible ? 1 : 0) } }

    func markerLane(id: UUID) -> MarkerLane? { markerLanes.first { $0.id == id } }

    /// The row a creation with no row named lands on: the first VISIBLE one, else the first one,
    /// else a freshly made one. A right click that says "put a marker here" must never have to ask
    /// which layer it means before there is more than one.
    @discardableResult
    func ensureMarkerLane() -> UUID {
        if let v = markerLanes.first(where: \.isVisible) { return v.id }
        if let f = markerLanes.first { return f.id }
        return addMarkerLane(name: L("markers.lane.default"))
    }

    @discardableResult
    func addMarkerLane(name: String? = nil, colorIndex: Int? = nil) -> UUID {
        pushUndo()
        let lane = MarkerLane(name: name ?? L("markers.lane.untitled", markerLanes.count + 1),
                              colorIndex: colorIndex ?? (markerLanes.count % ObjectColorPalette.count))
        markerLanes.append(lane)
        isDirty = true
        return lane.id
    }

    @discardableResult
    func removeMarkerLane(id: UUID) -> Bool {
        guard let idx = markerLanes.firstIndex(where: { $0.id == id }) else { return false }
        pushUndo()
        // A selection pointing into the row that is going would survive it, and ⌫ would then be
        // aimed at nothing.
        selectedAnnotations.removeAll { if case .laneMarker(let l, _) = $0 { return l == id }; return false }
        markerLanes.remove(at: idx)
        isDirty = true
        return true
    }

    @discardableResult
    func renameMarkerLane(id: UUID, to name: String) -> Bool {
        guard let idx = markerLanes.firstIndex(where: { $0.id == id }) else { return false }
        pushUndo()
        markerLanes[idx].name = name
        isDirty = true
        return true
    }

    /// The row's own hue — and therefore the DEFAULT of every mark on it that has not asked for
    /// another (@see Marker.colorIndex). Recolouring a row recolours its marks; the ones given a
    /// hue of their own keep it, which is the whole point of having asked.
    @discardableResult
    func setMarkerLaneColor(id: UUID, colorIndex: Int) -> Bool {
        guard let idx = markerLanes.firstIndex(where: { $0.id == id }) else { return false }
        pushUndo()
        markerLanes[idx].colorIndex = colorIndex
        isDirty = true
        return true
    }

    /// Shows / hides a row. It is not a deletion: the content stays, only the 16 px come back.
    @discardableResult
    func setMarkerLaneVisible(id: UUID, _ visible: Bool) -> Bool {
        guard let idx = markerLanes.firstIndex(where: { $0.id == id }) else { return false }
        guard markerLanes[idx].isVisible != visible else { return true }
        pushUndo()
        markerLanes[idx].isVisible = visible
        isDirty = true
        return true
    }

    // MARK: Markers and regions of the band

    /// Lays a marker (`duration == 0`) or a region (`duration > 0`) on a row. Time is ABSOLUTE
    /// here — it is the timeline's own, not an object's frame (@see Marker, the two frames).
    @discardableResult
    func addMarker(laneID: UUID? = nil, at time: Double, duration: Double = 0,
                   name: String = "") -> (lane: UUID, marker: UUID)? {
        let lid = laneID ?? ensureMarkerLane()
        guard let idx = markerLanes.firstIndex(where: { $0.id == lid }) else { return nil }
        pushUndo()
        let m = Marker(time: max(0, time), duration: max(0, duration), name: name)
        markerLanes[idx].markers.append(m)
        isDirty = true
        return (lid, m.id)
    }

    /// `pushesUndo == false` is for `removeAnnotations`, which takes several marks in ONE undo.
    @discardableResult
    func removeMarker(laneID: UUID, markerID: UUID, pushesUndo: Bool = true) -> Bool {
        guard let li = markerLanes.firstIndex(where: { $0.id == laneID }),
              let mi = markerLanes[li].markers.firstIndex(where: { $0.id == markerID })
        else { return false }
        if pushesUndo { pushUndo() }
        markerLanes[li].markers.remove(at: mi)
        deselectAnnotation(.laneMarker(lane: laneID, marker: markerID))
        isDirty = true
        return true
    }

    /// Renames a marker. `pushesUndo == false` is for the inline field, which has already pushed on
    /// entering edit — otherwise every rename would cost two undos, the second undoing nothing.
    @discardableResult
    func renameMarker(laneID: UUID, markerID: UUID, to name: String,
                      pushesUndo: Bool = true) -> Bool {
        guard let li = markerLanes.firstIndex(where: { $0.id == laneID }),
              let mi = markerLanes[li].markers.firstIndex(where: { $0.id == markerID })
        else { return false }
        if pushesUndo { pushUndo() }
        markerLanes[li].markers[mi].name = name
        isDirty = true
        return true
    }

    /// Moves a marker, and resizes it when it is a region. `duration` nil = leave it alone.
    @discardableResult
    func moveMarker(laneID: UUID, markerID: UUID, to time: Double,
                    duration: Double? = nil, pushesUndo: Bool = true) -> Bool {
        guard let li = markerLanes.firstIndex(where: { $0.id == laneID }),
              let mi = markerLanes[li].markers.firstIndex(where: { $0.id == markerID })
        else { return false }
        if pushesUndo { pushUndo() }
        markerLanes[li].markers[mi].time = max(0, time)
        if let d = duration { markerLanes[li].markers[mi].duration = max(0, d) }
        isDirty = true
        return true
    }

    /// A marker's own hue. nil = it goes back to taking the row's (@see Marker.colorIndex).
    @discardableResult
    func setMarkerColor(laneID: UUID, markerID: UUID, colorIndex: Int?,
                        pushesUndo: Bool = true) -> Bool {
        guard let li = markerLanes.firstIndex(where: { $0.id == laneID }),
              let mi = markerLanes[li].markers.firstIndex(where: { $0.id == markerID })
        else { return false }
        if pushesUndo { pushUndo() }
        markerLanes[li].markers[mi].colorIndex = colorIndex
        isDirty = true
        return true
    }

    /// Moves a marker from one row of the band to another, KEEPING ITS IDENTITY — the same `id`,
    /// hence the same selection, the same inline field and the same undo.
    ///
    /// A move rather than a copy-and-delete, because a marker changing row has not become another
    /// marker: it is the same mark read on another layer. The vertical half of the band's drag
    /// (@see TimelineView.handleMarkerBandDrag), and the reason the selection is re-aimed here —
    /// `.laneMarker` carries the row, so a selection left pointing at the old one would arm ⌫
    /// against nothing.
    @discardableResult
    func moveMarkerToLane(from source: UUID, markerID: UUID, to target: UUID,
                          pushesUndo: Bool = true) -> Bool {
        guard source != target else { return true }
        guard let si = markerLanes.firstIndex(where: { $0.id == source }),
              let mi = markerLanes[si].markers.firstIndex(where: { $0.id == markerID }),
              let ti = markerLanes.firstIndex(where: { $0.id == target })
        else { return false }
        if pushesUndo { pushUndo() }
        let m = markerLanes[si].markers.remove(at: mi)
        markerLanes[ti].markers.append(m)
        // The selection is re-aimed wherever it holds the mark — one of several as well as alone.
        let from = AnnotationSel.laneMarker(lane: source, marker: markerID)
        let to   = AnnotationSel.laneMarker(lane: target, marker: markerID)
        if selectedAnnotations.contains(from) {
            selectedAnnotations = selectedAnnotations.map { $0 == from ? to : $0 }
        }
        if annotationAnchor == from { annotationAnchor = to }
        isDirty = true
        return true
    }

    // MARK: Markers carried by an object

    /// Lays a marker on an object, at an ABSOLUTE time — the one the hand pointed at. It is stored
    /// RELATIVE to the object's start, which is what makes moving the object free afterwards
    /// (@see SoundObject.markers).
    ///
    /// The absolute start is read off `laneEntries` rather than off `startTime`, because a child's
    /// `startTime` is relative to its container: taking it as it is would put every marker of a
    /// nested object at the wrong place, and only inside groups.
    @discardableResult
    func addObjectMarker(objectID: UUID, atAbsoluteTime time: Double,
                         duration: Double = 0, name: String = "") -> UUID? {
        guard let object = find(id: objectID) else { return nil }
        let origin = absoluteStart(of: objectID) ?? object.startTime
        return addObjectMarker(objectID: objectID, atRelativeTime: time - origin,
                               duration: duration, name: name)
    }

    /// The same, in the object's own frame — what the command API speaks, since a script that has
    /// just read `markers` gets those times back.
    @discardableResult
    func addObjectMarker(objectID: UUID, atRelativeTime t: Double,
                         duration: Double = 0, name: String = "") -> UUID? {
        guard find(id: objectID) != nil else { return nil }
        pushUndo()
        let m = Marker(time: t, duration: max(0, duration), name: name)
        update(id: objectID) { $0.markers.append(m) }
        isDirty = true
        return m.id
    }

    @discardableResult
    func removeObjectMarker(objectID: UUID, markerID: UUID, pushesUndo: Bool = true) -> Bool {
        guard let object = find(id: objectID),
              object.markers.contains(where: { $0.id == markerID }) else { return false }
        if pushesUndo { pushUndo() }
        update(id: objectID) { $0.markers.removeAll { $0.id == markerID } }
        deselectAnnotation(.objectMarker(object: objectID, marker: markerID))
        isDirty = true
        return true
    }

    @discardableResult
    func renameObjectMarker(objectID: UUID, markerID: UUID, to name: String,
                            pushesUndo: Bool = true) -> Bool {
        guard let object = find(id: objectID),
              object.markers.contains(where: { $0.id == markerID }) else { return false }
        if pushesUndo { pushUndo() }
        update(id: objectID) { obj in
            if let i = obj.markers.firstIndex(where: { $0.id == markerID }) { obj.markers[i].name = name }
        }
        isDirty = true
        return true
    }

    /// Moves a marker carried by an object, and resizes it when it is a region. The time is the
    /// object's OWN — relative to its start (@see SoundObject.markers) — which is the whole of what
    /// a drag on such a mark can mean: it has no row of its own to change, the row is the object's.
    ///
    /// A NEGATIVE time is legal and is not clamped here: that is a mark pushed behind an edge by a
    /// left trim, kept in the model and waiting for the edge to be reopened. The gesture that
    /// clamps is the hand's (@see TimelineView.handleObjectMarkerDrag) — a mark dragged out of the
    /// window would stop being drawn under the hand that was moving it.
    @discardableResult
    func moveObjectMarker(objectID: UUID, markerID: UUID, toRelativeTime t: Double,
                          duration: Double? = nil, pushesUndo: Bool = true) -> Bool {
        guard let object = find(id: objectID),
              object.markers.contains(where: { $0.id == markerID }) else { return false }
        if pushesUndo { pushUndo() }
        update(id: objectID) { obj in
            guard let i = obj.markers.firstIndex(where: { $0.id == markerID }) else { return }
            obj.markers[i].time = t
            if let d = duration { obj.markers[i].duration = max(0, d) }
        }
        isDirty = true
        return true
    }

    /// The hue of a marker carried by an object. nil = white, which is what a mark laid on matter
    /// wants by default: it has to read against any waveform under it.
    @discardableResult
    func setObjectMarkerColor(objectID: UUID, markerID: UUID, colorIndex: Int?,
                              pushesUndo: Bool = true) -> Bool {
        guard let object = find(id: objectID),
              object.markers.contains(where: { $0.id == markerID }) else { return false }
        if pushesUndo { pushUndo() }
        update(id: objectID) { obj in
            if let i = obj.markers.firstIndex(where: { $0.id == markerID }) {
                obj.markers[i].colorIndex = colorIndex
            }
        }
        isDirty = true
        return true
    }

    /// The absolute start of an object, container nesting included. nil if it is not in the tree.
    func absoluteStart(of id: UUID) -> Double? {
        laneEntries.first { $0.item.id == id }?.absStart
    }

    // MARK: Comments — the frame a comment lives in
    //
    // A comment belongs to the TIMELINE (`parentID == nil`) or to a GROUP, recursively. The frame
    // is not a detail of the drawing: inside a group its `startTime` is relative to the group's
    // own start and its `lane` is a row of the group's band, exactly as a CHILD's lane is. That is
    // what makes it follow a move, a copy or a fold of the group without a single gesture naming
    // it — the same bargain an object's `markers` strike, one level up.
    //
    // The two conversions below are each other's inverse and they sit SIDE BY SIDE for the reason
    // written above `displayLane(forBase:)` (@see EditViewModel+Clipboard): two inverses that do
    // not count the same amount is this project's oldest recurring bug. With `parent == nil` they
    // are the top-level pair, word for word.

    /// The rows a frame is made of: the timeline's own items, or a group's children.
    func commentFrameSiblings(parent: UUID?) -> [SoundObject] {
        guard let parent, let g = find(id: parent),
              case .group(let children, _) = g.kind else { return items }
        return children
    }

    /// The display row a frame's row 0 sits on. nil = the frame is NOT on screen — a folded group,
    /// one showing its automation band instead of its children, or one whose own ancestor is
    /// folded (`laneEntries` only holds what is really drawn).
    func commentFrameOrigin(parent: UUID?) -> Int? {
        guard let parent else { return 0 }
        guard let e = laneEntries.first(where: { $0.item.id == parent }),
              e.item.showsChildrenInline else { return nil }
        return e.displayLane + 1
    }

    /// A BASE row of `parent`'s frame turned into the row it is drawn on. nil = the frame is folded.
    func displayLane(forBase baseLane: Int, inParent parent: UUID?) -> Int? {
        guard let origin = commentFrameOrigin(parent: parent) else { return nil }
        let siblings = commentFrameSiblings(parent: parent)
        return origin + baseLane
             + siblings.reduce(0) { $0 + ($1.lane < baseLane ? $1.expandedSpan : 0) }
    }

    /// The inverse: a row on screen brought back into `parent`'s frame.
    func baseLaneForDisplay(_ target: Int, inParent parent: UUID?) -> Int {
        guard parent != nil else { return baseLaneForDisplay(target) }
        guard let origin = commentFrameOrigin(parent: parent) else { return 0 }
        let siblings = commentFrameSiblings(parent: parent)
        var b = 0
        while b < 512 {
            let extra = siblings.reduce(0) { $0 + ($1.lane < b ? $1.expandedSpan : 0) }
            if origin + b + extra >= target { return b }
            b += 1
        }
        return b
    }

    /// The frame a display row belongs to: the innermost open group whose band holds it, or the
    /// timeline. The same rule a paste and a drop already follow (@see containerGroupEntry), so a
    /// comment is created where the eye is and nowhere else.
    func commentAnchor(forDisplayLane displayLane: Int) -> (parent: UUID?, lane: Int) {
        if let e = containerGroupEntry(forDisplayLanes: [displayLane]) {
            // A row of the group's frame, not a raw offset: open sub-groups, piano rolls and
            // automation bands above it in the group push the rows down (@see MoveDropResolution).
            return (e.item.id, baseLaneForDisplay(displayLane, inParent: e.item.id))
        }
        return (nil, baseLaneForDisplay(displayLane))
    }

    /// A comment's start in EDIT seconds, folded or not — the group's own start is already
    /// absolute, children carrying absolute `startTime`s (@see EditViewModel+ListRows).
    func commentAbsStart(_ c: TimelineComment) -> Double {
        guard let p = c.parentID, let g = find(id: p) else { return c.startTime }
        return g.startTime + c.startTime
    }

    /// The comments that are actually ON SCREEN, resolved once into the absolute time and the
    /// display row the drawing, the hit-testing and the drag all read. Resolved HERE and not at
    /// each of the three, which is exactly how the display row got stored in the model in the
    /// first place.
    var visibleComments: [PlacedComment] {
        comments.compactMap { c in
            guard let dl = displayLane(forBase: c.lane, inParent: c.parentID) else { return nil }
            return PlacedComment(comment: c, absStart: commentAbsStart(c), displayLane: dl)
        }
    }

    // MARK: Comments — laying them down and editing them

    /// Lays a comment over a span of the timeline. `from` / `to` are ABSOLUTE edit seconds, always
    /// — that is what a hand and a script both hold — and they are stored in `parentID`'s frame.
    /// `lane` is a BASE row of that same frame, not the visual row index: a caller holding a
    /// display row goes through `commentAnchor(forDisplayLane:)`, which answers both at once.
    @discardableResult
    func addComment(from: Double, to: Double, lane: Int, parentID: UUID? = nil,
                    text: String = "") -> UUID? {
        let lo = min(from, to), hi = max(from, to)
        guard hi - lo > 1e-9 else { return nil }
        // A parent that is not a group would leave the comment in a frame with no band to be drawn
        // in: it goes to the timeline rather than disappearing.
        var parent = parentID
        if let p = parent, find(id: p)?.isGroup != true { parent = nil }
        let origin = parent.flatMap { find(id: $0)?.startTime } ?? 0
        pushUndo()
        // No hue drawn from the palette: a comment is born WHITE, so that it never reads as one
        // more object laid on the lane (@see TimelineComment.colorIndex). A colour is something one
        // then CHOOSES, to sort the notes among themselves.
        let start = max(0, lo)
        let c = TimelineComment(startTime: start - origin, duration: hi - start,
                                lane: max(0, lane), text: text, parentID: parent)
        comments.append(c)
        isDirty = true
        return c.id
    }

    @discardableResult
    func removeComment(id: UUID, pushesUndo: Bool = true) -> Bool {
        guard let idx = comments.firstIndex(where: { $0.id == id }) else { return false }
        if pushesUndo { pushUndo() }
        comments.remove(at: idx)
        deselectAnnotation(.comment(id))
        isDirty = true
        return true
    }

    @discardableResult
    func setCommentText(id: UUID, _ text: String, pushesUndo: Bool = true) -> Bool {
        guard let idx = comments.firstIndex(where: { $0.id == id }) else { return false }
        guard comments[idx].text != text else { return true }
        if pushesUndo { pushUndo() }
        comments[idx].text = text
        isDirty = true
        return true
    }

    /// A comment's hue. nil = back to white, the colour that says 'this is not matter'.
    @discardableResult
    func setCommentColor(id: UUID, colorIndex: Int?, pushesUndo: Bool = true) -> Bool {
        guard let idx = comments.firstIndex(where: { $0.id == id }) else { return false }
        if pushesUndo { pushUndo() }
        comments[idx].colorIndex = colorIndex
        isDirty = true
        return true
    }

    /// Moves a comment, and resizes / re-rows / re-homes it if asked. `start` is an ABSOLUTE edit
    /// time (the one the hand and the grid both speak) and is stored in the comment's own frame;
    /// `lane` is a BASE row of that frame. `parent` is a DOUBLE optional on purpose: absent = leave
    /// the frame alone, `.some(nil)` = back onto the timeline, `.some(id)` = into that group.
    @discardableResult
    func moveComment(id: UUID, to start: Double, duration: Double? = nil, lane: Int? = nil,
                     parent: UUID?? = nil, pushesUndo: Bool = true) -> Bool {
        guard let idx = comments.firstIndex(where: { $0.id == id }) else { return false }
        if pushesUndo { pushUndo() }
        if let newParent = parent {
            comments[idx].parentID = (newParent.flatMap { find(id: $0)?.isGroup == true ? $0 : nil })
        }
        // The frame is settled FIRST: the absolute start has to be folded into the frame the
        // comment ends up in, not the one it is leaving.
        let origin = comments[idx].parentID.flatMap { find(id: $0)?.startTime } ?? 0
        comments[idx].startTime = max(0, start) - origin
        if let d = duration { comments[idx].duration = max(1e-3, d) }
        if let l = lane     { comments[idx].lane = max(0, l) }
        isDirty = true
        return true
    }

    /// The comments a deletion leaves with no frame: a group has gone and taken its band with it,
    /// so the notes laid in it go too. Called at the doors matter really disappears by, never in
    /// the middle of a reparenting — a comment whose group is momentarily out of the tree is not
    /// an orphan.
    func pruneOrphanComments() {
        guard comments.contains(where: { $0.parentID != nil }) else { return }
        var alive: Set<UUID> = []
        func walk(_ objs: [SoundObject]) {
            for o in objs {
                alive.insert(o.id)
                if case .group(let ch, _) = o.kind { walk(ch) }
            }
        }
        walk(items)
        let kept = comments.filter { $0.parentID == nil || alive.contains($0.parentID!) }
        guard kept.count != comments.count else { return }
        comments = kept
        pruneAnnotationSelection()
        isDirty = true
    }

    /// The comments of a copied sub-tree, copied onto the copies. `idMap` is the origin → copy
    /// table `makeCopy` fills (@see EditViewModel+Clipboard): nothing to shift here, since a
    /// comment's coordinates are already its group's own.
    func copyComments(using idMap: [UUID: UUID], from source: [TimelineComment]? = nil) {
        guard !idMap.isEmpty else { return }
        let pool = source ?? comments
        var made: [TimelineComment] = []
        for c in pool {
            guard let p = c.parentID, let np = idMap[p] else { continue }
            var copy = c
            copy.id = UUID()
            copy.parentID = np
            made.append(copy)
        }
        guard !made.isEmpty else { return }
        comments += made
        isDirty = true
    }

    /// The comments a group holds, its sub-groups' included — what a copy takes with it and what a
    /// cut has to put aside before the group goes.
    func commentsInSubtree(of rootID: UUID) -> [TimelineComment] {
        guard let root = find(id: rootID) else { return [] }
        var ids: Set<UUID> = [rootID]
        func walk(_ o: SoundObject) {
            guard case .group(let ch, _) = o.kind else { return }
            for c in ch { ids.insert(c.id); walk(c) }
        }
        walk(root)
        return comments.filter { $0.parentID.map(ids.contains) ?? false }
    }

    // MARK: What ⌫ and ⌘R are aimed at

    /// The marker an annotation selection names, whichever of the three kinds it is. nil for a
    /// comment (it has no name — its text IS its content).
    func marker(for sel: AnnotationSel) -> Marker? {
        switch sel {
        case .laneMarker(let l, let m):
            return markerLane(id: l)?.markers.first { $0.id == m }
        case .objectMarker(let o, let m):
            return find(id: o)?.markers.first { $0.id == m }
        case .comment:
            return nil
        }
    }

    /// True if the selection still names something. A selection can outlive its target — an undo,
    /// a cut that swallowed the marker, a deleted row — and every gesture reading it has to be able
    /// to ask.
    func annotationExists(_ sel: AnnotationSel) -> Bool {
        if case .comment(let c) = sel { return comments.contains { $0.id == c } }
        return marker(for: sel) != nil
    }

    /// ⌫ on the selected annotations — ONE, or all of them, in a single undo. Returns false if
    /// there was nothing to delete, so the key handler can fall through to its next branch rather
    /// than swallowing the key.
    @discardableResult
    func deleteSelectedAnnotation() -> Bool {
        removeAnnotations(selectedAnnotations) > 0
    }

    /// Deletes several marks — of the band, carried by objects, comments — as ONE gesture: one undo
    /// point, pushed before the first removal and only if something will really go. The marks that
    /// no longer exist are skipped rather than refused, so a stale selection still deletes what is
    /// left of it. Returns how many went.
    @discardableResult
    func removeAnnotations(_ sels: [AnnotationSel]) -> Int {
        let live = uniqueLiveAnnotations(sels)
        guard !live.isEmpty else { return 0 }
        pushUndo()
        var gone = 0
        for sel in live {
            let ok: Bool
            switch sel {
            case .laneMarker(let l, let m):   ok = removeMarker(laneID: l, markerID: m, pushesUndo: false)
            case .objectMarker(let o, let m): ok = removeObjectMarker(objectID: o, markerID: m, pushesUndo: false)
            case .comment(let c):             ok = removeComment(id: c, pushesUndo: false)
            }
            if ok { gone += 1 }
        }
        return gone
    }

    /// The selections that still name something, each once, in the order given.
    private func uniqueLiveAnnotations(_ sels: [AnnotationSel]) -> [AnnotationSel] {
        var seen = Set<AnnotationSel>()
        return sels.filter { annotationExists($0) && seen.insert($0).inserted }
    }

    /// The selection as a set — what the drawing layers ask, for membership only.
    var selectedAnnotationSet: Set<AnnotationSel> { Set(selectedAnnotations) }

    /// The mark an id names, whichever kind it is — for the inline fields, which carry only the id
    /// of what they are editing and must find it again when they commit, selection or no selection.
    /// Object markers are looked up among the objects ON SCREEN (`laneEntries`): that is where a
    /// field for one can exist.
    func annotationSel(forMarkerID id: UUID) -> AnnotationSel? {
        for lane in markerLanes where lane.markers.contains(where: { $0.id == id }) {
            return .laneMarker(lane: lane.id, marker: id)
        }
        if comments.contains(where: { $0.id == id }) { return .comment(id) }
        for e in laneEntries where e.item.markers.contains(where: { $0.id == id }) {
            return .objectMarker(object: e.item.id, marker: id)
        }
        return nil
    }

    /// Takes one mark out of the selection (and out of the ⇧ anchor's reach) — what every removal
    /// does for the mark that goes.
    func deselectAnnotation(_ sel: AnnotationSel) {
        if selectedAnnotations.contains(sel) { selectedAnnotations.removeAll { $0 == sel } }
        if annotationAnchor == sel { annotationAnchor = selectedAnnotations.last }
    }

    /// Lets go of the marks that no longer exist — after an undo, a cut that swallowed them, a
    /// deleted row or group. A selection can outlive its targets, and ⌫ aimed at a ghost would
    /// either do nothing or, worse, delete the one mark left beside it.
    func pruneAnnotationSelection() {
        if !selectedAnnotations.isEmpty {
            let kept = selectedAnnotations.filter(annotationExists)
            if kept.count != selectedAnnotations.count { selectedAnnotations = kept }
        }
        if let a = annotationAnchor, !annotationExists(a) { annotationAnchor = selectedAnnotations.last }
    }

    // MARK: Picking marks — the click's logic, which the hand and the API share

    /// A click on a mark (or on nothing) and what it does to the selection. The LOGIC lives here
    /// rather than in the timeline so that a script can drive exactly what a hand does
    /// (`marker.select`), and so that no assertion has to mean 'the view would have done…'.
    ///
    /// - plain: the mark alone is selected (the ⇧ anchor is laid on it). On a mark of the BAND —
    ///   a region or a point marker — the cursor also goes to its start, caret off: the same
    ///   gesture that selects says where one is. Dragging is not a click and never gets here.
    /// - ⌘: the mark goes in or out of the selection, the others staying.
    /// - ⇧: the marks of the band between the anchor and this one — in TIME (a region counts when
    ///   it overlaps the span) and in ROWS — replace the selection, the anchor holding still, so a
    ///   second ⇧-click aimed back inside SHORTENS it, as the time selection's does. With no
    ///   anchor on the band (a comment, a mark of an object, nothing yet) it simply adds the mark.
    /// - nothing under the hand: a plain click lets go of everything; with ⇧ or ⌘ it does nothing,
    ///   a slip of the hand near the edge of a mark not being a reason to lose the selection.
    ///
    /// `seek` moves the cursor (the caller knows whether the engine is playing).
    func handleMarkBandClick(hit: AnnotationSel?, shift: Bool, cmd: Bool,
                             seek: ((Double) -> Void)? = nil) {
        guard let hit else {
            if !shift && !cmd { selectedAnnotations = [] }
            return
        }
        if cmd {
            if selectedAnnotations.contains(hit) {
                deselectAnnotation(hit)
            } else {
                selectAnnotations([hit], additive: true)
                annotationAnchor = hit
            }
            return
        }
        if shift {
            if !extendAnnotationSelection(to: hit) {
                selectAnnotations([hit], additive: true)
                if annotationAnchor == nil { annotationAnchor = hit }
            }
            return
        }
        selectAnnotations([hit])
        annotationAnchor = hit
        if case .laneMarker = hit, let t = marker(for: hit)?.time {
            caretLane = nil
            seek?(t)
        }
    }

    /// The ⇧ half of `handleMarkBandClick`: false when there is no usable anchor on the band, and
    /// the caller then falls back on adding the mark. The anchor is VALIDATED here every time —
    /// it may have gone with an undo or a deletion since it was laid.
    private func extendAnnotationSelection(to hit: AnnotationSel) -> Bool {
        guard case .laneMarker(let hitLane, _) = hit,
              let anchor = annotationAnchor, annotationExists(anchor),
              case .laneMarker(let anchorLane, _) = anchor,
              let a = marker(for: anchor), let h = marker(for: hit)
        else { return false }
        let rows = visibleMarkerLanes
        guard let ra = rows.firstIndex(where: { $0.id == anchorLane }),
              let rh = rows.firstIndex(where: { $0.id == hitLane }) else { return false }
        let lo = min(a.time, h.time), hi = max(a.endTime, h.endTime)
        var picked: [AnnotationSel] = []
        for row in rows[min(ra, rh)...max(ra, rh)] {
            for m in row.sortedMarkers where m.time <= hi + 1e-9 && m.endTime >= lo - 1e-9 {
                picked.append(.laneMarker(lane: row.id, marker: m.id))
            }
        }
        selectAnnotations(picked)
        return true
    }

    /// What a right click on `hit` is about: the whole selection when the mark aimed at belongs to
    /// it, else that mark ALONE — selected on the spot, so that what the menu acts on is what one
    /// sees highlighted. The menu then reads its targets from here and never from a selection that
    /// might have moved by the time an item is chosen.
    func annotationsForContextMenu(hit: AnnotationSel) -> [AnnotationSel] {
        if !selectedAnnotations.contains(hit) { selectAnnotation(hit) }
        return selectedAnnotations
    }

    /// The text an inline rename starts from, and where it is committed. Going through the
    /// selection rather than through three separate paths is what keeps ⌘R and the double click to
    /// one branch each.
    func annotationName(_ sel: AnnotationSel) -> String {
        switch sel {
        case .comment(let c): return comments.first { $0.id == c }?.text ?? ""
        default:              return marker(for: sel)?.name ?? ""
        }
    }

    /// The hue of whichever of the three kinds the selection names — the strict counterpart of
    /// `setAnnotationName`, and for the same reason: the right click has ONE colour item to build,
    /// not three.
    @discardableResult
    func setAnnotationColor(_ sel: AnnotationSel, colorIndex: Int?, pushesUndo: Bool = true) -> Bool {
        switch sel {
        case .laneMarker(let l, let m):
            return setMarkerColor(laneID: l, markerID: m, colorIndex: colorIndex, pushesUndo: pushesUndo)
        case .objectMarker(let o, let m):
            return setObjectMarkerColor(objectID: o, markerID: m, colorIndex: colorIndex, pushesUndo: pushesUndo)
        case .comment(let c):
            return setCommentColor(id: c, colorIndex: colorIndex, pushesUndo: pushesUndo)
        }
    }

    /// The same hue on SEVERAL marks, in ONE undo — the right click on a multiple selection.
    /// Returns how many took it.
    @discardableResult
    func setAnnotationsColor(_ sels: [AnnotationSel], colorIndex: Int?) -> Int {
        let live = uniqueLiveAnnotations(sels)
        guard !live.isEmpty else { return 0 }
        pushUndo()
        var done = 0
        for sel in live where setAnnotationColor(sel, colorIndex: colorIndex, pushesUndo: false) { done += 1 }
        return done
    }

    /// The hue that selection currently carries, nil when it inherits one.
    func annotationColor(_ sel: AnnotationSel) -> Int? {
        if case .comment(let c) = sel { return comments.first { $0.id == c }?.colorIndex }
        return marker(for: sel)?.colorIndex
    }

    @discardableResult
    func setAnnotationName(_ sel: AnnotationSel, to name: String, pushesUndo: Bool = true) -> Bool {
        switch sel {
        case .laneMarker(let l, let m):
            return renameMarker(laneID: l, markerID: m, to: name, pushesUndo: pushesUndo)
        case .objectMarker(let o, let m):
            return renameObjectMarker(objectID: o, markerID: m, to: name, pushesUndo: pushesUndo)
        case .comment(let c):
            return setCommentText(id: c, name, pushesUndo: pushesUndo)
        }
    }
}
