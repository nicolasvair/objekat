import Foundation

// MARK: - FX links — the AUTOMATIC creation (a copy of plain plugins joins a bin)
//
// `copiedPlugins(of:)` is the one door every automatic copy of an object's chain goes through: a
// cut / split, `makeCopy`, ⌥-copy, a paste, a duplicate, an overlap's fragments. It used to write a
// `linkGroupID` on the plain plugins of the ORIGINAL and hand the copy the same group. It now makes a
// BIN instead (an `FXLink`): the copy receives a block of it, and the original is to receive one too.
//
// WHY THE ORIGINAL IS NOT CONVERTED ON THE SPOT. The callers of `copiedPlugins` do not agree on what
// the original is when it comes back: some re-read it from the model afterwards (an aux, a MIDI clip),
// others write back a value they took BEFORE the call (a clip that is the child of a group, the left
// halves of a detached sub-tree), so a conversion made in the model at that instant would be crushed
// by the stale value the caller lays down a few lines later — and the engine, compiled from the
// converted chain, would disagree with a model that no longer says so. So the conversion is
// DEFERRED and idempotent:
//
//   • `copiedPlugins` only REGISTERS the intention (`fxPendingSources[objectID]`: which plain plugins
//     of that object stand for which definition plugins of which bin);
//   • `adoptPendingFXSources()` applies it to whatever the model holds by then — at the top of
//     `rewireLinkGroups()` (which every path that adds the copy to the engine goes through) — and
//     `syncPlugins` applies it to the object it is compiling BY VALUE. Applying it twice, or to a
//     chain that already holds the block, changes nothing;
//   • it dies with the gesture: cleared by `pushUndo` (a new gesture), by an undo/redo (which restores
//     plain plugins with the very same ids — adopting them again would undo the undo), by a new
//     project and by a load.
//
// The mirror needs no synchronisation code of its own: an instance of a bin's plugin carries
// `linkGroupID == the definition plugin's id`, which is what `rewireLinkGroups` already turns into an
// engine mirror.

/// What `copiedPlugins` promised for one run of plain plugins of one object: the bin, and which plain
/// plugin (by id, in chain order) is the instance of which definition plugin.
struct FXPendingSource {
    var linkID: UUID
    var pairs: [(leaf: UUID, def: UUID)]
}

extension EditViewModel {

    // MARK: Creating the bin for a copied run

    /// Makes (or finds again) the bin of one run of plain plugins of `object`, and returns the block
    /// the COPY carries. `state` reads a plugin's live state (and records it for the write-back).
    func copiedRun(_ run: [ObjectPlugin], of object: SoundObject,
                   state: (ObjectPlugin) -> String?) -> ObjectPlugin {
        let ids = Set(run.map(\.id))
        // Read once per plugin: the live state comes off the engine.
        let states = Dictionary(uniqueKeysWithValues: run.map { ($0.id, state($0)) })
        // The same run copied twice in one gesture (a plain clip cut in three, an overlap resolved
        // on both sides) joins ONE bin — the second copy is a member like the first.
        let known = fxPendingSources[object.id]?.first { Set($0.pairs.map(\.leaf)) == ids }
        var link: FXLink
        var defByLeaf: [UUID: UUID] = [:]
        if let known, let existing = fxLink(known.linkID) {
            link = existing
            for pair in known.pairs { defByLeaf[pair.leaf] = pair.def }
        } else {
            var defs: [ObjectPlugin] = []
            for leaf in run {
                let d = ObjectPlugin(id: UUID(), name: leaf.name, manufacturer: leaf.manufacturer,
                                     identifier: leaf.identifier, formatName: leaf.formatName,
                                     isEnabled: leaf.isEnabled, stateXML: states[leaf.id] ?? nil,
                                     colorIndex: leaf.colorIndex)
                defs.append(d)
                defByLeaf[leaf.id] = d.id
            }
            link = FXLink(name: uniqueFXLinkName(nil), plugins: defs)
            fxLinks.append(link)
            fxPendingSources[object.id, default: []].append(
                FXPendingSource(linkID: link.id, pairs: run.map { ($0.id, defByLeaf[$0.id]!) }))
        }
        let instances: [ObjectPlugin] = run.compactMap { leaf in
            guard let defID = defByLeaf[leaf.id],
                  let d = link.plugins.first(where: { $0.id == defID }) else { return nil }
            return ObjectPlugin(id: UUID(), name: leaf.name, manufacturer: leaf.manufacturer,
                                identifier: leaf.identifier, formatName: leaf.formatName,
                                isEnabled: d.isEnabled, stateXML: states[leaf.id] ?? nil,
                                linkGroupID: defID, colorIndex: leaf.colorIndex)
        }
        return FXLink.blockEntry(linkID: link.id, name: link.name, instances: instances)
    }

    // MARK: Adopting the original

    /// `plugins` with the pending runs of `objectID` turned into their block, or nil when none applies
    /// (nothing pending, the plugins are no longer there as plain entries, or already adopted). The
    /// instances are the ORIGINAL plugins themselves (same ids: a live AudioUnit is never reloaded),
    /// joined to the bin's definition.
    func fxAdopting(_ plugins: [ObjectPlugin], for objectID: UUID) -> [ObjectPlugin]? {
        guard let pending = fxPendingSources[objectID], !pending.isEmpty else { return nil }
        var chain = plugins
        var changed = false
        for src in pending {
            guard let link = fxLink(src.linkID) else { continue }
            let want = Set(src.pairs.map(\.leaf))
            let found = chain.enumerated().filter { want.contains($0.element.id) }
            guard found.count == want.count,
                  found.allSatisfy({ Self.isFXLinkEligible($0.element) }) else { continue }
            let defByLeaf = Dictionary(uniqueKeysWithValues: src.pairs.map { ($0.leaf, $0.def) })
            let instances: [ObjectPlugin] = src.pairs.compactMap { pair in
                guard var inst = chain.first(where: { $0.id == pair.leaf }),
                      let d = link.plugins.first(where: { $0.id == defByLeaf[pair.leaf] }) else { return nil }
                inst.linkGroupID = d.id
                inst.isEnabled = d.isEnabled
                return inst
            }
            guard instances.count == want.count else { continue }
            let firstIndex = found.map(\.offset).min()!
            let block = FXLink.blockEntry(linkID: link.id, name: link.name, instances: instances)
            var out: [ObjectPlugin] = []
            for (i, p) in chain.enumerated() {
                if i == firstIndex { out.append(block) }
                if !want.contains(p.id) { out.append(p) }
            }
            chain = out
            changed = true
        }
        return changed ? chain : nil
    }

    /// Applies every pending adoption to the objects the model holds NOW, and recompiles what moved.
    /// Idempotent. An entry whose object is not in the model is kept — it may still arrive, or be
    /// compiled by value (`syncPlugins`) — until the gesture ends (@see the head of this file).
    func adoptPendingFXSources() {
        guard !fxPendingSources.isEmpty else { return }
        var recompile: [UUID] = []
        for id in Array(fxPendingSources.keys) {
            guard let chain = chainPlugins(id), let adopted = fxAdopting(chain, for: id) else { continue }
            updateChainPlugins(id) { $0 = adopted }
            recompile.append(id)
        }
        for id in recompile { compileRack(objectID: id) }
        if !recompile.isEmpty { isDirty = true }
    }

    /// Forgets the pending adoptions: the gesture that made them is over.
    func clearPendingFXSources() {
        if !fxPendingSources.isEmpty { fxPendingSources = [:] }
    }
}
