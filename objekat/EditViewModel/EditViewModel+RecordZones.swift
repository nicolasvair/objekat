import Foundation

// MARK: - Recording zones: an input dropped on the timeline, assigned to a group, armed
//
// A recording zone is a GROUP with a `recordInput`. Three things happen to it here, none of which records
// (that is the next increment): an input dragged from the Inputs tab creates one or is assigned to an
// existing group (`dropRecordInput`, the rules are `RecordZonePlanner`'s), a group's input can be set or
// cleared (`assignRecordInput`), and a zone can be armed (`setArmed`).
//
// Undo: the creation and the assignment are edits of the matter, the undo point comes BEFORE the first
// change and is never pushed for a refusal. Arming is not an edit — it is session state, like the
// playback loop: not saved, not in the undo.

/// What the timeline shows under the cursor while an input is dragged over it.
struct RecordDropGhost: Equatable {
    enum Kind: Equatable { case create, assign, refused }
    var kind: Kind
    var displayLane: Int
    /// Where the zone would stand (create), the group's own span (assign), or the stretch under the
    /// cursor (refused).
    var start: Double
    var end: Double
    var name: String
}

extension EditViewModel {

    // MARK: Which groups can record

    /// A group that can be a recording zone: not an infinite bus (no window), not looping (its window is
    /// a porthole onto a pattern), not an instance of a consolidated object. The same rule for the drop
    /// and for the arming.
    static func isRecordableZone(_ item: SoundObject) -> Bool {
        item.isGroup && !item.isInfinite && !item.loopEnabled && !item.isConsolidateInstance
    }

    // MARK: Is the input there?

    /// Whether the card has `ref` right now. The channel count is `AudioDeviceStatus`'s — observable, and
    /// 0 while the inputs are closed, so a project opened before "Enable inputs" has every zone greyed.
    func isRecordInputPresent(_ ref: InputRef) -> Bool {
        InputPairing.isPresent(ref, channelCount: AudioDeviceStatus.shared.snapshot.inputChannels,
                               pairs: recordInputs.pairs)
    }

    // MARK: Arming

    /// How the [o] of a zone looks, nil when there is none (no input, or a group that cannot record).
    /// `channels` is the card's input channel count, read ONCE by the caller for a whole pass.
    func recordZoneIcon(of item: SoundObject, channels: Int) -> RecordZoneIcon.State? {
        guard let ref = item.recordInput, Self.isRecordableZone(item) else { return nil }
        guard InputPairing.isPresent(ref, channelCount: channels, pairs: recordInputs.pairs) else { return .absent }
        return armedGroupIDs.contains(item.id) ? .armed : .idle
    }

    /// Why this group cannot be armed; nil when it can.
    func armRefusal(of id: UUID) -> String? {
        guard let item = find(id: id) else { return "unknown object" }
        guard item.isGroup else { return "only a group can record" }
        guard Self.isRecordableZone(item) else { return "an infinite, looping or consolidated group cannot record" }
        guard let ref = item.recordInput else { return "the group has no input" }
        guard isRecordInputPresent(ref) else { return "the group's input is not on the card (or the inputs are closed)" }
        return nil
    }

    /// Arms or disarms. nil on success, otherwise why not. Disarming is always possible.
    @discardableResult
    func setArmed(_ id: UUID, on: Bool) -> String? {
        if on {
            if let why = armRefusal(of: id) { return why }
            if !armedGroupIDs.contains(id) { armedGroupIDs.insert(id) }
        } else if armedGroupIDs.contains(id) {
            armedGroupIDs.remove(id)
        }
        return nil
    }

    /// The zones armed AND still able to record, in timeline order. An armed group that has been deleted,
    /// emptied of its input or whose input left the card simply stops counting.
    var armedRecordZones: [UUID] {
        guard !armedGroupIDs.isEmpty else { return [] }
        return armedGroupIDs.filter { armRefusal(of: $0) == nil }.sorted { a, b in
            let sa = find(id: a)?.startTime ?? 0, sb = find(id: b)?.startTime ?? 0
            return sa != sb ? sa < sb : a.uuidString < b.uuidString
        }
    }

    /// The transport's record button is live: something is armed, and the project has a folder to put the
    /// takes in (a project never saved has none).
    var canRecord: Bool { projectURL != nil && !armedRecordZones.isEmpty }

    // MARK: Assigning

    /// Gives a group its input (or takes it away with nil). Not when the group cannot record. One undo
    /// point, none when nothing changes. Returns whether the group now has `ref`.
    @discardableResult
    func assignRecordInput(_ ref: InputRef?, toGroup id: UUID) -> Bool {
        guard let item = find(id: id), Self.isRecordableZone(item) else { return false }
        if item.recordInput == ref { return true }
        pushUndo()
        update(id: id) { $0.recordInput = ref }
        if ref == nil { armedGroupIDs.remove(id) }
        isDirty = true
        return true
    }

    // MARK: Dropping

    /// What dropping `ref` at (`time`, `displayLane`) would do. Reads the model, changes nothing.
    func planRecordDrop(displayLane: Int, time: Double, visibleSpanSecs: Double,
                        pixelsPerSecond pps: Double) -> RecordZonePlanner.Plan {
        let entries = laneEntries

        // A lane inside a clip's piano roll or an automation band is not a row of the timeline.
        if entries.contains(where: { e in
            !e.item.showsChildrenInline && e.expandedSpan > 0
                && displayLane > e.displayLane && displayLane <= e.displayLane + e.expandedSpan
        }) { return .refuse(.onObject) }

        let container = containerGroupEntry(forDisplayLanes: [displayLane])
        let parent = container.map { c in
            RecordZonePlanner.Parent(
                id: c.item.id,
                allowed: Self.isRecordableZone(c.item) && !isInConsolidateEditStack(c.item.id))
        }
        let parentID = container?.item.id
        let objects: [RecordZonePlanner.LaneObject] = entries.compactMap { e in
            guard e.displayLane == displayLane, e.parentID == parentID else { return nil }
            let kind: RecordZonePlanner.LaneObject.Kind = e.item.isGroup
                ? .group(recordable: Self.isRecordableZone(e.item)) : .other
            // An infinite bus has no window: its band runs the length of the project.
            if e.item.isInfiniteBus {
                return .init(id: e.item.id, start: 0, end: .infinity, kind: kind)
            }
            return .init(id: e.item.id, start: e.absStart, end: e.absStart + e.item.duration, kind: kind)
        }
        let selection = timeSelection.map {
            RecordZonePlanner.Selection(start: $0.timeRange.lowerBound, end: $0.timeRange.upperBound,
                                        lanes: $0.lanes)
        }
        return RecordZonePlanner.plan(time: time, displayLane: displayLane,
                                      visibleSpanSecs: visibleSpanSecs, pixelsPerSecond: pps,
                                      laneObjects: objects, selection: selection, parent: parent)
    }

    /// The ghost for a plan: what the timeline draws under the cursor.
    func recordDropGhost(for plan: RecordZonePlanner.Plan, ref: InputRef, displayLane: Int,
                         time: Double) -> RecordDropGhost {
        switch plan {
        case .create(let start, let end, _):
            return RecordDropGhost(kind: .create, displayLane: displayLane, start: start, end: end,
                                   name: inputName(ref))
        case .assign(let id):
            let entry = laneEntry(forID: id)
            let start = entry?.absStart ?? time
            return RecordDropGhost(kind: .assign, displayLane: displayLane, start: start,
                                   end: start + (entry?.item.duration ?? 1), name: inputName(ref))
        case .refuse:
            return RecordDropGhost(kind: .refused, displayLane: displayLane, start: max(0, time),
                                   end: max(0, time) + 1, name: "")
        }
    }

    /// Carries out the drop: a zone is born, or a group takes the input, or nothing. Returns the plan that
    /// was followed and the group concerned (a refusal changes nothing and pushes no undo point).
    @discardableResult
    func dropRecordInput(_ ref: InputRef, displayLane: Int, time: Double, visibleSpanSecs: Double,
                         pixelsPerSecond pps: Double) -> (plan: RecordZonePlanner.Plan, group: UUID?) {
        let plan = planRecordDrop(displayLane: displayLane, time: time,
                                  visibleSpanSecs: visibleSpanSecs, pixelsPerSecond: pps)
        var group: UUID? = nil
        switch plan {
        case .refuse:
            break
        case .assign(let id):
            assignRecordInput(ref, toGroup: id)
            selectedIDs = [id]
            group = id
        case .create(let start, let end, _):
            pushUndo()
            // The group carries the input's NAME; `placeClip` puts it where the lane says — at the top
            // level, or inside the open group whose sub-lanes contain it (the same rule as the planner's).
            var zone = SoundObject(startTime: start, duration: end - start, lane: displayLane,
                                   label: inputName(ref), kind: .group(children: [], isExpanded: false))
            zone.recordInput = ref
            let placed = placeClip(zone, snapshot: laneEntries)
            if let s = timeSelection, s.timeRange.lowerBound == start, s.timeRange.upperBound == end {
                timeSelection = nil
            }
            selectedIDs = [placed.id]
            isDirty = true
            group = placed.id
        }
        return (plan, group)
    }
}
