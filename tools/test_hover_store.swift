// The timeline's hover store (`Timeline/TimelineHoverStore.swift`), asserted with no screen.
//
// What it proves is the contract the perf work rests on: the editing zone, the cut position and the
// tooltip are each read by ONE leaf view, so a pointer moving from zone to zone changes what the
// leaf shows and invalidates nothing else — in particular not `TimelineView.body`, which reads none
// of the three (the one thing it reads, `toolHoveredID`, is a `@State` and not here). A view's
// invalidation is modelled the way SwiftUI does it, with `withObservationTracking` re-armed after
// every change: the number of re-arms IS the number of evaluations.
//
//     swiftc -parse-as-library \
//         ../objekat/Timeline/TimelineHoverStore.swift ../objekat/Timeline/ClipEditZonesOverlay.swift \
//         test_hover_store.swift -o /tmp/hoverstore && /tmp/hoverstore
//
// Exit: 0 if every assertion passes, 1 otherwise.

import Foundation
import Observation
import CoreGraphics

var fails: [String] = []
var total = 0

func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    total += 1
    if ok { print("ok    " + label) }
    else { fails.append(label); print("FAIL  \(label)  \(detail)") }
}

/// A stand-in for one SwiftUI view: `read` is its body (the properties it reads are the ones it
/// depends on), `passes` counts its evaluations. Like SwiftUI, it re-evaluates after a change.
final class FakeView {
    private(set) var passes = 0
    private let read: () -> Void
    private var dirty = false
    init(_ read: @escaping () -> Void) { self.read = read; evaluate() }

    private func evaluate() {
        passes += 1
        withObservationTracking(read) { [weak self] in self?.dirty = true }
    }
    /// The next frame: a view that was invalidated re-evaluates (and re-arms its tracking).
    func frame() { if dirty { dirty = false; evaluate() } }
}

func hover(_ id: UUID, _ zone: ClipEditZone, x: Double = 0) -> EditZoneHover {
    EditZoneHover(id: id, rect: CGRect(x: x, y: 0, width: 200, height: 40), handleW: 20, zone: zone,
                  cornerRadius: 4, fadeInW: 0, fadeOutW: 0, loopMarkerX: 0)
}

@main
struct HoverStoreTest {
    static func main() {
        let a = UUID(), b = UUID()

        // MARK: a body that reads NONE of the store is untouched by any pointer movement
        do {
            let store = TimelineHoverStore()
            let body = FakeView { }
            let zones: [ClipEditZone] = [.fadeIn, .timeSelect, .fadeOut, .trimLeft, .move, .resizeRight]
            for (i, z) in zones.enumerated() {
                store.setEditZoneHover(hover(a, z))
                store.setCutHover(.init(id: a, localX: Double(i) * 3))
                store.setHelpText("zone \(i)")
                body.frame()
            }
            check("body (reads nothing of the store): 18 changes, 1 evaluation", body.passes == 1)
        }

        // MARK: control — a view that reads the zone and the tooltip DOES re-evaluate (the old model)
        do {
            let store = TimelineHoverStore()
            let body = FakeView { _ = store.editZoneHover; _ = store.toolZoneHelpText }
            store.setEditZoneHover(hover(a, .move)); body.frame()
            store.setHelpText("x"); body.frame()
            check("control: a view that reads the zone and the tooltip re-evaluates on them",
                  body.passes == 3, "passes = \(body.passes)")
        }

        // MARK: each leaf depends on its own property
        do {
            let store = TimelineHoverStore()
            let veil = FakeView { _ = store.editZoneHover }
            let cut  = FakeView { _ = store.cutHover }
            let help = FakeView { _ = store.toolZoneHelpText }

            store.setEditZoneHover(hover(a, .move))
            veil.frame(); cut.frame(); help.frame()
            check("leaf: the veil re-evaluates on its zone", veil.passes == 2)
            check("leaf: the cut line / tooltip stay still", cut.passes == 1 && help.passes == 1)

            store.setEditZoneHover(hover(a, .move))                 // same value
            veil.frame()
            check("leaf: the same zone again notifies nobody", veil.passes == 2)

            store.setEditZoneHover(hover(a, .move, x: 1))           // same zone, the block moved
            veil.frame()
            check("leaf: the same zone on a block that moved does re-evaluate", veil.passes == 3)

            store.setCutHover(.init(id: a, localX: 5)); cut.frame()
            store.setHelpText("x"); help.frame()
            veil.frame()
            check("leaf: cut line and tooltip re-evaluate on their own change",
                  cut.passes == 2 && help.passes == 2 && veil.passes == 3)
        }

        // MARK: clears
        do {
            let store = TimelineHoverStore()
            store.setHelpText("h")
            store.setEditZoneHover(hover(a, .move)); store.setCutHover(.init(id: a, localX: 1))
            store.clearZoneAndCut()
            check("clearZoneAndCut drops the veil and the cut line",
                  store.editZoneHover == nil && store.cutHover == nil)
            check("clearZoneAndCut leaves the tooltip", store.toolZoneHelpText == "h")
            store.setEditZoneHover(hover(b, .move))
            store.clearAll()
            check("clearAll drops everything",
                  store.toolZoneHelpText == nil && store.editZoneHover == nil && store.cutHover == nil)

            let leaf = FakeView { _ = store.editZoneHover; _ = store.cutHover; _ = store.toolZoneHelpText }
            store.clearAll(); leaf.frame()
            check("clearAll on an empty store notifies nobody", leaf.passes == 1)
        }

        print("\n\(total - fails.count)/\(total) assertions passed")
        exit(fails.isEmpty ? 0 : 1)
    }
}
