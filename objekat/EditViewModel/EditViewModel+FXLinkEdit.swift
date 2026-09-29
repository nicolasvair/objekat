import Foundation

// MARK: - FX links — the mutations
//
// Reading (registry, members, output) is in `EditViewModel+FXLink.swift`; the model and its rules
// are at the head of `FXLink.swift`. Everything that CHANGES a bin lives here, and follows one
// shape:
//
//   1. the DEFINITION (`fxLinks`) is edited — order, membership, on/off, output section;
//   2. `reconcileFXLinkMembers` rebuilds every ATTACHED member's block from it, reusing the
//      instances that already answer to a definition plugin (same id ⇒ a live AudioUnit, an open
//      editor and the automation aimed at it all survive), then recompiles the members' chains —
//      or, when only a flag or a level moved, pushes it hot with no recompile;
//   3. the mirror (`linkGroupID == definition id`) is re-armed on the engine side.
//
// A public entry point pushes ONE undo point for the gesture (`undo: false` for a caller that has
// its own — the automatic creation runs inside a cut, a paste, a duplicate). The registry and the
// chains restore together (@see EditSnapshot.fxLinks), which is why an undo needs nothing here.

extension EditViewModel {

    // MARK: Tree helpers

    /// `f` applied to the block `blockID`, wherever it sits (a block may be in a parallel branch).
    static func updatingBlock(_ blockID: UUID, in plugins: [ObjectPlugin],
                              _ f: (inout ObjectPlugin) -> Void) -> [ObjectPlugin] {
        plugins.map { p in
            if p.id == blockID, p.fxBlock != nil {
                var q = p
                f(&q)
                return q
            }
            if p.rack != nil { return p.mappingChildSeries { updatingBlock(blockID, in: $0, f) } }
            return p
        }
    }

    /// The block `blockID` of a chain, if there is one.
    static func findBlock(_ blockID: UUID, in plugins: [ObjectPlugin]) -> ObjectPlugin? {
        fxBlocks(in: plugins).first { $0.id == blockID }
    }

    /// A block replaced by other entries (the instances, inline), or removed when `with` is empty.
    static func replacingBlock(_ blockID: UUID, in plugins: [ObjectPlugin],
                               with replacement: [ObjectPlugin]) -> [ObjectPlugin] {
        plugins.flatMap { p -> [ObjectPlugin] in
            if p.id == blockID, p.fxBlock != nil { return replacement }
            if p.rack != nil { return [p.mappingChildSeries { replacingBlock(blockID, in: $0, with: replacement) }] }
            return [p]
        }
    }

    /// The top-level entries a bin can be made of: plain plugins, with no manual ⌘-link of their own
    /// (a legacy link stays what it is — the two mechanisms cohabit, they do not merge).
    static func isFXLinkEligible(_ p: ObjectPlugin) -> Bool {
        !p.isContainer && p.linkGroupID == nil && p.detachedLinkGroupID == nil
    }

    /// The runs of consecutive eligible plugins of the ROOT series, each a list of ids in chain
    /// order. What an automatic creation turns into bins: a rack, a legacy-linked plugin or a
    /// block breaks a run, so that no plugin ever changes its place in the signal path.
    static func fxLinkEligibleRuns(in plugins: [ObjectPlugin]) -> [[UUID]] {
        var runs: [[UUID]] = []
        var current: [UUID] = []
        for p in plugins {
            if isFXLinkEligible(p) { current.append(p.id) }
            else if !current.isEmpty { runs.append(current); current = [] }
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }

    // MARK: State helpers

    /// A plugin's state as it REALLY is: read off the live instance when there is one.
    func fxLiveState(of p: ObjectPlugin) -> String? {
        let live = engine?.getPluginStateXML(p.id.uuidString)
        return (live?.isEmpty == false) ? live : p.stateXML
    }

    /// The live state of a definition plugin, read off one of the attached members' instances.
    private func fxDefinitionLiveState(_ d: ObjectPlugin,
                                       members: [(hostID: UUID, block: ObjectPlugin)]) -> String? {
        for m in members {
            for inst in m.block.fxBlock?.plugins ?? [] where inst.linkGroupID == d.id {
                if let s = fxLiveState(of: inst), !s.isEmpty { return s }
            }
        }
        return d.stateXML
    }

    /// Writes the freshest state of every definition plugin into the registry, from the members'
    /// live instances. Called before the last member of a bin leaves it, so a later attach is born
    /// from what the bin sounded like and not from the state it was created with.
    func refreshFXDefinitionStates(_ linkID: UUID) {
        guard let i = fxLinkIndex(linkID) else { return }
        let members = fxLinkAttachedMembers(linkID)
        guard !members.isEmpty else { return }
        for k in fxLinks[i].plugins.indices {
            if let s = fxDefinitionLiveState(fxLinks[i].plugins[k], members: members), !s.isEmpty {
                fxLinks[i].plugins[k].stateXML = s
            }
        }
    }

    private func updateFXLink(_ id: UUID, _ f: (inout FXLink) -> Void) {
        guard let i = fxLinkIndex(id) else { return }
        f(&fxLinks[i])
        isDirty = true
    }

    private func uniqueFXLinkName(_ base: String?) -> String {
        if let base, !base.isEmpty { return base }
        var n = fxLinks.count + 1
        let taken = Set(fxLinks.map(\.name))
        while taken.contains("\(L("fxlink.default_name")) \(n)") { n += 1 }
        return "\(L("fxlink.default_name")) \(n)"
    }

    // MARK: Reconciling the members

    /// Rebuilds every ATTACHED block of bin `linkID` from its definition, then either recompiles the
    /// chains that moved (`compile`) or, when only flags and levels changed, pushes them hot.
    func reconcileFXLinkMembers(_ linkID: UUID, compile: Bool = true) {
        guard let link = fxLink(linkID) else { return }
        let members = fxLinkAttachedMembers(linkID)

        // The state a NEW instance is born with: the bin's, as one of its members plays it now.
        // Read BEFORE the model is touched — nothing is read from the engine inside a mutation.
        var fresh: [UUID: String] = [:]
        for d in link.plugins {
            let missing = members.contains { m in
                !(m.block.fxBlock?.plugins.contains { $0.linkGroupID == d.id } ?? false)
            }
            if missing, let s = fxDefinitionLiveState(d, members: members), !s.isEmpty { fresh[d.id] = s }
        }

        let keep = Set(link.plugins.map(\.id))
        var dropped: [UUID] = []
        var touched: [UUID] = []
        for m in members {
            let old = m.block.fxBlock?.plugins ?? []
            dropped += old.filter { !($0.linkGroupID.map(keep.contains) ?? false) }.map(\.id)
            updateChainPlugins(m.hostID) { chain in
                chain = Self.updatingBlock(m.block.id, in: chain) { b in
                    b.fxBlock?.plugins = link.instanceSeries(reusing: old, attached: true) {
                        fresh[$0.id] ?? $0.stateXML
                    }
                }
            }
            if !touched.contains(m.hostID) { touched.append(m.hostID) }
        }
        for id in dropped {
            endPluginParamTouchWatch(id)
            invalidatePluginParamInfos(id)
        }
        if compile {
            for h in touched { compileRack(objectID: h) }
            rewireLinkGroups()
        } else {
            pushFXLinkOutput(linkID)
        }
        isDirty = true
    }

    // MARK: Creating a bin

    /// Turns plugins of one host into a NEW bin: they become its definition, and the host's own
    /// instances (same ids — nothing is reloaded) form its block, at the place of the first one.
    /// All the plugins must be plain, in ONE series, and free of any manual link.
    @discardableResult
    func createFXLink(from hostID: UUID, pluginIDs: [UUID], name: String? = nil,
                      undo: Bool = true) -> UUID? {
        guard engine != nil, let chain = chainPlugins(hostID), !pluginIDs.isEmpty else { return nil }
        let leaves = Self.flattenLeaves(chain)
        var loc: SeriesLocation?
        var found: [(index: Int, plugin: ObjectPlugin)] = []
        for id in Set(pluginIDs) {
            guard let (l, i) = Self.locate(id, in: chain),
                  let leaf = leaves.first(where: { $0.id == id }),
                  Self.isFXLinkEligible(leaf) else { return nil }
            if case .block = l { return nil }           // already in a bin
            if let loc, loc != l { return nil }         // several series: no obvious place for the block
            loc = l
            found.append((i, leaf))
        }
        guard let loc else { return nil }
        found.sort { $0.index < $1.index }
        let firstIndex = found[0].index

        if undo { pushUndo() }

        var definition: [ObjectPlugin] = []
        var instances: [ObjectPlugin] = []
        for (_, leaf) in found {
            let state = fxLiveState(of: leaf)
            let d = ObjectPlugin(id: UUID(), name: leaf.name, manufacturer: leaf.manufacturer,
                                 identifier: leaf.identifier, formatName: leaf.formatName,
                                 isEnabled: leaf.isEnabled, stateXML: state, colorIndex: leaf.colorIndex)
            definition.append(d)
            var inst = leaf
            inst.stateXML = state
            inst.linkGroupID = d.id
            instances.append(inst)
        }
        let link = FXLink(name: uniqueFXLinkName(name), plugins: definition)
        fxLinks.append(link)
        let block = FXLink.blockEntry(linkID: link.id, name: link.name, instances: instances)
        updateChainPlugins(hostID) { c in
            let removed = Self.removingPlugins(Set(found.map { $0.plugin.id }), from: c)
            c = Self.inserting(block, into: loc, at: firstIndex, plugins: removed)
        }
        compileRack(objectID: hostID)
        rewireLinkGroups()
        isDirty = true
        return link.id
    }

    /// The bin of several OBJECTS (the timeline menu's last entry): the first of them — in timeline
    /// order — that has plugins gives the bin its definition (the first run of plain plugins of its
    /// chain), and every OTHER object receives a block of it at the END of its chain, its own
    /// plugins untouched. Nothing is ever removed from an object that was only asked to join.
    @discardableResult
    func createFXLinkFromObjects(_ ids: [UUID], name: String? = nil, undo: Bool = true) -> UUID? {
        let hosts = ids.compactMap { find(id: $0) }
            .sorted { ($0.startTime, $0.lane) < ($1.startTime, $1.lane) }
        guard let source = hosts.first(where: { !Self.fxLinkEligibleRuns(in: $0.plugins).isEmpty }),
              let run = Self.fxLinkEligibleRuns(in: source.plugins).first else { return nil }
        if undo { pushUndo() }
        guard let linkID = createFXLink(from: source.id, pluginIDs: run, name: name, undo: false) else {
            return nil
        }
        for h in hosts where h.id != source.id { attachFXLink(linkID, to: h.id, undo: false) }
        return linkID
    }

    // MARK: Attaching, detaching

    /// Gives `hostID` a block of bin `linkID` (at the end of its chain unless a place is given). A
    /// host that already holds a DETACHED block of this bin gets it reattached instead; one that
    /// already follows it is left as it is. Returns the block's id.
    @discardableResult
    func attachFXLink(_ linkID: UUID, to hostID: UUID, at place: (SeriesLocation, Int)? = nil,
                      undo: Bool = true) -> UUID? {
        guard engine != nil, let link = fxLink(linkID), let chain = chainPlugins(hostID) else { return nil }
        if let existing = Self.fxBlocks(in: chain).first(where: { $0.fxBlock?.linkID == linkID }) {
            if existing.fxBlock?.isDetached == true {
                return reattachFXBlock(hostID: hostID, blockID: existing.id, undo: undo) ? existing.id : nil
            }
            return existing.id
        }
        if undo { pushUndo() }
        let members = fxLinkAttachedMembers(linkID)
        var fresh: [UUID: String] = [:]
        for d in link.plugins {
            if let s = fxDefinitionLiveState(d, members: members), !s.isEmpty { fresh[d.id] = s }
        }
        let instances = link.instanceSeries(reusing: [], attached: true) { fresh[$0.id] ?? $0.stateXML }
        let block = FXLink.blockEntry(linkID: linkID, name: link.name, instances: instances)
        let (loc, idx) = place ?? (.root, chain.count)
        updateChainPlugins(hostID) { $0 = Self.inserting(block, into: loc, at: idx, plugins: chain) }
        compileRack(objectID: hostID)
        rewireLinkGroups()
        isDirty = true
        return block.id
    }

    /// Takes a host's block out of the bin without moving it: the host keeps an INDEPENDENT copy of
    /// the chain as it is now — instances, settings, and the bin's output section (`local`). The
    /// bin can be rejoined with `reattachFXBlock`.
    @discardableResult
    func detachFXBlock(hostID: UUID, blockID: UUID, undo: Bool = true) -> Bool {
        guard let engine, let chain = chainPlugins(hostID),
              let block = Self.findBlock(blockID, in: chain), let fb = block.fxBlock,
              !fb.isDetached, let link = fxLink(fb.linkID) else { return false }
        if undo { pushUndo() }
        refreshFXDefinitionStates(fb.linkID)
        let local = link.output
        for inst in fb.plugins { engine.clearPluginLinkGroup(inst.id.uuidString) }
        updateChainPlugins(hostID) { c in
            c = Self.updatingBlock(blockID, in: c) { b in
                b.fxBlock?.isDetached = true
                b.fxBlock?.local = local
                b.fxBlock?.plugins = fb.plugins.map { inst in
                    var q = inst
                    q.detachedLinkGroupID = inst.linkGroupID ?? inst.detachedLinkGroupID
                    q.linkGroupID = nil
                    return q
                }
            }
        }
        isDirty = true
        return true
    }

    /// Puts a detached block back on its bin: the host REALIGNS on the definition — its order, its
    /// membership, its output section — and its instances adopt the settings of the group (it is the
    /// host that aligns, never the members that stayed: coming back must not crush what they set).
    @discardableResult
    func reattachFXBlock(hostID: UUID, blockID: UUID, undo: Bool = true) -> Bool {
        guard let engine, let chain = chainPlugins(hostID),
              let block = Self.findBlock(blockID, in: chain), let fb = block.fxBlock,
              fb.isDetached, let link = fxLink(fb.linkID) else { return false }
        if undo { pushUndo() }
        let others = fxLinkAttachedMembers(fb.linkID).filter { $0.block.id != blockID }
        var fresh: [UUID: String] = [:]
        for d in link.plugins where !fb.plugins.contains(where: { $0.effectiveLinkGroupID == d.id }) {
            if let s = fxDefinitionLiveState(d, members: others), !s.isEmpty { fresh[d.id] = s }
        }
        let keep = Set(link.plugins.map(\.id))
        for inst in fb.plugins where !(inst.effectiveLinkGroupID.map(keep.contains) ?? false) {
            endPluginParamTouchWatch(inst.id)
            invalidatePluginParamInfos(inst.id)
        }
        let reused = fb.plugins.filter { $0.effectiveLinkGroupID.map(keep.contains) ?? false }
        let realigned = link.instanceSeries(reusing: fb.plugins, attached: true) { fresh[$0.id] ?? $0.stateXML }
        updateChainPlugins(hostID) { c in
            c = Self.updatingBlock(blockID, in: c) { b in
                b.fxBlock?.isDetached = false
                b.fxBlock?.local = nil
                b.fxBlock?.plugins = realigned
            }
        }
        compileRack(objectID: hostID)
        rewireLinkGroups()
        if others.isEmpty {
            // Nobody else follows the bin: this host is all there is of it, so the definition takes
            // ITS settings rather than the host being reset to a state nothing holds any more.
            refreshFXDefinitionStates(fb.linkID)
        } else {
            for inst in reused {
                if let g = link.plugins.first(where: { $0.id == inst.effectiveLinkGroupID })?.id {
                    engine.relinkPluginAdoptingGroup(inst.id.uuidString, groupID: g.uuidString)
                }
            }
        }
        pushFXBlockOutput(hostID: hostID, block: Self.findBlock(blockID, in: chainPlugins(hostID) ?? []) ?? block)
        isDirty = true
        return true
    }

    /// The host leaves the bin for good and KEEPS its plugins: the block is replaced, inline, by its
    /// instances — independent, no link of any kind. The bin's output section is not carried over
    /// (a bypass is: the plugins stay as silent as the block was).
    @discardableResult
    func releaseFXBlock(hostID: UUID, blockID: UUID, undo: Bool = true) -> Bool {
        guard let engine, let chain = chainPlugins(hostID),
              let block = Self.findBlock(blockID, in: chain), let fb = block.fxBlock else { return false }
        if undo { pushUndo() }
        let out = fxOutput(of: block)
        let inline = fb.plugins.map { inst -> ObjectPlugin in
            var q = inst
            q.isEnabled = inst.isEnabled && out.isEnabled
            q.linkGroupID = nil
            q.detachedLinkGroupID = nil
            return q
        }
        for inst in fb.plugins { engine.clearPluginLinkGroup(inst.id.uuidString) }
        updateChainPlugins(hostID) { $0 = Self.replacingBlock(blockID, in: $0, with: inline) }
        compileRack(objectID: hostID)
        isDirty = true
        return true
    }

    /// The host drops the block AND its plugins.
    @discardableResult
    func removeFXBlock(hostID: UUID, blockID: UUID, undo: Bool = true) -> Bool {
        guard engine != nil, let chain = chainPlugins(hostID),
              let block = Self.findBlock(blockID, in: chain), let fb = block.fxBlock else { return false }
        if undo { pushUndo() }
        if !fb.isDetached { refreshFXDefinitionStates(fb.linkID) }
        for inst in fb.plugins {
            endPluginParamTouchWatch(inst.id)
            invalidatePluginParamInfos(inst.id)
        }
        updateChainPlugins(hostID) { $0 = Self.replacingBlock(blockID, in: $0, with: []) }
        compileRack(objectID: hostID)
        isDirty = true
        return true
    }

    /// Dissolves the bin: every block, attached or detached, is replaced by its instances inline
    /// (independent), and the registry entry goes.
    @discardableResult
    func deleteFXLink(_ linkID: UUID, undo: Bool = true) -> Bool {
        guard fxLink(linkID) != nil else { return false }
        if undo { pushUndo() }
        for m in fxLinkMembers(linkID) { releaseFXBlock(hostID: m.hostID, blockID: m.block.id, undo: false) }
        fxLinks.removeAll { $0.id == linkID }
        isDirty = true
        return true
    }

    /// Moves a block within its host's chain (or into a branch of a parallel block).
    @discardableResult
    func moveFXBlock(hostID: UUID, blockID: UUID, to location: SeriesLocation, at index: Int,
                     undo: Bool = true) -> Bool {
        guard let chain = chainPlugins(hostID), let block = Self.findBlock(blockID, in: chain),
              let (srcLoc, srcIdx) = Self.locate(blockID, in: chain) else { return false }
        if case .block = location { return false }      // a bin does not hold a bin
        var target = index
        if srcLoc == location && srcIdx < index { target = index - 1 }
        if srcLoc == location && target == srcIdx { return false }
        if undo { pushUndo() }
        let removed = Self.replacingBlock(blockID, in: chain, with: [])
        let placed = Self.inserting(block, into: location, at: target, plugins: removed)
        updateChainPlugins(hostID) { $0 = Self.simplifyTree(placed) }
        compileRack(objectID: hostID)
        isDirty = true
        return true
    }

    // MARK: Editing the definition (every attached member follows)

    /// Adds a plugin to the bin's definition, at `index` (the end by default); every attached member
    /// gets an instance. `template` names the plugin (identity, colour); `state` is its starting
    /// state (nil = the plugin's defaults). Returns the DEFINITION plugin's id, or nil when the
    /// engine could not instantiate it anywhere.
    @discardableResult
    func fxAddPlugin(linkID: UUID, template: ObjectPlugin, state: String? = nil, at index: Int? = nil,
                     undo: Bool = true) -> UUID? {
        guard engine != nil, fxLink(linkID) != nil, !template.isContainer else { return nil }
        if undo { pushUndo() }
        let d = ObjectPlugin(id: UUID(), name: template.name, manufacturer: template.manufacturer,
                             identifier: template.identifier, formatName: template.formatName,
                             isEnabled: template.isEnabled, stateXML: state,
                             colorIndex: template.colorIndex)
        updateFXLink(linkID) { l in
            l.plugins.insert(d, at: min(max(0, index ?? l.plugins.count), l.plugins.count))
        }
        reconcileFXLinkMembers(linkID)
        // The engine drops the instances it cannot resolve (`compileRack`): a definition plugin
        // that survived in NO member is a plugin the project cannot play — it goes too.
        let survivors = fxLinkAttachedMembers(linkID)
        let played = survivors.isEmpty || survivors.contains {
            $0.block.fxBlock?.plugins.contains { $0.linkGroupID == d.id } ?? false
        }
        if !played {
            updateFXLink(linkID) { $0.plugins.removeAll { $0.id == d.id } }
            return nil
        }
        return d.id
    }

    @discardableResult
    func fxRemovePlugin(linkID: UUID, definitionID: UUID, undo: Bool = true) -> Bool {
        fxRemovePlugins(linkID: linkID, definitionIDs: [definitionID], undo: undo)
    }

    /// Several definition plugins out of the bin at once: one undo point, one recompile per member.
    @discardableResult
    func fxRemovePlugins(linkID: UUID, definitionIDs: [UUID], undo: Bool = true) -> Bool {
        guard let link = fxLink(linkID) else { return false }
        let gone = Set(definitionIDs).intersection(link.plugins.map(\.id))
        guard !gone.isEmpty else { return false }
        if undo { pushUndo() }
        refreshFXDefinitionStates(linkID)
        updateFXLink(linkID) { $0.plugins.removeAll { gone.contains($0.id) } }
        reconcileFXLinkMembers(linkID)
        return true
    }

    /// Reorders the definition: `index` is the plugin's place in the list once it has been taken out.
    @discardableResult
    func fxMovePlugin(linkID: UUID, definitionID: UUID, to index: Int, undo: Bool = true) -> Bool {
        guard let link = fxLink(linkID), let from = link.plugins.firstIndex(where: { $0.id == definitionID })
        else { return false }
        let target = min(max(0, index), link.plugins.count - 1)
        if target == from { return false }
        if undo { pushUndo() }
        updateFXLink(linkID) { l in
            let d = l.plugins.remove(at: from)
            l.plugins.insert(d, at: target)
        }
        reconcileFXLinkMembers(linkID)
        return true
    }

    /// The on/off of ONE plugin of the bin — every attached member's instance follows, hot.
    @discardableResult
    func fxSetPluginEnabled(linkID: UUID, definitionID: UUID, enabled: Bool, undo: Bool = true) -> Bool {
        guard let link = fxLink(linkID),
              let cur = link.plugins.first(where: { $0.id == definitionID }), cur.isEnabled != enabled
        else { return false }
        if undo { pushUndo() }
        updateFXLink(linkID) { l in
            if let k = l.plugins.firstIndex(where: { $0.id == definitionID }) { l.plugins[k].isEnabled = enabled }
        }
        reconcileFXLinkMembers(linkID, compile: false)
        return true
    }

    /// The bin's COMMON on/off: off bypasses every attached member's block, output section included.
    @discardableResult
    func fxSetEnabled(linkID: UUID, enabled: Bool, undo: Bool = true) -> Bool {
        guard let link = fxLink(linkID), link.isEnabled != enabled else { return false }
        if undo { pushUndo() }
        updateFXLink(linkID) { $0.isEnabled = enabled }
        pushFXLinkOutput(linkID)
        return true
    }

    /// The bin's output section. `nil` leaves a field as it is. Hot: no recompile, so it can run
    /// at the pace of a drag (`undo: false` from the second frame on).
    @discardableResult
    func fxSetOutput(linkID: UUID, gainDb: Float? = nil, pan: Float? = nil, muted: Bool? = nil,
                     undo: Bool = true) -> Bool {
        guard fxLink(linkID) != nil else { return false }
        if undo { pushUndo() }
        updateFXLink(linkID) { l in
            if let g = gainDb { l.gainDb = min(max(g, -96), 40) }
            if let p = pan { l.pan = min(max(p, -1), 1) }
            if let m = muted { l.muted = m }
        }
        pushFXLinkOutput(linkID)
        return true
    }

    /// The output section of a DETACHED block — its own copy.
    @discardableResult
    func fxSetLocalOutput(hostID: UUID, blockID: UUID, gainDb: Float? = nil, pan: Float? = nil,
                          muted: Bool? = nil, enabled: Bool? = nil, undo: Bool = true) -> Bool {
        guard let chain = chainPlugins(hostID), let block = Self.findBlock(blockID, in: chain),
              let fb = block.fxBlock, fb.isDetached else { return false }
        if undo { pushUndo() }
        var out = fb.local ?? FXLinkOutput()
        if let g = gainDb { out.gainDb = min(max(g, -96), 40) }
        if let p = pan { out.pan = min(max(p, -1), 1) }
        if let m = muted { out.muted = m }
        if let e = enabled { out.isEnabled = e }
        updateChainPlugins(hostID) { c in
            c = Self.updatingBlock(blockID, in: c) { $0.fxBlock?.local = out }
        }
        if let b = Self.findBlock(blockID, in: chainPlugins(hostID) ?? []) {
            pushFXBlockOutput(hostID: hostID, block: b)
        }
        isDirty = true
        return true
    }

    @discardableResult
    func renameFXLink(_ linkID: UUID, to name: String, undo: Bool = true) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let link = fxLink(linkID), !trimmed.isEmpty, link.name != trimmed else { return false }
        if undo { pushUndo() }
        updateFXLink(linkID) { $0.name = trimmed }
        return true
    }

    @discardableResult
    func setFXLinkColor(_ linkID: UUID, colorIndex: Int, undo: Bool = true) -> Bool {
        guard let link = fxLink(linkID), link.colorIndex != colorIndex,
              isValidPluginColorIndex(colorIndex) else { return false }
        if undo { pushUndo() }
        updateFXLink(linkID) { $0.colorIndex = colorIndex }
        return true
    }

    private func isValidPluginColorIndex(_ i: Int) -> Bool { i >= 0 && i < ObjekatPalette.plugins.count }

    // MARK: Redirecting the gestures aimed at a member's instance

    /// The bin and the definition plugin an ATTACHED member's instance stands for; nil for anything
    /// else (a plain plugin, a detached block's copy). A gesture aimed at such an instance is a
    /// gesture on the DEFINITION — the instance itself is never edited on its own.
    func fxDefinition(ofInstance pluginID: UUID, on hostID: UUID) -> (linkID: UUID, definitionID: UUID)? {
        guard let chain = chainPlugins(hostID),
              let block = Self.enclosingFXBlock(of: pluginID, in: chain),
              let fb = block.fxBlock, !fb.isDetached,
              let inst = fb.plugins.first(where: { $0.id == pluginID }),
              let g = inst.linkGroupID else { return nil }
        return (fb.linkID, g)
    }
}
