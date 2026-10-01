import Foundation
import Observation

/// What the pointer is aiming at on the timeline, kept OUT of `TimelineView`'s state.
///
/// These values used to be `@State` of the view and were read in its `body`, so every zone the
/// pointer crossed (and under the Cut tool every snapped pixel, under Volume every 40 / 20 / 40 %
/// zone) re-evaluated the whole timeline — the partition of every visible block included. They are
/// now properties of a small `@Observable` reference, and Observation tracks PER PROPERTY: only a
/// view that reads one depends on it.
///
/// The split is the whole design:
///
/// - the block's editing zone (`editZoneHover`), the hovered cut position (`cutHover`) and the
///   tooltip (`toolZoneHelpText`) are read by small LEAF views only (`EditZoneVeilLayer`,
///   `CutHoverLine`, `TimelineHoverHelp`, @see `TimelineHoverLayers.swift`), each of which
///   re-evaluates alone. `TimelineView.body` never reads them.
/// - the identity of the block aimed at under Volume / Pan / Stem (`TimelineView.toolHoveredID`)
///   is NOT here, deliberately: the body does read it (the partition makes that block rich), and it
///   is written only when that identity CHANGES. It stays a plain `@State`: measured on a project
///   of 600 selected children in an open group, routing that one invalidation through Observation
///   instead of `@State` cost ~25 % more per hover sweep (the graph has to fold the mutation in,
///   and every body pass re-registers its tracking) for no gain, the body being invalidated either
///   way.
///
/// A reference, held in a `@State` of the view: the NSEvent monitors and the hover callback write
/// through the same object whatever copy of the view struct they captured (a `var` of the struct
/// captured by a long-lived closure would be frozen at its value of the day).
///
/// Every setter writes only on a CHANGE: a notification that carries nothing is exactly what this
/// type exists to prevent.
@Observable
final class TimelineHoverStore {

    /// The cut position under the Cut tool: the block, and the snapped offset INSIDE it.
    struct CutHover: Equatable {
        let id: UUID
        let localX: Double
    }

    /// The block aimed at under the selection tool, and the zone of it (it reveals the six zones).
    private(set) var editZoneHover: EditZoneHover?
    /// The cut position under the Cut tool.
    private(set) var cutHover: CutHover?
    /// The tooltip of the tool zone under the pointer (@see `TimelineView.toolZoneHelp`).
    private(set) var toolZoneHelpText: String?

    func setEditZoneHover(_ hover: EditZoneHover?) {
        if editZoneHover != hover { editZoneHover = hover }
    }

    func setCutHover(_ hover: CutHover?) {
        if cutHover != hover { cutHover = hover }
    }

    func setHelpText(_ text: String?) {
        if toolZoneHelpText != text { toolZoneHelpText = text }
    }

    /// Puts the veil and the cut line out (the pointer is over something that is not a block: the
    /// ruler, a band, a comment, a drop in progress…).
    func clearZoneAndCut() {
        setEditZoneHover(nil)
        setCutHover(nil)
    }

    /// The pointer left the timeline: nothing is aimed at any more (the view clears
    /// `toolHoveredID` itself).
    func clearAll() {
        setHelpText(nil)
        clearZoneAndCut()
    }
}
