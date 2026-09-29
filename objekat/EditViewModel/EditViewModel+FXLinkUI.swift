import Foundation
import SwiftUI

// MARK: - FX links — what the signal view (synoptic) and the menus ask of the model
//
// Everything here is a READING or a thin door over `EditViewModel+FXLinkEdit`: the signal view is
// pure presentation, so it is told what a block looks like (`synopticFXInfo`), whether a selection
// can become a bin (`canCreateFXLink`), and which bins a host could still join
// (`joinableFXLinks`). The gestures themselves are the mutators of the edit file, one undo each.

extension EditViewModel {

    /// What the signal view draws round a bin's block: the frame's colour, the header's name and
    /// on/off, the footer's output section (the bin's while attached, the block's own while detached).
    func synopticFXInfo(_ block: ObjectPlugin) -> SynopticFXLink? {
        guard let fb = block.fxBlock else { return nil }
        let link = fxLink(fb.linkID)
        let out = fxOutput(of: block)
        return SynopticFXLink(blockID: block.id,
                              name: link?.name ?? block.name,
                              color: ObjekatPalette.plugin(link?.colorIndex ?? 0),
                              isDetached: fb.isDetached,
                              isEnabled: out.isEnabled,
                              gainDb: out.gainDb,
                              pan: out.pan,
                              muted: out.muted,
                              memberCount: fxLinkMembers(fb.linkID).count)
    }

    /// True if `pluginIDs` — plugins of `hostID`'s chain — can become the definition of a NEW bin:
    /// plain plugins, none of them in a bin already or carrying a manual link, all in ONE series.
    /// The very test `createFXLink` applies, asked without doing anything.
    func canCreateFXLink(host hostID: UUID, pluginIDs: [UUID]) -> Bool {
        guard !pluginIDs.isEmpty, let chain = chainPlugins(hostID) else { return false }
        let leaves = Self.flattenLeaves(chain)
        var loc: SeriesLocation?
        for id in Set(pluginIDs) {
            guard let (l, _) = Self.locate(id, in: chain),
                  let leaf = leaves.first(where: { $0.id == id }),
                  Self.isFXLinkEligible(leaf) else { return false }
            if case .block = l { return false }
            if let loc, loc != l { return false }
            loc = l
        }
        return loc != nil
    }

    /// The bins `hostID` could still join: those of the registry it holds no block of.
    func joinableFXLinks(host hostID: UUID) -> [(id: UUID, name: String)] {
        let held = Set((chainPlugins(hostID) ?? []).flatMap { Self.fxBlocks(in: [$0]) }
            .compactMap { $0.fxBlock?.linkID })
        return fxLinks.filter { !held.contains($0.id) }.map { ($0.id, $0.name) }
    }

    /// True if at least one object of `ids` could take part in a bin made from objects
    /// (@see createFXLinkFromObjects): two or more, one of them with a run of plain plugins.
    func canCreateFXLinkFromObjects(_ ids: [UUID]) -> Bool {
        let objs = ids.compactMap { find(id: $0) }
        guard objs.count >= 2 else { return false }
        return objs.contains { !Self.fxLinkEligibleRuns(in: $0.plugins).isEmpty }
    }

    /// Moves the colour of a bin on to the next of the plugin palette (a click on its dot).
    func cycleFXLinkColor(_ linkID: UUID) {
        guard let link = fxLink(linkID) else { return }
        setFXLinkColor(linkID, colorIndex: (link.colorIndex + 1) % ObjekatPalette.plugins.count)
    }

    /// The cards the signal view draws for a host's chain, as it builds them (the very mapping the
    /// view calls), flattened in reading order. Nil for an unknown host. It exists so that what a
    /// card SHOWS — a link badge, the greyed look of a disabled bin — can be read back by a script
    /// with no screen (@see `synoptic.cards`).
    func synopticCards(host hostID: UUID) -> [SynopticPlugin]? {
        guard let chain = chainPlugins(hostID) else { return nil }
        let (root, _) = SynopticMapping.build(chain, objectID: hostID,
                                              fxLinkInfo: { self.synopticFXInfo($0) })
        var out: [SynopticPlugin] = []
        func walk(_ n: SynopticNode) {
            switch n.kind {
            case .plugin(let p): out.append(p)
            case .series(let kids), .parallel(let kids): kids.forEach(walk)
            }
        }
        walk(root)
        return out
    }
}
