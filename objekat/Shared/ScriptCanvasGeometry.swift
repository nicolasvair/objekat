import Foundation

// MARK: - The script canvas's geometry — axes, viewport, ticks, readout strings
//
// The arithmetic alone: no view, no model, no image. A unit of its own for the reason `SendColumns`,
// `PianoRollFraming` and `VerticalLaneSnap` are — this is the half of the canvas with nothing behind
// it, so it can be compiled alone and asserted with no screen
// (@see tools/test_script_canvas_geometry.swift). The reference is `docs/plan_spectral_gain.md`
// §3.2 (axes and viewport) and D6 (warped units).
//
// Everything here is `nonisolated`: the project's default isolation is MainActor, and this code
// has no business there (the store, the command layer and the view all read it).
//
// WARPED UNITS. A `log` axis is laid out in octaves: `warp(v) = log2(v)`; a `lin` axis in its own
// units. Every LENGTH in this file (a viewport span, a brush diameter) is a length in warped units,
// which is what turns "32 points" into a size in data units on either kind of axis.
//
// This file knows NOTHING about gain: the app records gestures, it does not interpret them.

/// A point in DATA units (seconds, Hz, …) — not warped, not on screen.
nonisolated struct CanvasPoint: Equatable {
    var x: Double
    var y: Double

    init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

nonisolated enum CanvasAxisMapping: String, Equatable {
    case lin
    case log
}

// MARK: - Axis

/// One axis of the world: a range in data units, a unit label, and how the range is laid out.
nonisolated struct CanvasAxis: Equatable {
    var lo: Double
    var hi: Double
    var unit: String
    var mapping: CanvasAxisMapping

    init(lo: Double, hi: Double, unit: String = "", mapping: CanvasAxisMapping = .lin) {
        self.lo = lo
        self.hi = hi
        self.unit = unit
        self.mapping = mapping
    }

    /// Why an axis is refused, or nil when it is usable. Finite numbers, `lo < hi`, and `lo > 0`
    /// on a log axis (a log of zero is minus infinity, and no non-finite number may reach a JSON
    /// payload).
    var validationError: String? {
        guard lo.isFinite, hi.isFinite else { return "axis bounds must be finite numbers" }
        guard lo < hi else { return "axis min must be lower than max" }
        if mapping == .log && lo <= 0 { return "a log axis requires min > 0" }
        return nil
    }

    func warp(_ v: Double) -> Double {
        switch mapping {
        case .lin: return v
        case .log: return log2(v)
        }
    }

    func unwarp(_ w: Double) -> Double {
        switch mapping {
        case .lin: return w
        case .log: return exp2(w)
        }
    }

    var warpedLo: Double { warp(lo) }
    var warpedHi: Double { warp(hi) }
    var warpedSpan: Double { warpedHi - warpedLo }

    /// `v` brought inside [lo, hi] (data units).
    func clamp(_ v: Double) -> Double {
        Swift.min(Swift.max(v, lo), hi)
    }
}

// MARK: - World

/// The rectangle the base image covers, in data units. Layers always cover it exactly.
nonisolated struct CanvasWorld: Equatable {
    var x: CanvasAxis
    var y: CanvasAxis

    init(x: CanvasAxis, y: CanvasAxis) {
        self.x = x
        self.y = y
    }

    /// The same world (the axes, unit and mapping included) — "if the axes are unchanged, the view
    /// and the layers are kept".
    func isSame(as other: CanvasWorld) -> Bool { self == other }
}

// MARK: - Viewport

/// The visible window onto the world, in WARPED units, plus the size of the plot in points.
/// y is flipped on screen: warped `y1w` is at the top (sy = 0).
nonisolated struct CanvasViewport: Equatable {
    var x0w: Double
    var x1w: Double
    var y0w: Double
    var y1w: Double
    var width: Double
    var height: Double

    /// The ceilings of the zoom: the span can shrink to world / 10000 on x and world / 1000 on y.
    static let maxZoomX: Double = 10_000
    static let maxZoomY: Double = 1_000

    init(x0w: Double, x1w: Double, y0w: Double, y1w: Double, width: Double, height: Double) {
        self.x0w = x0w
        self.x1w = x1w
        self.y0w = y0w
        self.y1w = y1w
        self.width = width
        self.height = height
    }

    /// The whole world, in a plot of `width` × `height` points.
    static func fit(world: CanvasWorld, width: Double, height: Double) -> CanvasViewport {
        CanvasViewport(x0w: world.x.warpedLo, x1w: world.x.warpedHi,
                       y0w: world.y.warpedLo, y1w: world.y.warpedHi,
                       width: width, height: height)
    }

    var spanX: Double { x1w - x0w }
    var spanY: Double { y1w - y0w }

    /// Points per warped unit (`W / (x1w − x0w)`).
    var pointsPerX: Double { spanX > 0 ? width / spanX : 0 }
    var pointsPerY: Double { spanY > 0 ? height / spanY : 0 }

    // MARK: screen ↔ warped

    func screenX(forWarped xw: Double) -> Double { (xw - x0w) * pointsPerX }
    func screenY(forWarped yw: Double) -> Double { (y1w - yw) * pointsPerY }

    func warpedX(forScreen sx: Double) -> Double {
        pointsPerX > 0 ? x0w + sx / pointsPerX : x0w
    }

    func warpedY(forScreen sy: Double) -> Double {
        pointsPerY > 0 ? y1w - sy / pointsPerY : y1w
    }

    /// A brush diameter in points, as warped lengths: (`size_pt / pointsPerX`, `size_pt / pointsPerY`).
    /// Frozen when a gesture starts, so a zoom made afterwards does not change what was drawn.
    func warpedSize(forPoints sizePt: Double) -> (x: Double, y: Double) {
        (pointsPerX > 0 ? sizePt / pointsPerX : 0, pointsPerY > 0 ? sizePt / pointsPerY : 0)
    }

    // MARK: moves — each returns a CLAMPED viewport

    /// Zoom in x by `factor` (> 1 zooms in, < 1 out), keeping the warped value `anchor` fixed on
    /// screen.
    func zoomedX(by factor: Double, anchor: Double, in world: CanvasWorld) -> CanvasViewport {
        guard factor.isFinite, factor > 0, anchor.isFinite, spanX > 0 else { return self }
        var v = self
        let worldSpan = world.x.warpedSpan
        let newSpan = Swift.min(Swift.max(spanX / factor, worldSpan / Self.maxZoomX), worldSpan)
        let f = (anchor - x0w) / spanX
        v.x0w = anchor - f * newSpan
        v.x1w = v.x0w + newSpan
        return v.clamped(in: world)
    }

    /// The y counterpart of `zoomedX`.
    func zoomedY(by factor: Double, anchor: Double, in world: CanvasWorld) -> CanvasViewport {
        guard factor.isFinite, factor > 0, anchor.isFinite, spanY > 0 else { return self }
        var v = self
        let worldSpan = world.y.warpedSpan
        let newSpan = Swift.min(Swift.max(spanY / factor, worldSpan / Self.maxZoomY), worldSpan)
        // y grows upwards: the fraction is measured from the BOTTOM edge.
        let f = (anchor - y0w) / spanY
        v.y0w = anchor - f * newSpan
        v.y1w = v.y0w + newSpan
        return v.clamped(in: world)
    }

    /// Shift the window by warped amounts (positive `dxw` moves it towards larger x, positive `dyw`
    /// towards larger y).
    func panned(dxw: Double, dyw: Double, in world: CanvasWorld) -> CanvasViewport {
        guard dxw.isFinite, dyw.isFinite else { return self }
        var v = self
        v.x0w += dxw
        v.x1w += dxw
        v.y0w += dyw
        v.y1w += dyw
        return v.clamped(in: world)
    }

    /// Shift by an amount of POINTS on screen (a drag): dragging right moves the content right,
    /// so the window goes towards smaller x; dragging down moves it towards larger y.
    func panned(byScreenDX dx: Double, dy: Double, in world: CanvasWorld) -> CanvasViewport {
        panned(dxw: pointsPerX > 0 ? -dx / pointsPerX : 0,
               dyw: pointsPerY > 0 ? dy / pointsPerY : 0, in: world)
    }

    /// The window with its span held between the minimum and the world's, and kept inside the
    /// world. The span is what the zoom limits are about; the position is what the pan's are about.
    func clamped(in world: CanvasWorld) -> CanvasViewport {
        var v = self
        let (a0, a1) = Self.clampAxis(lo: x0w, hi: x1w, worldLo: world.x.warpedLo,
                                      worldHi: world.x.warpedHi, maxZoom: Self.maxZoomX)
        let (b0, b1) = Self.clampAxis(lo: y0w, hi: y1w, worldLo: world.y.warpedLo,
                                      worldHi: world.y.warpedHi, maxZoom: Self.maxZoomY)
        v.x0w = a0
        v.x1w = a1
        v.y0w = b0
        v.y1w = b1
        return v
    }

    private static func clampAxis(lo: Double, hi: Double, worldLo: Double, worldHi: Double,
                                  maxZoom: Double) -> (Double, Double) {
        let worldSpan = worldHi - worldLo
        guard worldSpan > 0, lo.isFinite, hi.isFinite else { return (worldLo, worldHi) }
        let span = Swift.min(Swift.max(hi - lo, worldSpan / maxZoom), worldSpan)
        var start = lo
        if start < worldLo { start = worldLo }
        if start + span > worldHi { start = worldHi - span }
        return (start, start + span)
    }

    /// The same window in a plot of another size (a window resize): the warped bounds are kept,
    /// only the points per unit change.
    func resized(width: Double, height: Double) -> CanvasViewport {
        var v = self
        v.width = width
        v.height = height
        return v
    }
}

// MARK: - Raw stroke trace

/// The discs the app draws for a stroke it has recorded and the script has not yet reflected:
/// one every ¼ diameter along the path. Purely visual — the app has no notion of hardness, and the
/// script's refreshed picture replaces the trace as soon as it arrives.
nonisolated enum CanvasStrokeTrace {

    /// The spacing between two discs, in diameters. Fixed.
    static let spacing: Double = 0.25

    /// Disc centres, in DATA units, laid at arc lengths `(k + 0.5) · spacing` along the path
    /// measured in the brush's own units (warped coordinates divided by `sizeX` / `sizeY`, so a
    /// diameter is 1 along each axis). A path with no length (a still hand, a single point)
    /// deposits nothing. Invalid sizes give nothing.
    static func discCentres(points: [CanvasPoint], sizeX: Double, sizeY: Double,
                            world: CanvasWorld) -> [CanvasPoint] {
        guard points.count >= 2, sizeX.isFinite, sizeY.isFinite, sizeX > 0, sizeY > 0 else { return [] }
        let u = points.map { world.x.warp($0.x) / sizeX }
        let v = points.map { world.y.warp($0.y) / sizeY }
        var out: [CanvasPoint] = []
        var acc = 0.0
        var k = 0
        for i in 1..<points.count {
            let du = u[i] - u[i - 1]
            let dv = v[i] - v[i - 1]
            let length = (du * du + dv * dv).squareRoot()
            guard length.isFinite, length > 0 else { continue }
            while (Double(k) + 0.5) * spacing <= acc + length {
                let t = ((Double(k) + 0.5) * spacing - acc) / length
                let wx = (u[i - 1] + t * du) * sizeX
                let wy = (v[i - 1] + t * dv) * sizeY
                out.append(CanvasPoint(x: world.x.unwarp(wx), y: world.y.unwarp(wy)))
                k += 1
            }
            acc += length
        }
        return out
    }
}

// MARK: - Ticks

nonisolated enum CanvasTicks {

    struct Tick: Equatable {
        /// Data units.
        var value: Double
        /// A round number — a power of ten times 1 on a log axis, every fifth step on a linear
        /// one. Drawn longer.
        var isMajor: Bool
    }

    /// The smallest distance, in points, between two ticks.
    static let minSpacing: Double = 70

    /// A linear axis: the step is the first of 1, 2, 5 × 10ⁿ that keeps two ticks at least
    /// `minSpacing` points apart. `pointsPerUnit` is the zoom in data units.
    static func linearStep(pointsPerUnit: Double, minSpacing: Double = CanvasTicks.minSpacing) -> Double {
        guard pointsPerUnit.isFinite, pointsPerUnit > 0 else { return 1 }
        let raw = minSpacing / pointsPerUnit
        let base = pow(10.0, floor(log10(raw)))
        for m in [1.0, 2.0, 5.0, 10.0] where m * base >= raw * (1 - 1e-12) {
            return m * base
        }
        return 10 * base
    }

    /// Ticks of a linear axis visible between `lo` and `hi` (data units) over `length` points.
    static func linear(lo: Double, hi: Double, length: Double,
                       minSpacing: Double = CanvasTicks.minSpacing) -> [Tick] {
        guard lo.isFinite, hi.isFinite, hi > lo, length > 0 else { return [] }
        let step = linearStep(pointsPerUnit: length / (hi - lo), minSpacing: minSpacing)
        let first = Int((lo / step - 1e-9).rounded(.up))
        let last = Int((hi / step + 1e-9).rounded(.down))
        guard last >= first, last - first < 10_000 else { return [] }
        return (first...last).map { i in
            Tick(value: Double(i) * step, isMajor: i % 5 == 0)
        }
    }

    /// Ticks of a log axis: the mantissa sets {1}, {1, 2, 5} or {1…9} × 10ⁿ, the DENSEST of the
    /// three whose closest pair is still at least `minSpacing` points apart. When even decades are
    /// closer than that, every n-th decade is kept. `lo` and `hi` are data units (> 0).
    static func logarithmic(lo: Double, hi: Double, length: Double,
                            minSpacing: Double = CanvasTicks.minSpacing) -> [Tick] {
        guard lo.isFinite, hi.isFinite, lo > 0, hi > lo, length > 0 else { return [] }
        let octaves = log2(hi / lo)
        let pointsPerOctave = length / octaves
        let mantissaSets: [[Double]] = [[1, 2, 3, 4, 5, 6, 7, 8, 9], [1, 2, 5], [1]]
        var chosen: [Double] = [1]
        var decadeStride = 1
        var found = false
        for mset in mantissaSets {
            // The closest pair in a decade: between two neighbours, and from the last one to the
            // next decade's 1.
            var closest = Double.infinity
            for i in 0..<mset.count {
                let next = i + 1 < mset.count ? mset[i + 1] : 10.0
                closest = Swift.min(closest, log2(next / mset[i]))
            }
            if closest * pointsPerOctave >= minSpacing {
                chosen = mset
                found = true
                break
            }
        }
        if !found {
            // A decade is 3.32 octaves: keep every n-th one.
            let perDecade = log2(10.0) * pointsPerOctave
            decadeStride = Swift.max(1, Int((minSpacing / Swift.max(perDecade, 1e-9)).rounded(.up)))
        }
        let firstDecade = Int(floor(log10(lo))) - 1
        let lastDecade = Int(ceil(log10(hi)))
        guard lastDecade >= firstDecade, lastDecade - firstDecade < 400 else { return [] }
        var out: [Tick] = []
        for d in firstDecade...lastDecade where ((d % decadeStride) + decadeStride) % decadeStride == 0 {
            for m in chosen {
                let value = m * pow(10.0, Double(d))
                if value >= lo * (1 - 1e-9) && value <= hi * (1 + 1e-9) {
                    out.append(Tick(value: value, isMajor: m == 1))
                }
            }
        }
        return out
    }

    /// The ticks for an axis over `length` points, whatever its mapping.
    static func ticks(for axis: CanvasAxis, visibleLo: Double, visibleHi: Double,
                      length: Double) -> [Tick] {
        switch axis.mapping {
        case .lin: return linear(lo: visibleLo, hi: visibleHi, length: length)
        case .log: return logarithmic(lo: visibleLo, hi: visibleHi, length: length)
        }
    }
}

// MARK: - Strings

/// The strings of the rulers and of the pointer readout. Locale-independent on purpose (a decimal
/// point, never a comma): these are measurements, and `String(format:)` without a locale is the
/// C one.
nonisolated enum CanvasFormat {

    /// A number with at most `decimals` decimals and no trailing zeros ("1.5", "1000", "0.25").
    static func trimmed(_ v: Double, decimals: Int) -> String {
        guard v.isFinite else { return "–" }
        var s = String(format: "%.\(Swift.max(0, decimals))f", v)
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        if s == "-0" { s = "0" }
        return s
    }

    /// `m:ss.mmm` — `decimals` (0…3) of them. Rounded to the millisecond first, so 59.9996 s reads
    /// "1:00.000" and not "0:60.000".
    static func time(_ seconds: Double, decimals: Int = 3) -> String {
        guard seconds.isFinite else { return "–" }
        let ms = Int((abs(seconds) * 1000).rounded())
        let m = ms / 60_000
        let s = (ms / 1000) % 60
        let frac = ms % 1000
        let d = Swift.min(3, Swift.max(0, decimals))
        var out = (seconds < 0 && ms > 0 ? "-" : "") + "\(m):" + String(format: "%02d", s)
        if d > 0 {
            let digits = String(format: "%03d", frac)
            out += "." + String(digits.prefix(d))
        }
        return out
    }

    /// Hz below 1000, kHz from there ("440 Hz", "1.5 kHz", "24 kHz").
    static func frequency(_ hz: Double) -> String {
        guard hz.isFinite else { return "–" }
        if abs(hz) >= 1000 { return trimmed(hz / 1000, decimals: 2) + " kHz" }
        return trimmed(hz, decimals: 1) + " Hz"
    }

    /// A number plus its unit ("-12.5 dB"); no unit, no space.
    static func number(_ v: Double, unit: String) -> String {
        let n = trimmed(v, decimals: 2)
        return unit.isEmpty ? n : n + " " + unit
    }

    /// A value read off an axis for the pointer readout: `"s"` is time, `"Hz"` is frequency,
    /// anything else a number and its unit.
    static func axisValue(_ v: Double, unit: String) -> String {
        switch unit {
        case "s": return time(v)
        case "Hz": return frequency(v)
        default: return number(v, unit: unit)
        }
    }

    /// A ruler label. `step` (data units between two labelled ticks) decides how many decimals a
    /// time needs: whole seconds read "0:05", a hundredth of a second "0:05.00".
    static func tickLabel(_ v: Double, unit: String, step: Double) -> String {
        switch unit {
        case "s":
            let decimals = step >= 1 ? 0 : Swift.min(3, Int(ceil(-log10(Swift.max(step, 1e-9)) - 1e-9)))
            return time(v, decimals: decimals)
        case "Hz":
            return frequency(v)
        default:
            let decimals = step >= 1 ? 0 : Swift.min(6, Int(ceil(-log10(Swift.max(step, 1e-9)) - 1e-9)))
            return trimmed(v, decimals: decimals)
        }
    }

    /// The readout of a value read from an indexed image. Index 0 is the floor of the range and is
    /// shown as "≤ v0" — the image cannot say how far below it the real value was.
    static func value(_ v: Double, unit: String, isFloor: Bool) -> String {
        let s = number(v, unit: unit)
        return isFloor ? "≤ " + s : s
    }
}
