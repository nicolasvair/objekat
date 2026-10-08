import Foundation

// Decision Q1 of docs/ara_melodyne_plan.md: OBJEKAT's undo NEVER touches a live Melodyne retouch.
// The archive stored in an undo snapshot only serves to RECREATE a source that no longer lives (the
// removal of a source, a deleted object): while the source of the snapshot is the SAME instance as the
// live one (same plugin id), the live archive wins. Pure, so that the case table is testable alone
// (tools/test_ara_model.swift).

enum ARAUndoPolicy {

    /// `snapshotItems` with, for every object whose source is the SAME source as in `live` (same
    /// plugin id), the archive of `live`. An object the undo leaves in place thereby stays equal to
    /// itself (the differential undo then does not rebuild it), and one it has to rebuild is recreated
    /// from the live archive. A source `live` does not contain (an undone removal, an object brought
    /// back) keeps the snapshot's own archive.
    static func adoptingLive(_ snapshotItems: [SoundObject], live: [SoundObject]) -> [SoundObject] {
        var liveSources: [UUID: ARASource] = [:]
        func collect(_ arr: [SoundObject]) {
            for o in arr {
                if let s = o.araSource { liveSources[o.id] = s }
                if case .group(let c, _) = o.kind { collect(c) }
            }
        }
        collect(live)
        guard !liveSources.isEmpty else { return snapshotItems }
        func adopt(_ arr: [SoundObject]) -> [SoundObject] {
            arr.map { original in
                var o = original
                if let s = o.araSource, let l = liveSources[o.id], l.plugin.id == s.plugin.id {
                    o.araSource?.archive = l.archive
                }
                if case .group(let c, let e) = o.kind { o.kind = .group(children: adopt(c), isExpanded: e) }
                return o
            }
        }
        return adopt(snapshotItems)
    }
}
