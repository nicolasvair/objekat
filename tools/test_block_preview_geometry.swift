// BlockPreviewGeometry — the gesture-time geometry shared by the rich views and the batched Canvas,
// asserted against VERBATIM copies of the formulas it replaced (SoundBlockView / GroupBlockView as
// they were before E7 step 1), on random inputs: any drift between the old calculation and the
// extracted one shows here with no screen.
//
//     swiftc -parse-as-library \
//         ../objekat/SoundObject/FadeCurve.swift ../objekat/Shared/WaveformShaping.swift \
//         ../objekat/Timeline/BlockPreviewGeometry.swift \
//         test_block_preview_geometry.swift -o /tmp/bpg && /tmp/bpg
//
// Exit: 0 if every assertion passes, 1 otherwise.

import Foundation

var fails: [String] = []
var total = 0

func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    total += 1
    if ok { return }
    fails.append(label)
    if fails.count <= 25 { print("FAIL  \(label)  \(detail)") }
}

struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

// MARK: - The OLD calculation, verbatim (parameters instead of the views' stored properties)

struct Old {
    // model
    var startTime, duration, sourceOffset, speedRatio: Double
    var isReversed: Bool
    var fadeIn, fadeOut: Double
    var fadeInCurve, fadeOutCurve: FadeCurve
    // view inputs
    var pixelsPerSecond: Double
    var previewOffset: (dx: Double, dy: Double)?
    var previewResizeDX, previewTrimDX: Double
    var previewFadeIn, previewFadeOut: Double?
    var previewFadeInCurve, previewFadeOutCurve: FadeCurve?
    var previewLoopRange: (start: Double, end: Double)?
    var rulerHeight, laneStep: Double
    var displayLane: Int

    // ---- SoundBlockView
    var effectiveDuration: Double {
        max(0.01, duration + (previewResizeDX - previewTrimDX) / pixelsPerSecond)
    }
    var clipFades: (fi: Double, fo: Double) {
        var fi = previewFadeIn ?? fadeIn
        var fo = previewFadeOut ?? fadeOut
        let D = effectiveDuration
        if previewTrimDX != 0 {
            if D < fo { fo = D; fi = 0 }
            else if D < fi + fo { fi = D - fo }
        } else if previewResizeDX != 0 {
            if D < fi { fi = D; fo = 0 }
            else if D < fi + fo { fo = D - fi }
        } else {
            if fi + fo > D {
                if previewFadeIn != nil { fo = max(0, D - fi) }
                else if previewFadeOut != nil { fi = max(0, D - fo) }
                else { fi = min(fi, D * 0.5); fo = min(fo, D * 0.5) }
            }
        }
        return (fi, fo)
    }
    var effectiveFadeInCurve: FadeCurve { previewFadeInCurve ?? fadeInCurve }
    var effectiveFadeOutCurve: FadeCurve { previewFadeOutCurve ?? fadeOutCurve }
    var loopMarkerPx: (start: Double, end: Double)? {
        guard let r = previewLoopRange else { return nil }
        return (r.start * pixelsPerSecond, r.end * pixelsPerSecond)
    }
    var clipBlockWidth: Double {
        let natural = (duration * pixelsPerSecond) + previewResizeDX - previewTrimDX
        if previewResizeDX != 0 { return max(natural, 1) }
        return max(natural, 2)
    }
    var clipXPos: Double {
        let natural = (duration * pixelsPerSecond) + previewResizeDX - previewTrimDX
        let offset = previewOffset?.dx ?? 0
        if natural < 2 && previewTrimDX != 0 {
            return (startTime * pixelsPerSecond) + (duration * pixelsPerSecond) - 2 + offset
        }
        return (startTime * pixelsPerSecond) + previewTrimDX + offset
    }
    var effectiveSourceOffset: Double {
        let moving = isReversed ? previewResizeDX : previewTrimDX
        guard moving != 0, pixelsPerSecond > 0 else { return sourceOffset }
        let dStart = previewTrimDX / pixelsPerSecond
        let dEnd = previewResizeDX / pixelsPerSecond
        return WaveformShaping.retrimmedSourceOffset(
            sourceOffset,
            oldStart: startTime, oldDuration: duration,
            newStart: startTime + dStart,
            newDuration: duration - dStart + dEnd,
            speedRatio: speedRatio, isReversed: isReversed)
    }
    var yPos: Double { rulerHeight + Double(displayLane) * laneStep + (previewOffset?.dy ?? 0) }

    // ---- GroupBlockView
    var groupBlockWidth: Double {
        let natural = duration * pixelsPerSecond + previewResizeDX - previewTrimDX
        return max(natural, 2)
    }
    var groupXPos: Double { (startTime * pixelsPerSecond) + previewTrimDX + (previewOffset?.dx ?? 0) }
    var effectiveStartTime: Double {
        guard previewTrimDX != 0, pixelsPerSecond > 0 else { return startTime }
        return startTime + previewTrimDX / pixelsPerSecond
    }
    var groupFadeIn: Double { previewFadeIn ?? fadeIn }
    var groupFadeOut: Double { previewFadeOut ?? fadeOut }
    var groupEffDur: Double { max(0.01, duration + (previewResizeDX - previewTrimDX) / pixelsPerSecond) }
}

// MARK: - Random inputs

func eq(_ a: Double, _ b: Double) -> Bool { a == b || (a.isNaN && b.isNaN) }
func eqCurve(_ a: FadeCurve, _ b: FadeCurve) -> Bool { a == b }

func randomCurve(_ g: inout SplitMix) -> FadeCurve {
    FadeCurve(shape: FadeShape.allCases.randomElement(using: &g)!, amount: Double.random(in: 0...1, using: &g))
}

@main
enum BlockPreviewGeometryTest {
  static func main() {
    var g = SplitMix(state: 20261001)
    let n = 200_000
    var neutralCount = 0
    for i in 0..<n {
        let pps = [0.5, 5, 20, 100, 400, 3000].randomElement(using: &g)!
        let dur = Double.random(in: 0.001...30, using: &g)
        let mode = Int.random(in: 0..<8, using: &g)
        // gesture: 0 none, 1 move, 2 trim, 3 resize, 4 fade, 5 trim+offset, 6 resize+fade, 7 everything
        func px(_ r: ClosedRange<Double>) -> Double { Double.random(in: r, using: &g).rounded() }
        var offset: (dx: Double, dy: Double)? = nil
        var resize = 0.0, trim = 0.0
        var pfi: Double? = nil, pfo: Double? = nil
        var pci: FadeCurve? = nil, pco: FadeCurve? = nil
        if [1, 5, 7].contains(mode) { offset = (Double.random(in: -800...800, using: &g), Double.random(in: -300...300, using: &g)) }
        if [2, 5, 7].contains(mode) { trim = px(-600...(dur * pps + 200)) }
        if [3, 6, 7].contains(mode) { resize = px(-(dur * pps + 200)...600) }
        if [4, 6, 7].contains(mode) {
            if Bool.random(using: &g) { pfi = Double.random(in: 0...dur * 1.3, using: &g) }
            if Bool.random(using: &g) || pfi == nil { pfo = Double.random(in: 0...dur * 1.3, using: &g) }
            if Bool.random(using: &g) { pci = randomCurve(&g) }
            if Bool.random(using: &g) { pco = randomCurve(&g) }
        }
        let loop: (start: Double, end: Double)? = Bool.random(using: &g)
            ? (Double.random(in: 0...dur, using: &g), Double.random(in: 0...dur, using: &g)) : nil
        let old = Old(startTime: Double.random(in: -5...200, using: &g), duration: dur,
                      sourceOffset: Double.random(in: 0...50, using: &g),
                      speedRatio: Double.random(in: 0.25...4, using: &g),
                      isReversed: Bool.random(using: &g),
                      fadeIn: Bool.random(using: &g) ? 0 : Double.random(in: 0...dur, using: &g),
                      fadeOut: Bool.random(using: &g) ? 0 : Double.random(in: 0...dur, using: &g),
                      fadeInCurve: randomCurve(&g), fadeOutCurve: randomCurve(&g),
                      pixelsPerSecond: pps, previewOffset: offset,
                      previewResizeDX: resize, previewTrimDX: trim,
                      previewFadeIn: pfi, previewFadeOut: pfo,
                      previewFadeInCurve: pci, previewFadeOutCurve: pco,
                      previewLoopRange: loop,
                      rulerHeight: Double.random(in: 20...90, using: &g),
                      laneStep: Double.random(in: 20...800, using: &g),
                      displayLane: Int.random(in: 0...40, using: &g))

        for kind in [BlockPreviewGeometry.Kind.clip, .group] {
            let geo = BlockPreviewGeometry(
                kind: kind, startTime: old.startTime, duration: old.duration,
                sourceOffset: old.sourceOffset, speedRatio: old.speedRatio, isReversed: old.isReversed,
                fadeIn: old.fadeIn, fadeOut: old.fadeOut,
                fadeInCurve: old.fadeInCurve, fadeOutCurve: old.fadeOutCurve,
                pixelsPerSecond: pps,
                offsetDX: offset?.dx ?? 0, offsetDY: offset?.dy ?? 0,
                resizeDX: resize, trimDX: trim,
                previewFadeIn: pfi, previewFadeOut: pfo,
                previewFadeInCurve: pci, previewFadeOutCurve: pco, previewLoopRange: loop)
            let tag = "#\(i) \(kind) mode \(mode)"
            check("\(tag) effectiveDuration", eq(geo.effectiveDuration, old.effectiveDuration))
            check("\(tag) yPos", eq(geo.yPos(rulerHeight: old.rulerHeight, displayLane: old.displayLane,
                                              laneStep: old.laneStep), old.yPos))
            check("\(tag) curveIn", eqCurve(geo.effectiveFadeInCurve, old.effectiveFadeInCurve))
            check("\(tag) curveOut", eqCurve(geo.effectiveFadeOutCurve, old.effectiveFadeOutCurve))
            check("\(tag) loopPx", {
                switch (geo.loopMarkerPx, old.loopMarkerPx) {
                case (nil, nil): return true
                case let (a?, b?): return eq(a.start, b.start) && eq(a.end, b.end)
                default: return false
                }
            }())
            check("\(tag) effectiveStartTime", eq(geo.effectiveStartTime, old.effectiveStartTime))
            switch kind {
            case .clip:
                let f = old.clipFades
                check("\(tag) fades", eq(geo.effectiveFadeIn, f.fi) && eq(geo.effectiveFadeOut, f.fo), "\(geo.effectiveFades) vs \(f)")
                check("\(tag) fadePx", eq(geo.fadeInPx, f.fi * pps) && eq(geo.fadeOutPx, f.fo * pps))
                check("\(tag) width", eq(geo.blockWidth, old.clipBlockWidth))
                check("\(tag) x", eq(geo.xPos, old.clipXPos))
                check("\(tag) sourceOffset", eq(geo.effectiveSourceOffset, old.effectiveSourceOffset))
            case .group:
                check("\(tag) fades", eq(geo.effectiveFadeIn, old.groupFadeIn) && eq(geo.effectiveFadeOut, old.groupFadeOut))
                check("\(tag) fadePx", eq(geo.fadeInPx, old.groupFadeIn * pps) && eq(geo.fadeOutPx, old.groupFadeOut * pps))
                check("\(tag) width", eq(geo.blockWidth, old.groupBlockWidth))
                check("\(tag) x", eq(geo.xPos, old.groupXPos))
            }
            if mode == 0 {
                neutralCount += 1
                check("\(tag) neutral", geo.isNeutral)
                check("\(tag) neutral x", eq(geo.xPos, old.startTime * pps))
                check("\(tag) neutral offset", geo.effectiveSourceOffset == old.sourceOffset)
                check("\(tag) neutral startTime", geo.effectiveStartTime == old.startTime)
            } else if mode != 0 {
                // a preview with any real value is not neutral (a zero trim in modes 2/5/7 can round to 0)
                if offset != nil || resize != 0 || trim != 0 || pfi != nil || pfo != nil {
                    check("\(tag) not neutral", !geo.isNeutral)
                }
            }
        }
    }
    // The documented edge cases, by hand.
    var base = BlockPreviewGeometry(kind: .clip, startTime: 10, duration: 1, sourceOffset: 3,
                                    speedRatio: 2, isReversed: false, fadeIn: 0.2, fadeOut: 0.2,
                                    fadeInCurve: .linear, fadeOutCurve: .linear, pixelsPerSecond: 100)
    base.trimDX = 150      // squeezed under 2 px by a left trim: the right edge is the anchor
    check("squeezed clip is pinned on its right edge", base.xPos == Double(1098))
    check("squeezed clip keeps 2 px", base.blockWidth == 2)
    check("left trim reads the source ahead of itself (speed 2)", abs(base.effectiveSourceOffset - 6.0) < 1e-12)
    base.isReversed = true
    check("reversed: a left trim does not move the source", base.effectiveSourceOffset == 3)
    base.resizeDX = -50
    check("reversed: the right edge governs", base.effectiveSourceOffset != 3)

    if fails.isEmpty {
        print("ALL PASS  \(total) assertions (\(neutralCount) neutral cases)")
    } else {
        print("\(fails.count) FAILED of \(total)")
    }
    exit(fails.isEmpty ? 0 : 1)
  }
}
