import Foundation

/// The caret as a magnet — what an object's edge can land on while the hand moves or trims it.
///
/// The caret (the point a plain click lays, `cursorPosition` + `caretLane`) is drawn as a short black
/// mark on its lane while no time selection is up. When an object is carried or trimmed, its edges
/// snap onto the marks, the other objects' edges and the grid; the caret is one more thing the eye
/// sees standing there, so an edge that passes next to it is attracted — the way a pen is drawn to
/// the cursor of a text.
///
/// ONLY the instant counts, whatever the lane: the snap is a matter of time, the lane the caret
/// stands on does not make it reachable or not. The playhead is not a target (it is the same number
/// as `cursorPosition` while the caret is hidden, which is exactly when the caret does not count).
///
/// Pure: no view, no model — compiled and run alone by `tools/test_caret_snap.swift`.
enum CaretSnap {

    /// The instant the caret offers as a snap target, or nil when there is none:
    /// - no caret (`caretLane == nil`: nothing has been clicked, or the click was cleared);
    /// - a time selection is up (the caret is not drawn then — the selection's own bounds take over);
    /// - the instant is before 0 (nothing is drawn before 0, so nothing may land there, same rule as
    ///   `ZeroFloor.isSnapTarget`).
    static func target(cursor: Double, caretLane: Int?, hasTimeSelection: Bool) -> Double? {
        guard caretLane != nil, !hasTimeSelection, cursor >= 0 else { return nil }
        return cursor
    }
}
