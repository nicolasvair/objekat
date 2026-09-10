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
        addItem(menu, &proxies, L("menu.context.marker.rename")) {
            vm.selectAnnotation(hit)
            vm.renamingID = hit.markerID
        }
        addItem(menu, &proxies, L("menu.context.marker.delete")) {
            vm.selectAnnotation(hit)
            vm.deleteSelectedAnnotation()
        }
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

    menu.addItem(.separator())
    addItem(menu, &proxies, L("markers.lane.new")) {
        let id = vm.addMarkerLane()
        vm.renamingID = id
    }
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
    let lane = selection.lanes.min() ?? 0
    addItem(menu, &proxies, L("menu.context.comment.create")) {
        if let id = vm.addComment(from: lo, to: hi, lane: lane) {
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
