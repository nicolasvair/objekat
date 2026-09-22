import Foundation

// What a cut leaves SELECTED — a question the split itself does not answer, because splitting is
// about the matter and this is about what the eye keeps watching afterwards.
//
// The rule: "a cut does not re-aim the selection, the selection follows the matter." An object
// that was not selected stays that way, whichever of its two pieces survives — a cut is not a
// pick. An object that WAS selected and loses one half outright (an oriented cut, or ripple) hands
// its selection to the piece that is left, there being only one candidate. The interesting case is
// a PLAIN division, where both halves survive: the SHORTER one (by timeline duration) gets the
// selection. The reasoning is that a cut is most often made to throw a small scrap away — a
// breath, a click, a count-in — and the natural next gesture is to select that scrap and delete
// it. Handing the selection to the piece one is about to discard saves exactly that click.
//
// Ties go LEFT, and not by convention: the left half of a split ALWAYS keeps the object's
// original id (every one of the five branches of `_splitInternal` hands the new UUID to the right
// piece, never the left). So "equal duration → left" costs the selection NOTHING — `selectedIDs`
// does not even have to be rewritten, the id it already names is still the one that matters. That
// is also, word for word, what the rule's own first line asks for: an object cut in half is, as
// far as the selection is concerned, unchanged.
//
// This file depends on nothing but `CutKeepSide` (declared just below) and the standard library,
// on purpose: it is the half of a cut's selection logic that has no model behind it, so it can be
// compiled and asserted alone —
//
//     swiftc -parse-as-library ../objekat/Shared/CutSelection.swift test_cut_selection.swift \
//         -o /tmp/cutsel && /tmp/cutsel

/// The side KEPT by an oriented cut (the Cut tool, a drag gesture).
enum CutKeepSide { case left, right }

/// Which of the two pieces a cut produces should carry the selection onward, when the object cut
/// WAS selected. See the file header for the rule and why ties go left.
enum CutSelectionSide { case left, right }

/// `objectStart` / `objectDuration` describe the object BEFORE the cut; `splitTime` is absolute,
/// like `objectStart`. `keeping` is the oriented cut's own choice when there is only one piece
/// left to answer for (`nil` = a plain division, both halves survive, durations decide).
func cutSelectionSide(objectStart: Double, objectDuration: Double, splitTime: Double,
                      keeping: CutKeepSide?) -> CutSelectionSide {
    if let keeping { return keeping == .left ? .left : .right }
    let leftDur  = splitTime - objectStart
    let rightDur = objectStart + objectDuration - splitTime
    return rightDur < leftDur - 1e-9 ? .right : .left
}
