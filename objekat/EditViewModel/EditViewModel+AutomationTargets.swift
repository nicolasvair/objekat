import Foundation

// The automation project — step 4: THE TARGET SELECTOR.
//
// An object's automation band must open on the parameter that has just been set, whatever
// it is. This file holds the two halves of that promise:
//
//   • THE CAPTURE — "this parameter has just been touched on this object". Two sources, because
//     there are two ways of setting a parameter in Objekat:
//       - the MODEL parameters (fader, pan, chain trims, send level) all go through
//         a view-model setter, which calls `recordAutomationTouch`; nothing to listen to;
//       - PLUGIN parameters only go through the model for built-ins (whose editor
//         is in SwiftUI, hence `setPluginParam`). A knob turned in the native GUI of an AU/VST
//         never crosses the bridge: the engine has to say so. That is `onPluginParamTouched`,
//         armed ONLY for as long as an editor is open (@see OBJEngineCore, which explains
//         why that tiny scope is enough).
//     The memory itself lives in the model (@see SoundObject.automationTouchOrder): it is
//     persisted, and above all it leaves `automationRows` a computed property of the model alone.
//
//   • THE DESCRIPTION — a plugin parameter's readable name and range. `ParamRef.plugin` carries
//     only a (pluginKey, paramID) pair; the NAME ("Frequency") and the bounds live only in
//     the engine instance. They are read once per plugin and kept: the band redraws on
//     every frame, it cannot query the engine for every row.
//
// THE VALUE CONVENTION, decided here: a plugin parameter's curve is stored NORMALISED
// 0…1 in the model (@see ParamRef.valueRange), and denormalised at push time. This is
// necessary, not cosmetic: Tracktion normalises the parameters of an EXTERNAL plugin, but not
// those of a built-in, whose range is in real units (a frequency runs from 30 to 18000 Hz) and to
// which the engine clamps everything pushed at it. Without this convention the same curve would
// mean two things depending on the plugin's family, and the band's vertical axis would have no scale.
extension EditViewModel {

    // MARK: - The description of a plugin parameter

    /// What the engine knows about a parameter and `ParamRef` does not carry.
    struct PluginParamInfo: Equatable {
        /// The rank in `getPluginParams:` — the index `setPluginParam` expects.
        let index: Int
        /// The readable name as the plugin announces it ("Frequency", "Mix"…).
        let name: String
        /// The parameter's REAL range on the engine side. 0…1 for an AU/VST (Tracktion normalises them),
        /// real units for a built-in.
        let range: ClosedRange<Float>
    }

    /// A plugin's automatable parameters, by `paramID`. Read once then kept: an instance's ranges
    /// and names do not change.
    ///
    /// An EMPTY answer is not cached: an external plugin whose instance is still loading
    /// answers empty, and that "not yet" would become a definitive "never".
    func pluginParamInfos(_ pluginKey: UUID) -> [String: PluginParamInfo] {
        if let cached = pluginParamInfoCache[pluginKey] { return cached }
        guard let raw = engine?.getPluginParams(pluginKey.uuidString) as? [[String: Any]],
              !raw.isEmpty else { return [:] }
        var out: [String: PluginParamInfo] = [:]
        for (i, d) in raw.enumerated() {
            guard let pid = d["paramID"] as? String else { continue }
            let lo = (d["minValue"] as? Float) ?? 0
            let hi = (d["maxValue"] as? Float) ?? 1
            out[pid] = PluginParamInfo(index: i,
                                       name: (d["name"] as? String) ?? pid,
                                       range: lo <= hi ? lo...hi : hi...lo)
        }
        pluginParamInfoCache[pluginKey] = out
        return out
    }

    /// Forgets what was known about a plugin. To be called when its INSTANCE changes — not when its
    /// settings change: a removal, a replacement, a project reload give another instance under the
    /// same key, and sometimes another list of parameters.
    func invalidatePluginParamInfos(_ pluginKey: UUID? = nil) {
        if let pluginKey { pluginParamInfoCache[pluginKey] = nil }
        else             { pluginParamInfoCache.removeAll() }
        // The VALUES read from that instance go with it: another instance under the same
        // key has no reason to be set the same way, and the offered row would show a figure
        // that is no longer its own (@see pluginParamValues).
        if let pluginKey {
            pluginParamValues = pluginParamValues.filter {
                if case .plugin(let k, _) = $0.key { return k != pluginKey }
                return true
            }
        } else {
            pluginParamValues.removeAll()
        }
    }

    /// A model value (0…1) → an ENGINE value, in the parameter's unit. The identity for an AU/VST.
    func denormalizedPluginValue(_ v: Float, pluginKey: UUID, paramID: String) -> Float {
        guard let info = pluginParamInfos(pluginKey)[paramID] else { return v }
        let lo = info.range.lowerBound, hi = info.range.upperBound
        return lo + v.clamped(to: 0...1) * (hi - lo)
    }

    /// A plugin parameter's CURRENT value, brought back to 0…1. Read from the engine, the only place
    /// it lives (the model keeps only the plugin's `stateXML`). Used to have a parameter's first
    /// row born on its current setting, hence with no jump of sound. nil if the
    /// engine does not know this parameter — plugin removed, or an external instance not yet loaded.
    ///
    /// A READ, not a subscription: the engine is queried at the moment of the gesture, never during
    /// the band's rendering, which redraws on every frame.
    func pluginCurrentValue(pluginKey: UUID, paramID: String) -> Float? {
        guard let info = pluginParamInfos(pluginKey)[paramID],
              let raw = engine?.getPluginParams(pluginKey.uuidString) as? [[String: Any]],
              info.index < raw.count,
              let v = raw[info.index]["value"] as? Float else { return nil }
        let lo = info.range.lowerBound, hi = info.range.upperBound
        guard hi > lo else { return 0 }
        return ((v - lo) / (hi - lo)).clamped(to: 0...1)
    }

    /// A parameter's CURRENT value as the band SHOWS it — the model's when it carries it,
    /// otherwise the plugin's last known value (@see pluginParamValues). A pure and free read:
    /// callable in the middle of a render, unlike `pluginCurrentValue`.
    ///
    /// nil as long as a plugin parameter's value has never been seen going past — that is the signal
    /// to go and fetch it ONCE (@see refreshPluginParamValue), not to invent one.
    func automationDisplayValue(_ ref: ParamRef, on object: SoundObject) -> Float? {
        if let v = automationStaticValue(ref, on: object) { return v }
        guard case .plugin = ref else { return nil }
        return pluginParamValues[ref]
    }

    /// Goes and reads a plugin parameter's value from the engine and keeps it. To be called when the
    /// OFFERED row changes, never during a render: it is an engine query (@see
    /// pluginCurrentValue). Does nothing if the value is already known — the bridge keeps it up to date
    /// for as long as an editor is open, and outside an editor it no longer moves.
    func refreshPluginParamValue(_ ref: ParamRef) {
        guard case .plugin(let pluginKey, let paramID) = ref,
              pluginParamValues[ref] == nil,
              let v = pluginCurrentValue(pluginKey: pluginKey, paramID: paramID) else { return }
        pluginParamValues[ref] = v
    }

    // MARK: - Capturing the touches

    /// Remembers "this parameter has just been set on this object". This is where the row of
    /// "automation to come" comes from (@see SoundObject.pendingAutomationParam).
    ///
    /// Deliberately WITHOUT `pushUndo` and without marking the project modified: it is the trace of a
    /// gesture, not an edit. A `⌘Z` after moving a fader must undo the fader, not undo the
    /// memory of having moved it. And the call is free when the parameter is already at the head — by
    /// far the most frequent case, a drag passing through here on every frame.
    func recordAutomationTouch(_ objectID: UUID, _ ref: ParamRef) {
        guard let obj = find(id: objectID), obj.automationTouchOrder.first != ref else { return }
        update(id: objectID) { $0.recordAutomationTouch(ref) }
    }

    /// A plugin parameter has just been touched, named by the key the ENGINE uses.
    /// Finds the object carrying it: the bridge knows only plugins, not objects.
    func recordPluginParamTouch(pluginKey: UUID, paramID: String) {
        guard let objectID = objectIDOwningPlugin(pluginKey) else { return }
        recordAutomationTouch(objectID, .plugin(pluginKey: pluginKey, paramID: paramID))
    }

    /// The object whose chain (FX or instrument, the branches of parallel blocks included) carries this
    /// plugin. nil if the plugin no longer belongs to anybody — a removal whose editor has not
    /// been closed again yet, for instance.
    func objectIDOwningPlugin(_ pluginKey: UUID) -> UUID? {
        allObjectsFlat.first {
            SoundObject.containsPlugin(pluginKey, in: $0.plugins)
                || SoundObject.containsPlugin(pluginKey, in: $0.instruments)
        }?.id
    }

    // MARK: - Listening to open editors

    /// Arms the listening for parameter touches on a plugin whose editor has just opened.
    /// Idempotent — reopening an already open editor merely brings it back to the front.
    ///
    /// BUILT-IN editors go through here all the same even though their sliders call
    /// `setPluginParam` (already caught on the Swift side): a built-in can also be driven by the LINK
    /// between instances, where it is the engine that pushes the value. A single rule — an open editor
    /// is listened to — beats two paths to keep in agreement.
    func beginPluginParamTouchWatch(_ pluginKey: UUID) {
        engine?.beginPluginParamTouchWatch(pluginKey.uuidString)
    }

    /// Stops the listening. To be called on EVERY editor closing, and before removing a plugin:
    /// the listening retains the plugin, leaving it armed would keep it alive for nothing.
    func endPluginParamTouchWatch(_ pluginKey: UUID) {
        engine?.endPluginParamTouchWatch(pluginKey.uuidString)
    }
}
