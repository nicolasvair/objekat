import Foundation

// MARK: - FX links (bins of shared plugins) — the registry and its queries
//
// The model, its rules and the reasons for them are written at the head of `FXLink.swift`. This
// file holds what reads it: finding a bin's members, resolving a block's effective output, and
// the persistence of the registry. The mutations (creating, editing the definition, attaching,
// detaching) live in `EditViewModel+FXLinkEdit.swift`.

extension EditViewModel {

    // MARK: Lookup

    /// The bin of id `id`, if the registry holds it.
    func fxLink(_ id: UUID) -> FXLink? { fxLinks.first { $0.id == id } }

    /// Index in `fxLinks`.
    func fxLinkIndex(_ id: UUID) -> Int? { fxLinks.firstIndex { $0.id == id } }

    // MARK: Walking the blocks

    /// The bins' blocks of one series, at any depth (a block may sit in a parallel branch).
    static func fxBlocks(in plugins: [ObjectPlugin]) -> [ObjectPlugin] {
        var out: [ObjectPlugin] = []
        for p in plugins {
            if p.fxBlock != nil { out.append(p) }
            else if p.rack != nil { for v in p.childSeries { out += fxBlocks(in: v) } }
        }
        return out
    }

    /// Every bin's block hosted anywhere in the project — timeline objects (groups walked down)
    /// AND buses — with the id of its host.
    static func fxBlocks(items: [SoundObject], stems: [Stem]) -> [(hostID: UUID, block: ObjectPlugin)] {
        var out: [(UUID, ObjectPlugin)] = []
        func walk(_ arr: [SoundObject]) {
            for o in arr {
                for b in fxBlocks(in: o.plugins) { out.append((o.id, b)) }
                if case .group(let children, _) = o.kind { walk(children) }
            }
        }
        walk(items)
        for s in stems { for b in fxBlocks(in: s.plugins) { out.append((s.id, b)) } }
        return out
    }

    /// Every block of the live project.
    func allFXBlocks() -> [(hostID: UUID, block: ObjectPlugin)] {
        Self.fxBlocks(items: items, stems: stems)
    }

    /// The hosts carrying a block of bin `linkID`, ATTACHED OR NOT. A host holding two blocks of the
    /// same bin appears twice.
    func fxLinkMembers(_ linkID: UUID) -> [(hostID: UUID, block: ObjectPlugin)] {
        allFXBlocks().filter { $0.block.fxBlock?.linkID == linkID }
    }

    /// The members that FOLLOW the bin: attached blocks only.
    func fxLinkAttachedMembers(_ linkID: UUID) -> [(hostID: UUID, block: ObjectPlugin)] {
        fxLinkMembers(linkID).filter { $0.block.fxBlock?.isDetached == false }
    }

    /// The bin's block that holds the plugin `pluginID` in `plugins`, if the plugin lives in one.
    static func enclosingFXBlock(of pluginID: UUID, in plugins: [ObjectPlugin]) -> ObjectPlugin? {
        for p in plugins {
            if let block = p.fxBlock {
                if block.plugins.contains(where: { $0.id == pluginID }) { return p }
            } else if p.rack != nil {
                for v in p.childSeries { if let b = enclosingFXBlock(of: pluginID, in: v) { return b } }
            }
        }
        return nil
    }

    /// `locate`, except that a plugin inside a bin's block answers with the BLOCK's own place: a copy
    /// laid "after" it lands after the block, never among the instances (which the definition rules).
    static func locateOutsideFXBlock(_ pluginID: UUID, in plugins: [ObjectPlugin]) -> (SeriesLocation, Int)? {
        guard let found = locate(pluginID, in: plugins) else { return nil }
        if case .block(let blockID) = found.0 { return locate(blockID, in: plugins) }
        return found
    }

    /// True if `pluginID` is an instance held by an ATTACHED block of host `hostID`: such an
    /// instance is not edited on its own — the bin's definition is (@see EditViewModel+FXLinkEdit).
    func isAttachedFXMember(_ pluginID: UUID, of hostID: UUID) -> Bool {
        guard let plugins = chainPlugins(hostID),
              let block = Self.enclosingFXBlock(of: pluginID, in: plugins) else { return false }
        return block.fxBlock?.isDetached == false
    }

    /// True if `pluginID` sits in ANY bin's block of the host, attached or detached.
    func isInFXBlock(_ pluginID: UUID, of hostID: UUID) -> Bool {
        guard let plugins = chainPlugins(hostID) else { return false }
        return Self.enclosingFXBlock(of: pluginID, in: plugins) != nil
    }

    // MARK: Output section

    /// The output section a block is heard with: the bin's while attached (a bin missing from the
    /// registry counts as neutral, and the block then plays its plugins as they are), the block's own
    /// copy while detached.
    func fxOutput(of block: ObjectPlugin) -> FXLinkOutput {
        guard let b = block.fxBlock else { return FXLinkOutput() }
        if b.isDetached { return b.local ?? FXLinkOutput() }
        return fxLink(b.linkID)?.output ?? FXLinkOutput()
    }

    /// Whether a member instance is HEARD as enabled: its own on/off AND the block's common one.
    func fxEffectiveEnabled(_ plugin: ObjectPlugin, in block: ObjectPlugin) -> Bool {
        plugin.isEnabled && fxOutput(of: block).isEnabled
    }

    // MARK: Persistence

    /// The registry as it is written: only the bins some block still refers to (an orphan is what
    /// a deleted object leaves behind — it is dropped at write time and never in memory, so an undo
    /// finds it again), each definition plugin carrying the freshest state the members hold.
    /// `items` are meant to be the ones whose plugin states were just captured from the engine, so
    /// that the definitions' states are the live ones without one more engine read.
    func fxLinksForPersistence(items: [SoundObject], stems: [Stem]) -> [FXLink] {
        let blocks = Self.fxBlocks(items: items, stems: stems).map(\.block)
        var referenced: Set<UUID> = []
        var stateByDef: [UUID: String] = [:]
        for b in blocks {
            guard let fb = b.fxBlock else { continue }
            referenced.insert(fb.linkID)
            guard !fb.isDetached else { continue }
            for inst in fb.plugins {
                if let g = inst.linkGroupID, stateByDef[g] == nil,
                   let xml = inst.stateXML, !xml.isEmpty { stateByDef[g] = xml }
            }
        }
        return fxLinks.filter { referenced.contains($0.id) }.map { link in
            var l = link
            l.plugins = link.plugins.map { d in
                var q = d
                if let xml = stateByDef[d.id] { q.stateXML = xml }
                return q
            }
            return l
        }
    }

    // MARK: Engine — hot pushes (no recompile)

    /// Pushes one block's output section and the effective on/off of its instances to the engine,
    /// with no recompile: a volume drag, a mute or the bin's common on/off must not glitch the
    /// chain. Silent for a block the engine has not compiled yet — the model holds the value, the
    /// next compile lays it down.
    func pushFXBlockOutput(hostID: UUID, block: ObjectPlugin) {
        guard let engine, let fb = block.fxBlock else { return }
        let out = fxOutput(of: block)
        engine.setFXBlockOutput(block.id.uuidString, gainDb: out.effectiveGainDb, pan: out.pan,
                                enabled: out.isEnabled)
        for leaf in fb.plugins {
            engine.setPlugin(leaf.id.uuidString, enabled: leaf.isEnabled && out.isEnabled,
                             forObjectID: hostID.uuidString)
        }
    }

    /// The same for every ATTACHED member of bin `linkID`.
    func pushFXLinkOutput(_ linkID: UUID) {
        for m in fxLinkAttachedMembers(linkID) { pushFXBlockOutput(hostID: m.hostID, block: m.block) }
    }

    /// The same for every block of the project — after an undo, which restores the registry
    /// beside chains that may have been kept in place (@see applySnapshot).
    func pushAllFXBlockOutputs() {
        for m in allFXBlocks() { pushFXBlockOutput(hostID: m.hostID, block: m.block) }
    }
}
