import Foundation

// MARK: - The gain stage: the view-model's one door
//
// What the "+" drag lays (the gain, then the gain + pan + mute), what `plugin.add_gain_stage` lays,
// and where the card and `plugin.gain_stage` read and write. The stage itself is an ordinary leaf
// (@see GainStage.swift): adding one is inserting a plugin, and every existing machinery (copy, cut,
// link, FX link definitions, sends' mini-chains, consolidate, undo) takes it from there.

/// Why a stage could not be laid. The raw value is the API's `reason`.
enum GainStageRefusal: String, Error {
    case unknownHost   = "unknown_host"
    case unknownSeries = "unknown_series"
    /// The chain (or the send's mini-chain) has no room left.
    case chainFull
}

extension EditViewModel {

    // MARK: Reading

    /// The chain host whose chain holds the leaf `pluginID`, with the leaf: objects (at any depth),
    /// stems and the Main, and the sends' mini-chains. nil if no chain holds it.
    func chainEntry(ofPlugin pluginID: UUID) -> (host: UUID, plugin: ObjectPlugin)? {
        func leaf(_ plugins: [ObjectPlugin]) -> ObjectPlugin? {
            Self.flattenLeaves(plugins).first { $0.id == pluginID }
        }
        for o in allObjectsFlat {
            if let p = leaf(o.plugins) { return (o.id, p) }
            for s in o.sends {
                if let p = leaf(s.plugins) { return (SendChain.hostID(sender: o.id, aux: s.auxID), p) }
            }
        }
        for s in stems {
            if let p = leaf(s.plugins) { return (s.id, p) }
        }
        return nil
    }

    /// The gain stage `pluginID` and its host, nil when it is not a stage (or not found).
    func gainStageEntry(_ pluginID: UUID) -> (host: UUID, plugin: ObjectPlugin, face: GainStageFace)? {
        guard let e = chainEntry(ofPlugin: pluginID), let face = e.plugin.gainStageFace else { return nil }
        return (e.host, e.plugin, face)
    }

    /// What the stage is set to NOW: read from the live instance (its three parameters), the model's
    /// stored state when the engine does not hold it (not compiled yet). nil if not a stage.
    func gainStageValues(_ pluginID: UUID) -> GainStageValues? {
        guard let entry = gainStageEntry(pluginID) else { return nil }
        let params = getPluginParams(pluginID: pluginID)
        if params.count > GainStageValues.muteIndex {
            return GainStageValues(gainDb: params[GainStageValues.gainIndex].value,
                                   pan: params[GainStageValues.panIndex].value,
                                   muted: params[GainStageValues.muteIndex].value >= 0.5)
        }
        return entry.plugin.gainStageStoredValues ?? .neutral
    }

    // MARK: Laying one

    /// Lays a NEW gain stage of `face` into `series` of `host`'s chain, at `index` (the view's index,
    /// as everywhere: send markers do not count at the root; nil = the end of the series), born at
    /// `values`. ONE undo point. Returns the id of the stage THIS host now carries.
    ///
    /// Dropped into an ATTACHED FX link's block, the stage joins the bin's DEFINITION — every member
    /// gets an instance, linked — exactly as any plugin dropped there (@see fxAddPlugin). A send's
    /// mini-chain takes it like any leaf, within its own limit.
    func insertGainStage(host: UUID, series: SeriesLocation = .root, index: Int? = nil,
                         face: GainStageFace, values: GainStageValues = .neutral)
        -> Result<UUID, GainStageRefusal> {
        guard engine != nil, let chain = chainPlugins(host) else { return .failure(.unknownHost) }
        let values = values.clamped
        let stage = ObjectPlugin.makeGainStage(face: face, values: values)

        // The series must exist in this chain.
        switch series {
        case .root: break
        case .voice(let blockID, let vi):
            guard let b = Self.findEntry(blockID, in: chain), let rack = b.rack, vi >= 0, vi < rack.voices.count
            else { return .failure(.unknownSeries) }
        case .block(let blockID):
            guard Self.findBlock(blockID, in: chain) != nil else { return .failure(.unknownSeries) }
        }

        // An attached bin: the definition takes it, the members follow.
        if case .block(let blockID) = series, let block = Self.findBlock(blockID, in: chain),
           let fb = block.fxBlock, !fb.isDetached {
            guard let defID = fxAddPlugin(linkID: fb.linkID, template: stage, state: stage.stateXML, at: index),
                  let inst = chainPlugins(host).flatMap({ Self.flattenLeaves($0).first { $0.linkGroupID == defID } })
            else { return .failure(.chainFull) }
            return .success(inst.id)
        }

        if sendChainRefusal(adding: 1, to: host) != nil { return .failure(.chainFull) }

        pushUndo()
        let depth = undoStack.count
        updateChainPlugins(host) { p in
            p = Self.inserting(stage, into: series, at: index ?? Self.seriesLength(series, in: p), plugins: p)
        }
        if compileRack(objectID: host).contains(stage.id) {
            // The engine had no room: `compileRack` already took the entry back out of the model.
            // Nothing happened, so the point goes too.
            if undoStack.count == depth { _ = undoStack.popLast() }
            return .failure(.chainFull)
        }
        isDirty = true
        return .success(stage.id)
    }

    // MARK: Setting one

    /// Sets a stage's gain (dB, within ±24), pan (-1…1) and/or mute — through the plugin's own
    /// parameters, so that a linked instance (an FX link's member) follows, and the touched parameter
    /// names its automation row. `undo`: one point BEFORE the first write (the card's drag passes it
    /// on its start only). Returns false when `pluginID` is not a stage.
    @discardableResult
    func setGainStage(pluginID: UUID, gainDb: Float? = nil, pan: Float? = nil, muted: Bool? = nil,
                      undo: Bool = true) -> Bool {
        guard engine != nil, gainStageEntry(pluginID) != nil else { return false }
        if undo { pushUndo() }
        let r = GainStageValues.gainRange, pr = GainStageValues.panRange
        if let g = gainDb {
            setPluginParam(pluginID: pluginID, index: GainStageValues.gainIndex,
                           value: min(max(g, r.lowerBound), r.upperBound))
        }
        if let p = pan {
            setPluginParam(pluginID: pluginID, index: GainStageValues.panIndex,
                           value: min(max(p, pr.lowerBound), pr.upperBound))
        }
        if let m = muted {
            setPluginParam(pluginID: pluginID, index: GainStageValues.muteIndex, value: m ? 1 : 0)
        }
        // The model follows (the drawn waveform reads it): what the instance says now, the fields just
        // written laid over it as written — the engine's answer is not needed to know those.
        var v = gainStageValues(pluginID) ?? .neutral
        if let g = gainDb { v.gainDb = min(max(g, r.lowerBound), r.upperBound) }
        if let p = pan { v.pan = min(max(p, pr.lowerBound), pr.upperBound) }
        if let m = muted { v.muted = m }
        mirrorGainStageValues(pluginID, v)
        isDirty = true
        return true
    }

    // MARK: The model's mirror (the drawn waveform)

    /// Writes `values` into the MODEL's stored state of the stage `pluginID` — and of every stage
    /// LINKED to it (same `linkGroupID`: an FX link's members), which the engine's mirror
    /// makes follow by index. ONE write of `items`, so ONE invalidation: the same path the fader's
    /// value takes to the drawn waveform (@see GainStageDisplay). Objects only — their chains and their
    /// sends' mini-chains; a stem's chain is not drawn, and its state is captured from the engine at
    /// every save and undo point like every plugin's. Nothing is written when nothing differs.
    ///
    /// The value of a stage lives in its INSTANCE; this mirror is what lets the drawing read it without
    /// asking the engine at every frame. Every hand / API write goes through here (`setGainStage`,
    /// `plugin.set_param` on a stage); an undo / redo brings the model back with the states captured
    /// live, so it is right afterwards too.
    func mirrorGainStageValues(_ pluginID: UUID, _ values: GainStageValues) {
        guard let entry = chainEntry(ofPlugin: pluginID), entry.plugin.isGainStage else { return }
        let group = entry.plugin.linkGroupID
        func isTarget(_ p: ObjectPlugin) -> Bool {
            p.isGainStage && (p.id == pluginID || (group != nil && p.linkGroupID == group))
        }
        func patched(_ plugins: [ObjectPlugin], _ changed: inout Bool) -> [ObjectPlugin] {
            plugins.map { p in
                if p.isContainer {
                    return p.mappingChildSeries { patched($0, &changed) }
                }
                guard isTarget(p) else { return p }
                let q = p.withGainStageStoredValues(values)
                if q.stateXML != p.stateXML { changed = true }
                return q
            }
        }
        // The objects that hold a target, then ONE batched write.
        var hosts: Set<UUID> = []
        for o in allObjectsFlat {
            var leaves = Self.flattenLeaves(o.plugins)
            for s in o.sends { leaves += Self.flattenLeaves(s.plugins) }
            if leaves.contains(where: isTarget) { hosts.insert(o.id) }
        }
        guard !hosts.isEmpty else { return }
        // A dry run first: an unchanged mirror must not write `items` (a redraw of the whole timeline).
        var anyChange = false
        for o in allObjectsFlat where hosts.contains(o.id) {
            _ = patched(o.plugins, &anyChange)
            for s in o.sends { _ = patched(s.plugins, &anyChange) }
            if anyChange { break }
        }
        guard anyChange else { return }
        updateMany(hosts) { o in
            var changed = false
            o.plugins = patched(o.plugins, &changed)
            for i in o.sends.indices where !o.sends[i].plugins.isEmpty {
                o.sends[i].plugins = patched(o.sends[i].plugins, &changed)
            }
        }
    }

    /// The ATTACHED FX links whose common on/off is off: their blocks' stages are not heard, so the
    /// drawn waveform does not count them (@see GainStageDisplay). Read by the timeline's drawing; a
    /// toggle of a bin's on/off changes `fxLinks`, which redraws it.
    var offFXLinkIDs: Set<UUID> {
        var out: Set<UUID> = []
        for l in fxLinks where !l.isEnabled { out.insert(l.id) }
        return out
    }

    // MARK: Tree helpers

    /// The number of entries a series shows (the view's count: markers and picks do not count).
    static func seriesLength(_ series: SeriesLocation, in plugins: [ObjectPlugin]) -> Int {
        switch series {
        case .root:
            return plugins.filter { !$0.isChainMarker }.count
        case .voice(let blockID, let vi):
            guard let b = findEntry(blockID, in: plugins), let rack = b.rack, vi < rack.voices.count else { return 0 }
            return rack.voices[vi].filter { !$0.isChannelPick }.count
        case .block(let blockID):
            return (findBlock(blockID, in: plugins)?.fxBlock?.plugins ?? []).filter { !$0.isChannelPick }.count
        }
    }

    /// The entry `id` anywhere in the tree (a leaf, a rack's carrier or a bin's block).
    static func findEntry(_ id: UUID, in plugins: [ObjectPlugin]) -> ObjectPlugin? {
        for p in plugins {
            if p.id == id { return p }
            for s in p.childSeries { if let f = findEntry(id, in: s) { return f } }
        }
        return nil
    }
}
