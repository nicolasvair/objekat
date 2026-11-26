// The legacy display link of the preview (below macOS 14, or under `CompatPolicy.forceLegacy`), with
// no window and no app: a `CVDisplayLink` over the active displays ticks for 2 s, and what the preview
// relies on is asserted — the ticks come at the screen's pace (mean interval ≈ 1 / refresh), the
// `outputTime.hostTime` grows strictly, its conversion (`CVLinkClock`) is in the base of
// `CACurrentMediaTime()` (the anchor's) and lies a little ahead of the instant the handler runs.
// With no display at all (a CI box) the test says SKIP and exits 0.
//
// From `tools/`:
//
//     swiftc -target arm64-apple-macos12.0 -parse-as-library ../objekat/Video/CVLinkClock.swift test_video_cvlink.swift \
//         -o /tmp/vcv && /tmp/vcv
//
// Exit: 0 if every assertion passes (or no display), 1 otherwise.

import Foundation
import CoreVideo
import QuartzCore
import CoreGraphics

var fails: [String] = []
var total = 0

func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    total += 1
    if ok { print("ok    " + label) }
    else { fails.append(label); print("FAIL  \(label)  \(detail)") }
}

final class Recorder: @unchecked Sendable {
    let lock = NSLock()
    var now: [Double] = []
    var target: [Double] = []
    var host: [UInt64] = []
    func add(now n: Double, host h: UInt64) {
        lock.lock()
        now.append(n); host.append(h); target.append(CVLinkClock.seconds(hostTime: h))
        lock.unlock()
    }
}

@main
enum VideoCVLinkTest {
  static func main() {
    // The conversion alone: same base as CACurrentMediaTime.
    let m = mach_absolute_time()
    let viaClock = CVLinkClock.seconds(hostTime: m)
    let direct = CACurrentMediaTime()
    check("hostTime in seconds is in the base of CACurrentMediaTime", abs(viaClock - direct) < 0.01,
          "\(viaClock) vs \(direct)")
    check("the conversion is monotone", CVLinkClock.seconds(hostTime: m + 1_000_000) > viaClock)

    var created: CVDisplayLink?
    // The app's own call first; a box with no ACTIVE display (screen asleep, no session) is tried on
    // the main display's id, which is what `setDisplayID` hands the link anyway.
    if CVDisplayLinkCreateWithActiveCGDisplays(&created) != kCVReturnSuccess || created == nil {
        created = nil
        _ = CVDisplayLinkCreateWithCGDisplay(CGMainDisplayID(), &created)
    }
    guard let link = created else {
        print("SKIP  no display: the link ticks cannot be measured here")
        finish(); return
    }
    let nominal = CVDisplayLinkGetNominalOutputVideoRefreshPeriod(link)
    let period = nominal.timeValue > 0 && nominal.timeScale > 0
        ? Double(nominal.timeValue) / Double(nominal.timeScale) : 1.0 / 60.0

    let rec = Recorder()
    CVDisplayLinkSetOutputHandler(link) { _, _, outputTime, _, _ in
        rec.add(now: CACurrentMediaTime(), host: outputTime.pointee.hostTime)
        return kCVReturnSuccess
    }
    check("the link starts", CVDisplayLinkStart(link) == kCVReturnSuccess)
    Thread.sleep(forTimeInterval: 2.0)
    CVDisplayLinkStop(link)

    rec.lock.lock()
    let now = rec.now, tgt = rec.target, host = rec.host
    rec.lock.unlock()

    let expected = 2.0 / period
    check("about one tick per refresh over 2 s (\(now.count) for ~\(Int(expected)))",
          Double(now.count) > expected * 0.8 && Double(now.count) < expected * 1.2,
          "\(now.count) ticks, period \(period)")
    if now.count >= 3 {
        var gaps: [Double] = []
        for i in 1..<now.count { gaps.append(now[i] - now[i - 1]) }
        let mean = gaps.reduce(0, +) / Double(gaps.count)
        check("the mean interval is the refresh period", abs(mean - period) < period * 0.15,
              "mean \(mean) period \(period)")
        var mono = true
        for i in 1..<host.count where host[i] <= host[i - 1] { mono = false }
        check("outputTime.hostTime grows strictly", mono)
        var hostGaps: [Double] = []
        for i in 1..<tgt.count { hostGaps.append(tgt[i] - tgt[i - 1]) }
        let hostMean = hostGaps.reduce(0, +) / Double(hostGaps.count)
        check("the target advances by one refresh per tick", abs(hostMean - period) < period * 0.15,
              "mean \(hostMean) period \(period)")
        var ahead: [Double] = []
        for i in 0..<now.count { ahead.append(tgt[i] - now[i]) }
        let lo = ahead.min() ?? 0, hi = ahead.max() ?? 0
        check("the target lies around the instant the handler runs (-50 ms … +100 ms)",
              lo > -0.050 && hi < 0.100, "min \(lo) max \(hi)")
    } else {
        check("enough ticks to measure", false, "\(now.count)")
    }
    finish()
  }

  static func finish() {
    print("\n\(total - fails.count)/\(total) passed")
    if !fails.isEmpty { print("FAILURES:"); for f in fails { print("  " + f) }; exit(1) }
    exit(0)
  }
}
