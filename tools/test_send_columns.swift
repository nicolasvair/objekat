// The Send tool's knob columns — the geometry, asserted with no screen.
//
// `SendColumns` depends on nothing at all, which is the whole reason it is a unit of its own: the
// columns are the half of the Send tool that has no model behind it, and the display and the
// hit-testing both read them. A knob one can SEE and cannot TURN is what happens the day those two
// readings drift — and that is exactly what a crossfade used to produce, its zone belonging to two
// objects at once.
//
//     swiftc -parse-as-library \
//         ../objekat/Timeline/SendColumns.swift test_send_columns.swift \
//         -o /tmp/sendcols && /tmp/sendcols
//
// Exit: 0 if every assertion passes, 1 otherwise.

import Foundation

var fails: [String] = []
var total = 0

func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    total += 1
    if ok { print("ok    " + label) }
    else { fails.append(label); print("FAIL  \(label)  \(detail)") }
}

@main
enum SendColumnsTest {
  static func main() {

    // MARK: - No crossfade: the columns set off from the left edge

    // A 300 px block, 3 auxes → 60 px a column (the ceiling), the first three hundred pixels
    // carrying them and the rest of the block carrying nothing.
    check("the first pixel is column 0",
          sendColumnIndex(localX: 0, blockWidth: 300, leadingInset: 0, count: 3) == 0)
    check("59 px along is still column 0",
          sendColumnIndex(localX: 59, blockWidth: 300, leadingInset: 0, count: 3) == 0)
    check("60 px along is column 1",
          sendColumnIndex(localX: 60, blockWidth: 300, leadingInset: 0, count: 3) == 1)
    check("the last column ends at 3 × 60",
          sendColumnIndex(localX: 179, blockWidth: 300, leadingInset: 0, count: 3) == 2)
    check("past the columns, nothing",
          sendColumnIndex(localX: 181, blockWidth: 300, leadingInset: 0, count: 3) == nil,
          "a wide block keeps its knobs on the left; the rest of it is not a knob")
    check("before the block, nothing",
          sendColumnIndex(localX: -1, blockWidth: 300, leadingInset: 0, count: 3) == nil)

    // A narrow block: the columns share what there is rather than overflowing.
    check("a narrow block splits its width",
          sendColumnIndex(localX: 0, blockWidth: 90, leadingInset: 0, count: 3) == 0)
    check("…three columns of 30 px",
          sendColumnIndex(localX: 61, blockWidth: 90, leadingInset: 0, count: 3) == 2)
    check("…and nothing past its edge",
          sendColumnIndex(localX: 91, blockWidth: 90, leadingInset: 0, count: 3) == nil)

    check("no aux, no column", sendColumnIndex(localX: 10, blockWidth: 300,
                                               leadingInset: 0, count: 0) == nil)

    // MARK: - A crossfade holding the left edge: the columns start AFTER it

    // The same 300 px block, its first 80 px shared with the neighbour it fades into.
    check("the shared span carries no knob",
          sendColumnIndex(localX: 40, blockWidth: 300, leadingInset: 80, count: 3) == nil,
          "those pixels belong to the neighbour too — the bug this inset exists for")
    check("the crossfade's last pixel still carries none",
          sendColumnIndex(localX: 79, blockWidth: 300, leadingInset: 80, count: 3) == nil)
    check("column 0 starts where the crossfade ends",
          sendColumnIndex(localX: 80, blockWidth: 300, leadingInset: 80, count: 3) == 0)
    check("and the columns follow from there",
          sendColumnIndex(localX: 140, blockWidth: 300, leadingInset: 80, count: 3) == 1)

    // What is LEFT of the block carries the columns: they get thinner, they do not run off the end.
    // 200 px block, 80 shared → 120 px for 3 columns = 40 px each.
    check("a heavily crossfaded block makes its columns thinner",
          sendColumnIndex(localX: 80 + 39, blockWidth: 200, leadingInset: 80, count: 3) == 0)
    check("…second column at 40 px along",
          sendColumnIndex(localX: 80 + 40, blockWidth: 200, leadingInset: 80, count: 3) == 1)
    check("…third one reaching the block's own edge",
          sendColumnIndex(localX: 199, blockWidth: 200, leadingInset: 80, count: 3) == 2)
    check("…and never past it",
          sendColumnIndex(localX: 201, blockWidth: 200, leadingInset: 80, count: 3) == nil)

    // A crossfade wider than the block leaves nowhere to put a knob — and must not answer 0 for it.
    check("a zone swallowing the block leaves no column at all",
          sendColumnIndex(localX: 10, blockWidth: 50, leadingInset: 50, count: 3) == nil)

    // MARK: - The pair, read as the canvas reads it
    //
    // Two 300 px blocks, the right one starting at 220: they share 80 px, 220…300. A point in
    // there is offered to BOTH, and neither may claim it — the left one's columns stopped at 180,
    // the right one's have not started.
    let leftLocal  = 250.0 - 0.0     // the point, seen from the left block's edge
    let rightLocal = 250.0 - 220.0   // …and from the right one's
    check("inside the zone the left object claims nothing",
          sendColumnIndex(localX: leftLocal, blockWidth: 300, leadingInset: 0, count: 3) == nil)
    check("inside the zone the right object claims nothing either",
          sendColumnIndex(localX: rightLocal, blockWidth: 300, leadingInset: 80, count: 3) == nil)
    check("just past the zone, the right object's first knob",
          sendColumnIndex(localX: 301 - 220, blockWidth: 300, leadingInset: 80, count: 3) == 0)

    // MARK: - A block partly scrolled away: the columns follow its VISIBLE portion
    //
    // `visibleX` / `visibleWidth` are the block's visible part, local to its left edge (what
    // `visibleSpan` answers, minus the block's x). 1000 px block, 3 auxes → 60 px a column.

    // Left edge off screen: 400 px scrolled away.
    check("left off-screen: the columns set off from the visible edge",
          sendColumnIndex(localX: 400, blockWidth: 1000, leadingInset: 0, count: 3,
                          visibleX: 400, visibleWidth: 600) == 0)
    check("left off-screen: column 1 is 60 px along the visible edge",
          sendColumnIndex(localX: 460, blockWidth: 1000, leadingInset: 0, count: 3,
                          visibleX: 400, visibleWidth: 600) == 1)
    check("left off-screen: the last column",
          sendColumnIndex(localX: 579, blockWidth: 1000, leadingInset: 0, count: 3,
                          visibleX: 400, visibleWidth: 600) == 2)
    check("left off-screen: nothing past the columns",
          sendColumnIndex(localX: 581, blockWidth: 1000, leadingInset: 0, count: 3,
                          visibleX: 400, visibleWidth: 600) == nil)
    check("left off-screen: the block's own (invisible) edge carries nothing",
          sendColumnIndex(localX: 10, blockWidth: 1000, leadingInset: 0, count: 3,
                          visibleX: 400, visibleWidth: 600) == nil)

    // Right edge off screen only: the left edge is visible, so nothing moves.
    check("right off-screen: the columns stay at the left edge",
          sendColumnIndex(localX: 0, blockWidth: 1000, leadingInset: 0, count: 3,
                          visibleX: 0, visibleWidth: 500) == 0)
    check("right off-screen: same columns as the unscrolled block",
          sendColumnIndex(localX: 130, blockWidth: 1000, leadingInset: 0, count: 3,
                          visibleX: 0, visibleWidth: 500)
          == sendColumnIndex(localX: 130, blockWidth: 1000, leadingInset: 0, count: 3))

    // Both edges off screen: a 200 px window in the middle of the block.
    check("both off-screen: column 0 at the window's left edge",
          sendColumnIndex(localX: 300, blockWidth: 1000, leadingInset: 0, count: 3,
                          visibleX: 300, visibleWidth: 200) == 0)
    check("both off-screen: the last column inside the window",
          sendColumnIndex(localX: 479, blockWidth: 1000, leadingInset: 0, count: 3,
                          visibleX: 300, visibleWidth: 200) == 2)
    // Few pixels visible and many auxes: the window is shared out, not overflowed.
    check("both off-screen: a narrow window shares its width (5 auxes, 100 px → 20 each)",
          sendColumnIndex(localX: 300 + 99, blockWidth: 1000, leadingInset: 0, count: 5,
                          visibleX: 300, visibleWidth: 100) == 4)
    check("both off-screen: …and nothing past the window",
          sendColumnIndex(localX: 300 + 101, blockWidth: 1000, leadingInset: 0, count: 5,
                          visibleX: 300, visibleWidth: 100) == nil)

    // Fully visible: explicit or absent, the window changes NOTHING.
    for x in stride(from: -5.0, through: 305.0, by: 5.0) {
        check("fully visible: x=\(x) reads as without a window",
              sendColumnIndex(localX: x, blockWidth: 300, leadingInset: 0, count: 3,
                              visibleX: 0, visibleWidth: 300)
              == sendColumnIndex(localX: x, blockWidth: 300, leadingInset: 0, count: 3))
    }
    check("a window wider than the block (visible span clamps) changes nothing",
          sendColumnIndex(localX: 61, blockWidth: 90, leadingInset: 0, count: 3,
                          visibleX: 0, visibleWidth: 5000) == 2)

    // A tiny visible sliver: 6 px → 2 px a column, all still addressed and consistent.
    check("sliver: first pixel is column 0",
          sendColumnIndex(localX: 700, blockWidth: 1000, leadingInset: 0, count: 3,
                          visibleX: 700, visibleWidth: 6) == 0)
    check("sliver: column 1 two pixels along",
          sendColumnIndex(localX: 702, blockWidth: 1000, leadingInset: 0, count: 3,
                          visibleX: 700, visibleWidth: 6) == 1)
    check("sliver: column 2 four pixels along",
          sendColumnIndex(localX: 705, blockWidth: 1000, leadingInset: 0, count: 3,
                          visibleX: 700, visibleWidth: 6) == 2)
    check("sliver: nothing past it",
          sendColumnIndex(localX: 706, blockWidth: 1000, leadingInset: 0, count: 3,
                          visibleX: 700, visibleWidth: 6) == nil)

    // The crossfade rule composes with the scroll.
    // 300 px block, 80 shared; visible from 50 → the inset wins (columns start at 80).
    check("crossfade + scroll: the inset still wins over a visible edge inside it",
          sendColumnIndex(localX: 79, blockWidth: 300, leadingInset: 80, count: 3,
                          visibleX: 50, visibleWidth: 200) == nil)
    check("crossfade + scroll: column 0 starts at the crossfade's end",
          sendColumnIndex(localX: 80, blockWidth: 300, leadingInset: 80, count: 3,
                          visibleX: 50, visibleWidth: 200) == 0)
    // …and a visible edge past the inset wins over the inset: 100…250 → 150 px, 50 each.
    check("crossfade + scroll: a visible edge past the crossfade leads",
          sendColumnIndex(localX: 100, blockWidth: 300, leadingInset: 80, count: 3,
                          visibleX: 100, visibleWidth: 150) == 0)
    check("crossfade + scroll: …and the span before it carries nothing",
          sendColumnIndex(localX: 99, blockWidth: 300, leadingInset: 80, count: 3,
                          visibleX: 100, visibleWidth: 150) == nil)
    check("crossfade + scroll: …third column",
          sendColumnIndex(localX: 249, blockWidth: 300, leadingInset: 80, count: 3,
                          visibleX: 100, visibleWidth: 150) == 2)
    // The visible part lying wholly inside the shared span: nothing of this object alone is
    // visible, so the layout falls back on the inset's (no phantom columns over the neighbour).
    check("crossfade + scroll: a window inside the shared span falls back on the inset",
          sendColumnIndex(localX: 40, blockWidth: 300, leadingInset: 80, count: 3,
                          visibleX: 0, visibleWidth: 60) == nil)
    check("crossfade + scroll: …and column 0 is still at the crossfade's end",
          sendColumnIndex(localX: 80, blockWidth: 300, leadingInset: 80, count: 3,
                          visibleX: 0, visibleWidth: 60) == 0)

    // The layout itself, the one the display and the send links read.
    do {
        let l = sendColumnsLayout(blockWidth: 1000, leadingInset: 0, count: 3,
                                  visibleX: 400, visibleWidth: 600)
        check("layout: origin is the visible edge", l.origin == 400 && l.width == 600)
        let w = sendColumnsLayout(blockWidth: 300, leadingInset: 80, count: 3)
        check("layout: no window = the inset alone", w.origin == 80 && w.width == 220)
    }

    // MARK: -

    print("")
    if fails.isEmpty {
        print("\(total) assertions, all pass")
        exit(0)
    } else {
        print("\(fails.count) FAILED: \(fails.joined(separator: " · "))")
        exit(1)
    }
  }
}
