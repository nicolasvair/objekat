// Transforming a selection of automation points — the arithmetic, asserted with no screen.
//
// `AutomationSelection.swift` depends on nothing but CoreGraphics, which is the whole reason it is
// a unit of its own: the eight grips of the transform box, the gradient a corner lays down and the
// rule saying what a rectangle takes are the half of this feature that has no model behind it, and
// without this file they could only be checked by eye. CLAUDE.md is formal about the rest — the
// command API has no `automation.*` family, so nothing headless can lay a point and read back what
// it is worth.
//
//     swiftc -parse-as-library ../objekat/Timeline/AutomationSelection.swift \
//         test_automation_transform.swift -o /tmp/autotransform && /tmp/autotransform
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

/// Floating-point equality with a tolerance — every figure here comes out of a division.
func near(_ a: Double, _ b: Double, _ eps: Double = 1e-9) -> Bool { abs(a - b) <= eps }

func nears(_ a: [Double], _ b: [Double], _ eps: Double = 1e-9) -> Bool {
    a.count == b.count && zip(a, b).allSatisfy { near($0, $1, eps) }
}

func values(_ s: [AutomationSample]) -> [Double] { s.map(\.n) }
func times(_ s: [AutomationSample]) -> [Double] { s.map(\.t) }

/// The samples of a row, written the way one reads a curve: (time, normalised value).
func samples(_ pairs: [(Double, Double)]) -> [AutomationSample] {
    pairs.map { AutomationSample(t: $0.0, n: $0.1) }
}

/// The span a gesture is read against — the selection's own time envelope.
func span(_ s: [AutomationSample]) -> AutomationTransform.TimeSpan {
    AutomationTransform.timeSpan(of: s)!
}

/// A vertical grip, with no time target: the shape almost every assertion below wants.
func vertical(_ handle: AutomationTransform.Handle, _ span: AutomationTransform.TimeSpan,
              _ k: Double, fine: Bool = false) -> AutomationTransform.Request {
    AutomationTransform.request(handle, span: span, verticalK: k, targetT: 0, fineTune: fine)
}

@main
enum AutomationTransformTest {
  static func main() {

    // MARK: - THE EXAMPLE FROM THE BRIEF, first and named as such
    //
    // A plateau at the top over t ∈ [0, 1]. Pulling the TOP-LEFT corner halfway down must leave
    // the right-hand end where it was and take the left one to half: full at the edge pulled,
    // nothing at all at the opposite one, a straight line between the two.

    let plateau = samples([(0, 1), (0.25, 1), (0.5, 1), (0.75, 1), (1, 1)])
    let flat = span(plateau)

    let byTopLeft = AutomationTransform.apply(vertical(.topLeft, flat, 0.5), to: plateau)
    check("the brief — top-LEFT corner to 0.5: 0.5 at the left, 1 at the right",
          near(byTopLeft[0].n, 0.5) && near(byTopLeft[4].n, 1.0),
          "\(values(byTopLeft))")
    check("the brief — and a STRAIGHT line between the two",
          nears(values(byTopLeft), [0.5, 0.625, 0.75, 0.875, 1.0]),
          "\(values(byTopLeft))")

    let byTopRight = AutomationTransform.apply(vertical(.topRight, flat, 0.5), to: plateau)
    check("the brief — top-RIGHT corner to 0.5: 1 at the left, 0.5 at the right",
          near(byTopRight[0].n, 1.0) && near(byTopRight[4].n, 0.5),
          "the effect is FULL at the edge pulled — \(values(byTopRight))")

    check("a corner moves no point in TIME",
          nears(times(byTopLeft), times(plateau)) && nears(times(byTopRight), times(plateau)))

    // MARK: - The TOP grip: v' = v · k, anchored on normalised 0

    let ramp = samples([(0, 0), (1, 0.4), (2, 1.0)])
    let rampSpan = span(ramp)

    check("top grip, k = 0.5 — every value halved towards the floor",
          nears(values(AutomationTransform.apply(vertical(.top, rampSpan, 0.5), to: ramp)),
                [0, 0.2, 0.5]))

    check("a point at normalised 0 does not move, whatever k",
          [0.0, 0.5, 1, 2, 7].allSatisfy {
              near(AutomationTransform.apply(vertical(.top, rampSpan, $0), to: ramp)[0].n, 0)
          },
          "the anchor is the value, not a pixel")

    check("k = 1 changes nothing at all",
          nears(values(AutomationTransform.apply(vertical(.top, rampSpan, 1), to: ramp)),
                [0, 0.4, 1.0]))

    // NON-DESTRUCTIVENESS — the clause of the brief, and the assertion that protects it: the
    // transform ALWAYS reads the originals, so a factor of 3 (which pins two of these three points
    // against the ceiling) followed by a factor of 1 gives the curve back EXACTLY. Composing on
    // the current state instead would leave it flattened up there for good.
    let pushed = AutomationTransform.apply(vertical(.top, rampSpan, 3), to: ramp)
    check("k = 3 clamps at the ceiling — and says so",
          nears(values(pushed), [0, 1.0, 1.0]))
    check("NON-DESTRUCTIVE: k = 3 then k = 1, from the SAME originals, is the identity",
          nears(values(AutomationTransform.apply(vertical(.top, rampSpan, 1), to: ramp)),
                [0, 0.4, 1.0]),
          "the clamp is an OUTPUT clamp and is never fed back")

    // MARK: - The BOTTOM grip: symmetrical, anchored on normalised 1

    let downRamp = samples([(0, 1), (1, 0.6), (2, 0)])
    let downSpan = span(downRamp)

    check("bottom grip, k = 0.5 — v' = 1 - (1 - v)·k",
          nears(values(AutomationTransform.apply(vertical(.bottom, downSpan, 0.5), to: downRamp)),
                [1.0, 0.8, 0.5]))

    check("a point at normalised 1 does not move, whatever k",
          [0.0, 0.5, 1, 2, 7].allSatisfy {
              near(AutomationTransform.apply(vertical(.bottom, downSpan, $0), to: downRamp)[0].n, 1)
          })

    // MARK: - The four corners, and a degenerate one

    let mid = samples([(0, 0.5), (1, 0.5), (2, 0.5)])
    let midSpan = span(mid)

    check("bottomLeft anchors HIGH and is full on the left",
          nears(values(AutomationTransform.apply(vertical(.bottomLeft, midSpan, 0.5), to: mid)),
                [0.75, 0.625, 0.5]))
    check("bottomRight anchors HIGH and is full on the right",
          nears(values(AutomationTransform.apply(vertical(.bottomRight, midSpan, 0.5), to: mid)),
                [0.5, 0.625, 0.75]))
    check("topLeft and topRight anchor LOW",
          nears(values(AutomationTransform.apply(vertical(.topLeft, midSpan, 0.5), to: mid)),
                [0.25, 0.375, 0.5])
          && nears(values(AutomationTransform.apply(vertical(.topRight, midSpan, 0.5), to: mid)),
                   [0.5, 0.375, 0.25]))

    // A selection with NO time extent: the gradient has nowhere to run, so a corner degenerates
    // into a flat scale. No NaN, no division by zero — the one place the arithmetic could have
    // produced one.
    let stacked = samples([(3, 1), (3, 0.5), (3, 0.25)])
    let stackedOut = AutomationTransform.apply(vertical(.topLeft, span(stacked), 0.5), to: stacked)
    check("a corner on a selection with NO time extent is a FLAT scale",
          nears(values(stackedOut), [0.5, 0.25, 0.125]))
    check("... and produces no NaN",
          stackedOut.allSatisfy { !$0.n.isNaN && !$0.t.isNaN })

    // MARK: - Time

    let inTime = samples([(1, 0.2), (2, 0.5), (3, 0.9)])
    let timeSpan3 = AutomationTransform.timeSpan(of: inTime)!
    check("timeSpan is the envelope, and nothing vertical",
          near(timeSpan3.t0, 1) && near(timeSpan3.t1, 3))

    // The RIGHT grip stretches towards its target, the LEFTMOST point standing still.
    let stretched = AutomationTransform.apply(
        AutomationTransform.request(.right, span: timeSpan3, verticalK: 1,
                                    targetT: 5, fineTune: false),
        to: inTime)
    check("right grip: the leftmost point does not move, the rightmost lands on the target",
          near(stretched[0].t, 1) && near(stretched[2].t, 5))
    check("... and the middle one follows pro rata",
          near(stretched[1].t, 3), "1 + (2-1)·2 = 3 — \(times(stretched))")
    check("a time grip leaves the VALUES alone",
          nears(values(stretched), values(inTime)))

    let stretchedLeft = AutomationTransform.apply(
        AutomationTransform.request(.left, span: timeSpan3, verticalK: 1,
                                    targetT: -1, fineTune: false),
        to: inTime)
    check("left grip: symmetrical, anchored on the RIGHTMOST point",
          near(stretchedLeft[2].t, 3) && near(stretchedLeft[0].t, -1))

    check("timeFactor is nil when the extreme sits ON the anchor",
          AutomationTransform.timeFactor(extreme: 2, target: 5, anchor: 2) == nil,
          "a selection with no extent cannot be stretched — the caller falls back on .shift")

    // The FALLBACK, and the assertion that keeps step 0 honest: a shift is a constant delta and
    // NEGATIVE times come through it untouched. A point behind the object's left edge is matter
    // waiting there, and the day the primitive clamped time to zero this is what it destroyed.
    let oneInstant = samples([(2, 0.3), (2, 0.8)])
    let shifted = AutomationTransform.apply(
        AutomationTransform.request(.left, span: span(oneInstant), verticalK: 1,
                                    targetT: -1.5, fineTune: false),
        to: oneInstant)
    check(".shift is a constant delta",
          nears(times(shifted), [-1.5, -1.5]))
    check(".shift PRESERVES negative times",
          shifted.allSatisfy { $0.t < 0 })

    let behindTheEdge = samples([(-0.5, 0.4), (0.5, 0.8)])
    let keptNegative = AutomationTransform.apply(
        AutomationTransform.request(.right, span: span(behindTheEdge), verticalK: 1,
                                    targetT: 1.5, fineTune: false),
        to: behindTheEdge)
    check("a point BEHIND the left edge is stretched, not clamped to zero",
          near(keptNegative[0].t, -0.5) && near(keptNegative[1].t, 1.5),
          "\(times(keptNegative))")

    // A target BEYOND the anchor would mirror the selection about it. The mirror is another
    // gesture and it exists already (`AutomationLane.mirrored(over:)`).
    let mirroredAttempt = AutomationTransform.apply(
        AutomationTransform.request(.right, span: timeSpan3, verticalK: 1,
                                    targetT: -10, fineTune: false),
        to: inTime)
    check("a time target past the anchor does NOT mirror (k >= 0)",
          mirroredAttempt.allSatisfy { near($0.t, 1) },
          "everything collapses onto the anchor instead — \(times(mirroredAttempt))")

    check("a vertical k below zero is bounded, never mirrored",
          nears(values(AutomationTransform.apply(vertical(.top, rampSpan, -3), to: ramp)),
                [0, 0, 0]))

    // MARK: - ⇧, the fine adjustment

    check("⇧ brings k back towards 1 by a factor of four",
          near(AutomationTransform.fine(3), 1.5) && near(AutomationTransform.fine(0), 0.75))
    check("⇧ leaves k = 1 exactly where it is",
          near(AutomationTransform.fine(1), 1),
          "otherwise ⇧ alone would move the curve")
    check("⇧ reaches the request's own valueK",
          near(vertical(.top, rampSpan, 3, fine: true).valueK, 1.5))

    // MARK: - boxFactor, the guard rail
    //
    // `k` is a ratio of PIXELS between the edge pulled and the edge anchored. It reads no point at
    // all, which is why the "extreme sitting on the anchor" case that used to need a nil has
    // nothing left to be undefined about. In the band's coordinates y grows downwards, so the TOP
    // grip's pulled edge is `minY` and its anchor `maxY`.
    let boxTop = 100.0, boxBottom = 200.0

    check("boxFactor — the pointer on the pulled edge gives exactly 1",
          near(AutomationTransform.boxFactor(pulled: boxTop, opposite: boxBottom,
                                             pointer: boxTop), 1))
    check("boxFactor — the pointer on the ANCHOR edge gives exactly 0",
          near(AutomationTransform.boxFactor(pulled: boxTop, opposite: boxBottom,
                                             pointer: boxBottom), 0))
    check("boxFactor — PAST the pulled edge, k > 1 and UNBOUNDED",
          near(AutomationTransform.boxFactor(pulled: boxTop, opposite: boxBottom,
                                             pointer: boxTop - 300), 4),
          "the assertion that stops anybody putting a clamp back on the pointer's path")
    check("boxFactor — the two grips anchor on OPPOSITE edges",
          near(AutomationTransform.boxFactor(pulled: boxTop, opposite: boxBottom, pointer: 150),
               0.5)
          && near(AutomationTransform.boxFactor(pulled: boxBottom, opposite: boxTop, pointer: 150),
                  0.5)
          && near(AutomationTransform.boxFactor(pulled: boxTop, opposite: boxBottom, pointer: 125),
                  0.75)
          && near(AutomationTransform.boxFactor(pulled: boxBottom, opposite: boxTop, pointer: 125),
                  0.25),
          "the same pointer, two different factors")

    // MARK: - THE SAME PROPORTIONS, DIFFERENT VALUES — the title assertion
    //
    // One Request travels to every row of the selection. It speaks in normalised ratios, so the
    // rows come out with identical NORMALISED values and, once each is converted through its own
    // range, with absolute differences in the ratio of those ranges.

    let volumeRow = samples([(0, 0.853), (1, 0.6), (2, 0.2)])   // -96…+40 dB
    let panRow    = samples([(0, 0.853), (1, 0.6), (2, 0.2)])   // -1…+1
    let together  = AutomationTransform.timeSpan(of: volumeRow + panRow)!
    let halve     = vertical(.top, together, 0.5)

    let volOut = AutomationTransform.apply(halve, to: volumeRow)
    let panOut = AutomationTransform.apply(halve, to: panRow)
    check("ONE request, two rows: the normalised outputs are identical",
          nears(values(volOut), values(panOut), 0),
          "to the bit — no per-row arithmetic at all")

    let dbBefore  = volumeRow.map { AutomationTransform.denormalized($0.n, lo: -96, hi: 40) }
    let dbAfter   = volOut.map    { AutomationTransform.denormalized($0.n, lo: -96, hi: 40) }
    let panBefore = panRow.map    { AutomationTransform.denormalized($0.n, lo: -1, hi: 1) }
    let panAfter  = panOut.map    { AutomationTransform.denormalized($0.n, lo: -1, hi: 1) }

    check("the ABSOLUTE values, however, do not coincide",
          !nears(dbAfter, panAfter),
          "a dB and a pan unit are not the same thing")
    check("their travels are in the ratio of the two ranges (136 against 2)",
          near((dbBefore[0] - dbAfter[0]) / (panBefore[0] - panAfter[0]), 136.0 / 2.0, 1e-9),
          "\(dbBefore[0] - dbAfter[0]) vs \(panBefore[0] - panAfter[0])")
    check("the round trip through the real bounds is exact",
          near(AutomationTransform.normalized(
                 AutomationTransform.denormalized(0.42, lo: -96, hi: 40), lo: -96, hi: 40),
               0.42, 1e-12)
          && near(AutomationTransform.normalized(0, lo: -1, hi: 1), 0.5))

    // MARK: - Degeneracy PER ROW, settled by arithmetic and not by a branch
    //
    // A row lying flat on the bound the grip anchors on cannot move: v' = 0 · k = 0. No test, no
    // guard — and the other rows rise all the same, with the very same k. It is word for word the
    // rule that lets a point at the ceiling stay put without freezing its neighbours, one storey
    // up.

    let onTheFloor = samples([(0, 0), (1, 0), (2, 0)])
    let hasMatter  = samples([(0, 0.2), (1, 0.4), (2, 0.3)])
    let bigK = vertical(.top, span(onTheFloor + hasMatter), 2)

    check("a row flat on the FLOOR is untouched, bit for bit, by the top grip",
          values(AutomationTransform.apply(bigK, to: onTheFloor)) == values(onTheFloor))
    check("... while the row beside it rises with the same k",
          nears(values(AutomationTransform.apply(bigK, to: hasMatter)), [0.4, 0.8, 0.6]))

    let onTheCeiling = samples([(0, 1), (1, 1), (2, 1)])
    let bigKLow = vertical(.bottom, span(onTheCeiling + hasMatter), 2)
    check("symmetrically: a row flat on the CEILING is untouched by the bottom grip",
          values(AutomationTransform.apply(bigKLow, to: onTheCeiling)) == values(onTheCeiling))
    check("... while its neighbour is pulled down",
          nears(values(AutomationTransform.apply(bigKLow, to: hasMatter)),
                [0.0, 1 - 2 * 0.6, 1 - 2 * 0.7].map { max(0, $0) }))

    // MARK: - A corner across two rows
    //
    // The skew carries the GLOBAL envelope, so the gradient is the same function of time in every
    // row — including in a row that has no point at the instant the other one does.

    let rowA = samples([(0, 1), (4, 1)])
    let rowB = samples([(2, 1), (3, 1)])
    let bothSpan = AutomationTransform.timeSpan(of: rowA + rowB)!
    check("the corner's envelope is GLOBAL (0…4), not each row's own",
          near(bothSpan.t0, 0) && near(bothSpan.t1, 4))

    let skewAll = vertical(.topLeft, bothSpan, 0.0)
    let outA = AutomationTransform.apply(skewAll, to: rowA)
    let outB = AutomationTransform.apply(skewAll, to: rowB)
    check("a corner on two rows: the SAME factor at the SAME t",
          near(outB[0].n, 0.5) && near(outB[1].n, 0.75),
          "t=2 is half way along the global envelope, t=3 three quarters — \(values(outB))")
    check("... and row A, which owns the envelope, is full at one end and untouched at the other",
          near(outA[0].n, 0) && near(outA[1].n, 1))

    // MARK: - A time stretch across two rows
    //
    // The pivot is the leftmost point of the WHOLE selection, even when it lives in the other row.

    let lowRow  = samples([(0, 0.5), (1, 0.5)])      // holds the leftmost point
    let highRow = samples([(2, 0.5), (4, 0.5)])
    let crossed = AutomationTransform.timeSpan(of: lowRow + highRow)!
    let pullRight = AutomationTransform.request(.right, span: crossed, verticalK: 1,
                                                targetT: 8, fineTune: false)
    let lowOut  = AutomationTransform.apply(pullRight, to: lowRow)
    let highOut = AutomationTransform.apply(pullRight, to: highRow)
    check("the pivot is the leftmost point of the WHOLE selection, in whichever row it lives",
          near(lowOut[0].t, 0))
    check("... and the other row stretches against it",
          nears(times(highOut), [4, 8]), "\(times(highOut))")
    check("... the pivot's own row stretching too",
          near(lowOut[1].t, 2))

    // MARK: - The non-destructive round trip, multi-row version

    let clipped  = samples([(0, 0.9), (1, 0.5)])     // 0.9 · 3 goes past the ceiling
    let modest   = samples([(0, 0.1), (1, 0.2)])
    let pairSpan = AutomationTransform.timeSpan(of: clipped + modest)!
    _ = AutomationTransform.apply(vertical(.top, pairSpan, 3), to: clipped)
    _ = AutomationTransform.apply(vertical(.top, pairSpan, 3), to: modest)
    check("multi-row: k = 3 then k = 1 from the same originals is the identity, on BOTH rows",
          values(AutomationTransform.apply(vertical(.top, pairSpan, 1), to: clipped))
            == values(clipped)
          && values(AutomationTransform.apply(vertical(.top, pairSpan, 1), to: modest))
            == values(modest),
          "including the row that had been clamped at the ceiling")

    // MARK: - What a rectangle takes
    //
    // The rule diverges DELIBERATELY from `SynopticMarquee.touching`, which refuses a flat
    // rectangle: sweeping ALONG a row is the most natural way to take a stretch of curve, and a
    // three-pixel-tall rectangle is exactly what that hand draws.

    let laid = [CGPoint(x: 10, y: 50), CGPoint(x: 30, y: 50),
                CGPoint(x: 50, y: 50), CGPoint(x: 70, y: 90)]

    check("a FLAT rectangle takes the points it sweeps along",
          AutomationTransform.touching(CGRect(x: 5, y: 50, width: 50, height: 0),
                                       points: laid, inset: 4) == [0, 1, 2],
          "the divergence from SynopticMarquee, and the whole point of it")
    check("a rectangle with NO extent at all takes nothing",
          AutomationTransform.touching(CGRect(x: 10, y: 50, width: 0, height: 0),
                                       points: laid, inset: 4).isEmpty,
          "a click that never travelled")
    check("a rectangle drawn UPWARDS and LEFTWARDS reads the same",
          AutomationTransform.touching(CGRect(x: 55, y: 95, width: -50, height: -50),
                                       points: laid, inset: 4)
            == AutomationTransform.touching(CGRect(x: 5, y: 45, width: 50, height: 50),
                                            points: laid, inset: 4))
    check("the 4 px tolerance reaches BEFORE the rectangle",
          AutomationTransform.touching(CGRect(x: 14, y: 46, width: 10, height: 8),
                                       points: laid, inset: 4) == [0],
          "the point at x = 10 is 4 px short of the left edge")
    check("... and AFTER it",
          AutomationTransform.touching(CGRect(x: 16, y: 46, width: 10, height: 8),
                                       points: laid, inset: 4) == [1],
          "the point at x = 30 is 4 px past the right edge")
    check("one pixel further and the point is out",
          AutomationTransform.touching(CGRect(x: 15, y: 46, width: 10, height: 8),
                                       points: laid, inset: 4).isEmpty,
          "neither 10 nor 30 is within 4 px of 15…25")
    check("a rectangle takes across rows, the y being read like any other",
          AutomationTransform.touching(CGRect(x: 0, y: 40, width: 100, height: 60),
                                       points: laid, inset: 4) == [0, 1, 2, 3])

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
