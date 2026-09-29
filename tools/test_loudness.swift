// Standalone assertions on the loudness measurement made while an export renders:
//
//   • the SIGNAL half — `Shared/OBJLoudness.h`, plain C, the very code the export's tap runs
//     (K-weighting for the real sample rate, 100 ms sub-block energies, 4x true peak);
//   • the ARITHMETIC half — `Export/LoudnessAnalysis.swift` (momentary, short-term, gated
//     integrated, loudness range, the running curves).
//
// Neither has an engine, a model or a view behind it, which is why they can be compiled and run
// alone, like `SendColumns` / `WaveformPeaks` / `CutSelection` before them. The signals are
// GENERATED, so a failure is reproducible from the source alone.
//
//     cd tools && swiftc -O -parse-as-library -import-objc-header ../objekat/Shared/OBJLoudness.h \
//         ../objekat/Export/LoudnessAnalysis.swift test_loudness.swift -o /tmp/loudness && /tmp/loudness
//
// What is checked, against what the standard says:
//   BS.1770-4 Tables 1-2   the K-weighting coefficients at 48 kHz, to 1e-9, and that other rates
//                          are RECOMPUTED (a 997 Hz sine reads the same at 44.1, 48, 88.2, 96 kHz)
//   EBU Tech 3341          a stereo 997 Hz sine at -23 dBFS reads M = S = I = -23.0 LUFS (+-0.1),
//                          -33 reads -33; alternating levels exercise BOTH gates
//   BS.1770-4 Annex 2      the true peak of a fs/4 sine at 45 degrees is its nominal peak while its
//                          samples are 3 dB under it
//   EBU Tech 3342          LRA of level sequences: -20/-30 -> 10, -20/-15 -> 5, -40/-20 -> 20,
//                          -50/-35/-20/-35/-50 -> 15 (+-1 LU); silence gives nothing
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

func near(_ a: Double, _ b: Double, _ tol: Double) -> Bool { abs(a - b) <= tol }
func f2(_ v: Double) -> String { String(format: "%.3f", v) }

// MARK: - Driving the C measurement

/// Collects what the C code emits.
final class Collector {
    var analysis = LoudnessAnalysis()
    var indices: [Int] = []
}

let emitCallback: OBJLoudnessEmit = { context, index, energy, truePeak in
    let c = Unmanaged<Collector>.fromOpaque(context!).takeUnretainedValue()
    c.indices.append(Int(index))
    c.analysis.append(energy: energy, truePeak: truePeak)
}

/// Runs `channels` (one array per channel, equal length) through a fresh measurement at
/// `sampleRate`, cutting the stream into blocks of `chunk` frames the way a render does.
func measure(channels: [[Float]], sampleRate: Double, chunk: Int = 512) -> Collector {
    let collector = Collector()
    guard let state = objloud_create(sampleRate, Int32(channels.count)) else { return collector }
    defer { objloud_destroy(state) }
    let ctx = Unmanaged.passUnretained(collector).toOpaque()
    let frames = channels[0].count
    var start = 0
    while start < frames {
        let n = min(chunk, frames - start)
        var pointers: [UnsafePointer<Float>?] = []
        // Keep every channel's storage pinned for the duration of the call.
        func feed(_ c: Int) {
            if c == channels.count {
                objloud_process(state, pointers, Int32(n), emitCallback, ctx)
                return
            }
            channels[c].withUnsafeBufferPointer { buf in
                pointers.append(buf.baseAddress! + start)
                feed(c + 1)
            }
        }
        feed(0)
        start += n
    }
    return collector
}

/// A stereo sine at `freq` whose PEAK level is `dbfs` on each channel, in segments (seconds, dBFS)
/// with a continuous phase. A segment at `nil` is digital silence.
func sineSegments(_ segments: [(Double, Double?)], sampleRate: Double, freq: Double = 997) -> [[Float]] {
    var out: [Float] = []
    var phase = 0.0
    let step = 2 * Double.pi * freq / sampleRate
    for (seconds, level) in segments {
        let n = Int(seconds * sampleRate)
        let amp = level.map { pow(10, $0 / 20) } ?? 0
        out.reserveCapacity(out.count + n)
        for _ in 0..<n {
            out.append(Float(amp * sin(phase)))
            phase += step
            if phase > 2 * Double.pi { phase -= 2 * Double.pi }
        }
    }
    return [out, out]
}

// MARK: - The suite

func runTests() {

// MARK: - K-weighting

do {
    var shelf = OBJLoudBiquad(), high = OBJLoudBiquad()
    objloud_kweighting(48000, &shelf, &high)
    // BS.1770-4 Table 1 and Table 2.
    check("K-weighting: shelf b0", near(shelf.b0, 1.53512485958697, 1e-9), f2(shelf.b0))
    check("K-weighting: shelf b1", near(shelf.b1, -2.69169618940638, 1e-9), f2(shelf.b1))
    check("K-weighting: shelf b2", near(shelf.b2, 1.19839281085285, 1e-9), f2(shelf.b2))
    check("K-weighting: shelf a1", near(shelf.a1, -1.69065929318241, 1e-9), f2(shelf.a1))
    check("K-weighting: shelf a2", near(shelf.a2, 0.73248077421585, 1e-9), f2(shelf.a2))
    check("K-weighting: high-pass numerator", high.b0 == 1 && high.b1 == -2 && high.b2 == 1)
    check("K-weighting: high-pass a1", near(high.a1, -1.99004745483398, 1e-9), f2(high.a1))
    check("K-weighting: high-pass a2", near(high.a2, 0.99007225036621, 1e-9), f2(high.a2))

    var shelf44 = OBJLoudBiquad(), high44 = OBJLoudBiquad()
    objloud_kweighting(44100, &shelf44, &high44)
    check("K-weighting: 44.1 kHz is recomputed, not the 48 kHz set reused",
          abs(shelf44.b0 - shelf.b0) > 1e-4 && abs(high44.a1 - high.a1) > 1e-4)
}

// MARK: - The true-peak table

do {
    guard let s = objloud_create(48000, 2) else { fatalError("create") }
    defer { objloud_destroy(s) }
    var sums: [Double] = []
    withUnsafePointer(to: &s.pointee.tp) { raw in
        raw.withMemoryRebound(to: Double.self, capacity: 48) { c in
            for p in 0..<4 { sums.append((0..<12).reduce(0.0) { $0 + c[p * 12 + $1] }) }
        }
    }
    check("true-peak FIR: phases 0 and 3 are mirror images (same DC gain)", near(sums[0], sums[3], 1e-12), "\(sums)")
    check("true-peak FIR: phases 1 and 2 are mirror images (same DC gain)", near(sums[1], sums[2], 1e-12), "\(sums)")
    check("true-peak FIR: every phase within 3 % of unity (the annex's own ripple)", sums.allSatisfy { abs($0 - 1) < 0.03 }, "\(sums)")
}

// MARK: - Tech 3341 — steady levels

for rate in [48000.0, 44100.0, 88200.0, 96000.0] {
    let c = measure(channels: sineSegments([(20, -23)], sampleRate: rate), sampleRate: rate)
    let a = c.analysis
    let tag = "\(Int(rate)) Hz"
    check("3341 sine -23 dBFS @\(tag): integrated -23", near(a.integrated, -23, 0.1), f2(a.integrated))
    if rate == 48000 || rate == 44100 {
        check("3341 sine -23 dBFS @\(tag): momentary -23", near(a.latestMomentary ?? 0, -23, 0.1), f2(a.latestMomentary ?? 0))
        check("3341 sine -23 dBFS @\(tag): short-term -23", near(a.latestShortTerm ?? 0, -23, 0.1), f2(a.latestShortTerm ?? 0))
        check("3341 sine -23 dBFS @\(tag): 200 sub-blocks", a.blockCount == 200, "\(a.blockCount)")
    }
}

do {
    let c = measure(channels: sineSegments([(20, -33)], sampleRate: 48000), sampleRate: 48000)
    let a = c.analysis
    check("3341 sine -33 dBFS: integrated -33", near(a.integrated, -33, 0.1), f2(a.integrated))
    check("3341 sine -33 dBFS: momentary -33", near(a.latestMomentary ?? 0, -33, 0.1), f2(a.latestMomentary ?? 0))
    check("3341 sine -33 dBFS: short-term -33", near(a.latestShortTerm ?? 0, -33, 0.1), f2(a.latestShortTerm ?? 0))
}

check("sub-blocks come out in order, none missing",
      { let c = measure(channels: sineSegments([(5, -20)], sampleRate: 44100), sampleRate: 44100)
        return c.indices == Array(0..<50) }())

// MARK: - Tech 3341 — the gates

do {
    // -80 is under the absolute gate, -45 is under the relative one (about 11 LU under the rest).
    let seq: [(Double, Double?)] = [(20, -80), (20, -23), (20, -45), (20, -23), (20, -80)]
    let a = measure(channels: sineSegments(seq, sampleRate: 48000), sampleRate: 48000).analysis
    check("gates: absolute AND relative leave -23", near(a.integrated, -23, 0.1), f2(a.integrated))
    // Without the gates the same sequence would read far lower: proof the test bites.
    let mean = a.momentary.reduce(0.0) { $0 + pow(10, ($1 + 0.691) / 10) } / Double(a.momentary.count)
    check("gates: the ungated mean would be way under (the test bites)",
          LoudnessAnalysis.lufs(mean) < -26, f2(LoudnessAnalysis.lufs(mean)))
}

do {
    // A quiet lead-in and tail around 60 s of -23: the relative gate leaves only the loud part.
    let seq: [(Double, Double?)] = [(10, -36), (60, -23), (10, -36)]
    let a = measure(channels: sineSegments(seq, sampleRate: 48000), sampleRate: 48000).analysis
    check("gates: 10 s -36 / 60 s -23 / 10 s -36 reads -23", near(a.integrated, -23, 0.1), f2(a.integrated))
}

do {
    // Tech 3341 case 5: nothing is gated (every block is within 10 LU of the mean), so the
    // integrated value is the plain power mean of the three levels.
    let seq: [(Double, Double?)] = [(20, -26), (20, -20), (20, -26)]
    let a = measure(channels: sineSegments(seq, sampleRate: 48000), sampleRate: 48000).analysis
    check("3341 case 5: -26 / -20 / -26 reads -23", near(a.integrated, -23, 0.1), f2(a.integrated))
}

do {
    // A staircase down from -23: the -23 part is 1/3 of the time, the rest is gated by the
    // relative threshold once it falls 10 LU under the power mean (which is near the loud part).
    let seq: [(Double, Double?)] = [(20, -23), (20, -33), (20, -43), (20, -53)]
    let a = measure(channels: sineSegments(seq, sampleRate: 48000), sampleRate: 48000).analysis
    // power mean of {-23,-33,-43,-53} is about -28.8: threshold -38.8 keeps -23 and -33.
    let expected = LoudnessAnalysis.lufs((pow(10, (-23 + 0.691) / 10) + pow(10, (-33 + 0.691) / 10)) / 2)
    check("gates: staircase keeps exactly the blocks above the relative threshold",
          near(a.integrated, expected, 0.15), "\(f2(a.integrated)) vs \(f2(expected))")
}

// MARK: - Chunking and channels

do {
    let sig = sineSegments([(3, -20)], sampleRate: 48000)
    let a = measure(channels: sig, sampleRate: 48000, chunk: 1).analysis
    let b = measure(channels: sig, sampleRate: 48000, chunk: 480).analysis
    let c = measure(channels: sig, sampleRate: 48000, chunk: 7777).analysis
    let same = zip(a.energies, b.energies).allSatisfy { abs($0 - $1) <= 1e-12 * max(1, abs($0)) }
        && zip(a.energies, c.energies).allSatisfy { abs($0 - $1) <= 1e-12 * max(1, abs($0)) }
        && a.truePeaks == b.truePeaks && a.truePeaks == c.truePeaks
    check("the block size the render uses changes nothing", same && a.blockCount == 30 && b.blockCount == 30)
}

do {
    // One channel: half the energy of the same signal on two.
    let mono = [sineSegments([(20, -20)], sampleRate: 48000)[0]]
    let a = measure(channels: mono, sampleRate: 48000).analysis
    check("mono -20 dBFS reads -23 (one channel, not two)", near(a.integrated, -23.01, 0.1), f2(a.integrated))
}

do {
    // Left only at -20 and right silent: still -23 (one channel carries it).
    var sig = sineSegments([(10, -20)], sampleRate: 48000)
    sig[1] = [Float](repeating: 0, count: sig[0].count)
    let a = measure(channels: sig, sampleRate: 48000).analysis
    check("hard-left -20 dBFS reads -23", near(a.integrated, -23.01, 0.1), f2(a.integrated))
}

// MARK: - True peak

func quarterRateSine(amplitude: Double, seconds: Double, rate: Double, phase: Double) -> [[Float]] {
    let n = Int(seconds * rate)
    var s: [Float] = []
    for i in 0..<n { s.append(Float(amplitude * sin(2 * Double.pi * Double(i) / 4 + phase))) }
    return [s, s]
}

do {
    let amp = 0.5   // -6.0206 dBFS
    let sig = quarterRateSine(amplitude: amp, seconds: 2, rate: 48000, phase: Double.pi / 4)
    let a = measure(channels: sig, sampleRate: 48000).analysis
    let nominal = 20 * log10(amp)
    let samplePeak = 20 * log10(Double(sig[0].map { abs($0) }.max()!))
    check("true peak: fs/4 sine at 45 degrees reads its nominal peak",
          near(a.truePeakDB, nominal, 0.15), "\(f2(a.truePeakDB)) vs \(f2(nominal))")
    check("true peak: the samples themselves are 3 dB lower",
          near(samplePeak, nominal - 3.0103, 0.01) && a.truePeakDB > samplePeak + 2.7,
          "sample \(f2(samplePeak)), true \(f2(a.truePeakDB))")
}

do {
    let sig = quarterRateSine(amplitude: 1.0, seconds: 1, rate: 44100, phase: Double.pi / 4)
    let a = measure(channels: sig, sampleRate: 44100).analysis
    check("true peak: a full-scale fs/4 sine at 45 degrees is about 0 dBTP while its samples are -3",
          near(a.truePeakDB, 0, 0.15), f2(a.truePeakDB))
}

do {
    // A tiny signal on ONE channel and a loud one on the other: the peak is the loudest of both.
    var sig = sineSegments([(2, -40)], sampleRate: 48000)
    sig[1] = sineSegments([(2, -10)], sampleRate: 48000)[0]
    let a = measure(channels: sig, sampleRate: 48000).analysis
    check("true peak: the loudest channel wins", near(a.truePeakDB, -10, 0.15), f2(a.truePeakDB))
}

do {
    // The sub-block carries its own peak: a click in the third second shows in that sub-block only.
    var sig = sineSegments([(5, nil)], sampleRate: 48000)
    sig[0][3 * 48000 + 100] = 0.5
    sig[1] = sig[0]
    let a = measure(channels: sig, sampleRate: 48000).analysis
    let hot = a.truePeaks.enumerated().filter { $0.element > 0.1 }.map(\.offset)
    check("true peak: a click lands in ITS sub-block", hot == [30], "\(hot)")
}

// MARK: - Tech 3342 — loudness range

func lra(_ levels: [Double], seconds: Double = 20) -> Double? {
    let seq = levels.map { (seconds, Optional($0)) }
    return measure(channels: sineSegments(seq, sampleRate: 48000), sampleRate: 48000).analysis.loudnessRange
}

do {
    let cases: [(String, [Double], Double)] = [
        ("-20 / -30", [-20, -30], 10),
        ("-20 / -15", [-20, -15], 5),
        ("-40 / -20", [-40, -20], 20),
        ("-50 / -35 / -20 / -35 / -50", [-50, -35, -20, -35, -50], 15),
    ]
    for (name, levels, expected) in cases {
        let v = lra(levels)
        check("3342 LRA \(name) = \(Int(expected)) LU", v != nil && near(v!, expected, 1.0), v.map(f2) ?? "nil")
    }
}

do {
    let a = measure(channels: sineSegments([(20, -23)], sampleRate: 48000), sampleRate: 48000).analysis
    check("LRA of a steady sine is about 0", (a.loudnessRange ?? 99) < 0.3, "\(a.loudnessRange ?? -1)")
}

// MARK: - Silence and short material

do {
    let a = measure(channels: sineSegments([(10, nil)], sampleRate: 48000), sampleRate: 48000).analysis
    check("silence: integrated is -inf", a.integrated == -.infinity)
    check("silence: LRA is nil", a.loudnessRange == nil)
    check("silence: true peak is -inf", a.truePeakDB == -.infinity)
    check("silence: momentary and short-term are -inf, not nil (their windows exist)",
          a.latestMomentary == -.infinity && a.latestShortTerm == -.infinity)
}

do {
    let a = measure(channels: sineSegments([(0.3, -23)], sampleRate: 48000), sampleRate: 48000).analysis
    check("under 400 ms: no momentary yet", a.latestMomentary == nil && a.blockCount == 3)
    check("under 400 ms: integrated is -inf and LRA nil", a.integrated == -.infinity && a.loudnessRange == nil)

    let b = measure(channels: sineSegments([(2, -23)], sampleRate: 48000), sampleRate: 48000).analysis
    check("under 3 s: a momentary but no short-term", b.latestMomentary != nil && b.latestShortTerm == nil)
    check("under 3 s: no range yet", b.loudnessRange == nil)
}

// MARK: - The running curves

do {
    let seq: [(Double, Double?)] = [(20, -23), (20, -33)]
    let a = measure(channels: sineSegments(seq, sampleRate: 48000), sampleRate: 48000).analysis

    check("curves: as many momentary values as sub-blocks minus 3", a.momentary.count == a.blockCount - 3)
    check("curves: as many short-term values as sub-blocks minus 29", a.shortTerm.count == a.blockCount - 29)
    check("curves: the last integrated point IS the integrated value",
          a.integratedCurve.last == a.integrated, "\(a.integratedCurve.last ?? 0) vs \(a.integrated)")
    check("curves: integrated is -23 at the end of the loud half",
          near(a.integratedCurve[195], -23, 0.1), f2(a.integratedCurve[195]))
    check("curves: the momentary curve steps down at 20 s",
          near(a.momentary[100], -23, 0.1) && near(a.momentary[300], -33, 0.1),
          "\(f2(a.momentary[100])) / \(f2(a.momentary[300]))")
    check("curves: maxima", near(a.momentaryMax, -23, 0.1) && near(a.shortTermMax, -23, 0.1),
          "\(f2(a.momentaryMax)) / \(f2(a.shortTermMax))")
    // The quiet half is only 10 LU under: within the relative gate, so it counts (unlike -45 above).
    let both = LoudnessAnalysis.lufs((pow(10, (-23 + 0.691) / 10) + pow(10, (-33 + 0.691) / 10)) / 2)
    check("curves: a half 10 LU down is still inside the relative gate",
          near(a.integrated, both, 0.15), "\(f2(a.integrated)) vs \(f2(both))")

    let v = a.values(atSubblock: 199)
    check("values(atSubblock:) reads all three at the end of sub-block 199",
          v.momentary != nil && v.shortTerm != nil && v.integrated != nil)
    let early = a.values(atSubblock: 5)
    check("values(atSubblock:) has no short-term at 0.6 s", early.momentary != nil && early.shortTerm == nil)
    check("values(atSubblock:) out of range is empty",
          a.values(atSubblock: -1).momentary == nil && a.values(atSubblock: 9999).momentary == nil)

    let cv = a.curves(points: 50)
    check("curves(points:) cuts down to 50", cv.times.count == 50 && cv.momentary.count == 50
          && cv.shortTerm.count == 50 && cv.integrated.count == 50)
    check("curves(points:) starts nil where a window has not filled, and ends with values",
          cv.momentary.first! == nil || cv.times.first! >= 0.4)
    check("curves(points:) ends at the last instant", near(cv.times.last!, Double(a.blockCount) * 0.1, 1e-9))
    check("curves(points:) never returns more than there are blocks",
          a.curves(points: 100_000).times.count == a.blockCount)
}

do {
    // Feeding one sub-block at a time is the same as all at once (it is how the poll arrives).
    let c = measure(channels: sineSegments([(12, -23), (8, -40)], sampleRate: 48000), sampleRate: 48000)
    var replay = LoudnessAnalysis()
    for (e, p) in zip(c.analysis.energies, c.analysis.truePeaks) { replay.append(energy: e, truePeak: p) }
    check("incremental feeding reproduces the same readings",
          replay.integrated == c.analysis.integrated && replay.loudnessRange == c.analysis.loudnessRange
          && replay.momentary == c.analysis.momentary && replay.integratedCurve == c.analysis.integratedCurve)
    replay.removeAll()
    check("removeAll empties everything", replay.blockCount == 0 && replay.integrated == -.infinity
          && replay.loudnessRange == nil && replay.truePeakDB == -.infinity)
}

do {
    var a = LoudnessAnalysis()
    for _ in 0..<40 { a.append(energy: .nan, truePeak: .nan) }
    check("NaN is treated as silence and poisons nothing", a.integrated == -.infinity && a.truePeakDB == -.infinity
          && a.momentary.allSatisfy { $0 == -.infinity })
}

do {
    // A loud render far over full scale (a float export) saturates the histogram, not the maths.
    var a = LoudnessAnalysis()
    for _ in 0..<40 { a.append(energy: 1000, truePeak: 20) }
    check("a signal over full scale still reads (energy counts in full)",
          near(a.integrated, LoudnessAnalysis.lufs(1000), 0.01), f2(a.integrated))
}

}

// MARK: - Report

@main
enum LoudnessTests {
    static func main() {
        runTests()
        print("")
        if fails.isEmpty {
            print("ALL PASS (\(total) assertions)")
            exit(0)
        } else {
            print("\(fails.count) FAILED out of \(total): \(fails.joined(separator: " | "))")
            exit(1)
        }
    }
}
