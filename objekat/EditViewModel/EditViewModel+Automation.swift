import Foundation

// The automation project — the foundation (step 1) + editing the points (step 2).
//
// This file OPENS, NAMES and EDITS: toggling an object's automation band, composing the
// label of each of its rows, and mutating its points under the band's gestures
// (@see AutomationBandView). Every mutation ends with a `pushAutomation` — the push to the
// engine, written DIRECTLY into the parameter curves (not through `AutomationCurveModifier`),
// which lives in EditViewModel+AutomationEngine, where the relative time → edit time conversion
// and the composition with the listening silence are also held.
extension EditViewModel {

    // MARK: - Opening the band

    /// Unfolds/folds an object's automation band, under it, like an expanded group or a
    /// piano roll (@see SoundObject.expandedSpan). Pure UI: no engine call, only the open
    /// state is persisted — the same contract as `togglePianoRoll`.
    ///
    /// For a GROUP, opening the band hides its children without folding them: `isExpanded` is
    /// left as it is and the content comes back on closing (@see SoundObject.showsChildrenInline).
    func toggleAutomation(id: UUID) {
        setAutomationOpen(id: id, !(find(id: id)?.automationOpen ?? false))
    }

    /// Sets the automation band's open state. Used by the timeline's "content / automation"
    /// selector, which wants to set a value rather than toggle the other one.
    func setAutomationOpen(id: UUID, _ open: Bool) {
        update(id: id) { obj in obj.automationOpen = open }
        isDirty = true
    }

    /// True if this object offers a CHOICE between seeing its content and seeing its curves — hence
    /// if the selector has any reason to exist. An audio clip or an aux has no content to unfold: its
    /// band can only show automations, and the selector would have a single button.
    func hasAutomationSelector(_ object: SoundObject) -> Bool {
        object.isGroup || object.isMIDI
    }

    /// Applies one zone of the "objects / automations" hem (@see AutomationSelectorBezel.swift).
    /// A single entry point, because the three zones compose the SAME calls in different
    /// orders, and the order is a trap: `toggleGroupExpansion` and `togglePianoRoll`
    /// return early when the automation band is open (they give the content back
    /// first) — so the band must ALWAYS be closed first, otherwise their call toggles the
    /// unfolding instead of setting it.
    func applyAutomationSelector(_ hit: AutomationBezel.Hit, id: UUID) {
        guard let obj = find(id: id) else { return }
        switch hit {
        case .automations:
            setAutomationOpen(id: id, true)
        case .objects:
            setAutomationOpen(id: id, false)
            if obj.isGroup, !isGroupExpanded(id)   { toggleGroupExpansion(id: id) }
            if obj.isMIDI,  !obj.pianoRollOpen     { togglePianoRoll(id: id) }
        case .collapse:
            if obj.expandedSpan > 0 {
                setAutomationOpen(id: id, false)
                if obj.isGroup, isGroupExpanded(id) { toggleGroupExpansion(id: id) }
                if obj.isMIDI,  obj.pianoRollOpen   { togglePianoRoll(id: id) }
            } else {
                applyAutomationSelector(.objects, id: id)
            }
        }
    }

    // MARK: - Row labels

    /// The readable name of an automation row, on this object. `ParamRef.shortLabel` cannot
    /// name what lives elsewhere in the project: a send carries the name of its aux, a
    /// plugin parameter that of its plugin. The resolution therefore happens here, where the whole
    /// project is readable.
    func automationLabel(_ ref: ParamRef, on object: SoundObject) -> String {
        switch ref {
        case .volume, .pan, .chainInGain, .chainOutGain:
            return ref.shortLabel
        case .send(let auxID):
            let name = find(id: auxID)?.displayName ?? L("automation.label.unknownAux")
            return L("automation.label.send", name)
        case .plugin(let pluginKey, let paramID):
            let name = Self.pluginName(pluginKey, in: object) ?? L("automation.label.unknownPlugin")
            // The `paramID` is an addressing key, not a name: Tracktion returns the index ("12")
            // for an AU and the internal id for a VST3. The readable name lives only in the engine
            // instance (@see pluginParamInfos); failing that, the key beats nothing.
            let param = pluginParamInfos(pluginKey)[paramID]?.name ?? paramID
            return "\(name) · \(param)"
        }
    }

    /// The text of the figure shown during a gesture on a row. Redirects to `ParamRef.format`,
    /// EXCEPT for a plugin parameter: the model stores it normalised 0…1 (@see
    /// EditViewModel+AutomationTargets), and "0.73" says nothing when the plugin itself speaks in
    /// hertz. So the value is given in the parameter's own unit when the engine knows it for us.
    func automationReadout(_ ref: ParamRef, value: Float, on object: SoundObject) -> String {
        guard case .plugin(let pluginKey, let paramID) = ref,
              let info = pluginParamInfos(pluginKey)[paramID],
              info.range != 0...1 else { return ref.format(value) }
        return String(format: "%.2f", denormalizedPluginValue(value, pluginKey: pluginKey,
                                                              paramID: paramID))
    }

    /// The name of the plugin of id `key` in this object's chain (parallel blocks and instruments
    /// included). nil if the plugin has been removed since — a curve can survive its plugin,
    /// and the row must then say so rather than vanish silently.
    private static func pluginName(_ key: UUID, in object: SoundObject) -> String? {
        func search(_ plugins: [ObjectPlugin]) -> String? {
            for p in plugins {
                if let rack = p.rack {
                    for v in rack.voices { if let n = search(v) { return n } }
                } else if p.id == key {
                    return p.name
                }
            }
            return nil
        }
        return search(object.plugins) ?? search(object.instruments)
    }
}

// MARK: - Editing the points

// Points are designated by their STORAGE index, never by their rank in time: a drag
// that takes a point over its neighbour must not end up driving the other one
// halfway through. So the storage is never re-sorted (@see AutomationLane.points,
// whose comment already lays down this rule); only the display sorts, through `sortedPoints`.
extension EditViewModel {

    /// The start of a continuous gesture on a curve (dragging a point, a segment, the
    /// curvature, or the static value of an empty row): captures the undo ONCE for the whole
    /// gesture, as `beginMidiNoteEdit` does for the piano roll.
    func beginAutomationEdit() { pushUndo() }

    /// The STORED points of a parameter on this object (storage order, unsorted). Empty if that
    /// parameter is not automated.
    func automationPoints(_ objectID: UUID, _ param: ParamRef) -> [AutomationPoint] {
        find(id: objectID)?.automation.first(where: { $0.param == param })?.points ?? []
    }

    /// Creates a point and returns its storage index (nil if the object does not exist). Creates the
    /// curve along the way if this is the first point: that is the precise instant when "no point =
    /// no automation" tips over, and when the model's static value stops ruling alone.
    @discardableResult
    func addAutomationPoint(objectID: UUID, param: ParamRef,
                            t: Double, v: Float, c: Float = 0) -> Int? {
        var index: Int? = nil
        pushUndo()
        // The chain trims exist on the engine side only if the rack has been compiled — and it is
        // not, for an object with no plugin whose trims have stayed at 0 dB. Materialise it
        // BEFORE the first point, otherwise the curve would have no plugin to write itself into (the same
        // precaution as `setChainGain`, which compiles when the engine answers it "no rack").
        if param == .chainInGain || param == .chainOutGain,
           let obj = find(id: objectID), !obj.needsChainCompile {
            compileRack(objectID: objectID)
        }
        let ok = update(id: objectID) { obj in
            let pt = AutomationPoint(t: max(0, t),
                                     v: v.clamped(to: param.valueRange),
                                     c: c.clamped(to: -1...1))
            if let i = obj.automation.firstIndex(where: { $0.param == param }) {
                obj.automation[i].points.append(pt)
                index = obj.automation[i].points.count - 1
            } else {
                obj.automation.append(AutomationLane(param: param, points: [pt]))
                index = 0
            }
        }
        guard ok else { return nil }
        // A send whose static level is at -∞ has no plugin on the engine side: the first
        // point of its curve brings it alive, so it has to be wired BEFORE the curve is pushed.
        if case .send(let auxID) = param { syncSendEngine(objectID: objectID, auxID: auxID) }
        pushAutomation(objectID)
        isDirty = true
        return index
    }

    /// Removes a point. Removing the LAST point removes the whole curve: an entry with no
    /// point does not exist (an invariant), and the row becomes a static-value row again.
    func removeAutomationPoint(objectID: UUID, param: ParamRef, at index: Int) {
        pushUndo()
        update(id: objectID) { obj in
            guard let i = obj.automation.firstIndex(where: { $0.param == param }),
                  obj.automation[i].points.indices.contains(index) else { return }
            obj.automation[i].points.remove(at: index)
            if obj.automation[i].points.isEmpty { obj.automation.remove(at: i) }
        }
        // Removing the last point erases the curve on the engine side (an empty list pushed): the
        // parameter then takes its static value back on its own — and a send that falls back to -∞
        // unwires itself (symmetrical with `addAutomationPoint`).
        if case .send(let auxID) = param { syncSendEngine(objectID: objectID, auxID: auxID) }
        pushAutomation(objectID)
        isDirty = true
    }

    /// A live mutation of the points during a drag: no `pushUndo` (already done by
    /// `beginAutomationEdit`). The guard covers the WHOLE list — the value within the parameter's
    /// range, the curvature within -1…+1, the time positive. No UPPER bound on the time here: it
    /// depends on the band's width (an infinite bus has no end), hence on the gesture, which sets
    /// it itself.
    func updateAutomationPoints(objectID: UUID, param: ParamRef,
                                _ transform: (inout [AutomationPoint]) -> Void) {
        update(id: objectID) { obj in
            guard let i = obj.automation.firstIndex(where: { $0.param == param }) else { return }
            var pts = obj.automation[i].points
            transform(&pts)
            for k in pts.indices {
                pts[k].t = max(0, pts[k].t)
                pts[k].v = pts[k].v.clamped(to: param.valueRange)
                pts[k].c = pts[k].c.clamped(to: -1...1)
            }
            obj.automation[i].points = pts
        }
        // During a drag: one push per frame. This is a ValueTree write, not a graph
        // rebuild — the engine recomputes the parameter's iterator only once,
        // on a deferred timer (@see AutomationCurveSource).
        pushAutomation(objectID)
        isDirty = true
    }

    /// One wheel notch of CURVATURE on a segment (an alternative to ⌥drag). `steps` is
    /// counted UPWARDS, like the volume / pan / send notches of the same monitor.
    ///
    /// The sign follows the segment's direction: in the engine's model, a positive `c` hollows
    /// a rising segment but bulges a falling one. It is compensated so that the gesture keeps
    /// a single promise — the curve rises when you go up (@see AutomationBandView.curveDelta,
    /// which applies the same rule to the drag, with the mouse's inverted vertical axis).
    func adjustAutomationCurvature(objectID: UUID, param: ParamRef, at index: Int, steps: Int) {
        let pts = automationPoints(objectID, param)
        guard pts.indices.contains(index) else { return }
        // The segment's right-hand end = the next point in TIME, not in storage.
        guard let right = pts.filter({ $0.t > pts[index].t }).min(by: { $0.t < $1.t }) else { return }
        let sign: Float = right.v > pts[index].v ? -1 : 1
        let delta = Float(steps) * Self.automationCurveScrollStep * sign
        updateAutomationPoints(objectID: objectID, param: param) { p in
            guard p.indices.contains(index) else { return }
            p[index].c += delta
        }
    }

    /// The curvature added per wheel notch: 20 notches sweep the whole -1…+1 range.
    static let automationCurveScrollStep: Float = 0.05

    // MARK: - The PLAYED value (playback)

    /// What a curve is worth at the playback position, on this object. nil if the parameter is
    /// not automated, or if playback has not been through there yet.
    func liveAutomationValue(_ ref: ParamRef, on objectID: UUID) -> Float? {
        liveAutomationValues[objectID]?[ref]
    }

    /// Recomputes the played values at `editTime`, for the SELECTED objects. Called by the
    /// playhead tick (@see ObjekatSession.tickPlayhead), hence twenty times a second: it
    /// writes only if a figure has moved, otherwise it would invalidate the inspector continuously.
    ///
    /// The same conversion as the engine push — edit time = `startTime + t` (@see
    /// engineCurvePoints) — and the same interpolation function: what is shown is exactly what
    /// is heard.
    func refreshLiveAutomation(at editTime: Double) {
        var out: [UUID: [ParamRef: Float]] = [:]
        for id in selectedIDs {
            guard let o = find(id: id), !o.automation.isEmpty else { continue }
            var vals: [ParamRef: Float] = [:]
            for lane in o.automation where !lane.points.isEmpty {
                vals[lane.param] = AutomationCurveMath.value(at: editTime - o.startTime,
                                                             in: lane.sortedPoints,
                                                             default: lane.param.neutralValue)
            }
            if !vals.isEmpty { out[id] = vals }
        }
        if out != liveAutomationValues { liveAutomationValues = out }
    }

    // MARK: - A parameter's static value

    /// A parameter's STATIC value — the one the inspector sets, and the one that rules as long
    /// as no point exists. It is the solid line of an empty automation row, and what a
    /// drag on that row modifies (a decision: a row with no point is a fader, it does not
    /// manufacture points — otherwise "no point = no automation" would become
    /// unrecoverable the moment the row is brushed).
    ///
    /// nil for a PLUGIN parameter: its value does not live in the model but in the
    /// plugin itself (the model keeps only its `stateXML`), and reading it would take one engine
    /// query per render frame. Its row is therefore drawn on the value at rest and does not answer
    /// a static drag — until it carries a point.
    func automationStaticValue(_ ref: ParamRef, on object: SoundObject) -> Float? {
        switch ref {
        case .volume:            return object.volume
        case .pan:               return object.pan
        case .chainInGain:       return object.chainInGainDb
        case .chainOutGain:      return object.chainOutGainDb
        case .send(let auxID):   return sendLevel(from: object.id, to: auxID)
        case .plugin:            return nil
        }
    }

    /// The MODEL parameters that can be offered for automation on this object, those already
    /// automated aside: fader, pan, trims, sends. Plugin parameters have their own list
    /// (@see automatablePluginParams), because they run into the hundreds and are filed by
    /// plugin — mixing them in with these would drown the menu.
    func automatableParams(for object: SoundObject) -> [ParamRef] {
        pushableAutomationTargets(of: object)
            .filter { if case .plugin = $0 { return false } else { return true } }
            .filter { !isAutomated($0, on: object) }
    }

    /// The automatable parameters of this object's plugins, grouped BY PLUGIN and in the chain's
    /// order — the shape of a menu with sub-menus, the only one tenable when a single AU brings three
    /// hundred of them. Parameters already automated are removed (their row exists), and a plugin
    /// that leaves none disappears from the menu rather than opening an empty sub-menu in it.
    ///
    /// An external plugin whose instance is still loading answers nothing: it does not appear, and
    /// will reappear by itself the next time the menu is opened (@see pluginParamInfos, which takes
    /// good care not to cache an empty list).
    func automatablePluginParams(for object: SoundObject)
        -> [(plugin: ObjectPlugin, params: [(ref: ParamRef, name: String)])] {
        let leaves = SoundObject.pluginLeaves(object.instruments)
                   + SoundObject.pluginLeaves(object.plugins)
        return leaves.compactMap { plug in
            let params = pluginParamInfos(plug.id)
                .sorted { $0.value.index < $1.value.index }
                .map { (ref: ParamRef.plugin(pluginKey: plug.id, paramID: $0.key), name: $0.value.name) }
                .filter { !isAutomated($0.ref, on: object) }
            return params.isEmpty ? nil : (plugin: plug, params: params)
        }
    }

    /// Opens a parameter's row by laying ONE point in it, at `t` (relative), on its current
    /// STATIC value. Used by the band's context menu — the catch-up for a parameter
    /// that has not been touched recently, the normal way being to touch it (@see
    /// SoundObject.pendingAutomationParam). The first point is born on the current setting: an
    /// automation being born must start where the sound was, with no jump.
    ///
    /// A PLUGIN parameter has no static value in the model; its own is read from the
    /// engine, normalised over its range, so that its row too is born with no jump.
    func beginAutomationLane(objectID: UUID, param: ParamRef, at t: Double = 0) {
        guard let obj = find(id: objectID), !isAutomated(param, on: obj) else { return }
        var v = automationStaticValue(param, on: obj)
        if v == nil, case .plugin(let pluginKey, let paramID) = param {
            v = pluginCurrentValue(pluginKey: pluginKey, paramID: paramID)
        }
        addAutomationPoint(objectID: objectID, param: param, t: t, v: v ?? param.neutralValue)
    }

    /// Writes a parameter's static value, by the SAME paths as the inspector (hence
    /// with their engine push and their propagation to linked instances). No `pushUndo`:
    /// the gesture has already pushed one, once and for all.
    func setAutomationStaticValue(_ ref: ParamRef, on objectID: UUID, to value: Float) {
        let v = value.clamped(to: ref.valueRange)
        switch ref {
        case .volume:          updateVolume(id: objectID, volume: v)
        case .pan:             updatePan(id: objectID, pan: v)
        case .chainInGain:     setChainGain(objectID: objectID, output: false, dB: v)
        case .chainOutGain:    setChainGain(objectID: objectID, output: true,  dB: v)
        case .send(let auxID): setSendLevel(from: objectID, to: auxID, levelDb: v)
        case .plugin:          break   // no static value on the model side (see above)
        }
        isDirty = true
    }
}
