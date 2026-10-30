import Foundation
import QuartzCore
import Synchronization

// MARK: - The clock the picture follows (plan-video §4.1, §4.2)
//
// THE AUDIO IS THE MASTER. The picture never commands the engine: its whole contact with it is one
// read of the position that is really AUDIBLE, taken on the main thread (Tracktion's rule) through the
// bridge `-[OBJEngineCore videoClockSample:latency:playing:]`.
//
//   position the picture shows = audible (block being rendered, minus the graph's own latency)
//                              − the card's output latency       (the bridge computes it, ONE function)
//                              + the project's A/V offset         (`avOffsetSeconds`, 0 by default)
//
// `currentPlaybackPosition` would not do (a cached value, refreshed at 50 Hz, blind to the card's
// latency). What the main thread publishes is not a position but an ANCHOR — (position, machine time) —
// in a lock-free structure; the display link's own thread EXTRAPOLATES from it with the machine clock.
// That is the whole point of the split: the main thread stalls (the timeline falls to 14 fps when
// zoomed on 480 objects), and an anchor extrapolated elsewhere does not freeze the picture with it.
//
// The anchor is re-based, not trusted blindly: a light filter absorbs the granularity of the audio
// block (10.7 ms at 512/48 kHz), and a jump — a seek, a loop turning round, a stop, the end of the
// start-up latency countdown — re-anchors at once and bumps `epoch`, which the players read as "the
// timeline moved, do not chase it, resynchronise".

/// What the render thread reads: a consistent snapshot of the anchor.
nonisolated struct VideoClockReading: Equatable, Sendable {
    /// Timeline seconds at `hostTime`.
    var position: Double
    /// `CACurrentMediaTime()` at the instant `position` was true.
    var hostTime: Double
    /// True when the position ADVANCES (the transport runs and the audio is really moving).
    var advancing: Bool
    /// Bumped on every jump (seek, loop wrap, stop, start).
    var epoch: UInt64

    /// The timeline position at machine time `host`.
    func position(atHost host: Double) -> Double {
        advancing ? position + (host - hostTime) : position
    }
}

/// A single-writer / many-readers seqlock: the main thread writes, any thread reads, nobody waits.
/// Four words and a counter — the reader retries if it caught the writer mid-way.
nonisolated final class VideoClockAnchor: @unchecked Sendable {
    private let seq = Atomic<UInt64>(0)
    private let positionBits = Atomic<UInt64>(0)
    private let hostBits = Atomic<UInt64>(0)
    private let flags = Atomic<UInt64>(0)      // bit 0: advancing
    private let epochWord = Atomic<UInt64>(0)

    /// Single writer: the main thread.
    func publish(_ r: VideoClockReading) {
        let s = seq.load(ordering: .relaxed)
        seq.store(s &+ 1, ordering: .relaxed)                 // odd: a write is under way
        atomicMemoryFence(ordering: .releasing)
        positionBits.store(r.position.bitPattern, ordering: .relaxed)
        hostBits.store(r.hostTime.bitPattern, ordering: .relaxed)
        flags.store(r.advancing ? 1 : 0, ordering: .relaxed)
        epochWord.store(r.epoch, ordering: .relaxed)
        seq.store(s &+ 2, ordering: .releasing)               // even: published
    }

    /// Any thread. Lock-free: retries while a write is in flight (a handful of nanoseconds).
    func read() -> VideoClockReading {
        while true {
            let s1 = seq.load(ordering: .acquiring)
            if s1 & 1 == 1 { continue }
            let p = positionBits.load(ordering: .relaxed)
            let h = hostBits.load(ordering: .relaxed)
            let f = flags.load(ordering: .relaxed)
            let e = epochWord.load(ordering: .relaxed)
            atomicMemoryFence(ordering: .acquiring)
            let s2 = seq.load(ordering: .relaxed)
            if s1 == s2 {
                return VideoClockReading(position: Double(bitPattern: p), hostTime: Double(bitPattern: h),
                                         advancing: f & 1 == 1, epoch: e)
            }
        }
    }
}

/// The main-thread half: samples the engine and keeps the anchor.
@MainActor
final class VideoClock {

    /// The anchor the render thread extrapolates from.
    nonisolated let anchor = VideoClockAnchor()

    /// The project's A/V offset, seconds (positive = the picture runs LATE compared to the sound, i.e.
    /// the position shown is moved forward). 0 by default (§4.2); not persisted in V1.
    var avOffsetSeconds: Double = 0

    /// What a stopped transport shows: the cursor.
    var stoppedPosition: () -> Double = { 0 }

    /// How often the main thread samples. Well below the block time on purpose: each sample is one
    /// atomic read, and a denser sampling is what lets the filter see a block boundary.
    nonisolated static let sampleInterval: TimeInterval = 1.0 / 120.0

    /// A disagreement between the extrapolation and a sample beyond this is a JUMP, not jitter.
    nonisolated static let jumpThreshold = 0.080
    /// Weight of a sample against the extrapolation when it is only jitter.
    nonisolated static let blend = 0.15
    /// The audible position unchanged for this long while the transport runs is the start-up latency
    /// countdown (or a stall): hold, do not extrapolate ahead of a sound that has not begun.
    nonisolated static let stallAfter = 0.060

    private weak var engine: OBJEngineCore?
    private var timer: Timer?

    // The last decision, for the commands and the filter.
    private(set) var lastAudible = 0.0
    private(set) var lastLatency = 0.0
    private(set) var lastPlaying = false
    private(set) var epoch: UInt64 = 0
    private var current = VideoClockReading(position: 0, hostTime: 0, advancing: false, epoch: 0)
    private var lastChangeHost = 0.0

    init(engine: OBJEngineCore) {
        self.engine = engine
        let now = CACurrentMediaTime()
        current = VideoClockReading(position: 0, hostTime: now, advancing: false, epoch: 0)
        lastChangeHost = now
        anchor.publish(current)
    }

    var isRunning: Bool { timer != nil }

    func start() {
        guard timer == nil else { return }
        reset()
        let t = Timer(timeInterval: Self.sampleInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Forget the anchor and take the next sample as the truth (a seek, a project load, a tab switch).
    func reset() {
        lastPlaying = false          // the next tick re-bases
        tick()
    }

    /// One sample. Exposed so that a command (or a test) can drive it without the timer.
    func tick() {
        guard let engine else { return }
        var audible = 0.0, latency = 0.0
        var playing: ObjCBool = false
        engine.videoClockSample(&audible, latency: &latency, playing: &playing)
        let now = CACurrentMediaTime()
        lastLatency = latency
        let isPlaying = playing.boolValue

        func publish(_ position: Double, advancing: Bool, newEpoch: Bool) {
            if newEpoch { epoch &+= 1 }
            current = VideoClockReading(position: position, hostTime: now, advancing: advancing, epoch: epoch)
            anchor.publish(current)
        }

        // Stopped: the picture shows the cursor, still.
        guard isPlaying else {
            let p = stoppedPosition()
            if current.advancing || abs(p - current.position) > 1e-9 || lastPlaying {
                publish(p, advancing: false, newEpoch: current.advancing || lastPlaying)
            }
            lastPlaying = false
            lastAudible = audible
            lastChangeHost = now
            return
        }

        let sample = audible - latency + avOffsetSeconds

        // Just started (or re-based): hold on the sample until the audio is SEEN to move. During the
        // start-up latency countdown the graph retains the position, and extrapolating ahead of a sound
        // that has not begun would show the picture early and then pull it back.
        guard lastPlaying else {
            publish(sample, advancing: false, newEpoch: true)
            lastPlaying = true
            lastAudible = audible
            lastChangeHost = now
            return
        }

        let moved = abs(audible - lastAudible) > 1e-9
        if moved { lastChangeHost = now }
        lastAudible = audible
        let stalled = (now - lastChangeHost) > Self.stallAfter

        if stalled {
            // The countdown, or a stall: hold at the sample.
            if current.advancing || abs(sample - current.position) > 1e-9 {
                publish(sample, advancing: false, newEpoch: current.advancing)
            }
            return
        }
        if !current.advancing {
            // The first movement after a hold: anchor on it.
            if moved { publish(sample, advancing: true, newEpoch: true) }
            return
        }

        let predicted = current.position(atHost: now)
        let error = sample - predicted
        if abs(error) > Self.jumpThreshold {
            // A seek, the loop turning round: re-anchor and tell the players.
            publish(sample, advancing: true, newEpoch: true)
        } else {
            publish(predicted + Self.blend * error, advancing: true, newEpoch: false)
        }
    }

    /// What the render thread would read right now (for `video.clock`).
    func snapshot() -> VideoClockReading { anchor.read() }
}
