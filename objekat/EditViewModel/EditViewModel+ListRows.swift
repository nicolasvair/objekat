import Foundation

// MARK: - The rows of the left panel's sound list
//
// TO BE READ BESIDE `EditViewModel.buildLaneEntries` (EditViewModel.swift, just under
// `laneEntries`). The two walk the SAME tree of `items`, and they are allowed to answer
// differently — knowing exactly where they diverge is the whole point of this comment, because
// two tree walks that nobody compares eventually stop describing the same project.
//
//   `laneEntries`   — the timeline's DISPLAY ROWS. Ordered by display lane, CACHED (rebuilt on
//                     the `didSet` of `items`, with a re-entrant depth counter for the batched
//                     mutations), read in some sixty sites including per drag and per scroll
//                     frame. It descends on `showsChildrenInline`, that is `isExpanded &&
//                     !automationOpen`: a group showing its automation band has no children ON
//                     SCREEN, and what is not on screen must not be hit-testable either.
//
//   `soundListRows` — the same tree ordered by TIME, with one row per GROUP as well as one per
//                     clip (`laneEntries` has group rows too, but the list is read as a table of
//                     contents and the group row is its heading). COMPUTED on every read. It
//                     descends on `isExpanded` ALONE: the list's chevron IS the timeline's fold,
//                     one state seen from two places, and an open automation band is a display
//                     mode of the timeline — not a statement about what the project contains.
//                     So a group in automation mode still lists its children here.
//
// The consequence of that single divergence, said plainly: for the children of a group whose
// automation band is open, `displayLane` is the row those children WOULD take if the band were
// closed. Nothing reads it for geometry — in the list it only breaks a tie in the sort — and
// anything that does need a real row on screen must go to `laneEntries`, which is the authority.
//
// No cache here, deliberately. The list is a 240 pt panel redrawn on a click, not a canvas
// redrawn per frame; a second cache would above all be a second cache to INVALIDATE, and
// `laneEntries`' invalidation machinery (a didSet, a depth counter, `batchItemsMutation`) is
// precisely the thing one does not want a second copy of.

/// One row of the sound list. Flat, but carrying its place in the tree (`depth`, `parentID`) so
/// that the view can draw the hierarchy without walking anything itself.
struct SoundListRow: Identifiable {
    var id: UUID { object.id }
    let object: SoundObject
    let depth: Int
    let parentID: UUID?
    /// The row's instant on the timeline. The same value `laneEntries` carries: a child's
    /// `startTime` is already stored in ABSOLUTE edit seconds (@see EditViewModel+Groups, where
    /// grouping keeps the children's startTime as it is), so nothing is added on the way down.
    let absStart: Double
    let displayLane: Int
    /// A group holding at least one child. The chevron is drawn on this and not on `isGroup`:
    /// a chevron over an empty group promises something to unfold and delivers nothing.
    let hasChildren: Bool
}

extension EditViewModel {

    /// The sound list's rows, in the order things HAPPEN, the hierarchy kept.
    ///
    /// Sorted by level of siblings and never globally: a flat sort by time would tear a child
    /// away from its parent and the indentation would describe nothing. Filtered by `filterText`
    /// on the way (@see `listRowMatchesFilter`).
    var soundListRows: [SoundListRow] {
        var out: [SoundListRow] = []
        out.reserveCapacity(items.count)
        EditViewModel.appendListRows(items, parentID: nil, depth: 0, displayLaneOffset: 0,
                                     filter: filterText, into: &out)
        return out
    }

    /// True if this object's own file is missing, or if anything under it is missing its own.
    ///
    /// This is what the panel's "missing files" filter keeps, and it is a PREDICATE rather than a
    /// third tree walk on purpose: applied to the already-flat `soundListRows`, it holds for every
    /// ANCESTOR of a missing object as well as for the object itself, so the filtered list keeps
    /// its hierarchy for free — filtering a tree with a predicate that is not true of the parents
    /// is what leaves children indented under nothing.
    func subtreeHasMissingFile(_ object: SoundObject) -> Bool {
        if isMissing(object) { return true }
        guard case .group(let children, _) = object.kind else { return false }
        return children.contains { subtreeHasMissingFile($0) }
    }

    // MARK: - The walk

    private static func appendListRows(
        _ siblings: [SoundObject],
        parentID: UUID?,
        depth: Int,
        displayLaneOffset: Int,
        filter: String,
        into out: inout [SoundListRow]
    ) {
        // The display row of a sibling, arrived at EXACTLY as `buildLaneEntries` does it: an
        // item's row is its own lane plus the rows opened above it by everything unfolded on a
        // strictly higher lane. Prefix sum → O(N) instead of the O(N²) of a filter per item.
        // Kept in step BY HAND with the timeline's version: if one of the two changes, both do.
        var spanByLane: [Int: Int] = [:]
        for it in siblings { spanByLane[it.lane, default: 0] += it.expandedSpan }
        var prefixBelowLane: [Int: Int] = [:]
        var running = 0
        for lane in spanByLane.keys.sorted() {
            prefixBelowLane[lane] = running
            running += spanByLane[lane]!
        }

        // The sort, at THIS level of siblings only. Earliest first; at the same instant the
        // higher row wins, which is the order the timeline itself is read in; and the original
        // index settles the last tie, because Swift's sort is not stable and two objects starting
        // at the same instant on the same lane would otherwise swap places from one recomputation
        // to the next — a list that reshuffles under the hand for no reason at all.
        var ordered: [(index: Int, item: SoundObject, displayLane: Int)] = []
        ordered.reserveCapacity(siblings.count)
        for (index, item) in siblings.enumerated() {
            ordered.append((index: index,
                            item: item,
                            displayLane: displayLaneOffset + item.lane + (prefixBelowLane[item.lane] ?? 0)))
        }
        ordered.sort {
            if $0.item.startTime != $1.item.startTime { return $0.item.startTime < $1.item.startTime }
            if $0.displayLane != $1.displayLane { return $0.displayLane < $1.displayLane }
            return $0.index < $1.index
        }

        for entry in ordered {
            let item = entry.item
            guard listRowMatchesFilter(item, filter) else { continue }

            let children: [SoundObject]
            if case .group(let c, _) = item.kind { children = c } else { children = [] }

            out.append(SoundListRow(object: item,
                                    depth: depth,
                                    parentID: parentID,
                                    absStart: item.startTime,
                                    displayLane: entry.displayLane,
                                    hasChildren: !children.isEmpty))

            // `isExpanded` and not `showsChildrenInline` — see the divergence at the top of the
            // file. The offset follows the timeline's own rule: the children's band starts on the
            // row just under their group.
            if item.isExpanded && !children.isEmpty {
                appendListRows(children,
                               parentID: item.id,
                               depth: depth + 1,
                               displayLaneOffset: entry.displayLane + 1,
                               filter: filter,
                               into: &out)
            }
        }
    }

    /// A row survives the text filter if IT matches or if anything UNDER it does.
    ///
    /// Keeping only what matches is what breaks a tree: the parents go and their children are left
    /// indented under nothing. So a group is kept for its descendants' sake — shown dimmed by the
    /// view, which is how one tells "this is on the way" from "this is what you were looking for".
    ///
    /// The whole sub-tree is searched, FOLDED groups included. A group holding a match therefore
    /// stays in the list although the match itself is not shown yet: the search answers "it is in
    /// there" instead of silently answering nothing, and unfolding reveals it. The alternative —
    /// unfolding by itself — would have a search WRITE into the document's state, which a way of
    /// looking at a project must never do.
    private static func listRowMatchesFilter(_ object: SoundObject, _ filter: String) -> Bool {
        guard !filter.isEmpty else { return true }
        if object.displayName.localizedCaseInsensitiveContains(filter) { return true }
        guard case .group(let children, _) = object.kind else { return false }
        return children.contains { listRowMatchesFilter($0, filter) }
    }
}
