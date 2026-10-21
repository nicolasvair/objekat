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
    /// find the right series again. Every series id is STABLE across builds (the bound view rebuilds
    /// the tree at every VU poll, ~70 ms): the root is the host's id, a bin's series its block's id, and
    /// a parallel's branch an id DERIVED from its block's id and its index (@see voiceSeriesID) — so a
    /// '+' named by its series survives a rebuild, and a hover or a drag in flight does not lose it.
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
        // A send's marker is not a card of the chain (step 2.9 draws the sends as cards of their own).
        let children: [SynopticNode] = plugins.compactMap { p in
            if p.isChainMarker { return nil }
            if let rack = p.rack {
                let gains = EditViewModel.paddedWetDb(rack.wetDb, count: rack.voices.count)
                let mutes = EditViewModel.paddedMutes(rack.voiceMutes, count: rack.voices.count)
                let voices: [SynopticNode] = rack.voices.enumerated().map { vi, voice in
                    var vnode = buildSeries(voice, seriesID: voiceSeriesID(blockID: p.id, voiceIndex: vi),
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
                // The block carries the link and the common on/off: its cards are drawn greyed (their own on/off untouched) while the bin is off.
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
        var node = SynopticNode(id: seriesID, kind: .series(children))
        node.cablePicks = ChannelPicks.picks(in: plugins)
        return node
    }

    /// The id of branch `voiceIndex` of the parallel block `blockID`: the block's id with a few bits
    /// flipped by the index — the same at every build (the block's id is the rack carrier's, stable), and
    /// never one of the model's ids (a random UUID is not reached by flipping a tagged byte pattern).
    static func voiceSeriesID(blockID: UUID, voiceIndex: Int) -> UUID {
        var u = blockID.uuid
        let i = UInt16(truncatingIfNeeded: voiceIndex + 1)
        u.0 ^= 0x5A
        u.1 ^= 0xC3
        u.14 ^= UInt8(i >> 8)
        u.15 ^= UInt8(i & 0xFF)
        return UUID(uuid: u)
    }

    static func leaf(_ p: ObjectPlugin, vu: Double = 0) -> SynopticPlugin {
        SynopticPlugin(id: p.id, name: p.name, category: .infer(from: p),
                       isEnabled: p.isEnabled, vu: vu,
                       isBuiltIn: p.isBuiltIn, formatLabel: p.formatLabel,
                       color: p.color,
                       gainStage: synopticFace(of: p),
                       trimInDb: p.trims.input, trimOutDb: p.trims.output, trimCompDb: p.compensation)
    }

    /// A gain stage's face as the signal view names it (nil = not a stage).
    static func synopticFace(of p: ObjectPlugin) -> SynopticGainStageFace? {
        switch p.gainStageFace {
        case .gain?:        return .gain
        case .gainPanMute?: return .gainPanMute
        case nil:           return nil
        }
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

    /// A FRESH insertion: it starts on its type's default preset, if one is set (@see freshPlugin).
    private func makeObjectPlugin(_ a: AvailablePlugin) -> ObjectPlugin { freshPlugin(a) }

    /// The signal view's '+': inserts a new plugin into the target series, at the given index.
    func synopticInsert(objectID: UUID, available: AvailablePlugin,
                        into location: SeriesLocation, at index: Int) {
        guard let plugins = chainPlugins(objectID) else { return }
        // Dropped into an ATTACHED block, a new plugin joins the bin's DEFINITION (every member gets
        // an instance); the editor opens on this host's own.
        if case .block(let blockID) = location,
           let block = Self.findBlock(blockID, in: plugins), let fb = block.fxBlock, !fb.isDetached {
            let template = makeObjectPlugin(available)
            guard let defID = fxAddPlugin(linkID: fb.linkID, template: template, state: template.stateXML, at: index) else {
                availablePlugins.removeAll { $0.identifier == available.identifier && $0.formatName == available.formatName }
                return
            }
            if let inst = chainPlugins(objectID).flatMap({ Self.flattenLeaves($0).first { $0.linkGroupID == defID } }) {
                if inst.isBuiltIn { openBuiltInPluginEditor(plug: inst) }
                else { openPluginEditor(objectID: objectID, pluginID: inst.id) }
            }
            return
        }
        // A send's mini-chain (the "+" of its box) takes plain plugins only, up to its own limit.
        if let why = sendChainRefusal(adding: 1, to: objectID, instrument: available.isInstrument) {
            NSLog("[SENDS] plugin not added to a send: %@", why.rawValue)
            NSSound.beep()
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

    /// A parallel branch out of the '+' at view index `index` of the series `location` (a drag down-right),
    /// taking the run @see SynopticBranchRun.forPlus reads from `selection`: the element under the '+', or the
    /// selected run that starts there; an EMPTY series gets an empty branch. ONE undo point.
    /// - Returns: the ids put in the branch ([] = an empty branch), nil = refused (nothing changed).
    @discardableResult
    func synopticBranch(objectID: UUID, location: SeriesLocation, at index: Int,
                        selection: Set<UUID>) -> [UUID]? {
        guard let plugins = chainPlugins(objectID),
              let series = Self.seriesEntries(location, in: plugins) else { return nil }
        if case .block = location { return nil }   // inside a bin: the bin's order is the definition's
        let run = SynopticBranchRun.forPlus(at: index, in: Self.branchRunElements(series, selection: selection))
        return applyBranch(objectID: objectID, run: run, location: location, insertIndex: index, plugins: plugins)
    }

    /// "Create a parallel branch" from a card's context menu: the selected run round the card when it is in
    /// `selection`, the card alone otherwise (@see SynopticBranchRun.around). ONE undo point.
    /// - Returns: the ids put in the branch, nil = refused (a bin's instance, an unknown card).
    @discardableResult
    func synopticBranch(objectID: UUID, pluginID: UUID, selection: Set<UUID>) -> [UUID]? {
        guard let plugins = chainPlugins(objectID),
              let (location, _) = Self.locate(pluginID, in: plugins) else { return nil }
        if case .block = location { return nil }   // a bin's instance is not put in parallel on its own
        guard let series = Self.seriesEntries(location, in: plugins),
              let run = SynopticBranchRun.around(pluginID, in: Self.branchRunElements(series, selection: selection))
        else { return nil }
        return applyBranch(objectID: objectID, run: run, location: location, insertIndex: 0, plugins: plugins)
    }

    /// The one door both gestures go through: one undo point, the tree, the engine.
    private func applyBranch(objectID: UUID, run: [UUID], location: SeriesLocation, insertIndex: Int,
                             plugins: [ObjectPlugin]) -> [UUID]? {
        // A bin's instance is never put in parallel on its own (its block is, whole).
        if run.contains(where: { fxDefinition(ofInstance: $0, on: objectID) != nil }) { return nil }
        guard let next = Self.branching(run: run, at: location, insertIndex: insertIndex, in: plugins) else { return nil }
        pushUndo()
        updateChainPlugins(objectID) { $0 = next }
        compileRack(objectID: objectID)
        isDirty = true
        return run
    }

    /// The tree with a parallel branch made of `run` — consecutive entries of the series `location`, in
    /// order: one entry that is a block → one more (empty) branch on it; one plugin or a bin's block → a
    /// 2-branch block (it, and an empty branch); several → a 2-branch block (the run as ONE series, and an
    /// empty branch), laid where the run was. An empty run → a 2-branch block of two EMPTY branches at
    /// `insertIndex` (view index). nil = the run is not consecutive in that series.
    static func branching(run: [UUID], at location: SeriesLocation, insertIndex: Int,
                          in plugins: [ObjectPlugin]) -> [ObjectPlugin]? {
        if run.isEmpty {
            return inserting(rackCarrier(voices: [[], []]), into: location, at: insertIndex, plugins: plugins)
        }
        if run.count == 1 { return branchingEmpty(plugins, elementID: run[0]) }
        guard let series = seriesEntries(location, in: plugins) else { return nil }
        let idx = run.compactMap { id in series.firstIndex { $0.id == id } }
        // A cable pick between two cards of the run is not a card: it goes into the branch with them (the
        // run is consecutive CARDS), while the pick ahead of the run stays on the cable that feeds the block.
        guard idx.count == run.count, let lo = idx.min(), let hi = idx.max(),
              series[lo...hi].filter({ !$0.isChannelPick }).map(\.id) == idx.sorted().map({ series[$0].id }),
              idx == idx.sorted() else { return nil }
        return mappingSeries(location, in: plugins) { s in
            var a = s
            let carrier = rackCarrier(voices: [Array(s[lo...hi]), []])
            a.replaceSubrange(lo...hi, with: [carrier])
            return a
        }
    }

    /// A series' entries as the run reads them: a send's marker is a barrier; a container is selected when
    /// its id is, or when every leaf it holds is.
    static func branchRunElements(_ series: [ObjectPlugin], selection: Set<UUID>) -> [SynopticBranchRun.Element] {
        // A cable pick is not an element: it is invisible to the run (it follows the cards it sits between).
        series.filter { !$0.isChannelPick }.map { p in
            let leaves = p.isContainer && !p.isSendMarker ? flattenLeaves([p]) : []
            let selected = selection.contains(p.id)
                || (!leaves.isEmpty && leaves.allSatisfy { selection.contains($0.id) })
            return SynopticBranchRun.Element(id: p.id, isBarrier: p.isSendMarker, isSelected: selected)
        }
    }

    /// The entries of the series `location` in MODEL order (markers included at the root). nil = no such
    /// series in this tree.
    static func seriesEntries(_ location: SeriesLocation, in plugins: [ObjectPlugin]) -> [ObjectPlugin]? {
        switch location {
        case .root:
            return plugins
        case .voice(let blockID, let vi):
            guard let b = findEntry(blockID, in: plugins), let rack = b.rack, rack.voices.indices.contains(vi)
            else { return nil }
            return rack.voices[vi]
        case .block(let blockID):
            return findBlock(blockID, in: plugins)?.fxBlock?.plugins
        }
    }

    /// The tree with `transform` applied to the series `location` (and nothing else).
    static func mappingSeries(_ location: SeriesLocation, in plugins: [ObjectPlugin],
                              _ transform: ([ObjectPlugin]) -> [ObjectPlugin]) -> [ObjectPlugin] {
        switch location {
        case .root:
            return transform(plugins)
        case .voice(let blockID, let vi):
            return plugins.map { p in
                if p.id == blockID, var rack = p.rack, rack.voices.indices.contains(vi) {
                    rack.voices[vi] = transform(rack.voices[vi])
                    var np = p; np.rack = rack; return np
                }
                if p.isContainer { return p.mappingChildSeries { mappingSeries(location, in: $0, transform) } }
                return p
            }
        case .block(let blockID):
            return plugins.map { p in
                if p.id == blockID, var block = p.fxBlock {
                    block.plugins = transform(block.plugins)
                    var np = p; np.fxBlock = block; return np
                }
                if p.isContainer { return p.mappingChildSeries { mappingSeries(location, in: $0, transform) } }
                return p
            }
        }
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
    @discardableResult
    func synopticReorder(objectID: UUID, pluginID: UUID, to location: SeriesLocation, at index: Int) -> Bool {
        // A bin's BLOCK dragged by its header moves as one piece, instances and all.
        if let plugins = chainPlugins(objectID), Self.findBlock(pluginID, in: plugins) != nil {
            return moveFXBlock(hostID: objectID, blockID: pluginID, to: location, at: index)
        }
        guard let plugins = chainPlugins(objectID),
              let (srcLoc, srcIdx) = Self.locate(pluginID, in: plugins),
              let plug = Self.flattenLeaves(plugins).first(where: { $0.id == pluginID }) else { return false }
        // Inside an ATTACHED block the order is the bin's: reordering there reorders the definition,
        // for every member; and an instance does not leave its block, nor does a plugin enter one
        // from outside by this gesture (the drop of a plugin ON a bin adds to the definition — see
        // fxAddPlugin — and belongs to the timeline drag, not to a reorder).
        if let def = fxDefinition(ofInstance: pluginID, on: objectID) {
            guard case .block(let dst) = location,
                  let block = Self.findBlock(dst, in: plugins), block.fxBlock?.linkID == def.linkID else { return false }
            var target = index
            if srcLoc == location && srcIdx < index { target = index - 1 }
            return fxMovePlugin(linkID: def.linkID, definitionID: def.definitionID, to: target)
        }
        if case .block(let dst) = location, let block = Self.findBlock(dst, in: plugins),
           block.fxBlock?.isDetached == false { return false }
        // The same series: removing upstream shifts the following indices → adjust the target.
        var target = index
        if srcLoc == location && srcIdx < index { target = index - 1 }
        if srcLoc == location && target == srcIdx { return false }   // no movement
        pushUndo()
        let removed = Self.removingPlugins([pluginID], from: plugins)
        let inserted = Self.inserting(plug, into: location, at: target, plugins: removed)
        updateChainPlugins(objectID) { $0 = Self.simplifyTree(inserted) }
        compileRack(objectID: objectID)
        isDirty = true
        return true
    }

    /// The signal view's ⌥-drag: an independent COPY of `pluginID` into the series `location` at
    /// `index` (a new UUID, the state captured from the live instance, no link). A no-op if absent.
    @discardableResult
    func synopticCopyPlugin(objectID: UUID, pluginID: UUID, to location: SeriesLocation, at index: Int) -> Bool {
        guard let plugins = chainPlugins(objectID),
              let plug = Self.flattenLeaves(plugins).first(where: { $0.id == pluginID }) else { return false }
        // A copy does not land INSIDE an attached block: the instances are the bin's to decide.
        if case .block(let dst) = location, let block = Self.findBlock(dst, in: plugins),
           block.fxBlock?.isDetached == false { return false }
        let live = engine?.getPluginStateXML(pluginID.uuidString)
        let stateXML = (live?.isEmpty == false) ? live : plug.stateXML
        let copy = ObjectPlugin(id: UUID(), name: plug.name, manufacturer: plug.manufacturer,
                                identifier: plug.identifier, formatName: plug.formatName,
                                isEnabled: plug.isEnabled, stateXML: stateXML, linkGroupID: nil,
                                sidechain: plug.sidechain,
                                monoFold: plug.monoFold).withTrims(of: plug)
        pushUndo()
        updateChainPlugins(objectID) {
            $0 = Self.simplifyTree(Self.inserting(copy, into: location, at: index, plugins: plugins))
        }
        compileRack(objectID: objectID)
        isDirty = true
        return true
    }

    /// A drop in the signal view, whatever it carries: a plugin or several, an instance of a bin, a whole
    /// bin's block; wherever it comes from (this host's chain or another's) and wherever it lands (a cable,
    /// before a card, the end of a bin). The single door: the cursor read the same resolver, so what the hand
    /// was told is what happens (@see pluginDropOutcome).
    @discardableResult
    func synopticDrop(_ payload: PluginDragPayload, host hostID: UUID, at site: PluginDropSite,
                      flags: NSEvent.ModifierFlags) -> Bool {
        performPluginDrop(payload, on: hostID, at: site, modifiers: flags)
    }

    /// Locates a plugin in the tree: (the containing series, the index within that series).
    /// The index is the one the VIEW uses: send markers and cable picks do not count (`ObjectPlugin.visibleIndex`),
    /// so that `locate` and `inserting` agree with the cards the signal view draws.
    static func locate(_ pluginID: UUID, in plugins: [ObjectPlugin],
                       location: SeriesLocation = .root) -> (SeriesLocation, Int)? {
        for (i, p) in plugins.enumerated() {
            if p.id == pluginID {
                return (location, ObjectPlugin.visibleIndex(ofModelIndex: i, in: plugins))
            }
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
                                      wetDb: Array(repeating: 0, count: voices.count)),
                     monoFold: nil)   // a container: only its leaves have a fold
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

    /// `index` is the view's (send markers and cable picks do not count), in any series.
    static func inserting(_ newPlug: ObjectPlugin, into location: SeriesLocation,
                          at index: Int, plugins: [ObjectPlugin]) -> [ObjectPlugin] {
        switch location {
        case .root:
            // `index` counts the entries the view shows: the markers of the sends are not among them.
            var a = plugins
            a.insert(newPlug, at: ObjectPlugin.modelIndex(ofVisibleIndex: index, in: plugins))
            return a
        case .voice(let blockID, let vi):
            return plugins.map { p in
                if p.id == blockID, var rack = p.rack, vi < rack.voices.count {
                    var voice = rack.voices[vi]
                    voice.insert(newPlug, at: ObjectPlugin.modelIndex(ofVisibleIndex: index, in: voice))
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
                    block.plugins.insert(newPlug, at: ObjectPlugin.modelIndex(ofVisibleIndex: index, in: block.plugins))
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
