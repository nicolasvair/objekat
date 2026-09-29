import SwiftUI

// MARK: - Signal view ↔ real model mapping (step 2 — batch 3)
//
// The signal view is driven by the REAL `[ObjectPlugin]` tree (series plus parallel blocks
// carried by `ObjectPlugin.rack`). We build a `SynopticNode` (the view) from that model,
// and every action from the view falls back on a mutation of the model tree plus a
// recompilation of the engine rack (see EditViewModel.compileRack).

/// Locates a SERIES in the model tree, so as to target an insertion: the root (the trunk),
/// or the branch `voiceIndex` of a parallel block carried by the `ObjectPlugin` `blockID`.
enum SeriesLocation: Hashable {
    case root
    case voice(blockID: UUID, voiceIndex: Int)
    /// The single series of an FX link's block (`ObjectPlugin.fxBlock`): what a hand drops into is
    /// the bin's DEFINITION, so the gestures aimed here are redirected to the bin
    /// (@see EditViewModel+FXLink).
    case block(blockID: UUID)

    var key: String {
        switch self {
        case .root:                       return "root"
        case .voice(let b, let i):        return "voice-\(b.uuidString)-\(i)"
        case .block(let b):               return "block-\(b.uuidString)"
        }
    }
}

enum SynopticMapping {
    /// Builds the signal graph from the `[ObjectPlugin]` tree (recursive over the voices of a
    /// `rack` block) plus the `seriesID → SeriesLocation` table that lets the insertion actions
    /// find the right series again. The series/branch ids are regenerated on every build: the
    /// action closures capture the table from the SAME build, so it is consistent.
    static func build(_ plugins: [ObjectPlugin], objectID: UUID, levels: [UUID: Double] = [:],
                      fxLinkInfo: ((ObjectPlugin) -> SynopticFXLink?)? = nil)
        -> (node: SynopticNode, locations: [UUID: SeriesLocation]) {
        var locations: [UUID: SeriesLocation] = [:]
        let node = buildSeries(plugins, seriesID: objectID, location: .root,
                               locations: &locations, levels: levels, fxLinkInfo: fxLinkInfo)
        return (node, locations)
    }

    private static func buildSeries(_ plugins: [ObjectPlugin], seriesID: UUID,
                                    location: SeriesLocation,
                                    locations: inout [UUID: SeriesLocation],
                                    levels: [UUID: Double],
                                    fxLinkInfo: ((ObjectPlugin) -> SynopticFXLink?)?) -> SynopticNode {
        locations[seriesID] = location
        let children: [SynopticNode] = plugins.map { p in
            if let rack = p.rack {
                let gains = EditViewModel.paddedWetDb(rack.wetDb, count: rack.voices.count)
                let mutes = EditViewModel.paddedMutes(rack.voiceMutes, count: rack.voices.count)
                let voices: [SynopticNode] = rack.voices.enumerated().map { vi, voice in
                    var vnode = buildSeries(voice, seriesID: UUID(),
                                            location: .voice(blockID: p.id, voiceIndex: vi),
                                            locations: &locations, levels: levels,
                                            fxLinkInfo: fxLinkInfo)
                    vnode.voiceGainDb = gains[vi]   // the end-of-branch dB gain → a UI control
                    vnode.voiceMuted  = mutes[vi]   // the branch's mute → a UI button
                    return vnode
                }
                return SynopticNode(id: p.id, kind: .parallel(voices))
            }
            if let block = p.fxBlock {
                // A bin's block: a series of its instances, framed and controlled as ONE thing.
                var node = buildSeries(block.plugins, seriesID: p.id, location: .block(blockID: p.id),
                                       locations: &locations, levels: levels, fxLinkInfo: fxLinkInfo)
                node.fxLink = fxLinkInfo?(p)
                // The block carries the link and the common on/off: its cards show no badge of their
                // own, and are drawn greyed (their own on/off untouched) while the bin is off.
                let greyed = node.fxLink.map { !$0.isEnabled } ?? false
                if case .series(let kids) = node.kind {
                    node.kind = .series(kids.map { kid in
                        guard case .plugin(var sp) = kid.kind else { return kid }
                        sp.inFXBlock = true
                        sp.greyedByBlock = greyed
                        var k = kid
                        k.kind = .plugin(sp)
                        return k
                    })
                }
                return node
            }
            return SynopticNode(id: p.id, kind: .plugin(leaf(p, vu: levels[p.id] ?? 0)))
        }
        return SynopticNode(id: seriesID, kind: .series(children))
    }

    static func leaf(_ p: ObjectPlugin, vu: Double = 0) -> SynopticPlugin {
        SynopticPlugin(id: p.id, name: p.name, category: .infer(from: p),
                       isEnabled: p.isEnabled, vu: vu,
                       isBuiltIn: p.isBuiltIn, formatLabel: p.formatLabel,
                       isLinked: p.isLinked, isLinkDetached: p.isLinkDetached,
                       color: p.color)
    }
}

// MARK: - Model tree mutations (by value, recursive) plus signal view actions

extension EditViewModel {

    /// Every plugin leaf of the object, voices flattened (for openEditor / states).
    func leafPlugins(objectID: UUID) -> [ObjectPlugin] {
        Self.flattenLeaves(chainPlugins(objectID) ?? [])
    }

    static func flattenLeaves(_ plugins: [ObjectPlugin]) -> [ObjectPlugin] {
        plugins.flatMap { p -> [ObjectPlugin] in
            if p.isContainer { return p.childSeries.flatMap { flattenLeaves($0) } }
            return [p]
        }
    }

    private func makeObjectPlugin(_ a: AvailablePlugin) -> ObjectPlugin {
        ObjectPlugin(id: UUID(), name: a.name, manufacturer: a.manufacturer,
                     identifier: a.identifier, formatName: a.formatName)
    }

    /// The signal view's '+': inserts a new plugin into the target series, at the given index.
    func synopticInsert(objectID: UUID, available: AvailablePlugin,
                        into location: SeriesLocation, at index: Int) {
        guard let plugins = chainPlugins(objectID) else { return }
        // Dropped into an ATTACHED block, a new plugin joins the bin's DEFINITION (every member gets
        // an instance); the editor opens on this host's own.
        if case .block(let blockID) = location,
           let block = Self.findBlock(blockID, in: plugins), let fb = block.fxBlock, !fb.isDetached {
            let template = makeObjectPlugin(available)
            guard let defID = fxAddPlugin(linkID: fb.linkID, template: template, at: index) else {
                availablePlugins.removeAll { $0.identifier == available.identifier && $0.formatName == available.formatName }
                return
            }
            if let inst = chainPlugins(objectID).flatMap({ Self.flattenLeaves($0).first { $0.linkGroupID == defID } }) {
                if inst.isBuiltIn { openBuiltInPluginEditor(plug: inst) }
                else { openPluginEditor(objectID: objectID, pluginID: inst.id) }
            }
            return
        }
        let newPlug = makeObjectPlugin(available)
        pushUndo()
        updateChainPlugins(objectID) { $0 = Self.inserting(newPlug, into: location, at: index, plugins: plugins) }
        if compileRack(objectID: objectID).contains(newPlug.id) {
            availablePlugins.removeAll { $0.identifier == available.identifier && $0.formatName == available.formatName }
        } else if newPlug.isBuiltIn {
            openBuiltInPluginEditor(plug: newPlug)
        } else {
            openPluginEditor(objectID: objectID, pluginID: newPlug.id)
        }
        isDirty = true
    }

    /// The signal view's '//': puts the element in parallel with an EMPTY BRANCH (just a gain at
    /// the end plus a '+' to add a plugin to it). No picker. A plugin → a 2-branch block (the
    /// element plus an empty branch); an existing block → one more empty branch.
    func synopticBranch(objectID: UUID, elementID: UUID) {
        guard let plugins = chainPlugins(objectID),
              fxDefinition(ofInstance: elementID, on: objectID) == nil else { return }   // a bin's instance is not put in parallel on its own
        pushUndo()
        updateChainPlugins(objectID) { $0 = Self.branchingEmpty(plugins, elementID: elementID) }
        compileRack(objectID: objectID)
        isDirty = true
    }

    /// Removes a branch from a parallel block (along with its gain). If the block falls below 2
    /// branches, it is inlined (back to a series).
    func removeVoice(objectID: UUID, blockID: UUID, voiceIndex: Int) {
        guard let plugins = chainPlugins(objectID) else { return }
        pushUndo()
        updateChainPlugins(objectID) { $0 = Self.removingVoice(blockID, voiceIndex, in: plugins) }
        compileRack(objectID: objectID)
        isDirty = true
    }

    /// Drag-reordering in the signal view: moves `pluginID` to the series `location` at the given
    /// index (the same branch, another branch, or the root). The engine instance is preserved
    /// (the same id, reused by the reconciliation). A no-op if the plugin is not in the object.
    func synopticReorder(objectID: UUID, pluginID: UUID, to location: SeriesLocation, at index: Int) {
        // A bin's BLOCK dragged by its header moves as one piece, instances and all.
        if let plugins = chainPlugins(objectID), Self.findBlock(pluginID, in: plugins) != nil {
            moveFXBlock(hostID: objectID, blockID: pluginID, to: location, at: index)
            return
        }
        guard let plugins = chainPlugins(objectID),
              let (srcLoc, srcIdx) = Self.locate(pluginID, in: plugins),
              let plug = Self.flattenLeaves(plugins).first(where: { $0.id == pluginID }) else { return }
        // Inside an ATTACHED block the order is the bin's: reordering there reorders the definition,
        // for every member; and an instance does not leave its block, nor does a plugin enter one
        // from outside by this gesture (the drop of a plugin ON a bin adds to the definition — see
        // fxAddPlugin — and belongs to the timeline drag, not to a reorder).
        if let def = fxDefinition(ofInstance: pluginID, on: objectID) {
            guard case .block(let dst) = location,
                  let block = Self.findBlock(dst, in: plugins), block.fxBlock?.linkID == def.linkID else { return }
            var target = index
            if srcLoc == location && srcIdx < index { target = index - 1 }
            fxMovePlugin(linkID: def.linkID, definitionID: def.definitionID, to: target)
            return
        }
        if case .block(let dst) = location, let block = Self.findBlock(dst, in: plugins),
           block.fxBlock?.isDetached == false { return }
        // The same series: removing upstream shifts the following indices → adjust the target.
        var target = index
        if srcLoc == location && srcIdx < index { target = index - 1 }
        if srcLoc == location && target == srcIdx { return }   // no movement
        pushUndo()
        let removed = Self.removingPlugins([pluginID], from: plugins)
        let inserted = Self.inserting(plug, into: location, at: target, plugins: removed)
        updateChainPlugins(objectID) { $0 = Self.simplifyTree(inserted) }
        compileRack(objectID: objectID)
        isDirty = true
    }

    /// The signal view's ⌥-drag: an independent COPY of `pluginID` into the series `location` at
    /// `index` (a new UUID, the state captured from the live instance, no link). A no-op if absent.
    func synopticCopyPlugin(objectID: UUID, pluginID: UUID, to location: SeriesLocation, at index: Int) {
        guard let plugins = chainPlugins(objectID),
              let plug = Self.flattenLeaves(plugins).first(where: { $0.id == pluginID }) else { return }
        // A copy does not land INSIDE an attached block: the instances are the bin's to decide.
        if case .block(let dst) = location, let block = Self.findBlock(dst, in: plugins),
           block.fxBlock?.isDetached == false { return }
        let live = engine?.getPluginStateXML(pluginID.uuidString)
        let stateXML = (live?.isEmpty == false) ? live : plug.stateXML
        let copy = ObjectPlugin(id: UUID(), name: plug.name, manufacturer: plug.manufacturer,
                                identifier: plug.identifier, formatName: plug.formatName,
                                isEnabled: plug.isEnabled, stateXML: stateXML, linkGroupID: nil)
        pushUndo()
        updateChainPlugins(objectID) {
            $0 = Self.simplifyTree(Self.inserting(copy, into: location, at: index, plugins: plugins))
        }
        compileRack(objectID: objectID)
        isDirty = true
    }

    /// Dropping a plugin ONTO a card (a branch's axis): inserts `pluginID` into the SAME branch
    /// as `targetPluginID`, just before it. `copy` (⌥) → a copy, otherwise a move. It allows
    /// dropping on the axis and not only on the small '+'.
    func synopticDropOnPlugin(objectID: UUID, pluginID: UUID, targetPluginID: UUID, copy: Bool) {
        guard pluginID != targetPluginID,
              let plugins = chainPlugins(objectID),
              let (loc, idx) = Self.locate(targetPluginID, in: plugins) else { return }
        if copy {
            synopticCopyPlugin(objectID: objectID, pluginID: pluginID, to: loc, at: idx)
        } else {
            synopticReorder(objectID: objectID, pluginID: pluginID, to: loc, at: idx)
        }
    }

    /// Locates a plugin in the tree: (the containing series, the index within that series).
    static func locate(_ pluginID: UUID, in plugins: [ObjectPlugin],
                       location: SeriesLocation = .root) -> (SeriesLocation, Int)? {
        for (i, p) in plugins.enumerated() {
            if p.id == pluginID { return (location, i) }
            if let rack = p.rack {
                for (vi, voice) in rack.voices.enumerated() {
                    if let found = locate(pluginID, in: voice,
                                          location: .voice(blockID: p.id, voiceIndex: vi)) {
                        return found
                    }
                }
            } else if let block = p.fxBlock {
                if let found = locate(pluginID, in: block.plugins, location: .block(blockID: p.id)) {
                    return found
                }
            }
        }
        return nil
    }

    // MARK: Tree helpers (static)

    /// wetDb (the dB gain per branch) aligned on `count` voices: padded/truncated at 0 dB.
    static func paddedWetDb(_ wetDb: [Float]?, count: Int) -> [Float] {
        var w = wetDb ?? []
        if w.count < count { w += Array(repeating: 0, count: count - w.count) }
        else if w.count > count { w = Array(w.prefix(count)) }
        return w
    }

    /// voiceMutes aligned on `count` voices: padded/truncated to false by default.
    static func paddedMutes(_ mutes: [Bool]?, count: Int) -> [Bool] {
        var m = mutes ?? []
        if m.count < count { m += Array(repeating: false, count: count - m.count) }
        else if m.count > count { m = Array(m.prefix(count)) }
        return m
    }

    /// The EFFECTIVE dB gain per branch (exact silence if the branch is muted): pushed to the engine.
    static func effectiveWetDb(_ rack: PluginRack) -> [Float] {
        let w = paddedWetDb(rack.wetDb, count: rack.voices.count)
        let m = paddedMutes(rack.voiceMutes, count: rack.voices.count)
        return zip(w, m).map { gain, muted in muted ? objGainSilenceDb : gain }
    }

    /// The entry carrying a parallel block (not a real plugin: neutral fields, only `rack` counts).
    static func rackCarrier(voices: [[ObjectPlugin]]) -> ObjectPlugin {
        ObjectPlugin(id: UUID(), name: "//", manufacturer: "", identifier: "", formatName: "",
                     rack: PluginRack(voices: voices,
                                      wetDb: Array(repeating: 0, count: voices.count)))
    }

    /// Puts the element in parallel with an EMPTY branch (the gain-only path). A plugin → a
    /// 2-branch block ([element], []); an existing block → one more empty branch. The new branch has a 0 dB gain.
    static func branchingEmpty(_ plugins: [ObjectPlugin], elementID: UUID) -> [ObjectPlugin] {
        plugins.map { p in
            if p.id == elementID {
                if var rack = p.rack {                       // an existing block → one more empty branch
                    rack.voices.append([])
                    rack.wetDb = paddedWetDb(rack.wetDb, count: rack.voices.count)  // the added branch = 0 dB
                    var np = p; np.rack = rack; return np
                }
                return rackCarrier(voices: [[p], []])        // a plugin → a 2-branch block (a real one and an empty one)
            }
            if p.isContainer { return p.mappingChildSeries { branchingEmpty($0, elementID: elementID) } }
            return p
        }
    }

    /// Removes branch `vi` from block `blockID` (and its gain). Fewer than 2 branches left → inline (un-parallel).
    static func removingVoice(_ blockID: UUID, _ vi: Int, in plugins: [ObjectPlugin]) -> [ObjectPlugin] {
        plugins.flatMap { p -> [ObjectPlugin] in
            if p.id == blockID, var rack = p.rack, vi >= 0, vi < rack.voices.count {
                var w = paddedWetDb(rack.wetDb, count: rack.voices.count)
                var m = paddedMutes(rack.voiceMutes, count: rack.voices.count)
                rack.voices.remove(at: vi); w.remove(at: vi); m.remove(at: vi)
                rack.wetDb = w; rack.voiceMutes = m
                if rack.voices.count < 2 { return rack.voices.first ?? [] }
                var np = p; np.rack = rack; return [np]
            }
            if p.isContainer { return [p.mappingChildSeries { removingVoice(blockID, vi, in: $0) }] }
            return [p]
        }
    }

    static func inserting(_ newPlug: ObjectPlugin, into location: SeriesLocation,
                          at index: Int, plugins: [ObjectPlugin]) -> [ObjectPlugin] {
        switch location {
        case .root:
            var a = plugins
            a.insert(newPlug, at: min(max(0, index), a.count))
            return a
        case .voice(let blockID, let vi):
            return plugins.map { p in
                if p.id == blockID, var rack = p.rack, vi < rack.voices.count {
                    var voice = rack.voices[vi]
                    voice.insert(newPlug, at: min(max(0, index), voice.count))
                    rack.voices[vi] = voice
                    var np = p; np.rack = rack; return np
                }
                if p.isContainer {
                    return p.mappingChildSeries { inserting(newPlug, into: location, at: index, plugins: $0) }
                }
                return p
            }
        case .block(let blockID):
            return plugins.map { p in
                if p.id == blockID, var block = p.fxBlock {
                    block.plugins.insert(newPlug, at: min(max(0, index), block.plugins.count))
                    var np = p; np.fxBlock = block; return np
                }
                if p.isContainer {
                    return p.mappingChildSeries { inserting(newPlug, into: location, at: index, plugins: $0) }
                }
                return p
            }
        }
    }

    /// Sets a plugin's `isEnabled` (recursive over the voices).
    static func settingEnabled(_ id: UUID, _ enabled: Bool, in plugins: [ObjectPlugin]) -> [ObjectPlugin] {
        plugins.map { p in
            if p.id == id { var np = p; np.isEnabled = enabled; return np }
            if p.isContainer { return p.mappingChildSeries { settingEnabled(id, enabled, in: $0) } }
            return p
        }
    }

    /// The dB gain of a parallel block's branch: updates the model (`wetDb`) then the live gain
    /// plugin on the engine side (lightly, without recompiling → no glitch while dragging).
    func setVoiceGain(objectID: UUID, blockID: UUID, voiceIndex: Int, dB: Float) {
        updateChainPlugins(objectID) { p in
            p = Self.settingVoiceGain(blockID, voiceIndex, dB, in: p)
        }
        // Pushes the EFFECTIVE gain: if the branch is muted, it stays silent even while dragging.
        let eff = chainPlugins(objectID).flatMap { Self.effectiveVoiceGain(blockID, voiceIndex, in: $0) } ?? dB
        engine?.setVoiceGain(eff, forBlockID: blockID.uuidString,
                             voiceIndex: Int32(voiceIndex), objectID: objectID.uuidString)
        isDirty = true
    }

    /// Writes the dB gain of branch `vi` of block `blockID` into `wetDb` (recursive over the voices).
    static func settingVoiceGain(_ blockID: UUID, _ vi: Int, _ dB: Float,
                                 in plugins: [ObjectPlugin]) -> [ObjectPlugin] {
        plugins.map { p in
            if p.id == blockID, var rack = p.rack {
                var w = paddedWetDb(rack.wetDb, count: rack.voices.count)
                if vi >= 0 && vi < w.count { w[vi] = dB }
                rack.wetDb = w
                var np = p; np.rack = rack; return np
            }
            if p.isContainer { return p.mappingChildSeries { settingVoiceGain(blockID, vi, dB, in: $0) } }
            return p
        }
    }

    /// The mute of branch `vi` of a parallel block: updates the model (`voiceMutes`) then pushes
    /// the EFFECTIVE gain (silence if muted, otherwise the gain set) to the live plugin on the engine side.
    func setVoiceMute(objectID: UUID, blockID: UUID, voiceIndex: Int, muted: Bool) {
        updateChainPlugins(objectID) { p in
            p = Self.settingVoiceMute(blockID, voiceIndex, muted, in: p)
        }
        // The effective gain to push on the fly (mute does not change the stored dB value).
        let eff: Float? = chainPlugins(objectID).flatMap { p in
            Self.effectiveVoiceGain(blockID, voiceIndex, in: p)
        }
        if let eff {
            engine?.setVoiceGain(eff, forBlockID: blockID.uuidString,
                                 voiceIndex: Int32(voiceIndex), objectID: objectID.uuidString)
        }
        isDirty = true
    }

    /// Writes the mute of branch `vi` of block `blockID` into `voiceMutes` (recursive over the voices).
    static func settingVoiceMute(_ blockID: UUID, _ vi: Int, _ muted: Bool,
                                 in plugins: [ObjectPlugin]) -> [ObjectPlugin] {
        plugins.map { p in
            if p.id == blockID, var rack = p.rack {
                var m = paddedMutes(rack.voiceMutes, count: rack.voices.count)
                if vi >= 0 && vi < m.count { m[vi] = muted }
                rack.voiceMutes = m
                var np = p; np.rack = rack; return np
            }
            if p.isContainer { return p.mappingChildSeries { settingVoiceMute(blockID, vi, muted, in: $0) } }
            return p
        }
    }

    /// The EFFECTIVE dB gain of branch `vi` of block `blockID` (silence if muted). nil if not found.
    static func effectiveVoiceGain(_ blockID: UUID, _ vi: Int, in plugins: [ObjectPlugin]) -> Float? {
        for p in plugins {
            if p.id == blockID, let rack = p.rack {
                let eff = effectiveWetDb(rack)
                return (vi >= 0 && vi < eff.count) ? eff[vi] : nil
            }
            if p.isContainer {
                for voice in p.childSeries {
                    if let f = effectiveVoiceGain(blockID, vi, in: voice) { return f }
                }
            }
        }
        return nil
    }

    /// Sets a plugin's `linkGroupID` (recursive over the voices). nil = unlink.
    static func settingLinkGroup(_ id: UUID, _ gid: UUID?, in plugins: [ObjectPlugin]) -> [ObjectPlugin] {
        plugins.map { p in
            if p.id == id { var np = p; np.linkGroupID = gid; return np }
            if p.isContainer { return p.mappingChildSeries { settingLinkGroup(id, gid, in: $0) } }
            return p
        }
    }

    /// Sets `detachedLinkGroupID` — the dormant group (recursive over the voices).
    static func settingDetachedLinkGroup(_ id: UUID, _ gid: UUID?, in plugins: [ObjectPlugin]) -> [ObjectPlugin] {
        plugins.map { p in
            if p.id == id { var np = p; np.detachedLinkGroupID = gid; return np }
            if p.isContainer { return p.mappingChildSeries { settingDetachedLinkGroup(id, gid, in: $0) } }
            return p
        }
    }

    /// Writes a plugin's `stateXML` into the tree (recursive over the voices).
    static func settingStateXML(_ id: UUID, _ xml: String, in plugins: [ObjectPlugin]) -> [ObjectPlugin] {
        plugins.map { p in
            if p.id == id { var np = p; np.stateXML = xml; return np }
            if p.isContainer { return p.mappingChildSeries { settingStateXML(id, xml, in: $0) } }
            return p
        }
    }

    /// Folds the tree back after a removal: empty voices are removed, a parallel with 0 branches is
    /// deleted, one with 1 branch is inlined into the parent series. Recursive.
    static func simplifyTree(_ plugins: [ObjectPlugin]) -> [ObjectPlugin] {
        plugins.flatMap { p -> [ObjectPlugin] in
            // A bin's block is not a rack to fold back: it stays whatever it holds (its content is
            // the bin's definition, and an emptied bin is the bin's business, not the tree's).
            guard let rack = p.rack else { return [p] }
            let gains = paddedWetDb(rack.wetDb, count: rack.voices.count)
            let mutes = paddedMutes(rack.voiceMutes, count: rack.voices.count)
            // It KEEPS empty branches (deliberate gain-only paths). A block is only folded if it
            // has fewer than 2 branches (a branch being removed through removingVoice). Branches are
            // removed explicitly, never because they have become empty.
            let voices = rack.voices.map { simplifyTree($0) }
            if voices.count < 2 { return voices.first ?? [] }
            var np = p; np.rack = PluginRack(voices: voices, wetDb: gains, voiceMutes: mutes); return [np]
        }
    }
}
