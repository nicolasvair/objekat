import Foundation

// MARK: - Which elements a new parallel branch takes (PURE: no view, no layout, no model)
//
// docs/plan_synoptic_rework.md §B.2, the user's rules of 13 October 2026. A parallel branch is made from
// a "+" (a drag down-right) or from a card's context menu ("Create a parallel branch"); either way ONE
// branch takes a RUN of consecutive elements of ONE series, and one undo point covers it:
//
//  - from a "+", with no selection that concerns it: the element UNDER the "+" (D3: the element after it;
//    the one above it for the series' tail "+");
//  - from a "+" whose element is SELECTED: that element and the selected elements that follow it in the
//    same series, down to the first one that is not selected (the tail "+": the selected elements going
//    UP from the last one);
//  - from a "+" of an EMPTY series: nothing — the caller makes an EMPTY branch;
//  - from a card's menu: the run of selected elements round the card (both ways) when the card is in
//    the selection, the card alone otherwise.
//
// A selection that is not contiguous keeps the part that touches the starting element (the rest stays
// where it is); a selected element of ANOTHER series is ignored. A send's marker (the place a send taps
// the trunk) is a BARRIER: no run crosses one, since a send taken between two plugins cannot move into a
// branch with them. These choices are the agent's, listed in the plan's journal (§H) for the user.
//
// This file is compiled alone by `tools/test_synoptic_branch_run.swift`.

/// What the canvas asks for when it wants a parallel branch (@see SynopticActions.onBranch). The selection
/// is read by the receiver (it lives in the view-model, with its host).
enum SynopticBranchRequest: Equatable {
    /// A drag down-right out of the "+" at view index `index` (markers do not count) of the series `seriesID`.
    case plus(seriesID: UUID, index: Int)
    /// "Create a parallel branch" from the context menu of the card `pluginID`.
    case plugin(UUID)
}

enum SynopticBranchRun {

    /// One entry of a series, in the MODEL's order.
    struct Element: Equatable {
        let id: UUID
        /// A send's marker: not an element the view shows, and never crossed by a run.
        var isBarrier: Bool = false
        /// In the selection (a container: its id, or every leaf it holds).
        var isSelected: Bool = false

        init(id: UUID, isBarrier: Bool = false, isSelected: Bool = false) {
            self.id = id
            self.isBarrier = isBarrier
            self.isSelected = isSelected
        }
    }

    /// The run a "+" at view index `index` branches, in order. Empty = an empty series (make an empty branch).
    static func forPlus(at index: Int, in elements: [Element]) -> [UUID] {
        let shown = elements.indices.filter { !elements[$0].isBarrier }
        guard !shown.isEmpty else { return [] }
        let isTail = index >= shown.count
        let start = shown[isTail ? shown.count - 1 : max(0, index)]
        guard elements[start].isSelected else { return [elements[start].id] }
        let step = isTail ? -1 : 1
        var run = [start]
        var k = start + step
        while elements.indices.contains(k), !elements[k].isBarrier, elements[k].isSelected {
            run.append(k)
            k += step
        }
        return run.sorted().map { elements[$0].id }
    }

    /// The run the context menu of the card `id` branches, in order. nil = the card is not an element of
    /// this series.
    static func around(_ id: UUID, in elements: [Element]) -> [UUID]? {
        guard let i = elements.firstIndex(where: { $0.id == id && !$0.isBarrier }) else { return nil }
        guard elements[i].isSelected else { return [id] }
        var lo = i, hi = i
        while lo > 0, !elements[lo - 1].isBarrier, elements[lo - 1].isSelected { lo -= 1 }
        while hi + 1 < elements.count, !elements[hi + 1].isBarrier, elements[hi + 1].isSelected { hi += 1 }
        return elements[lo...hi].map(\.id)
    }
}
