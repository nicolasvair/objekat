// Which gesture a press in the marker band starts — asserted with no screen.
//
// Point C of the 2026-10-02 Canvas feedback: the band reads like the RULER wherever it is empty
// (a drag traces a time selection, a plain click lays the cursor), and nothing changes on a mark
// or on the pinned controls laid over it.
//
//     swiftc -parse-as-library objekat/Shared/MarkerBandGesture.swift \
//            tools/test_marker_band_gesture.swift -o /tmp/mbg && /tmp/mbg

import Foundation

var fails = 0
func check(_ label: String, _ ok: Bool) {
    if ok { print("ok    " + label) } else { fails += 1; print("FAIL  " + label) }
}

@main
enum MarkerBandGestureTest {
  static func main() {
    typealias G = MarkerBandGesture

    // ── the route of a drag ──
    check("empty stretch -> ruler", G.route(zoneHit: false, inHeader: false, inFlight: nil) == .ruler)
    check("on a mark -> mark", G.route(zoneHit: true, inHeader: false, inFlight: nil) == .mark)
    check("on a pinned control -> nothing", G.route(zoneHit: false, inHeader: true, inFlight: nil) == .none)
    check("a mark under the pinned names stays a mark (what it did before)",
          G.route(zoneHit: true, inHeader: true, inFlight: nil) == .mark)
    // a drag under way is never re-decided, whatever lies under the hand now
    for zone in [false, true] {
        for header in [false, true] {
            check("mark drag in flight stays a mark (zone \(zone), header \(header))",
                  G.route(zoneHit: zone, inHeader: header, inFlight: .mark) == .mark)
            check("ruler drag in flight stays the ruler's (zone \(zone), header \(header))",
                  G.route(zoneHit: zone, inHeader: header, inFlight: .ruler) == .ruler)
        }
    }

    // ── the pinned controls' geometry (viewport coordinates) ──
    let vw = 1200.0
    check("the row's colour dot (x = 8) is a pinned control", G.inPinnedControls(xInViewport: 8, viewportWidth: vw))
    check("the widest name (x = 130) is a pinned control", G.inPinnedControls(xInViewport: 130, viewportWidth: vw))
    check("the pill's far edge (x = 137) still is", G.inPinnedControls(xInViewport: 137, viewportWidth: vw))
    check("just past the names (x = 140) is empty band", !G.inPinnedControls(xInViewport: 140, viewportWidth: vw))
    check("the middle of the band is empty", !G.inPinnedControls(xInViewport: 600, viewportWidth: vw))
    check("the row button at the far right is a pinned control",
          G.inPinnedControls(xInViewport: vw - 10, viewportWidth: vw))
    check("just left of the row button is empty band",
          !G.inPinnedControls(xInViewport: vw - 40, viewportWidth: vw))
    check("an unmeasured viewport (0) never invents a right-hand control",
          !G.inPinnedControls(xInViewport: 600, viewportWidth: 0))
    // scrolled content: the headers do not scroll, so the same viewport x answers the same
    check("header extent does not depend on the scroll (content x = 5000 + 8 at scroll 5000)",
          G.inPinnedControls(xInViewport: (5000 + 8) - 5000, viewportWidth: vw))

    // ── the click ──
    check("click on empty band lays the cursor",
          G.clickMovesCursor(hitMark: false, inHeader: false, shift: false, command: false))
    check("click on a mark does not (it selects, and goes to its own start)",
          !G.clickMovesCursor(hitMark: true, inHeader: false, shift: false, command: false))
    check("click on a pinned control does not",
          !G.clickMovesCursor(hitMark: false, inHeader: true, shift: false, command: false))
    check("⇧ click on empty band keeps the old behaviour",
          !G.clickMovesCursor(hitMark: false, inHeader: false, shift: true, command: false))
    check("⌘ click on empty band keeps the old behaviour",
          !G.clickMovesCursor(hitMark: false, inHeader: false, shift: false, command: true))

    print(fails == 0 ? "ALL PASS" : "\(fails) FAILED")
    exit(fails == 0 ? 0 : 1)
  }
}
