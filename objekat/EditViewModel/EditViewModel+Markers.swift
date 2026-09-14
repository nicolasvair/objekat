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
        if case .laneMarker(let l, _) = selectedAnnotation, l == id { selectedAnnotation = nil }
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

    @discardableResult
    func removeMarker(laneID: UUID, markerID: UUID) -> Bool {
        guard let li = markerLanes.firstIndex(where: { $0.id == laneID }),
              let mi = markerLanes[li].markers.firstIndex(where: { $0.id == markerID })
        else { return false }
        pushUndo()
        markerLanes[li].markers.remove(at: mi)
        if selectedAnnotation == .laneMarker(lane: laneID, marker: markerID) { selectedAnnotation = nil }
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
    func setMarkerColor(laneID: UUID, markerID: UUID, colorIndex: Int?) -> Bool {
        guard let li = markerLanes.firstIndex(where: { $0.id == laneID }),
              let mi = markerLanes[li].markers.firstIndex(where: { $0.id == markerID })
        else { return false }
        pushUndo()
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
        if selectedAnnotation == .laneMarker(lane: source, marker: markerID) {
            selectedAnnotation = .laneMarker(lane: target, marker: markerID)
        }
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
    func removeObjectMarker(objectID: UUID, markerID: UUID) -> Bool {
        guard let object = find(id: objectID),
              object.markers.contains(where: { $0.id == markerID }) else { return false }
        pushUndo()
        update(id: objectID) { $0.markers.removeAll { $0.id == markerID } }
        if selectedAnnotation == .objectMarker(object: objectID, marker: markerID) {
            selectedAnnotation = nil
        }
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

    /// The hue of a marker carried by an object. nil = white, which is what a mark laid on matter
    /// wants by default: it has to read against any waveform under it.
    @discardableResult
    func setObjectMarkerColor(objectID: UUID, markerID: UUID, colorIndex: Int?) -> Bool {
        guard let object = find(id: objectID),
              object.markers.contains(where: { $0.id == markerID }) else { return false }
        pushUndo()
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

    // MARK: Comments

    /// Lays a comment over a span of the timeline. `lane` is a DISPLAY row, the same frame the
    /// time selection speaks in.
    @discardableResult
    func addComment(from: Double, to: Double, lane: Int, text: String = "") -> UUID? {
        let lo = min(from, to), hi = max(from, to)
        guard hi - lo > 1e-9 else { return nil }
        pushUndo()
        // No hue drawn from the palette: a comment is born WHITE, so that it never reads as one
        // more object laid on the lane (@see TimelineComment.colorIndex). A colour is something one
        // then CHOOSES, to sort the notes among themselves.
        let c = TimelineComment(startTime: max(0, lo), duration: hi - max(0, lo),
                                lane: max(0, lane), text: text)
        comments.append(c)
        isDirty = true
        return c.id
    }

    @discardableResult
    func removeComment(id: UUID) -> Bool {
        guard let idx = comments.firstIndex(where: { $0.id == id }) else { return false }
        pushUndo()
        comments.remove(at: idx)
        if selectedAnnotation == .comment(id) { selectedAnnotation = nil }
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
    func setCommentColor(id: UUID, colorIndex: Int?) -> Bool {
        guard let idx = comments.firstIndex(where: { $0.id == id }) else { return false }
        pushUndo()
        comments[idx].colorIndex = colorIndex
        isDirty = true
        return true
    }

    @discardableResult
    func moveComment(id: UUID, to start: Double, duration: Double? = nil, lane: Int? = nil,
                     pushesUndo: Bool = true) -> Bool {
        guard let idx = comments.firstIndex(where: { $0.id == id }) else { return false }
        if pushesUndo { pushUndo() }
        comments[idx].startTime = max(0, start)
        if let d = duration { comments[idx].duration = max(1e-3, d) }
        if let l = lane     { comments[idx].lane = max(0, l) }
        isDirty = true
        return true
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

    /// ⌫ on a selected annotation. Returns false if there was nothing to delete, so the key handler
    /// can fall through to its next branch rather than swallowing the key.
    @discardableResult
    func deleteSelectedAnnotation() -> Bool {
        guard let sel = selectedAnnotation else { return false }
        switch sel {
        case .laneMarker(let l, let m):   return removeMarker(laneID: l, markerID: m)
        case .objectMarker(let o, let m): return removeObjectMarker(objectID: o, markerID: m)
        case .comment(let c):             return removeComment(id: c)
        }
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
    func setAnnotationColor(_ sel: AnnotationSel, colorIndex: Int?) -> Bool {
        switch sel {
        case .laneMarker(let l, let m):   return setMarkerColor(laneID: l, markerID: m, colorIndex: colorIndex)
        case .objectMarker(let o, let m): return setObjectMarkerColor(objectID: o, markerID: m, colorIndex: colorIndex)
        case .comment(let c):             return setCommentColor(id: c, colorIndex: colorIndex)
        }
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
