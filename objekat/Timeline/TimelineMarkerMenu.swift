import AppKit
import SwiftUI

// MARK: - The right click's annotation items

/// The menu of the RULER and of the marker band: creating a mark, renaming one, deleting one.
///
/// A free function rather than a method, like `addMakeObjectsItem` next door: the right-click
/// monitor's closure hands it the `proxies` array it must keep alive — an `NSMenuItem`'s target is
/// held weakly, so a proxy that went out of scope would give a menu whose items do nothing.
@MainActor
func buildMarkerBandMenu(vm: EditViewModel,
                         proxies: inout [MenuActionProxy],
                         laneID: UUID?,
                         time: Double,
                         hit: AnnotationSel?) -> NSMenu {
    let menu = NSMenu()

    if let hit {
        addAnnotationItems(menu, &proxies, vm: vm, sel: hit)
        menu.addItem(.separator())
    }

    addItem(menu, &proxies, L("menu.context.marker.create")) {
        if let made = vm.addMarker(laneID: laneID, at: time) {
            vm.selectAnnotation(.laneMarker(lane: made.lane, marker: made.marker))
            vm.renamingID = made.marker      // one gesture: it is created NAMED, or it is a tick
        }
    }

    // A region needs a span, and the timeline already has a way of saying one: the time selection.
    // No second gesture invented for it — you trace, you right-click, you name.
    if let sel = vm.timeSelection {
        let lo = sel.timeRange.lowerBound, hi = sel.timeRange.upperBound
        addItem(menu, &proxies, L("menu.context.region.create")) {
            if let made = vm.addMarker(laneID: laneID, at: lo, duration: hi - lo) {
                vm.selectAnnotation(.laneMarker(lane: made.lane, marker: made.marker))
                vm.renamingID = made.marker
            }
        }
    }

    // NO 'new marker lane' here. Creating a ROW is the lanes' button's alone (@see
    // MarkerLaneHeaderView.clampButton): it is where one goes to show, hide and delete them, so it
    // is where one goes to make one. Repeated in this menu, it stood beside two items that lay a
    // MARK and read as a third way of doing the same thing.
    return menu
}

// MARK: - What every annotation shares

/// Rename, delete, recolour — the three items a marker, a region and a comment all have, built
/// once for the three menus that show them (the band's, an object's, a comment's).
///
/// The COLOUR is the reason this exists as a function rather than three copies. It is a grid, not a
/// list: sixteen hues read at a glance, in one AppKit view (@see ColorSwatchGridView), and above it
/// the one item that gives the hue BACK — a mark of the band inherits its row's colour, a mark on
/// an object and a comment are white. Inheriting is not 'no colour': it is what makes recolouring
/// a row recolour everything on it.
@MainActor
func addAnnotationItems(_ menu: NSMenu, _ proxies: inout [MenuActionProxy],
                        vm: EditViewModel, sel: AnnotationSel) {
    let isComment: Bool = { if case .comment = sel { return true }; return false }()

    addItem(menu, &proxies, isComment ? L("menu.context.comment.edit")
                                      : L("menu.context.marker.rename")) {
        vm.selectAnnotation(sel)
        vm.renamingID = sel.markerID
    }
    addItem(menu, &proxies, isComment ? L("menu.context.comment.delete")
                                      : L("menu.context.marker.delete")) {
        vm.selectAnnotation(sel)
        vm.deleteSelectedAnnotation()
    }

    menu.addItem(.separator())
    let current = vm.annotationColor(sel)
    let inheritTitle: String = { if case .laneMarker = sel { return L("menu.context.marker.laneColor") }
                                 return L("menu.context.annotation.whiteColor") }()
    let pReset = MenuActionProxy { Task { @MainActor in vm.setAnnotationColor(sel, colorIndex: nil) } }
    proxies.append(pReset)
    let reset = NSMenuItem(title: inheritTitle, action: #selector(MenuActionProxy.run), keyEquivalent: "")
    reset.target = pReset
    reset.state = current == nil ? .on : .off
    menu.addItem(reset)

    let swatch = NSMenuItem()
    swatch.view = ColorSwatchGridView(currentColorIndex: current) { picked in
        Task { @MainActor in vm.setAnnotationColor(sel, colorIndex: picked) }
    }
    menu.addItem(swatch)
}

/// The menu of an annotation laid over the LANES — a comment, or a marker carried by an object.
/// Nothing but the three shared items: there is no row to create here and no time to lay a mark at
/// that the object's own menu does not already offer.
@MainActor
func buildAnnotationMenu(vm: EditViewModel, proxies: inout [MenuActionProxy],
                         sel: AnnotationSel) -> NSMenu {
    let menu = NSMenu()
    addAnnotationItems(menu, &proxies, vm: vm, sel: sel)
    return menu
}

/// The items the right click adds to an OBJECT's menu: a marker inside the object, at the point
/// aimed at. In the object's own frame, which is what makes it survive a move or a right trim
/// (@see the note on `SoundObject.markers`).
@MainActor
func addObjectMarkerItem(menu: NSMenu, proxies: inout [MenuActionProxy],
                         vm: EditViewModel, objectID: UUID, atAbsoluteTime time: Double) {
    if !menu.items.isEmpty { menu.addItem(.separator()) }
    addItem(menu, &proxies, L("menu.context.objectMarker.create")) {
        if let mid = vm.addObjectMarker(objectID: objectID, atAbsoluteTime: time) {
            vm.selectAnnotation(.objectMarker(object: objectID, marker: mid))
            vm.renamingID = mid
        }
    }
}

/// The item the right click adds over a TIME SELECTION: a comment on that passage. It lands on the
/// first lane of the selection, which is the one the eye was on when the range was traced.
@MainActor
func addCommentItem(menu: NSMenu, proxies: inout [MenuActionProxy],
                    vm: EditViewModel, selection: TimeSelection) {
    let lo = selection.timeRange.lowerBound
    let hi = selection.timeRange.upperBound
    // A time selection speaks in DISPLAY rows; a comment stores a BASE one, IN THE FRAME IT FALLS
    // IN (@see TimelineComment.parentID). A range traced over the open band of a group therefore
    // lays the comment INSIDE that group — where the eye put it — and `commentAnchor` answers the
    // frame and the row at once, on the same rule a paste and a drop already follow.
    let anchor = vm.commentAnchor(forDisplayLane: selection.lanes.min() ?? 0)
    addItem(menu, &proxies, L("menu.context.comment.create")) {
        if let id = vm.addComment(from: lo, to: hi, lane: anchor.lane, parentID: anchor.parent) {
            vm.selectAnnotation(.comment(id))
            vm.renamingID = id       // it opens on its editor: an empty comment says nothing
        }
    }
}

@MainActor
private func addItem(_ menu: NSMenu, _ proxies: inout [MenuActionProxy],
                     _ title: String, _ action: @escaping @MainActor () -> Void) {
    let p = MenuActionProxy { Task { @MainActor in action() } }
    proxies.append(p)
    let item = NSMenuItem(title: title, action: #selector(MenuActionProxy.run), keyEquivalent: "")
    item.target = p
    menu.addItem(item)
}
