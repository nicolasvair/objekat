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

    // MARK: The zone's name

    /// What the timeline writes IN FRONT of a zone's name: the input's name ("[mic] Input → [folder] Name"),
    /// nil when the zone has no name of its own (its default name is the input's) or is no zone. Only
    /// the timeline draws it — the list and the inspector show the name alone.
    func recordZoneInputPrefix(of item: SoundObject) -> String? {
        guard item.isGroup, let source = item.recordSource else { return nil }
        return RecordZoneName.prefix(label: item.label, inputName: sourceName(source))
    }

    /// The glyph written in front of the prefix: a mic for a card input, keys for a MIDI input.
    func recordZoneInputGlyph(of item: SoundObject) -> String {
        item.recordMidiInput != nil ? ObjectKindIcon.recordMidiInput : ObjectKindIcon.recordInput
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
        guard let source = item.recordSource, Self.isRecordableZone(item) else { return nil }
        switch source {
        case .audio(let ref):
            guard InputPairing.isPresent(ref, channelCount: channels, pairs: recordInputs.pairs) else { return .absent }
        case .midi(let ref):
            guard resolvedMidiInput(ref) != nil else { return .absent }
        }
        return armedGroupIDs.contains(item.id) ? .armed : .idle
    }

    /// Why this group cannot be armed; nil when it can.
    func armRefusal(of id: UUID) -> String? {
        guard let item = find(id: id) else { return "unknown object" }
        guard item.isGroup else { return "only a group can record" }
        guard Self.isRecordableZone(item) else { return "an infinite, looping or consolidated group cannot record" }
        guard let source = item.recordSource else { return "the group has no input" }
        guard isRecordSourcePresent(source) else {
            if case .midi = source { return "the group's MIDI input is not there" }
            return "the group's input is not on the card (or the inputs are closed)"
        }
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

    /// The zones a click on the [ o ] of `clicked` acts on. A zone that is PART of the selection brings
    /// along the other selected zones that can take the change (an input on the card, a group that can
    /// record) — the others are passed over without a word; a zone outside the selection acts alone and
    /// the selection stays as it is (the rule of the plugin cards). `clicked` comes first.
    func armTargets(clicked: UUID) -> [UUID] {
        guard selectedIDs.contains(clicked), selectedIDs.count > 1 else { return [clicked] }
        let others = selectedIDs.filter { $0 != clicked && armRefusal(of: $0) == nil }.sorted { a, b in
            let sa = find(id: a)?.startTime ?? 0, sb = find(id: b)?.startTime ?? 0
            return sa != sb ? sa < sb : a.uuidString < b.uuidString
        }
        return [clicked] + others
    }

    /// Arms or disarms several zones at once, each as `setArmed` would. Returns the refusals by id (the
    /// zones that could not take the change); an empty dictionary when all went through.
    @discardableResult
    func setArmed(ids: [UUID], on: Bool) -> [UUID: String] {
        var refusals: [UUID: String] = [:]
        for id in ids {
            if let why = setArmed(id, on: on) { refusals[id] = why }
        }
        return refusals
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
    /// A zone that records only MIDI writes no file: it does not need the folder.
    var canRecord: Bool {
        let zones = armedRecordZones
        guard !zones.isEmpty else { return false }
        return projectURL != nil || zones.allSatisfy { find(id: $0)?.recordMidiInput != nil }
    }

    // MARK: Assigning

    /// Gives a group its input (or takes it away with nil). Not when the group cannot record, and not
    /// while a recording runs (the zone's input is frozen at the press, like the stereo pairs:
    /// `inputPairsLocked`). One undo point, none when nothing changes. Returns whether the group now has
    /// `ref`.
    @discardableResult
    func assignRecordInput(_ ref: InputRef?, toGroup id: UUID) -> Bool {
        assignRecordSource(ref.map { .audio($0) }, toGroup: id)
    }

    /// Same, for a source that may be a MIDI input (a zone has ONE source: the new one replaces the other kind).
    /// Changing a zone's kind of source does not carry its MIDI instrument along: it is dropped with the source.
    @discardableResult
    func assignRecordSource(_ source: RecordSource?, toGroup id: UUID) -> Bool {
        guard !isRecording else { return false }
        guard let item = find(id: id), Self.isRecordableZone(item) else { return false }
        if item.recordSource == source { return true }
        // An AUDIO source on a zone that carries (or sits under) an instrument is refused (E5).
        if case .audio = source, refusesAudioInput(on: id) { return false }
        pushUndo()
        applyRecordSource(source, toGroup: id)
        return true
    }

    /// The change itself, for a caller that owns the undo point (a drop of several inputs makes ONE).
    private func applyRecordSource(_ source: RecordSource?, toGroup id: UUID) {
        update(id: id) { o in o.recordSource = source }
        if source == nil { armedGroupIDs.remove(id) }
        syncArmedInputs()   // an armed zone changed input: the hidden tracks follow
        syncMidiZones()
        isDirty = true
    }

    // MARK: Dropping

    /// What the lane `displayLane` holds, as the planner reads it; nil when it is not a row of the
    /// timeline (inside a clip's piano roll or an automation band). Reads the model, changes nothing.
    private func recordLaneContext(_ displayLane: Int, entries: [LaneEntry]) -> RecordZonePlanner.LaneContext? {
        if entries.contains(where: { e in
            !e.item.showsChildrenInline && e.expandedSpan > 0
                && displayLane > e.displayLane && displayLane <= e.displayLane + e.expandedSpan
        }) { return nil }

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
        return .init(objects: objects, selection: selection, parent: parent)
    }

    /// What dropping `count` inputs at (`time`, `displayLane`) would do — one plan per input, on the
    /// lane of the hand and the ones below it. Reads the model, changes nothing.
    func planRecordDrops(count: Int, displayLane: Int, time: Double, visibleSpanSecs: Double,
                         pixelsPerSecond pps: Double) -> [RecordZonePlanner.Plan] {
        let entries = laneEntries
        return RecordZonePlanner.planMany(time: time, firstLane: displayLane, count: count,
                                          visibleSpanSecs: visibleSpanSecs, pixelsPerSecond: pps) {
            recordLaneContext($0, entries: entries)
        }
    }

    /// What dropping ONE input at (`time`, `displayLane`) would do.
    func planRecordDrop(displayLane: Int, time: Double, visibleSpanSecs: Double,
                        pixelsPerSecond pps: Double) -> RecordZonePlanner.Plan {
        planRecordDrops(count: 1, displayLane: displayLane, time: time, visibleSpanSecs: visibleSpanSecs,
                        pixelsPerSecond: pps)[0]
    }

    /// The ghost for a plan: what the timeline draws under the cursor.
    func recordDropGhost(for plan: RecordZonePlanner.Plan, ref: InputRef, displayLane: Int,
                         time: Double) -> RecordDropGhost {
        recordDropGhost(for: plan, source: .audio(ref), displayLane: displayLane, time: time)
    }

    /// Same, for a source that may be a MIDI input.
    func recordDropGhost(for plan: RecordZonePlanner.Plan, source: RecordSource, displayLane: Int,
                         time: Double) -> RecordDropGhost {
        let name = sourceName(source)
        switch plan {
        case .create(let start, let end, _):
            return RecordDropGhost(kind: .create, displayLane: displayLane, start: start, end: end,
                                   name: name)
        case .assign(let id):
            let entry = laneEntry(forID: id)
            let start = entry?.absStart ?? time
            return RecordDropGhost(kind: .assign, displayLane: displayLane, start: start,
                                   end: start + (entry?.item.duration ?? 1), name: name)
        case .refuse:
            return RecordDropGhost(kind: .refused, displayLane: displayLane, start: max(0, time),
                                   end: max(0, time) + 1, name: "")
        }
    }

    /// The ghosts of a drop of several inputs, one per lane: all red as soon as one lane is refused.
    func recordDropGhosts(for plans: [RecordZonePlanner.Plan], refs: [InputRef], displayLane: Int,
                          time: Double) -> [RecordDropGhost] {
        recordDropGhosts(for: plans, sources: refs.map { .audio($0) }, displayLane: displayLane, time: time)
    }

    /// Same, for sources that may be MIDI inputs.
    func recordDropGhosts(for plans: [RecordZonePlanner.Plan], sources: [RecordSource], displayLane: Int,
                          time: Double) -> [RecordDropGhost] {
        let refused = RecordZonePlanner.isRefused(plans)
        return plans.indices.map { i in
            let lane = displayLane + i
            return refused
                ? RecordDropGhost(kind: .refused, displayLane: lane, start: max(0, time),
                                  end: max(0, time) + 1, name: "")
                : recordDropGhost(for: plans[i], source: sources[i], displayLane: lane, time: time)
        }
    }

    /// Carries out the drop of ONE input: a zone is born, or a group takes the input, or nothing. Returns
    /// the plan that was followed and the group concerned (a refusal changes nothing and pushes no undo).
    @discardableResult
    func dropRecordInput(_ ref: InputRef, displayLane: Int, time: Double, visibleSpanSecs: Double,
                         pixelsPerSecond pps: Double) -> (plan: RecordZonePlanner.Plan, group: UUID?) {
        let r = dropRecordInputs([ref], displayLane: displayLane, time: time,
                                 visibleSpanSecs: visibleSpanSecs, pixelsPerSecond: pps)
        return (r.plans[0], r.groups[0])
    }

    /// Gives the zone `id` the chain `chain` copied from an input — the ONE function behind a new zone and a group that
    /// was entirely empty (`RecordDropInheritance`). The FX are laid and compiled here unless the zone was born with them
    /// (`fxAlreadyPlaced`: they went through `placeClip`); the instrument goes in once the zone is in place, because the
    /// group rule needs its place to answer. A refused instrument leaves the zone without one, with the usual alert.
    /// Records what was copied for `rec.drop`.
    private func giveInheritedChain(_ chain: InheritedChain, to id: UUID, fxAlreadyPlaced: Bool) {
        guard !chain.isNothing else { return }
        if !fxAlreadyPlaced, !chain.plugins.isEmpty {
            update(id: id) { $0.plugins = chain.plugins }
            compileRack(objectID: id)
        }
        var instrumentName: String? = nil
        if let inst = chain.instrument, !refusesInstrument(on: id) {
            update(id: id) { $0.instruments = [inst] }
            if let updated = find(id: id) { syncInstruments(updated) }
            refreshPassiveChains()
            instrumentName = inst.name
        }
        if !chain.plugins.isEmpty || instrumentName != nil {
            lastDropInheritance[id] = InheritedInput(fx: Self.flattenLeaves(chain.plugins).count, instrument: instrumentName)
        }
    }

    /// Carries out the drop of several inputs, `refs` in the order of the lanes they take downwards from
    /// `displayLane`: each becomes a zone (or goes to the group on its lane), ALL in ONE undo point —
    /// taken before the first change, and not at all for a refusal (global: one lane refused, nothing
    /// is done) or when nothing would change. Every zone made or reached is selected. `groups` is aligned
    /// with `plans` (nil for a refusal).
    @discardableResult
    func dropRecordInputs(_ refs: [InputRef], displayLane: Int, time: Double, visibleSpanSecs: Double,
                          pixelsPerSecond pps: Double) -> (plans: [RecordZonePlanner.Plan], groups: [UUID?]) {
        dropRecordSources(refs.map { .audio($0) }, displayLane: displayLane, time: time,
                          visibleSpanSecs: visibleSpanSecs, pixelsPerSecond: pps)
    }

    /// The same drop, with sources that may be MIDI inputs (a mixed drag: one lane per source, in the order
    /// given). A MIDI source makes a zone with the MIDI input and no instrument yet.
    @discardableResult
    func dropRecordSources(_ refs: [RecordSource], displayLane: Int, time: Double, visibleSpanSecs: Double,
                           pixelsPerSecond pps: Double) -> (plans: [RecordZonePlanner.Plan], groups: [UUID?]) {
        let plans = planRecordDrops(count: refs.count, displayLane: displayLane, time: time,
                                    visibleSpanSecs: visibleSpanSecs, pixelsPerSecond: pps)
        var groups = [UUID?](repeating: nil, count: plans.count)
        lastDropInheritance = [:]
        guard !plans.isEmpty, !RecordZonePlanner.isRefused(plans) else { return (plans, groups) }

        // An instrument group takes no audio source (E5): the whole drop is refused, whole, before any undo point.
        for (i, plan) in plans.enumerated() {
            guard case .audio = refs[i] else { continue }
            switch plan {
            case .assign(let id):
                if find(id: id)?.recordSource != refs[i], refusesAudioInput(on: id) { return (plans, groups) }
            case .create(let start, let end, _):
                var zone = SoundObject(startTime: start, duration: end - start, lane: displayLane + i,
                                       label: nil, kind: .group(children: [], isExpanded: false))
                zone.recordSource = refs[i]
                if refusesPlacing([zone], snapshot: laneEntries) { return (plans, groups) }
            case .refuse:
                break
            }
        }

        // What each lane copies from its input, worked out BEFORE the undo point: whether a redrop of the same source
        // on a still-empty group changes anything depends on it (RecordDropInheritance).
        let copies: [InheritedChain] = plans.indices.map { i in
            switch plans[i] {
            case .create:
                return inheritedChain(for: refs[i])
            case .assign(let id):
                guard let zone = find(id: id), RecordDropInheritance.copiesChain(ontoExisting: zone) else { return .none }
                return inheritedChain(for: refs[i])
            case .refuse:
                return .none
            }
        }
        let changes = plans.indices.contains { i in
            switch plans[i] {
            case .create: return true
            case .assign(let id): return find(id: id)?.recordSource != refs[i] || !copies[i].isNothing
            case .refuse: return false
            }
        }
        if changes { pushUndo() }   // BEFORE the first change, one for the whole gesture

        var spent = false   // the time selection is consumed by the zone that took exactly its in/out
        for (i, plan) in plans.enumerated() {
            let ref = refs[i]
            switch plan {
            case .refuse:
                break
            case .assign(let id):
                if find(id: id)?.recordSource != ref { applyRecordSource(ref, toGroup: id) }
                // An entirely empty group takes the input's chain like a new zone; any other keeps its own.
                giveInheritedChain(copies[i], to: id, fxAlreadyPlaced: false)
                groups[i] = id
            case .create(let start, let end, _):
                // The zone is born WITHOUT a label: its default name is its input's (`displayName(of:)`), as
                // an unnamed group takes the name composed from its content — only a name typed later is a
                // group name (@see `RecordZoneName`). `placeClip` puts it where the lane says — at the top
                // level, or inside the open group whose sub-lanes contain it (the same rule as the planner's).
                var zone = SoundObject(startTime: start, duration: end - start, lane: displayLane + i,
                                       label: nil, kind: .group(children: [], isExpanded: false))
                zone.recordSource = ref
                // A NEW zone starts with a copy of what its input carries (E11): the FX of a card input, the FX AND the
                // instrument of a MIDI input. The FX are on the zone before it is placed (the add compiles them as a paste).
                zone.plugins = copies[i].plugins
                let placed = placeClip(zone, snapshot: laneEntries)
                giveInheritedChain(copies[i], to: placed.id, fxAlreadyPlaced: true)
                // A zone of the selection starts at its in and ends at its out, or earlier (an object behind).
                if let s = timeSelection, start == max(0, s.timeRange.lowerBound),
                   end <= s.timeRange.upperBound { spent = true }
                groups[i] = placed.id
            }
        }
        if spent { timeSelection = nil }
        selectedIDs = Set(groups.compactMap { $0 })
        if changes { isDirty = true }
        return (plans, groups)
    }
}

/// The chain a drop copies from an input: the FX, and the instrument of a MIDI input (independent copies).
struct InheritedChain {
    var plugins: [ObjectPlugin] = []
    var instrument: ObjectPlugin? = nil

    static let none = InheritedChain()
    var isNothing: Bool { plugins.isEmpty && instrument == nil }
}

/// What a recording zone took from its input when it was born (docs/plan_groupes_midi.md, E11).
struct InheritedInput: Equatable {
    /// Cards copied from a card input's chain.
    var fx: Int
    /// The instrument copied from a MIDI input's, by name.
    var instrument: String?
}
