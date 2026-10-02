import Foundation

// MARK: - What a right click on the LANES means — the part with no view and no model behind it
//
// The right click is decided by four facts and nothing else: whether the point lies INSIDE the
// time selection, whether a time selection exists at all, which half of the block it landed on
// (the upper half is TIME, the lower half is the OBJECT — the 50 % line the left click already
// uses, @see TimelineView.handleCanvasTap) and whether that object is already part of the
// selection. From them follow which menu is built, whether the click selects the object first, and
// which of the two annotation items it offers.
//
// It lives here so that `tools/test_context_menu_plan.swift` can compile and assert it alone, the
// way `CrossfadeGrab` / `CutSelection` are: the monitor that builds the menu is AppKit and cannot
// be driven headless, but WHAT IT DECIDES can.
//
//   • INSIDE the time selection, ON an object (either half of its block): the two annotation
//     items and nothing else — 'Create an object marker' (in the object, at the instant aimed at)
//     and 'Create a comment' (over the range). The hand is pointing at a passage OF an object, and
//     those are the two things one lays there; the range's other entries (group, aux, MIDI clip)
//     and the object's own (consolidate, colour, scripts, relink, FX link) stay reachable from an
//     empty lane and from the object's lower half outside the range. The click selects nothing.
//   • INSIDE the time selection, on NO object: the menu the range has always had, untouched, and
//     the click selects nothing — the range is what was aimed at.
//   • Upper half of a block, outside any range: time. A marker laid inside the object at that
//     instant — and no comment (a comment is about a range, and there is none under the hand).
//     Nothing is selected and the cursor does not move: the left click on that half lays the caret,
//     this one touches nothing.
//   • Lower half: the object. The click selects it first, as the left click does (range cleared,
//     cursor moved) — unless it is already selected, in which case NOTHING changes: that is what
//     keeps a multiple selection alive for 'Consolidate N linked' and the FX link.
//   • No object under the hand (an empty lane): a time selection ANYWHERE gives the range's menu,
//     inside it or not — nothing about the range has changed for a click that lands on no object.
//     With no time selection but OBJECTS selected (clips that are not consolidated instances): the
//     'Group the selection' menu, as it always was, and nothing else — the click selects nothing.
//     With neither: no menu, the event goes on to the views.

enum ContextMenuPlan {

    /// Which half of a block the click landed on.
    enum BlockZone: Equatable {
        /// The upper half: time.
        case time
        /// The lower half: the object's body.
        case body

        /// The same 50 % line as the left click's `inUpperZone`.
        static func zone(localY: Double, blockHeight: Double) -> BlockZone {
            localY < blockHeight * 0.50 ? .time : .body
        }
    }

    /// Which menu gets built.
    enum Layout: Equatable {
        /// The range's menu (group, aux, MIDI clip, comment…): the point is on an empty lane while
        /// a time selection exists (inside it or not).
        case rangeMenu
        /// The point is inside the time selection AND on an object: the object marker and the
        /// comment, and nothing else.
        case rangeAnnotationsMenu
        /// The upper half of a block: the annotation items only.
        case objectTimeMenu
        /// The lower half of a block: the object's own menu.
        case objectBodyMenu
        /// An empty lane, no time selection, clips selected: 'Group the clip / the selection (N)'
        /// alone — the selection being what the menu is about, the click touches nothing.
        case groupSelectionMenu
        /// Nothing under the hand worth a menu.
        case nothing
    }

    struct Decision: Equatable {
        let layout: Layout
        /// The click selects the object under it first (range cleared, cursor moved) — the left
        /// click's selection. False when it is already selected: nothing is touched then.
        let selectsObject: Bool
        /// 'Create an object marker', at the instant aimed at, inside the object under the hand.
        let offersObjectMarker: Bool
        /// 'Create a comment' over the time selection.
        let offersComment: Bool
    }

    /// `pointInTimeSelection`: the point lies inside the range (its lanes AND its time span).
    /// `hasTimeSelection`: a range exists, wherever it lies (implied by `pointInTimeSelection`).
    /// `zone`: nil when there is no object under the point.
    /// `hasGroupableSelection`: the selection holds at least one clip or MIDI clip that is not a
    /// consolidated instance (only read on an empty lane with no time selection).
    static func decide(pointInTimeSelection: Bool, hasTimeSelection: Bool, zone: BlockZone?,
                       objectAlreadySelected: Bool, hasGroupableSelection: Bool = false) -> Decision {
        if pointInTimeSelection {
            return Decision(layout: zone != nil ? .rangeAnnotationsMenu : .rangeMenu,
                            selectsObject: false,
                            offersObjectMarker: zone != nil, offersComment: true)
        }
        switch zone {
        case .none:
            // An empty lane: the range's menu if there is a range, wherever it lies; failing that,
            // 'Group the selection' if clips are selected; failing that, nothing.
            return Decision(layout: hasTimeSelection ? .rangeMenu
                                  : (hasGroupableSelection ? .groupSelectionMenu : .nothing),
                            selectsObject: false,
                            offersObjectMarker: false, offersComment: hasTimeSelection)
        case .time:
            return Decision(layout: .objectTimeMenu, selectsObject: false,
                            offersObjectMarker: true, offersComment: false)
        case .body:
            return Decision(layout: .objectBodyMenu, selectsObject: !objectAlreadySelected,
                            offersObjectMarker: false, offersComment: false)
        }
    }

    /// Whether a point lies inside a time selection: its DISPLAY lane is one of the range's and its
    /// instant is within the span (bounds included) — the same rule the drag applies to decide
    /// whether a grab is inside the range.
    static func contains(lane: Int, time: Double, lanes: Set<Int>,
                         range: ClosedRange<Double>) -> Bool {
        lanes.contains(lane) && range.contains(time)
    }
}
