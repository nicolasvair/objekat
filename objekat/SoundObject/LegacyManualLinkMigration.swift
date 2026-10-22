import Foundation

// MARK: - The single-instance manual link is gone (session format 32)
//
// Up to format 31 a plugin could be "⌘-linked" to other instances of the same plugin on other
// objects: its `linkGroupID` named a group of OUTSIDE plugins, the engine mirrored the parameters
// of the group. The user's decision of 22 October 2026 removes that gesture and that state: the FX
// link (a bin of plugins several objects share) is the only way left of sharing parameters.
//
// What stays: `linkGroupID` / `detachedLinkGroupID` as FIELDS, the engine's mirror and
// `rewireLinkGroups`. A bin's instance names its bin's DEFINITION plugin through them. So the
// discriminant of a manual link is WHERE the field sits:
//
//  • on a plugin INSIDE an `fxBlock` (a bin's member, attached or detached) → a bin's instance, untouched;
//  • on a plugin OUTSIDE every block (a trunk plugin, a rack's voice, an instrument, a send's
//    plugin, a stem's plugin) → a manual link (or the residue of one: a detached plugin able to
//    rejoin its group) → both fields are cleared. The plugin stays, with its settings, and now
//    simply plays on its own.
//
// The bins' registry (`fxLinks`, the definitions) is never walked: a definition's plugins are not
// instances in a chain. A channel choice (`channelPick`) of a bin keeps its own field the same way.
//
// PRESENCE-DRIVEN and IDEMPOTENT: it acts on what it finds, whatever the file's format number, and
// a second run finds nothing. Pure: no view-model, no engine. Called by the load funnel
// (`EditViewModel.performStructureSetup`, every way of opening a project, a tab's restoration
// included) and by a consolidated object's sidecar decoder. The load is NOT marked modified for it:
// the file on disk still holds the link, and the next save simply writes it without. To the ear
// nothing changes but the lost synchronisation of the formerly linked instances.

enum LegacyManualLinkMigration {

    /// What a migration did. All zero = nothing to do (a format-32 file, or a file with no manual link).
    struct Report: Equatable {
        /// Plugins (and instruments) that stopped being linked.
        var unlinkedPlugins = 0
        /// Objects, stems or sends' chains that held at least one of them, counted by HOST (an object
        /// counts once whatever the number of its plugins).
        var hosts = 0

        var isEmpty: Bool { self == Report() }

        static func + (a: Report, b: Report) -> Report {
            Report(unlinkedPlugins: a.unlinkedPlugins + b.unlinkedPlugins, hosts: a.hosts + b.hosts)
        }
        static func += (a: inout Report, b: Report) { a = a + b }
    }

    // MARK: - Entry points

    /// A whole session: every object at any depth (a group's children included), and the stems with
    /// the Main.
    @discardableResult
    static func migrate(items: inout [SoundObject], stems: inout [Stem]) -> Report {
        var report = Report()
        for i in items.indices { migrate(&items[i], &report) }
        for i in stems.indices {
            var count = 0
            stems[i].plugins = unlinked(stems[i].plugins, &count)
            if count > 0 { report.unlinkedPlugins += count; report.hosts += 1 }
        }
        return report
    }

    /// A consolidated object's sidecar (a sub-tree, no registry).
    @discardableResult
    static func migrate(_ subtree: inout SoundObject) -> Report {
        var report = Report()
        migrate(&subtree, &report)
        return report
    }

    // MARK: - Objects

    /// The three roots of an object's plugins (`SendChain.allRoots`): the chain, the instruments and
    /// each send's mini-chain.
    private static func migrate(_ o: inout SoundObject, _ report: inout Report) {
        if case .group(var children, let expanded) = o.kind {
            for i in children.indices { migrate(&children[i], &report) }
            o.kind = .group(children: children, isExpanded: expanded)
        }
        var count = 0
        o.plugins = unlinked(o.plugins, &count)
        o.instruments = unlinked(o.instruments, &count)
        for k in o.sends.indices { o.sends[k].plugins = unlinked(o.sends[k].plugins, &count) }
        if count > 0 { report.unlinkedPlugins += count; report.hosts += 1 }
    }

    // MARK: - Series

    /// `series` with every link field outside a bin's block cleared. A block is left whole; a rack is
    /// walked down branch by branch.
    private static func unlinked(_ series: [ObjectPlugin], _ count: inout Int) -> [ObjectPlugin] {
        series.map { p in
            if p.fxBlock != nil { return p }
            if p.rack != nil {
                return p.mappingChildSeries { unlinked($0, &count) }
            }
            guard p.linkGroupID != nil || p.detachedLinkGroupID != nil else { return p }
            var q = p
            q.linkGroupID = nil
            q.detachedLinkGroupID = nil
            count += 1
            return q
        }
    }
}
