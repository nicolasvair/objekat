import Foundation
import AVFoundation
import CoreVideo
import CoreImage
import QuartzCore

// MARK: - The players behind the picture (plan-video §4.4, §6.2)
//
// ONE muted `AVPlayer` per active layer, two at most. The picture is read through an
// `AVPlayerItemVideoOutput` (`suppressesPlayerRendering`, so that the player draws nothing by itself)
// and the display link asks it for the frame of the instant IT computed from the clock — never the
// player's own idea of "now". The player is only kept NEAR that instant: when it runs and strays by
// more than `driftThreshold` it is re-synchronised by a seek, which is the "correction by seek if the
// gap is too large" of the plan. The audio is the master and nothing here ever commands the engine.
//
// What V0 measured, and the shape that follows from it:
//   - to start a player at a given machine instant: exact seek, `preroll(atRate:)`, then
//     `setRate(_:time:atHostTime:)` — the three in this order, the host time taken AFTER the preroll;
//   - a time given as a Double on a frame boundary can land on the previous frame: every request is
//     moved by `frameEpsilon` into the middle of its frame;
//   - `hasNewPixelBuffer` is false for a frame already copied, so the last buffer is KEPT and shown
//     again (that is also "only the last frame is kept": one buffer per slot, never a queue);
//   - a player that is stopped must be finished with before another takes its place: recycling a slot
//     always invalidates the old one first, on the thread that creates the new one;
//   - the output does not apply the track's `preferredTransform`: the orientation is read from the
//     track and handed to the composer.
//
// THREADS. Every method of `VideoPlayerSlot` and `VideoPlayerEngine` that decides something is called
// from ONE thread at a time (the display link's, or the caller of a still); AVFoundation completion
// handlers come back on its own queues, hence the recursive lock. Nothing here calls the audio engine
// and nothing here runs on the main thread except `flush()`.

nonisolated final class VideoPlayerSlot: @unchecked Sendable {

    /// A frame lies in [pts, pts + 1/fps[: asking for the middle-ish of it, 0.5 ms past the boundary,
    /// is robust to the rounding of a Double to a CMTime (V0 trap).
    static let frameEpsilon = 0.0005
    /// A running player further than this from where it should be is re-synchronised.
    static let driftThreshold = 0.06
    /// While scrubbing, a request that follows the previous one within this delay is "fast": its seek
    /// may land on a nearby key frame.
    static let fastScrub = 0.10
    static let fastTolerance = 0.25
    /// Once nothing has moved for this long, a fast seek is refined by an exact one.
    static let refineAfter = 0.12

    private static let counter = NSLock()
    nonisolated(unsafe) private static var nextID: UInt64 = 0
    private static func newID() -> UInt64 {
        counter.lock(); defer { counter.unlock() }
        nextID &+= 1
        return nextID
    }

    let id = VideoPlayerSlot.newID()
    let path: String
    /// The picture object this slot was last assigned to (a hint for the matching only).
    var objectID: UUID?
    /// `CACurrentMediaTime()` of the last tick that used it: the recycling order.
    var lastUse = 0.0

    private let asset: AVURLAsset
    private let player = AVPlayer()
    private let item: AVPlayerItem
    private let output: AVPlayerItemVideoOutput
    private let lock = NSRecursiveLock()

    // Everything below is guarded by `lock`.
    private var orientation: CGImagePropertyOrientation = .up
    private var orientationLoaded = false
    private var lastBuffer: CVPixelBuffer?
    private var bufferSerial: UInt64 = 0
    private var invalid = false
    /// Bumped by everything that cancels what is in flight (a pause, a scrub, an invalidation).
    private var generation: UInt64 = 0
    // Playback.
    private var running = false
    private var runningRate = 0.0
    private var runningEpoch: UInt64 = 0
    private var syncing = false
    private var plan = (s0: 0.0, h0: 0.0, rate: 1.0)
    // Scrub.
    private var seeking = false
    private var pendingSeek: (time: Double, tolerant: Bool)?
    private var requestedTime: Double?
    private var lastRequestAt = 0.0
    private var lastSeekWasTolerant = false

    init(path: String) {
        self.path = path
        asset = AVURLAsset(url: URL(fileURLWithPath: path))
        item = AVPlayerItem(asset: asset)
        output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true])
        output.suppressesPlayerRendering = true
        item.add(output)
        player.automaticallyWaitsToMinimizeStalling = false
        player.isMuted = true
        player.replaceCurrentItem(with: item)
        let asset = self.asset
        Task.detached(priority: .userInitiated) { [weak self] in
            var o = CGImagePropertyOrientation.up
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let t = try? await track.load(.preferredTransform) {
                o = Self.orientation(of: t)
            }
            self?.setOrientation(o)
        }
    }

    /// The EXIF-style orientation a track's `preferredTransform` asks for. Only the four rotations —
    /// a mirrored track is shown as it is (V1).
    static func orientation(of t: CGAffineTransform) -> CGImagePropertyOrientation {
        let a = Int(t.a.rounded()), b = Int(t.b.rounded()), c = Int(t.c.rounded()), d = Int(t.d.rounded())
        switch (a, b, c, d) {
        case (0, 1, -1, 0): return .right
        case (0, -1, 1, 0): return .left
        case (-1, 0, 0, -1): return .down
        default: return .up
        }
    }

    private func setOrientation(_ o: CGImagePropertyOrientation) {
        lock.lock(); orientation = o; orientationLoaded = true; lock.unlock()
    }

    private func cm(_ t: Double) -> CMTime { CMTime(seconds: t, preferredTimescale: 90_000) }

    /// The item is loaded and the orientation known: frames can be asked for.
    var isReady: Bool {
        lock.lock(); defer { lock.unlock() }
        return !invalid && orientationLoaded && item.status == .readyToPlay
    }
    var hasFailed: Bool { item.status == .failed }

    // MARK: Frames

    /// The frame for the SOURCE instant `s`: a new one if the output has it, otherwise the last one
    /// kept. nil until the first frame has arrived.
    func frame(forSource s: Double) -> (buffer: CVPixelBuffer, orientation: CGImagePropertyOrientation, serial: UInt64)? {
        let t = cm(max(0, s) + Self.frameEpsilon)
        if output.hasNewPixelBuffer(forItemTime: t) {
            var shown = CMTime.invalid
            if let pb = output.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: &shown) {
                lock.lock(); lastBuffer = pb; bufferSerial &+= 1; lock.unlock()
            }
        }
        lock.lock(); defer { lock.unlock() }
        guard let b = lastBuffer else { return nil }
        return (b, orientation, bufferSerial)
    }

    // MARK: Playing

    /// Keeps the player running in step with the timeline. `s` is the source instant at machine time
    /// `target`; `now` is the machine time of this call.
    func follow(source s: Double, rate: Double, target: Double, now: Double, epoch: UInt64) {
        lock.lock(); defer { lock.unlock() }
        guard isReady else { return }
        plan = (s, target, rate)
        pendingSeek = nil
        requestedTime = nil
        if syncing { return }
        var needs = !running || runningRate != rate || runningEpoch != epoch
        if !needs {
            if abs(Double(player.rate)) < 0.001 {
                needs = true                                    // stalled, or ran off the end
            } else {
                let expected = s + rate * (now - target)
                needs = abs(player.currentTime().seconds - expected) > Self.driftThreshold
            }
        }
        guard needs else { return }

        // Re-synchronise: exact seek a little ahead, preroll, then start at a machine instant taken
        // AFTER the preroll (V0).
        generation &+= 1
        let gen = generation
        syncing = true
        running = false
        let ahead = max(0, s + rate * (now - target + 0.10))
        player.seek(to: cm(ahead), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            guard let self else { return }
            self.lock.lock()
            guard !self.invalid, self.generation == gen, finished else {
                if self.generation == gen { self.syncing = false }
                self.lock.unlock()
                return
            }
            self.lock.unlock()
            self.player.preroll(atRate: Float(rate)) { [weak self] ok in
                guard let self else { return }
                self.lock.lock(); defer { self.lock.unlock() }
                guard !self.invalid, self.generation == gen else { return }
                guard ok else { self.syncing = false; return }
                let h2 = CACurrentMediaTime() + 0.02
                let sAt = max(0, self.plan.s0 + self.plan.rate * (h2 - self.plan.h0))
                self.player.setRate(Float(rate), time: self.cm(sAt),
                                    atHostTime: CMTime(seconds: h2, preferredTimescale: 1_000_000_000))
                self.running = true
                self.runningRate = rate
                self.runningEpoch = epoch
                self.syncing = false
            }
        }
    }

    // MARK: Scrubbing (stopped, or an instant the player cannot run)

    /// Shows the source instant `s` while the transport is stopped. The latest request wins: one seek
    /// is in flight at a time and the newest target replaces any that was waiting.
    func scrub(to s: Double, now: Double) {
        lock.lock(); defer { lock.unlock() }
        if running || syncing {
            generation &+= 1
            running = false
            syncing = false
            requestedTime = nil
            player.pause()
        }
        guard isReady else { return }
        if let r = requestedTime, abs(r - s) < 1e-6 {
            // Nothing new: refine a fast seek once the hand has been still for a moment.
            if lastSeekWasTolerant, !seeking, pendingSeek == nil, now - lastRequestAt > Self.refineAfter {
                pendingSeek = (s, false)
                kick()
            }
            return
        }
        let fast = (now - lastRequestAt) < Self.fastScrub
        requestedTime = s
        lastRequestAt = now
        pendingSeek = (s, fast)
        kick()
    }

    private func kick() {
        guard !seeking, let req = pendingSeek else { return }
        pendingSeek = nil
        seeking = true
        lastSeekWasTolerant = req.tolerant
        let tol = req.tolerant ? CMTime(seconds: Self.fastTolerance, preferredTimescale: 600) : CMTime.zero
        player.seek(to: cm(max(0, req.time)), toleranceBefore: tol, toleranceAfter: tol) { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            self.seeking = false
            if !self.invalid { self.kick() }
            self.lock.unlock()
        }
    }

    // MARK: Parking and ending

    /// Stops the player but keeps it for a quick return.
    func park() {
        lock.lock(); defer { lock.unlock() }
        guard running || syncing || seeking || pendingSeek != nil else { return }
        generation &+= 1
        running = false
        syncing = false
        pendingSeek = nil
        requestedTime = nil
        player.pause()
    }

    /// Ends the slot for good. Safe to call twice.
    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        guard !invalid else { return }
        invalid = true
        generation &+= 1
        running = false
        syncing = false
        pendingSeek = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        lastBuffer = nil
    }

    // MARK: A still

    /// Blocks until the exact frame for `s` is in hand, or `timeout` runs out. For `video.render_frame`
    /// — never called from the display thread.
    func exactFrame(forSource s: Double, timeout: Double) -> (buffer: CVPixelBuffer, orientation: CGImagePropertyOrientation)? {
        let t0 = CACurrentMediaTime()
        while !isReady {
            if hasFailed || CACurrentMediaTime() - t0 > timeout { return nil }
            usleep(2_000)
        }
        player.pause()
        let done = DispatchSemaphore(value: 0)
        player.seek(to: cm(max(0, s) + Self.frameEpsilon), toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            done.signal()
        }
        let remaining = max(0.1, timeout - (CACurrentMediaTime() - t0))
        if done.wait(timeout: .now() + remaining) == .timedOut { return nil }
        while CACurrentMediaTime() - t0 < timeout {
            if let f = frame(forSource: s) { return (f.buffer, f.orientation) }
            usleep(2_000)
        }
        return nil
    }
}

// MARK: - The set of slots

/// Two slots at most, assigned to the layers of each tick. Called by one thread at a time (the
/// display link's); `flush()` takes the same lock from the main thread.
nonisolated final class VideoPlayerEngine: @unchecked Sendable {

    private let lock = NSLock()
    private var slots: [VideoPlayerSlot] = []

    /// What a tick yields: the inputs to compose (bottom first) and a signature of them, equal from one
    /// tick to the next when nothing visible has changed.
    struct Prepared {
        var inputs: [VideoComposer.Input] = []
        var signature: [UInt64] = []
    }

    /// Positions the players for the layers of the tick and collects their frames.
    /// - Parameters:
    ///   - reading: the clock's anchor; `advancing` says playing or stopped.
    ///   - target: machine time at which the picture will be on screen.
    func prepare(layers: [VideoLayer], reading: VideoClockReading, target: Double, now: Double) -> Prepared {
        lock.lock(); defer { lock.unlock() }
        let assigned = assign(layers, now: now)
        var out = Prepared()
        for (layer, slot) in zip(layers, assigned) {
            slot.lastUse = now
            slot.objectID = layer.objectID
            if reading.advancing && !layer.isReversed && layer.rate > 0 {
                slot.follow(source: layer.sourceTime, rate: layer.rate, target: target, now: now,
                            epoch: reading.epoch)
            } else {
                slot.scrub(to: layer.sourceTime, now: now)
            }
            if let f = slot.frame(forSource: layer.sourceTime) {
                out.inputs.append(VideoComposer.Input(buffer: f.buffer, orientation: f.orientation,
                                                      opacity: layer.opacity))
                out.signature.append(slot.id)
                out.signature.append(f.serial)
                out.signature.append(layer.opacity.bitPattern)
            }
        }
        let used = Set(assigned.map(\.id))
        for s in slots where !used.contains(s.id) { s.park() }
        return out
    }

    /// One slot per layer: the one already on this object, else on this file, else a free one, else
    /// the least recently used (recycled — the old player is ended before the new one begins).
    private func assign(_ layers: [VideoLayer], now: Double) -> [VideoPlayerSlot] {
        var result: [VideoPlayerSlot?] = Array(repeating: nil, count: layers.count)
        var taken = Set<UInt64>()
        for (i, l) in layers.enumerated() {
            if let s = slots.first(where: { !taken.contains($0.id) && $0.path == l.filePath && $0.objectID == l.objectID }) {
                result[i] = s; taken.insert(s.id)
            }
        }
        for (i, l) in layers.enumerated() where result[i] == nil {
            if let s = slots.first(where: { !taken.contains($0.id) && $0.path == l.filePath }) {
                result[i] = s; taken.insert(s.id)
            }
        }
        for (i, l) in layers.enumerated() where result[i] == nil {
            if slots.count < VideoResolver.maxLayers {
                let s = VideoPlayerSlot(path: l.filePath)
                slots.append(s)
                result[i] = s; taken.insert(s.id)
            } else if let victim = slots.filter({ !taken.contains($0.id) }).min(by: { $0.lastUse < $1.lastUse }),
                      let at = slots.firstIndex(where: { $0.id == victim.id }) {
                victim.invalidate()
                let s = VideoPlayerSlot(path: l.filePath)
                slots[at] = s
                result[i] = s; taken.insert(s.id)
            }
        }
        return result.compactMap { $0 }
    }

    /// Ends every player (a project load, a window closing). Main thread or any.
    func flush() {
        lock.lock(); defer { lock.unlock() }
        for s in slots { s.invalidate() }
        slots.removeAll()
    }

    var activeSlotCount: Int {
        lock.lock(); defer { lock.unlock() }
        return slots.count
    }

    // MARK: A still, through the same composition

    /// The picture at the layers' instants, off screen, through THE composer the display link uses.
    /// Blocks (decoding an exact frame takes tens of milliseconds): call it away from the main thread.
    /// Each call uses its own short-lived players, so it never disturbs the preview's.
    static func renderStill(layers: [VideoLayer], size: CGSize, composer: VideoComposer,
                            timeout: Double = 8) -> (image: CGImage?, shown: Int)? {
        var inputs: [VideoComposer.Input] = []
        let temp = layers.map { VideoPlayerSlot(path: $0.filePath) }
        defer { temp.forEach { $0.invalidate() } }
        for (l, slot) in zip(layers, temp) {
            if let f = slot.exactFrame(forSource: l.sourceTime, timeout: timeout) {
                inputs.append(VideoComposer.Input(buffer: f.buffer, orientation: f.orientation, opacity: l.opacity))
            }
        }
        let image = composer.renderStill(inputs, size: size)
        return (image, inputs.count)
    }
}
