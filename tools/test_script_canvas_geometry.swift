// The script canvas's geometry — axes, viewport, trace, ticks, strings — asserted with no screen.
//
// `ScriptCanvasGeometry` depends on Foundation alone, which is the whole reason it is a unit of its
// own: it is the half of the canvas with no model, no image and no window behind it.
//
//     swiftc -parse-as-library \
//         ../objekat/Shared/ScriptCanvasGeometry.swift test_script_canvas_geometry.swift \
//         -o /tmp/scg && /tmp/scg
//
// Exit: 0 if every assertion passes, 1 otherwise. It compiles and passes (125/125, run on a Mac);
// it was first written on a machine with no Swift compiler.

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
enum ScriptCanvasGeometryTest {
  static func main() {

    // The world of the spectral editor: x = time 0…2 s (lin), y = 20 Hz…24 kHz (log).
    let world = CanvasWorld(x: CanvasAxis(lo: 0, hi: 2, unit: "s", mapping: .lin),
                            y: CanvasAxis(lo: 20, hi: 24000, unit: "Hz", mapping: .log))

    // MARK: - Axes

    check("lin warp is the identity", CanvasAxis(lo: 0, hi: 2).warp(1.25) == 1.25)
    let logAxis = world.y
    check("log warp is log2", near(logAxis.warp(1024), 10))
    check("log warp / unwarp round trip", near(logAxis.unwarp(logAxis.warp(3000)), 3000, 1e-9))
    check("lin unwarp round trip", near(world.x.unwarp(world.x.warp(0.7)), 0.7))
    check("warped span of a log axis is in octaves",
          near(logAxis.warpedSpan, log2(24000.0 / 20.0)))
    check("clamp inside", world.x.clamp(1) == 1)
    check("clamp below", world.x.clamp(-3) == 0)
    check("clamp above", world.x.clamp(9) == 2)
    check("a valid axis has no error", world.x.validationError == nil && world.y.validationError == nil)
    check("min >= max is refused", CanvasAxis(lo: 2, hi: 2).validationError != nil)
    check("min > max is refused", CanvasAxis(lo: 3, hi: 2).validationError != nil)
    check("a log axis with min 0 is refused",
          CanvasAxis(lo: 0, hi: 10, mapping: .log).validationError != nil)
    check("a log axis with a negative min is refused",
          CanvasAxis(lo: -1, hi: 10, mapping: .log).validationError != nil)
    check("a non-finite bound is refused",
          CanvasAxis(lo: 0, hi: .infinity).validationError != nil
          && CanvasAxis(lo: .nan, hi: 1).validationError != nil)
    check("the mapping names", CanvasAxisMapping(rawValue: "log") == .log
          && CanvasAxisMapping(rawValue: "lin") == .lin && CanvasAxisMapping(rawValue: "x") == nil)
    check("the same world is the same", world.isSame(as: world))
    var other = world
    other.x.hi = 3
    check("another range is not the same world", !world.isSame(as: other))
    other = world
    other.y.mapping = .lin
    check("another mapping is not the same world", !world.isSame(as: other))

    // MARK: - Viewport: fit and conversions

    let fit = CanvasViewport.fit(world: world, width: 1000, height: 500)
    check("fit covers the world in x", near(fit.x0w, 0) && near(fit.x1w, 2))
    check("fit covers the world in y (warped)",
          near(fit.y0w, log2(20)) && near(fit.y1w, log2(24000)))
    check("pointsPerX = W / span", near(fit.pointsPerX, 500))
    check("pointsPerY = H / span", near(fit.pointsPerY, 500 / logAxis.warpedSpan))
    check("x0 is at screen 0, x1 at the width",
          near(fit.screenX(forWarped: 0), 0) && near(fit.screenX(forWarped: 2), 1000))
    check("y is flipped: y1w is the top, y0w the bottom",
          near(fit.screenY(forWarped: fit.y1w), 0) && near(fit.screenY(forWarped: fit.y0w), 500))
    check("screen → warped round trip x", near(fit.warpedX(forScreen: fit.screenX(forWarped: 1.3)), 1.3))
    check("screen → warped round trip y",
          near(fit.warpedY(forScreen: fit.screenY(forWarped: 8.5)), 8.5))
    check("the middle of the plot is the middle of the warped range",
          near(fit.warpedY(forScreen: 250), (fit.y0w + fit.y1w) / 2))

    // MARK: - Brush size in warped units

    let size = fit.warpedSize(forPoints: 32)
    check("size_x = size_pt / pointsPerX", near(size.x, 32 / fit.pointsPerX))
    check("size_y = size_pt / pointsPerY", near(size.y, 32 / fit.pointsPerY))
    // The plan's worked example (§6 b): a 'view_scale {x: 500, y: 100}' and a 32 pt brush.
    check("32 pt at 500 pt/unit is 0.064", near(32.0 / 500.0, 0.064))
    check("32 pt at 100 pt/unit is 0.32", near(32.0 / 100.0, 0.32))
    let flat = CanvasViewport(x0w: 0, x1w: 0, y0w: 0, y1w: 1, width: 100, height: 100)
    check("a degenerate span has no size and no division by zero",
          flat.pointsPerX == 0 && flat.warpedSize(forPoints: 32).x == 0)

    // MARK: - Zoom with a fixed anchor

    let anchorX = 0.5
    let zx = fit.zoomedX(by: 4, anchor: anchorX, in: world)
    check("zoom x by 4 divides the span by 4", near(zx.spanX, 0.5))
    check("zoom x keeps the anchor at the same screen position",
          near(zx.screenX(forWarped: anchorX), fit.screenX(forWarped: anchorX), 1e-6))
    // Anchor in the middle of the visible window: the screen position must hold exactly.
    let mid = fit.panned(dxw: 0, dyw: 0, in: world)
    let z1 = mid.zoomedX(by: 2, anchor: 1.0, in: world)       // anchor at 50 %: window [0.5, 1.5]
    check("zoom x at the centre keeps the centre", near(z1.x0w, 0.5) && near(z1.x1w, 1.5))
    check("…and the anchor is still at the middle of the screen",
          near(z1.screenX(forWarped: 1.0), 500))
    let z2 = z1.zoomedX(by: 2, anchor: 0.75, in: world)       // anchor at 25 % of [0.5, 1.5]
    check("zoom with an off-centre anchor holds its screen position",
          near(z2.screenX(forWarped: 0.75), z1.screenX(forWarped: 0.75), 1e-6))
    check("zoom out undoes zoom in (inside the world)",
          near(z2.zoomedX(by: 0.5, anchor: 0.75, in: world).x0w, z1.x0w, 1e-9))
    let out = fit.zoomedX(by: 0.1, anchor: 1, in: world)
    check("zoom out cannot exceed the world", near(out.x0w, 0) && near(out.x1w, 2))
    let deep = fit.zoomedX(by: 1e9, anchor: 1, in: world)
    check("x span has a floor of world / 10000", near(deep.spanX, 2.0 / 10_000, 1e-12))
    let deepY = fit.zoomedY(by: 1e9, anchor: 8, in: world)
    check("y span has a floor of world / 1000", near(deepY.spanY, logAxis.warpedSpan / 1000, 1e-12))
    check("the deep y window stays inside the world",
          deepY.y0w >= fit.y0w - 1e-12 && deepY.y1w <= fit.y1w + 1e-12)
    let ay = 8.0
    let zy = fit.zoomedY(by: 3, anchor: ay, in: world)
    check("zoom y divides the span", near(zy.spanY, fit.spanY / 3, 1e-12))
    check("zoom y keeps the anchor at the same screen position",
          near(zy.screenY(forWarped: ay), fit.screenY(forWarped: ay), 1e-6))
    check("a zero or negative factor changes nothing",
          fit.zoomedX(by: 0, anchor: 1, in: world) == fit && fit.zoomedY(by: -2, anchor: 1, in: world) == fit)
    check("a non-finite factor changes nothing", fit.zoomedX(by: .nan, anchor: 1, in: world) == fit)

    // MARK: - Pan and clamp

    let pz = fit.zoomedX(by: 4, anchor: 1, in: world)         // window [0.75, 1.25]
    let p1 = pz.panned(dxw: 0.25, dyw: 0, in: world)
    check("pan moves the window", near(p1.x0w, 1.0) && near(p1.x1w, 1.5))
    check("pan keeps the span", near(p1.spanX, pz.spanX))
    let p2 = pz.panned(dxw: 10, dyw: 0, in: world)
    check("pan is clamped at the right of the world", near(p2.x1w, 2) && near(p2.spanX, 0.5))
    let p3 = pz.panned(dxw: -10, dyw: 0, in: world)
    check("pan is clamped at the left of the world", near(p3.x0w, 0) && near(p3.spanX, 0.5))
    let p4 = fit.panned(dxw: 1, dyw: 1, in: world)
    check("a pan of the whole world goes nowhere",
          near(p4.x0w, fit.x0w) && near(p4.x1w, fit.x1w) && near(p4.y0w, fit.y0w) && near(p4.y1w, fit.y1w))
    let sp = pz.panned(byScreenDX: 100, dy: 0, in: world)       // 100 pt right at 2000 pt/unit
    check("dragging right moves the window towards smaller x", near(sp.x0w, 0.75 - 0.05))
    let zyv = fit.zoomedY(by: 4, anchor: 8, in: world)
    let spy = zyv.panned(byScreenDX: 0, dy: 50, in: world)
    check("dragging down moves the window towards larger y", spy.y0w > zyv.y0w)
    let big = CanvasViewport(x0w: -5, x1w: 9, y0w: 0, y1w: 100, width: 100, height: 100)
    let cl = big.clamped(in: world)
    check("clamped brings an oversized window back to the world",
          near(cl.x0w, 0) && near(cl.x1w, 2) && near(cl.y0w, fit.y0w) && near(cl.y1w, fit.y1w))
    let tiny = CanvasViewport(x0w: 1, x1w: 1 + 1e-12, y0w: 8, y1w: 8 + 1e-12, width: 100, height: 100)
    let ct = tiny.clamped(in: world)
    check("clamped enforces the minimum span", near(ct.spanX, 2.0 / 10_000, 1e-12)
          && near(ct.spanY, logAxis.warpedSpan / 1000, 1e-12))
    let r = pz.resized(width: 500, height: 250)
    check("resize keeps the warped window", r.x0w == pz.x0w && r.x1w == pz.x1w && r.width == 500)

    // MARK: - Stroke trace

    let flatWorld = CanvasWorld(x: CanvasAxis(lo: 0, hi: 10, unit: "s"),
                                y: CanvasAxis(lo: 0, hi: 10, unit: ""))
    // A horizontal path 2 units long with a 1-unit diameter: 2 diameters, so 8 discs.
    let path = [CanvasPoint(x: 1, y: 5), CanvasPoint(x: 3, y: 5)]
    let discs = CanvasStrokeTrace.discCentres(points: path, sizeX: 1, sizeY: 1, world: flatWorld)
    check("two diameters of path give 8 discs (¼ diameter apart)", discs.count == 8, "\(discs.count)")
    check("the first disc is half a spacing in", near(discs[0].x, 1 + 0.125) && near(discs[0].y, 5))
    check("discs are ¼ diameter apart", near(discs[1].x - discs[0].x, 0.25))
    check("the last disc is half a spacing short of the end", near(discs[7].x, 3 - 0.125))
    let still = CanvasStrokeTrace.discCentres(points: [CanvasPoint(x: 2, y: 2), CanvasPoint(x: 2, y: 2)],
                                              sizeX: 1, sizeY: 1, world: flatWorld)
    check("a still path gives no discs", still.isEmpty)
    check("a single point gives no discs",
          CanvasStrokeTrace.discCentres(points: [CanvasPoint(x: 2, y: 2)], sizeX: 1, sizeY: 1,
                                        world: flatWorld).isEmpty)
    check("no points give no discs",
          CanvasStrokeTrace.discCentres(points: [], sizeX: 1, sizeY: 1, world: flatWorld).isEmpty)
    check("a path shorter than half a spacing gives no disc",
          CanvasStrokeTrace.discCentres(points: [CanvasPoint(x: 1, y: 1), CanvasPoint(x: 1.1, y: 1)],
                                        sizeX: 1, sizeY: 1, world: flatWorld).isEmpty)
    check("a zero size gives nothing",
          CanvasStrokeTrace.discCentres(points: path, sizeX: 0, sizeY: 1, world: flatWorld).isEmpty)
    check("a non-finite size gives nothing",
          CanvasStrokeTrace.discCentres(points: path, sizeX: .infinity, sizeY: 1, world: flatWorld).isEmpty)
    // Resampling is independent of how densely the path was sampled.
    var dense: [CanvasPoint] = []
    for i in 0...200 { dense.append(CanvasPoint(x: 1 + 2 * Double(i) / 200, y: 5)) }
    let discsDense = CanvasStrokeTrace.discCentres(points: dense, sizeX: 1, sizeY: 1, world: flatWorld)
    check("a densely sampled path gives the same discs",
          discsDense.count == discs.count
          && zip(discs, discsDense).allSatisfy { near($0.x, $1.x, 1e-9) && near($0.y, $1.y, 1e-9) })
    // Anisotropic diameter: 2 units wide, 1 unit tall, a diagonal path.
    let diag = CanvasStrokeTrace.discCentres(
        points: [CanvasPoint(x: 0, y: 0), CanvasPoint(x: 2, y: 1)], sizeX: 2, sizeY: 1, world: flatWorld)
    // Normalised, the path is (0,0) → (1,1): length √2 diameters → 6 discs (k + ½ ≤ 5.66).
    check("the path length is measured in normalised units", diag.count == 6, "\(diag.count)")
    check("anisotropic discs stay on the path",
          diag.allSatisfy { near($0.y, $0.x / 2, 1e-9) })
    // On a log axis the discs are equally spaced in OCTAVES.
    let logWorld = CanvasWorld(x: CanvasAxis(lo: 0, hi: 10), y: CanvasAxis(lo: 20, hi: 20480, mapping: .log))
    let lp = [CanvasPoint(x: 1, y: 20), CanvasPoint(x: 1, y: 20480)]       // 10 octaves
    let ld = CanvasStrokeTrace.discCentres(points: lp, sizeX: 1, sizeY: 1, world: logWorld)
    check("10 octaves of a 1-octave brush give 40 discs", ld.count == 40, "\(ld.count)")
    check("log discs are 1/4 octave apart",
          near(log2(ld[1].y / ld[0].y), 0.25, 1e-9))
    check("log discs stay on the vertical", ld.allSatisfy { near($0.x, 1) })

    // MARK: - Ticks

    check("linear step: 500 pt/unit → 0.2", near(CanvasTicks.linearStep(pointsPerUnit: 500), 0.2))
    check("linear step: 1000 pt/unit → 0.1 (70 pt = 0.07 → 0.1)",
          near(CanvasTicks.linearStep(pointsPerUnit: 1000), 0.1))
    check("linear step: 10 pt/unit → 10 (7 → 10)", near(CanvasTicks.linearStep(pointsPerUnit: 10), 10))
    check("linear step: 70 pt/unit → exactly 1", near(CanvasTicks.linearStep(pointsPerUnit: 70), 1))
    check("linear step: 20 pt/unit → 5 (3.5 → 5)", near(CanvasTicks.linearStep(pointsPerUnit: 20), 5))
    check("linear step: 35 pt/unit → 2", near(CanvasTicks.linearStep(pointsPerUnit: 35), 2))
    let lin = CanvasTicks.linear(lo: 0, hi: 2, length: 1000)           // 500 pt/unit → step 0.2
    check("0…2 s over 1000 pt gives 11 ticks at 0.2", lin.count == 11, "\(lin.count)")
    check("linear ticks are 0.2 apart and start on 0",
          near(lin.first!.value, 0) && near(lin[1].value - lin[0].value, 0.2) && near(lin.last!.value, 2))
    check("every linear pair is at least 70 pt apart",
          zip(lin, lin.dropFirst()).allSatisfy { ($1.value - $0.value) * 500 >= 70 - 1e-9 })
    let lin2 = CanvasTicks.linear(lo: 0.95, hi: 1.25, length: 600)     // 2000 pt/unit → 0.05
    check("a zoomed window has ticks on multiples of the step",
          lin2.allSatisfy { near($0.value / 0.05, ($0.value / 0.05).rounded(), 1e-6) } && lin2.count == 7,
          "\(lin2.map { $0.value })")
    check("ticks lie inside the window",
          lin2.allSatisfy { $0.value >= 0.95 - 1e-9 && $0.value <= 1.25 + 1e-9 })
    check("negative values tick too", CanvasTicks.linear(lo: -1, hi: 1, length: 700).first!.value <= -1 + 1e-9)
    check("an empty or inverted range has no ticks",
          CanvasTicks.linear(lo: 1, hi: 1, length: 100).isEmpty
          && CanvasTicks.linear(lo: 2, hi: 1, length: 100).isEmpty
          && CanvasTicks.linear(lo: 0, hi: 1, length: 0).isEmpty)

    // Log: 20 Hz … 24 kHz is 10.2 octaves over 500 pt = 49 pt/octave.
    let lg = CanvasTicks.logarithmic(lo: 20, hi: 24000, length: 500)
    // {1}: decades are 3.32 oct = 163 pt apart ≥ 70; {1,2,5}: 1 octave = 49 pt < 70 → decades only.
    check("20 Hz…24 kHz over 500 pt keeps decades only",
          lg.map { $0.value } == [100, 1000, 10000], "\(lg.map { $0.value })")
    check("decade ticks are major", lg.allSatisfy { $0.isMajor })
    // 1 kHz…10 kHz: 3.32 octaves over 500 pt = 150 pt/octave: {1,2,5} closest pair 1 oct = 150 ≥ 70.
    let lg2 = CanvasTicks.logarithmic(lo: 1000, hi: 10000, length: 500)
    check("a zoomed window gets 1-2-5", lg2.map { $0.value } == [1000, 2000, 5000, 10000],
          "\(lg2.map { $0.value })")
    check("only the 1 is major", lg2.filter { $0.isMajor }.map { $0.value } == [1000, 10000])
    // 2 kHz…4 kHz: 1 octave over 700 pt = 700 pt/octave: {1…9}'s closest pair is 9→10 = 0.152 oct = 107 pt.
    let lg3 = CanvasTicks.logarithmic(lo: 2000, hi: 4000, length: 700)
    check("a deep zoom gets 1…9", lg3.map { $0.value } == [2000, 3000, 4000], "\(lg3.map { $0.value })")
    // A very narrow plot: decades closer than 70 pt keep every n-th decade.
    let lg4 = CanvasTicks.logarithmic(lo: 1, hi: 1e6, length: 200)    // 20 octaves → 10 pt/oct → 33 pt/decade
    check("closer decades are thinned", lg4.map { $0.value } == [1, 1000, 1e6], "\(lg4.map { $0.value })")
    check("log ticks stay inside the window",
          lg3.allSatisfy { $0.value >= 2000 && $0.value <= 4000 })
    check("a non-positive log window has no ticks",
          CanvasTicks.logarithmic(lo: 0, hi: 10, length: 100).isEmpty)
    check("ticks(for:) follows the mapping",
          CanvasTicks.ticks(for: world.x, visibleLo: 0, visibleHi: 2, length: 1000).count == 11
          && CanvasTicks.ticks(for: world.y, visibleLo: 20, visibleHi: 24000, length: 500).count == 3)

    // MARK: - Strings

    check("signed dB: positive, negative, zero", CanvasFormat.signedDB(6) == "+6 dB" && CanvasFormat.signedDB(-3.5) == "-3.5 dB"
          && CanvasFormat.signedDB(0) == "0 dB")
    check("signed dB: -0.04 reads 0 dB (no '+', no '-0')", CanvasFormat.signedDB(-0.04) == "0 dB" && CanvasFormat.signedDB(0.04) == "0 dB")
    check("signed dB: the ends of the range", CanvasFormat.signedDB(20) == "+20 dB" && CanvasFormat.signedDB(-20) == "-20 dB")
    check("time 0", CanvasFormat.time(0) == "0:00.000")
    check("time 1.5", CanvasFormat.time(1.5) == "0:01.500")
    check("time 65.25", CanvasFormat.time(65.25) == "1:05.250")
    check("time rounds to the millisecond and carries", CanvasFormat.time(59.9996) == "1:00.000")
    check("time 600", CanvasFormat.time(600) == "10:00.000")
    check("time negative", CanvasFormat.time(-1.5) == "-0:01.500")
    check("time of a negative zero has no sign", CanvasFormat.time(-0.0001) == "0:00.000")
    check("time with no decimals", CanvasFormat.time(5.4, decimals: 0) == "0:05")
    check("time with 2 decimals truncates the digits", CanvasFormat.time(5.4567, decimals: 2) == "0:05.45")
    check("time of a non-finite value", CanvasFormat.time(.nan) == "–")
    check("440 Hz", CanvasFormat.frequency(440) == "440 Hz")
    check("1000 Hz is 1 kHz", CanvasFormat.frequency(1000) == "1 kHz")
    check("1500 Hz is 1.5 kHz", CanvasFormat.frequency(1500) == "1.5 kHz")
    check("24000 Hz is 24 kHz", CanvasFormat.frequency(24000) == "24 kHz")
    check("20.5 Hz", CanvasFormat.frequency(20.5) == "20.5 Hz")
    check("3.14159 kHz keeps 2 decimals", CanvasFormat.frequency(3141.59) == "3.14 kHz")
    check("number with a unit", CanvasFormat.number(-12.5, unit: "dB") == "-12.5 dB")
    check("number without a unit", CanvasFormat.number(3, unit: "") == "3")
    check("number rounds to 2 decimals", CanvasFormat.number(1.0 / 3.0, unit: "x") == "0.33 x")
    check("trimmed never says -0", CanvasFormat.trimmed(-0.001, decimals: 1) == "0")
    check("axisValue s", CanvasFormat.axisValue(1.5, unit: "s") == "0:01.500")
    check("axisValue Hz", CanvasFormat.axisValue(1500, unit: "Hz") == "1.5 kHz")
    check("axisValue other", CanvasFormat.axisValue(-30, unit: "dB") == "-30 dB")
    check("tick label of a whole second", CanvasFormat.tickLabel(5, unit: "s", step: 1) == "0:05")
    check("tick label of a fifth of a second", CanvasFormat.tickLabel(1.2, unit: "s", step: 0.2) == "0:01.2")
    check("tick label of a hundredth", CanvasFormat.tickLabel(1.25, unit: "s", step: 0.05) == "0:01.25")
    check("tick label of a thousandth", CanvasFormat.tickLabel(1.001, unit: "s", step: 0.001) == "0:01.001")
    check("tick label Hz", CanvasFormat.tickLabel(2000, unit: "Hz", step: 1000) == "2 kHz")
    check("tick label other unit has no unit", CanvasFormat.tickLabel(0.5, unit: "dB", step: 0.5) == "0.5")
    check("value readout", CanvasFormat.value(-42.5, unit: "dB", isFloor: false) == "-42.5 dB")
    check("floor readout", CanvasFormat.value(-100, unit: "dB", isFloor: true) == "≤ -100 dB")

    print("\n\(total - fails.count)/\(total) assertions pass")
    if !fails.isEmpty {
        print("FAILED: " + fails.joined(separator: "; "))
        exit(1)
    }
  }
}
