import Foundation

// The automation project — step 3: PUSHING THE CURVES TO THE ENGINE.
//
// The Swift model is the authority; the engine carries only a reflection of it, replaced wholesale
// every time (@see OBJEngineCore.setAutomationCurve:…). This file holds the only two things the
// engine cannot guess:
//
//   • the TIME CONVERSION. The points are stored in time RELATIVE to the start of the object
//     (@see AutomationPoint) — that is what makes a move or a trim touch no
//     point. The engine, for its part, reads its curves in EDIT time. The conversion is therefore
//     `startTime + t`, and it holds as it is inside a group: a group's ContainerClip
//     carries an offset equal to its start, so local time = edit time, at any
//     depth of nesting (@see refreshContainerSpanForKey:).
//
//   • the COMPOSITION WITH LISTENING. A volume curve ruling unshared would resurrect
//     a muted or un-soloed object. So on an object reduced to silence NO point is pushed:
//     the fader stays at the -96 dB laid down by `pushMix`, and the curve comes back as it is as soon as
//     the object becomes audible again (@see engineCurvePoints).
//
// THE COROLLARY, which is the whole wiring job: the object's geometry is part of the
// curve pushed. Anything that moves, trims, or rebuilds an object must push its
// curves again — the same call sites as `pushMix` / `syncPosition`, plus the paths that recreate
// the carrying plugins (compileRack for the trims, resyncAllSends for the sends).
//
// A STATIC FADER VS A CURVE: no offset, no composition. As soon as a parameter carries a
// point, the curve is the authority and the model's static setting is no longer heard — it stays written,
// and becomes the parameter's value again as soon as the last point goes (the engine takes the
// last explicit value back by itself). The interface greys the setting out so that this is legible
// (@see EditViewModel.isAutomated).
extension EditViewModel {

    // MARK: - Engine addressing

    /// The translation of a `ParamRef` into an engine target — the exact triple
    /// `setAutomationCurve:forObject:target:targetKey:paramID:` expects.
    static func engineTarget(for ref: ParamRef) -> (target: OBJAutomationTarget,
                                                   key: String?, paramID: String?) {
        switch ref {
        case .volume:          return (.volume,   nil, nil)
        case .pan:             return (.pan,      nil, nil)
        case .chainInGain:     return (.trimIn,   nil, nil)
        case .chainOutGain:    return (.trimOut,  nil, nil)
        case .send(let auxID): return (.send,     auxID.uuidString, nil)
        case .plugin(let pluginKey, let paramID):
            // `uuid` serves only the API's symmetry on the engine side: a pluginKey is unique in
            // the Edit, and it is the one that names the carrier (@see automatableParamForObject:).
            return (.plugin, pluginKey.uuidString, paramID)
        }
    }

    /// The parameters a push has to cover for this object: those whose engine chain carries
    /// the plugin, automated or not. The un-automated ones count — pushing an EMPTY
    /// list is how a curve removed from the model gets erased.
    ///
    /// PLUGIN parameters follow another rule, out of necessity: a single AU brings
    /// hundreds of them, and sweeping the whole rack on every push (hence on every frame of a drag)
    /// would cost one parameter lookup by name for nothing. So only those that CARRY
    /// a curve in the model are covered — and erasing those that no longer carry one is
    /// held separately, by the memory of what has already been pushed (@see pushAutomation).
    func pushableAutomationTargets(of object: SoundObject) -> [ParamRef] {
        [.volume, .pan, .chainInGain, .chainOutGain]
            + object.sends.map { .send(auxID: $0.auxID) }
            + object.automation.map(\.param).filter { if case .plugin = $0 { return true } else { return false } }
    }

    // MARK: - Conversion

    /// A parameter's points AS THE ENGINE MUST SEE THEM: edit time, the value in the parameter's
    /// unit, sorted, and empty when the curve must not rule. Empty ⇒ the parameter
    /// falls back on its static value.
    func engineCurvePoints(_ ref: ParamRef, on object: SoundObject) -> [[String: Any]] {
        // A composed silence (mute, stem mute, a solo elsewhere): the volume curve is set
        // aside, not transposed. An offset would "almost" silence it — here silence is what is wanted.
        if ref == .volume, isSilenced(object) { return [] }
        guard let lane = object.automation.first(where: { $0.param == ref }),
              !lane.points.isEmpty else { return [] }
        let origin = object.startTime
        // Conversion into EDIT time first, bounding second: a trim of the left edge leaves
        // points at a negative RELATIVE time (matter masked, not destroyed — @see
        // AutomationLane.shifted), and they are perfectly legitimate as long as `start + t` stays
        // positive. It is even what gives the parameter the right value from the clip's very first
        // frame. Only the TIMELINE's zero cannot be crossed, and the engine would clip there in
        // silence (@see AutomationCurveMath.clippedAtZero).
        let edit = AutomationCurveMath.clippedAtZero(
            lane.sortedPoints.map { AutomationPoint(t: origin + $0.t, v: $0.v, c: $0.c) },
            default: ref.neutralValue)
        // A plugin parameter is stored NORMALISED 0…1 and is not necessarily so on the engine side
        // (a built-in speaks in hertz or in dB, and the engine clamps to ITS range). This is the only
        // place where the two conventions meet (@see EditViewModel+AutomationTargets).
        guard case .plugin(let pluginKey, let paramID) = ref else {
            return edit.map { ["t": $0.t, "v": $0.v, "c": $0.c] }
        }
        return edit.map {
            ["t": $0.t,
             "v": denormalizedPluginValue($0.v, pluginKey: pluginKey, paramID: paramID),
             "c": $0.c]
        }
    }

    // MARK: - The push

    /// Pushes EVERY addressable curve of this object back to the engine. Idempotent, and free
    /// for an object with no automation (the engine returns straight away when the target curve is already empty).
    func pushAutomation(_ object: SoundObject) {
        guard let engine else { return }
        var refs = pushableAutomationTargets(of: object)

        // Erasing the PLUGIN curves removed from the model. They are not in
        // `pushableAutomationTargets` (see its comment), so nothing would erase them: we
        // keep track of the ones we pushed and cover them with an empty list once,
        // at the first push that no longer mentions them. It counts for real — the curve of a
        // plugin parameter lives in the plugin's ValueTree, hence in its `stateXML`, hence
        // would survive being saved.
        let live = Set(refs)
        if let stale = pushedPluginParams[object.id]?.subtracting(live), !stale.isEmpty {
            refs += stale
        }
        pushedPluginParams[object.id] = live.filter { if case .plugin = $0 { return true } else { return false } }

        for ref in refs {
            let t = Self.engineTarget(for: ref)
            engine.setAutomationCurve(engineCurvePoints(ref, on: object),
                                      forObject: object.id.uuidString,
                                      target: t.target,
                                      targetKey: t.key,
                                      paramID: t.paramID)
        }
    }

    /// The variant by id. No effect if the id is not that of a sound object (a stem bus,
    /// for instance: `compileRack` serves the stems too, and they have no automation).
    func pushAutomation(_ objectID: UUID) {
        guard let obj = find(id: objectID) else { return }
        pushAutomation(obj)
    }

    /// The object AND its descendants. What is needed after a gesture that moves a GROUP: its
    /// children have moved in edit time, so their curves have too.
    func pushAutomationTree(_ object: SoundObject) {
        pushAutomation(object)
        if case .group(let children, _) = object.kind {
            for child in children { pushAutomationTree(child) }
        }
    }

    /// The whole project. Reserved for the moments when the TOPOLOGY has changed without our being able to say which
    /// objects have lost their carrying plugins (loading, undo, recomposing groups): the
    /// sweep is a plain tree walk, and objects with no curve cost nothing.
    func pushAllAutomation() {
        for obj in allObjectsFlat where !obj.automation.isEmpty { pushAutomation(obj) }
    }

    // MARK: - Legibility on the interface side

    /// True if this parameter is driven by a curve — hence if its static setting is no longer
    /// heard. The views use it to grey out the corresponding control: without it, a fader that
    /// does nothing when moved would look like a breakdown.
    func isAutomated(_ ref: ParamRef, on object: SoundObject) -> Bool {
        object.automation.contains { $0.param == ref && !$0.points.isEmpty }
    }

    /// The same question by id — the convenient form for the views, which hold a selection id.
    func isAutomated(_ ref: ParamRef, on objectID: UUID) -> Bool {
        guard let obj = find(id: objectID) else { return false }
        return isAutomated(ref, on: obj)
    }
}
