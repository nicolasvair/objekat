import Foundation

/// Which gesture a press in the MARKER BAND starts — one pure decision, asserted with no screen
/// (`tools/test_marker_band_gesture.swift`).
///
/// The band sits under the time ruler, and until the 2 October 2026 feedback a drag that started
/// anywhere in it went to the mark drag, which does nothing when the hand is not on a mark. The
/// band now reads like the ruler wherever it is EMPTY: a drag traces a time selection and a plain
/// click lays the cursor (`handleRulerDrag` / `moveCursorFromRuler`, reused as they are — snap, ⇧
/// to extend, the range, the selection of the objects and the cursor at the release all come from
/// there). Nothing changes on a mark: drag, crop, ⇧ / ⌘, renaming, right click.
///
/// Two things stay out of it, because the views laid over the band answer them themselves: the
/// rows' pinned names (the dot's right click, the double click that renames, the field) and the
/// button that governs the rows, at the far right.
enum MarkerBandGesture {

    enum Route: Equatable {
        /// An empty stretch of the band: it is the ruler's gesture.
        case ruler
        /// A mark (or a mark's name, or a region): the mark drag.
        case mark
        /// A pinned control of the band: no canvas gesture at all.
        case none
    }

    /// What a drag already under way is: it goes on being that, whatever is under the hand now.
    enum InFlight: Equatable { case ruler, mark }

    /// The pinned names' column, from the viewport's left edge: the row's leading padding (3), the
    /// pill's own (5), the dot (10), the gap (4), the widest name (110) and the pill's trailing
    /// padding (5) — `MarkerLaneHeaderView`'s arithmetic, taken at its widest.
    static let headerExtentX: Double = 3 + 5 + 10 + 4 + 110 + 5
    /// The row-governing button at the far right: its width (26) and its trailing padding (6).
    static let clampExtentX: Double = 26 + 6

    /// True where a press lands on a pinned control (`xInViewport` is measured from the viewport's
    /// left edge: these views do not scroll with the content).
    static func inPinnedControls(xInViewport x: Double, viewportWidth: Double) -> Bool {
        x <= headerExtentX || (viewportWidth > 0 && x >= viewportWidth - clampExtentX)
    }

    /// The route of a drag in the band.
    /// - `zoneHit`: the press lands on a mark / region (@see TimelineView.markerBandZone).
    /// - `inHeader`: the press lands on a pinned control.
    /// - `inFlight`: a band drag already running — nothing is re-decided mid-gesture.
    static func route(zoneHit: Bool, inHeader: Bool, inFlight: InFlight?) -> Route {
        if let f = inFlight { return f == .ruler ? .ruler : .mark }
        if zoneHit { return .mark }
        if inHeader { return .none }
        return .ruler
    }

    /// Whether a click on the band lays the CURSOR, as one on the ruler does: only on an empty
    /// stretch (a mark is selected, and its own click moves the cursor to its start), outside the
    /// pinned controls, and with no modifier — ⇧ and ⌘ keep composing the marks' selection.
    static func clickMovesCursor(hitMark: Bool, inHeader: Bool, shift: Bool, command: Bool) -> Bool {
        !hitMark && !inHeader && !shift && !command
    }
}
