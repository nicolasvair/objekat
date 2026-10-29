import Foundation

// How a LIST of rows is selected by the hand: a click, with or without ⌘ / ⇧, and the arrows.
//
// It is the rule of the sound list (`SoundObjectListView.selectRow` / `extendSelection`) taken out of the
// view so that the Inputs tab can speak it too, and so that it can be compiled and asserted alone:
//
//  - a bare click selects THE ROW and nothing else;
//  - ⌘ adds the row, or removes it when it was already there;
//  - ⇧ extends to a contiguous range, taken from the ENDS of what is already selected to the row clicked —
//    no anchor is remembered between two clicks, the selection itself says where it starts. With nothing
//    selected (in the rows shown) there is nothing to extend from, so it behaves as a bare click. ⇧ wins
//    over ⌘ when both are held;
//  - ↑ / ↓ move the selection by one row, from its ENDS too (↓ goes under the lowest selected row, ↑ above
//    the highest) and stop at either end rather than wrapping; with nothing selected the first press takes
//    the end the key points at. ⇧↑ / ⇧↓ extend the selection by one row at that end (a selection is only
//    grown that way, never shortened);
//  - ⌘A selects every row shown.
//
// `ordered` is the rows AS SHOWN, top to bottom: a range is the rows one sees in between. Whatever the
// selection holds that is not in `ordered` is left alone by ⌘ and dropped by everything else.
//
//     swiftc -parse-as-library ../objekat/Shared/ListClickSelection.swift test_list_click_selection.swift \
//         -o /tmp/listclick && /tmp/listclick

enum ListClickSelection {

    /// The selection after a click on `clicked`.
    static func apply<ID: Hashable>(current: Set<ID>, clicked: ID, ordered: [ID],
                                    shift: Bool, command: Bool) -> Set<ID> {
        if shift {
            guard let target = ordered.firstIndex(of: clicked) else { return current }
            guard let (lo, hi) = ends(of: current, in: ordered) else { return [clicked] }
            return Set(ordered[min(lo, target)...max(hi, target)])
        }
        if command {
            var next = current
            if next.contains(clicked) { next.remove(clicked) } else { next.insert(clicked) }
            return next
        }
        return [clicked]
    }

    /// The selection after ↑ (`delta` < 0) or ↓ (`delta` > 0); `extend` is ⇧.
    static func move<ID: Hashable>(current: Set<ID>, delta: Int, ordered: [ID], extend: Bool) -> Set<ID> {
        guard !ordered.isEmpty, delta != 0 else { return current }
        let down = delta > 0
        guard let (lo, hi) = ends(of: current, in: ordered) else {
            return [down ? ordered[0] : ordered[ordered.count - 1]]
        }
        if extend {
            let from = down ? lo : max(lo - 1, 0)
            let to = down ? min(hi + 1, ordered.count - 1) : hi
            return Set(ordered[from...to])
        }
        return [ordered[down ? min(hi + 1, ordered.count - 1) : max(lo - 1, 0)]]
    }

    /// ⌘A.
    static func all<ID: Hashable>(ordered: [ID]) -> Set<ID> { Set(ordered) }

    /// The index in `ordered` of the row a key press just reached: the lowest end after ↓, the highest
    /// after ↑. What the list scrolls to. Nil when the selection is empty.
    static func edge<ID: Hashable>(of selection: Set<ID>, delta: Int, ordered: [ID]) -> Int? {
        guard let (lo, hi) = ends(of: selection, in: ordered) else { return nil }
        return delta > 0 ? hi : lo
    }

    /// The first and last indices of `ordered` that `selection` holds, or nil.
    private static func ends<ID: Hashable>(of selection: Set<ID>, in ordered: [ID]) -> (Int, Int)? {
        var lo: Int? = nil, hi: Int? = nil
        for (i, id) in ordered.enumerated() where selection.contains(id) {
            if lo == nil { lo = i }
            hi = i
        }
        guard let l = lo, let h = hi else { return nil }
        return (l, h)
    }
}
