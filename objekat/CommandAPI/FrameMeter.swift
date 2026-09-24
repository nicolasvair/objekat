import AppKit
import QuartzCore
import os

/// Counts the frames the timeline's screen really shows, for the navigation commands and
/// `perf.frames.*`.
///
/// Two sources, read together:
///   • a `CADisplayLink` of the timeline's own view — its callbacks come on the main thread, one
///     per refresh of THAT screen (120 Hz on ProMotion, 60 elsewhere), so the gap between two of
///     them is how long a frame really took to come round: a main thread busy for 50 ms shows as
///     one 50 ms interval where there should have been six. The expected interval is read off the
///     link itself, never assumed to be 16.7 ms;
///   • an observer of the main run loop, `afterWaiting` → `beforeWaiting`: how long each turn kept
///     the main thread busy — the WHY behind a late frame.
///
/// No threshold, no verdict: the report hands back distributions, meant to compare two situations
/// (50 objects against 500, a build against the next), not to be judged alone.
@MainActor
final class FrameRecording: NSObject {

    private var link: CADisplayLink?
    private var observer: CFRunLoopObserver?

    /// Timestamps of the display link's callbacks (seconds, host time).
    private(set) var ticks: [CFTimeInterval] = []
    /// Each callback's own `targetTimestamp - timestamp`: what the screen promised.
    private var expectedIntervals: [CFTimeInterval] = []
    /// How long each main run-loop turn stayed busy (seconds).
    private(set) var busy: [Double] = []
    private var turnStart: CFAbsoluteTime? = nil

    private(set) var startedAt = CACurrentMediaTime()
    private(set) var stoppedAt: CFTimeInterval? = nil

    private static let signposter = OSSignposter(subsystem: "com.objekat.perf", category: "frames")
    private var signpostState: OSSignpostIntervalState?
    private let label: StaticString

    init(on view: NSView, label: StaticString = "frames") {
        self.label = label
        super.init()
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link

        let observer = CFRunLoopObserverCreateWithHandler(
            nil, CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue,
            true, 0
        ) { [weak self] _, activity in
            MainActor.assumeIsolated { self?.runLoop(activity) }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer

        startedAt = CACurrentMediaTime()
        signpostState = Self.signposter.beginInterval(label)
    }

    @objc private func tick(_ link: CADisplayLink) {
        ticks.append(link.timestamp)
        let promised = link.targetTimestamp - link.timestamp
        if promised > 0 { expectedIntervals.append(promised) }
    }

    private func runLoop(_ activity: CFRunLoopActivity) {
        let now = CFAbsoluteTimeGetCurrent()
        if activity == .afterWaiting {
            turnStart = now
        } else if activity == .beforeWaiting, let start = turnStart {
            busy.append(now - start)
            turnStart = nil
        }
    }

    /// Stops the recording (idempotent) and hands back the report.
    func stop(includeSamples: Bool = false) -> JSONValue {
        if stoppedAt == nil {
            stoppedAt = CACurrentMediaTime()
            link?.invalidate(); link = nil
            if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
            observer = nil
            if let signpostState { Self.signposter.endInterval(label, signpostState) }
        }
        return report(includeSamples: includeSamples)
    }

    // MARK: - The report

    func report(includeSamples: Bool) -> JSONValue {
        let end = stoppedAt ?? CACurrentMediaTime()
        let duration = end - startedAt
        let intervals = zip(ticks.dropFirst(), ticks).map { $0 - $1 }
        let expected = FrameStats.median(expectedIntervals) ?? FrameStats.median(intervals) ?? 1.0 / 60

        var late = 0, dropped = 0
        var hitchTime = 0.0
        for dt in intervals {
            let frames = (dt / expected).rounded()
            if frames >= 2 { late += 1; dropped += Int(frames) - 1 }
            hitchTime += max(0, dt - expected)
        }

        var o: [String: JSONValue] = [
            "duration_ms": .number(FrameStats.ms(duration)),
            "frames": .int(ticks.count),
            "expected_frame_ms": .number(FrameStats.ms(expected)),
            "refresh_hz": .number((1 / expected).rounded()),
            "fps_mean": .number(duration > 0 ? (Double(ticks.count) / duration * 10).rounded() / 10 : 0),
            "frame_ms": FrameStats.distribution(intervals.map { $0 * 1000 }),
            // A frame that took the time of two or more is one where the screen showed the
            // previous image again. Counted against THIS screen's interval, whatever it is.
            "late_frames": .int(late),
            "dropped_frames_est": .int(dropped),
            "hitch_ms_per_s": .number(duration > 0 ? (hitchTime * 1000 / duration * 100).rounded() / 100 : 0),
            "main_busy_ms": FrameStats.distribution(busy.map { $0 * 1000 }),
            "main_busy_total_ms": .number(FrameStats.ms(busy.reduce(0, +))),
        ]
        if includeSamples {
            o["frame_intervals_ms"] = .array(intervals.map { .number(FrameStats.ms($0)) })
        }
        return .object(o)
    }
}

/// The arithmetic of a report, kept apart from anything with a screen behind it.
enum FrameStats {

    static func ms(_ seconds: Double) -> Double { (seconds * 1_000_000).rounded() / 1000 }

    static func median(_ xs: [Double]) -> Double? { percentile(xs.sorted(), 50) }

    /// Nearest-rank percentile on a SORTED array.
    static func percentile(_ sorted: [Double], _ p: Double) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let rank = Int((p / 100 * Double(sorted.count)).rounded(.up))
        return sorted[min(sorted.count - 1, max(0, rank - 1))]
    }

    /// p50 / p95 / p99 / max / mean of samples already in milliseconds.
    static func distribution(_ samples: [Double]) -> JSONValue {
        guard !samples.isEmpty else { return .null }
        let s = samples.sorted()
        func r(_ v: Double?) -> JSONValue { .number(((v ?? 0) * 1000).rounded() / 1000) }
        return .object([
            "count": .int(s.count),
            "p50": r(percentile(s, 50)), "p95": r(percentile(s, 95)), "p99": r(percentile(s, 99)),
            "max": r(s.last), "mean": r(s.reduce(0, +) / Double(s.count)),
        ])
    }
}
