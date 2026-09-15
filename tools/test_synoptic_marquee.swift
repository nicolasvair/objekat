// Choosing cards in the signal view — the geometry, asserted with no screen.
//
// `SynopticMarquee` depends on nothing but CoreGraphics, which is the whole reason it is a unit of
// its own: the rectangle one drags and the box ⇧ deduces are the half of this feature that has no
// model behind it, and without this file they could only be checked by eye.
//
//     swiftc -parse-as-library \
//         ../objekat/Inspector/Synoptic/SynopticMarquee.swift test_synoptic_marquee.swift \
//         -o /tmp/marquee && /tmp/marquee
//
// Exit: 0 if every assertion passes, 1 otherwise.

import CoreGraphics
import Foundation

var fails: [String] = []
var total = 0

func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    total += 1
    if ok { print("ok    " + label) }
    else { fails.append(label); print("FAIL  \(label)  \(detail)") }
}

/// A card's id, made readable: the test speaks of "a", "b"… and prints those names back.
let names = ["a", "b", "c", "d", "e"]
let ids = names.map { _ in UUID() }
func name(_ id: UUID) -> String { ids.firstIndex(of: id).map { names[$0] } ?? "?" }
func names(_ list: [UUID]) -> [String] { list.map(name).sorted() }

// A chain shaped like the real thing: a trunk (a, then a parallel of two branches b | c, then d),
// with the cards 124 × 30 as the layout lays them.
//
//        a          x 100…224   y  0…30
//     b     c       x  20…144 / 200…324   y 60…90
//        d          x 100…224   y 120…150
//        e          x 100…224   y 180…210   (far below, to check what a box does NOT take)
let cards = [
    SynopticMarquee.Card(id: ids[0], frame: CGRect(x: 100, y: 0, width: 124, height: 30)),
    SynopticMarquee.Card(id: ids[1], frame: CGRect(x: 20, y: 60, width: 124, height: 30)),
    SynopticMarquee.Card(id: ids[2], frame: CGRect(x: 200, y: 60, width: 124, height: 30)),
    SynopticMarquee.Card(id: ids[3], frame: CGRect(x: 100, y: 120, width: 124, height: 30)),
    SynopticMarquee.Card(id: ids[4], frame: CGRect(x: 100, y: 180, width: 124, height: 30)),
]

@main
enum MarqueeTest {
  static func main() {
    // MARK: - The marquee: ENTIRELY inside, never merely brushed

    check("a rectangle round nothing takes nothing",
          SynopticMarquee.fullyInside(CGRect(x: 0, y: 220, width: 400, height: 40), cards: cards).isEmpty)

    check("a rectangle round one card takes it",
          names(SynopticMarquee.fullyInside(CGRect(x: 90, y: -10, width: 150, height: 50), cards: cards)) == ["a"])

    check("a card merely brushed is NOT taken",
          SynopticMarquee.fullyInside(CGRect(x: 90, y: -10, width: 150, height: 20), cards: cards).isEmpty,
          "the rectangle stops at y=10, a runs to y=30")

    check("one branch taken, its neighbour left alone",
          names(SynopticMarquee.fullyInside(CGRect(x: 10, y: 50, width: 150, height: 50), cards: cards)) == ["b"],
          "this is the whole reason for containment rather than intersection")

    check("a wide rectangle takes both branches",
          names(SynopticMarquee.fullyInside(CGRect(x: 0, y: 50, width: 400, height: 50), cards: cards)) == ["b", "c"])

    check("a rectangle over the whole canvas takes everything",
          names(SynopticMarquee.fullyInside(CGRect(x: -10, y: -10, width: 500, height: 300), cards: cards))
            == ["a", "b", "c", "d", "e"])

    // Drawn the other way: upwards and leftwards, the same rectangle.
    let downRight = SynopticMarquee.fullyInside(CGRect(x: 0, y: 50, width: 400, height: 50), cards: cards)
    let upLeft    = SynopticMarquee.fullyInside(CGRect(x: 400, y: 100, width: -400, height: -50), cards: cards)
    check("drawn upwards and leftwards reads the same", names(downRight) == names(upLeft))

    check("a rectangle with no width takes nothing",
          SynopticMarquee.fullyInside(CGRect(x: 100, y: 0, width: 0, height: 300), cards: cards).isEmpty)
    check("a rectangle with no height takes nothing",
          SynopticMarquee.fullyInside(CGRect(x: 0, y: 15, width: 400, height: 0), cards: cards).isEmpty)

    check("a card exactly the rectangle's size is taken",
          names(SynopticMarquee.fullyInside(CGRect(x: 100, y: 0, width: 124, height: 30), cards: cards)) == ["a"],
          "the edges touching is containment, not a brush")

    // MARK: - ⇧: the bounding box, and what it sweeps up on the way

    check("⇧ on an empty selection takes the target alone",
          names(SynopticMarquee.boundingBox(of: [], extendedTo: ids[0], cards: cards)) == ["a"])

    check("⇧ on an unknown card takes nothing",
          SynopticMarquee.boundingBox(of: [ids[0]], extendedTo: UUID(), cards: cards).isEmpty)

    check("⇧ from a to d takes what is between, branches included",
          names(SynopticMarquee.boundingBox(of: [ids[0]], extendedTo: ids[3], cards: cards))
            == ["a", "b", "c", "d"],
          "the box a→d spans x 20…324, so it crosses both branches — and that IS the rule")

    check("⇧ from a to d does not reach e",
          !SynopticMarquee.boundingBox(of: [ids[0]], extendedTo: ids[3], cards: cards).contains(ids[4]))

    check("⇧ from b to c takes the two branches and nothing above",
          names(SynopticMarquee.boundingBox(of: [ids[1]], extendedTo: ids[2], cards: cards)) == ["b", "c"],
          "the box spans y 60…90 only")

    check("⇧ onto a card already held changes nothing",
          names(SynopticMarquee.boundingBox(of: [ids[1], ids[2]], extendedTo: ids[1], cards: cards))
            == ["b", "c"])

    check("⇧ grows from the WHOLE selection, not from the last card",
          names(SynopticMarquee.boundingBox(of: [ids[0], ids[4]], extendedTo: ids[1], cards: cards))
            == ["a", "b", "c", "d", "e"],
          "a and e already span the canvas top to bottom")

    check("⇧ takes a card it merely touches",
          SynopticMarquee.boundingBox(of: [ids[1]], extendedTo: ids[2], cards: cards).count == 2,
          "intersection here, unlike the marquee: the box's edges fall ON the cards")

    // MARK: -

    print("")
    if fails.isEmpty {
        print("\(total) assertions, all pass")
        exit(0)
    } else {
        print("\(fails.count) FAILED: \(fails.joined(separator: " · "))")
        exit(1)
    }

  }
}
