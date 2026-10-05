// "What a hand on a crossfade means" — the decisions behind the gesture, asserted with no screen.
// `CrossfadeGrab` (`Shared/CrossfadeGrab.swift`) has no view and no model behind it, which is why
// it can be compiled and run alone, like `CutSelection` / `SendColumns` before it.
//
//     swiftc -parse-as-library \
//         ../objekat/Shared/CrossfadeGrab.swift test_crossfade_grab.swift \
//         -o /tmp/xfgrab && /tmp/xfgrab
//
// Three questions: a fade handle that sticks out of its zone (which pair, which side), which other
// crossfades follow when several objects are selected, and where each zone goes for one travel.
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

func near(_ a: Double, _ b: Double, _ tol: Double = 1e-9) -> Bool { abs(a - b) <= tol }

@main
enum CrossfadeGrabTest {
  static func main() {
    let a = UUID(), b = UUID(), c = UUID(), d = UUID(), z = UUID()
    typealias P = CrossfadeGrab.Pair

    // MARK: - A fade handle outside the zone → the crossfade's side

    // B has a crossfade with A on its left. Its fade-IN handle overhangs the zone on the RIGHT
    // (past the zone's end, inside B): the edge NEAREST the hand is the zone's END (rule A).
    do {
        let r = CrossfadeGrab.pair(forFade: .fadeIn, of: b, partnerLeft: a, partnerRight: nil)
        check("fade-in with a partner on the left -> that pair", r?.pair == P(left: a, right: b))
        check("fade-in overhang (right of the zone) -> the zone's END, the nearest edge",
              r?.part == .sideEnd)
    }
    // A has a crossfade with B on its right. Its fade-OUT handle overhangs on the LEFT: the START.
    do {
        let r = CrossfadeGrab.pair(forFade: .fadeOut, of: a, partnerLeft: nil, partnerRight: b)
        check("fade-out with a partner on the right -> that pair", r?.pair == P(left: a, right: b))
        check("fade-out overhang (left of the zone) -> the zone's START, the nearest edge",
              r?.part == .sideStart)
    }
    // The fade-OUT of B, which only has a partner on its LEFT, is not a crossfade's: plain fade.
    check("fade-out with a partner on the LEFT only -> nothing (plain fade)",
          CrossfadeGrab.pair(forFade: .fadeOut, of: b, partnerLeft: a, partnerRight: nil) == nil)
    check("fade-in with a partner on the RIGHT only -> nothing (plain fade)",
          CrossfadeGrab.pair(forFade: .fadeIn, of: a, partnerLeft: nil, partnerRight: b) == nil)
    check("no partner at all -> nothing",
          CrossfadeGrab.pair(forFade: .fadeIn, of: z, partnerLeft: nil, partnerRight: nil) == nil
          && CrossfadeGrab.pair(forFade: .fadeOut, of: z, partnerLeft: nil, partnerRight: nil) == nil)
    // A middle object A–B–C: B's two handles go to the two different zones.
    do {
        let fi = CrossfadeGrab.pair(forFade: .fadeIn, of: b, partnerLeft: a, partnerRight: c)
        let fo = CrossfadeGrab.pair(forFade: .fadeOut, of: b, partnerLeft: a, partnerRight: c)
        check("middle object: fade-in -> the zone on its left", fi?.pair == P(left: a, right: b))
        check("middle object: fade-out -> the zone on its right", fo?.pair == P(left: b, right: c))
    }

    // MARK: - Which other crossfades follow

    // Partners of the chain A–B–C–D (three zones: AB, BC, CD).
    let chain: [UUID: (left: UUID?, right: UUID?)] = [
        a: (nil, b), b: (a, c), c: (b, d), d: (c, nil),
    ]
    func partners(_ id: UUID) -> (left: UUID?, right: UUID?) { chain[id] ?? (nil, nil) }
    let ab = P(left: a, right: b), bc = P(left: b, right: c), cd = P(left: c, right: d)

    // A zone in the selection, a side: every selected object with a crossfade on THAT side follows.
    check("start side, A+B+C+D selected, grab AB: BC and CD follow, not AB itself",
          CrossfadeGrab.followers(part: .sideStart, grabbed: ab, selected: [a, b, c, d],
                                  partners: partners) == [bc, cd])
    check("end side, A+B+C+D selected, grab CD: AB and BC follow",
          CrossfadeGrab.followers(part: .sideEnd, grabbed: cd, selected: [a, b, c, d],
                                  partners: partners) == [ab, bc])
    // Only B and C selected, grab BC at its start (B+C are both in): C's left partner is B -> BC
    // itself (the grabbed one); B's left partner is A -> AB follows.
    check("start side, B+C selected, grab BC: AB follows (B's left), BC is the grabbed one",
          CrossfadeGrab.followers(part: .sideStart, grabbed: bc, selected: [b, c],
                                  partners: partners) == [ab])
    check("end side, B+C selected, grab BC: CD follows (C's right)",
          CrossfadeGrab.followers(part: .sideEnd, grabbed: bc, selected: [b, c],
                                  partners: partners) == [cd])
    // A side is ONE edge: an object selected only for its OTHER side brings nothing.
    // A alone selected (right partner B): a start-side gesture on AB has A in the selection but no
    // object with a LEFT partner other than B itself... B is not selected.
    check("start side, only A selected, grab AB: nothing follows (A has no left partner)",
          CrossfadeGrab.followers(part: .sideStart, grabbed: ab, selected: [a],
                                  partners: partners).isEmpty)
    // The edge a side holds belongs to ONE object: grabbing AB's START (B's left edge) with only A
    // selected is grabbing something that is not selected, even though A is one of the pair.
    check("start side, A+C selected, grab AB (B not selected): alone, as a fade on an unselected object",
          CrossfadeGrab.followers(part: .sideStart, grabbed: ab, selected: [a, c],
                                  partners: partners).isEmpty)
    check("end side, B+C selected, grab AB (A not selected): alone",
          CrossfadeGrab.followers(part: .sideEnd, grabbed: ab, selected: [b, c],
                                  partners: partners).isEmpty)
    check("end side, A+C selected, grab AB: CD follows through C's right partner",
          CrossfadeGrab.followers(part: .sideEnd, grabbed: ab, selected: [a, c],
                                  partners: partners) == [cd])

    // The whole zone has no side: every crossfade touching a selected object follows.
    check("zone (both), B selected, grab AB: BC follows (B's right side)",
          CrossfadeGrab.followers(part: .both, grabbed: ab, selected: [b], partners: partners) == [bc])
    check("zone (move), A+D selected, grab AB: CD follows through D's left partner",
          CrossfadeGrab.followers(part: .move, grabbed: ab, selected: [a, d], partners: partners) == [cd])
    check("zone (both), B+C selected, grab BC: AB and CD follow",
          CrossfadeGrab.followers(part: .both, grabbed: bc, selected: [b, c], partners: partners) == [ab, cd])
    // Each zone is named ONCE even when both its objects are selected: B+C selected, grab AB. BC is
    // reached through B (its right) AND through C (its left).
    do {
        let f = CrossfadeGrab.followers(part: .both, grabbed: ab, selected: [b, c], partners: partners)
        check("a zone with both objects selected is named once", f == [bc, cd] && f.count == 2, "\(f)")
    }

    // Grabbing something outside the selection drives only itself.
    check("grabbed zone with neither object selected -> alone (a side)",
          CrossfadeGrab.followers(part: .sideStart, grabbed: cd, selected: [a, b], partners: partners).isEmpty)
    check("grabbed zone with neither object selected -> alone (the whole zone)",
          CrossfadeGrab.followers(part: .both, grabbed: cd, selected: [a, b], partners: partners).isEmpty)
    check("empty selection -> alone",
          CrossfadeGrab.followers(part: .both, grabbed: ab, selected: [], partners: partners).isEmpty)
    // An object with no crossfade at all brings nothing, and does not hurt.
    check("a selected object with no crossfade is harmless",
          CrossfadeGrab.followers(part: .both, grabbed: ab, selected: [a, z], partners: partners).isEmpty)

    // Taken through a fade handle OVERHANGING the zone: the held fade owns the grab and names the
    // side that follows, while the part (the nearest edge) is the opposite of the plain reading.
    // B's fade-in held (zone AB, part .sideEnd): B owns it; every selected object's LEFT crossfade
    // follows — the fade gesture's "same end of its fade".
    check("held fade-in of B (AB, part end), B+D selected: CD follows (D's left), not BC",
          CrossfadeGrab.followers(part: .sideEnd, grabbed: ab, selected: [b, d], heldFade: .fadeIn,
                                  partners: partners) == [cd])
    check("held fade-in of B (AB, part end), A+D selected (B not): alone",
          CrossfadeGrab.followers(part: .sideEnd, grabbed: ab, selected: [a, d], heldFade: .fadeIn,
                                  partners: partners).isEmpty)
    // A's fade-out held (zone AB, part .sideStart): A owns it; every selected RIGHT crossfade follows.
    check("held fade-out of A (AB, part start), A+C selected: CD follows (C's right), not BC",
          CrossfadeGrab.followers(part: .sideStart, grabbed: ab, selected: [a, c], heldFade: .fadeOut,
                                  partners: partners) == [cd])
    check("held fade-out of A (AB, part start), B+C selected (A not): alone",
          CrossfadeGrab.followers(part: .sideStart, grabbed: ab, selected: [b, c], heldFade: .fadeOut,
                                  partners: partners).isEmpty)
    // No held fade: unchanged reading (the zone's own upper half).
    check("no held fade: the part decides, as before",
          CrossfadeGrab.followers(part: .sideEnd, grabbed: ab, selected: [a, c], heldFade: nil,
                                  partners: partners) == [cd])

    // MARK: - Where a zone goes for one travel

    // The zone from 4.0 to 5.0 (width 1.0), centre 4.5.
    let s0 = 4.0, e0 = 5.0
    do {
        let t = CrossfadeGrab.target(part: .move, anchorStart: s0, anchorEnd: e0, shift: 0.25)
        check("move: width kept", near(t.rawWidth, 1.0), "\(t.rawWidth)")
        check("move: start travels by the shift", near(t.idealStart, 4.25), "\(t.idealStart)")
    }
    do {
        let t = CrossfadeGrab.target(part: .both, anchorStart: s0, anchorEnd: e0, shift: 0.25)
        check("both: the width changes by TWICE the shift", near(t.rawWidth, 1.5), "\(t.rawWidth)")
        check("both: still centred on 4.5", near(t.idealStart + t.rawWidth / 2, 4.5), "\(t.idealStart)")
        let n = CrossfadeGrab.target(part: .both, anchorStart: s0, anchorEnd: e0, shift: -0.75)
        check("both: past zero the width goes NEGATIVE (the spill), the start sits on the centre",
              near(n.rawWidth, -0.5) && near(n.idealStart, 4.5), "\(n)")
    }
    do {
        let t = CrossfadeGrab.target(part: .sideStart, anchorStart: s0, anchorEnd: e0, shift: 0.25)
        check("start side: the width loses the shift", near(t.rawWidth, 0.75), "\(t.rawWidth)")
        check("start side: the end stays at 5.0", near(t.idealStart + t.rawWidth, 5.0), "\(t.idealStart)")
        let o = CrossfadeGrab.target(part: .sideStart, anchorStart: s0, anchorEnd: e0, shift: 1.5)
        check("start side pushed past the end: negative width, start pinned on the end",
              near(o.rawWidth, -0.5) && near(o.idealStart, 5.0), "\(o)")
    }
    do {
        let t = CrossfadeGrab.target(part: .sideEnd, anchorStart: s0, anchorEnd: e0, shift: 0.25)
        check("end side: the width gains the shift", near(t.rawWidth, 1.25), "\(t.rawWidth)")
        check("end side: the start stays at 4.0", near(t.idealStart, 4.0), "\(t.idealStart)")
        let o = CrossfadeGrab.target(part: .sideEnd, anchorStart: s0, anchorEnd: e0, shift: -1.5)
        check("end side pulled past the start: negative width", near(o.rawWidth, -0.5), "\(o)")
    }
    // The SAME shift on a zone of another width: the delta is shared, not the width.
    do {
        let narrow = CrossfadeGrab.target(part: .sideEnd, anchorStart: 10, anchorEnd: 10.4, shift: 0.3)
        let wide   = CrossfadeGrab.target(part: .sideEnd, anchorStart: 20, anchorEnd: 22.0, shift: 0.3)
        check("same shift, two zones: each keeps its own width plus the same delta",
              near(narrow.rawWidth, 0.7) && near(wide.rawWidth, 2.3), "\(narrow) \(wide)")
        let nm = CrossfadeGrab.target(part: .move, anchorStart: 10, anchorEnd: 10.4, shift: 0.3)
        let wm = CrossfadeGrab.target(part: .move, anchorStart: 20, anchorEnd: 22.0, shift: 0.3)
        check("same shift on a move: both slide by the same travel",
              near(nm.idealStart - 10, 0.3) && near(wm.idealStart - 20, 0.3), "\(nm) \(wm)")
    }

    print("\n\(total - fails.count)/\(total) assertions passed")
    if !fails.isEmpty {
        print("FAILED: " + fails.joined(separator: " | "))
        exit(1)
    }
  }
}
