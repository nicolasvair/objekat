import Foundation
import AppKit
import QuartzCore
import Metal
import CoreVideo

// MARK: - The display link (plan-video §4.4, §6.3)
//
// A `CAMetalDisplayLink` (macOS 14+) on a thread of its own, at the screen's pace (60 Hz asked, 2
// frames of latency) — or, below macOS 14 and under `CompatPolicy.forceLegacy`, a `CVDisplayLink`
// (macOS 10.4, deprecated only in 15 so it warns nowhere at a deployment target of 12), whose output
// handler runs on CoreVideo's own thread and takes the drawable itself (`nextDrawable`). Either way
// ONE thread is the ONLY consumer of the picture: on each tick it
//   1. reads the clock's anchor (a tiny lock) and extrapolates it to the instant the frame will be on
//      the glass — `targetPresentationTimestamp`, or the output time of the CVDisplayLink's timestamp
//      (`CVLinkClock`: the same machine clock as `CACurrentMediaTime`) — so a stalled main thread does
//      not freeze the picture;
//   2. asks the resolver which pictures that instant shows (over an index copy it owns, swapped under
//      a short lock by the controller — the view-model is never read from here);
//   3. lets the players follow, collects their last frames, and composes them into the drawable with
//      the SAME composer `video.render_frame` uses.
// A tick whose picture is the one already on screen presents nothing (same layers, same buffers, same
// size): a stopped transport costs a clock read and a compare.
//
// The QoS is `.userInitiated`: below the audio thread's real-time class on purpose. If the machine is
// short of time it is the picture that loses a frame.

nonisolated final class VideoDisplay: NSObject, @unchecked Sendable {

    private let layer: CAMetalLayer
    private let composer: VideoComposer
    private let engine: VideoPlayerEngine
    private let anchor: VideoClockAnchor

    private let stateLock = NSLock()
    private var index = VideoObjectIndex()
    /// Identifies the run a render thread belongs to: a thread leaves as soon as it is no longer the current one.
    private var runID = 0
    private var thread: Thread?
    /// A `CAMetalDisplayLink` (macOS 14), held untyped so the class itself stays usable below it.
    private var link: AnyObject?
    /// The legacy link (below macOS 14, or `CompatPolicy.forceLegacy`).
    private var cvLink: CVDisplayLink?
    /// The screen the window is on, once known (`setDisplayID`); nil = CoreVideo's own choice.
    private var displayID: CGDirectDisplayID?

    // Render thread only.
    private var lastSignature: [UInt64] = []
    private var lastWidth = 0, lastHeight = 0
    private var hasPresented = false

    // Counters, read by `video.clock` (relaxed: informative).
    private let statsLock = NSLock()
    private var presented = 0, skipped = 0, ticks = 0
    private var lastLayerCount = 0

    init(layer: CAMetalLayer, composer: VideoComposer, engine: VideoPlayerEngine, anchor: VideoClockAnchor) {
        self.layer = layer
        self.composer = composer
        self.engine = engine
        self.anchor = anchor
        super.init()
    }

    /// Replaces the index the render thread resolves against.
    func setIndex(_ i: VideoObjectIndex) {
        stateLock.lock(); index = i; stateLock.unlock()
    }

    var stats: (ticks: Int, presented: Int, skipped: Int, layers: Int) {
        statsLock.lock(); defer { statsLock.unlock() }
        return (ticks, presented, skipped, lastLayerCount)
    }

    var isRunning: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return thread != nil || cvLink != nil
    }

    /// Which driver is running: "metal" (CAMetalDisplayLink), "cv" (CVDisplayLink) or "none".
    var mode: String {
        stateLock.lock(); defer { stateLock.unlock() }
        if cvLink != nil { return "cv" }
        return thread != nil ? "metal" : "none"
    }

    /// The screen the window sits on: the legacy link follows it (no-op for the other driver, whose
    /// link follows its layer by itself).
    func setDisplayID(_ id: CGDirectDisplayID) {
        stateLock.lock()
        displayID = id
        let l = cvLink
        stateLock.unlock()
        if let l { CVDisplayLinkSetCurrentCGDisplay(l, id) }
    }

    func start() {
        stateLock.lock()
        guard thread == nil, cvLink == nil else { stateLock.unlock(); return }
        runID += 1
        let myRun = runID
        lastSignature = []
        hasPresented = false
        if #available(macOS 14, *), !CompatPolicy.forceLegacy {
            startMetal(run: myRun)       // returns with the lock released
        } else {
            startLegacy(run: myRun)      // returns with the lock released
        }
    }

    /// `CAMetalDisplayLink` on a thread of its own. Called with `stateLock` held, releases it.
    @available(macOS 14, *)
    private func startMetal(run myRun: Int) {
        let ready = DispatchSemaphore(value: 0)
        let th = Thread { [weak self] in
            guard let self else { ready.signal(); return }
            let l = CAMetalDisplayLink(metalLayer: self.layer)
            l.delegate = self
            l.preferredFrameLatency = 2
            l.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
            l.add(to: .current, forMode: .common)
            self.stateLock.lock(); self.link = l; self.stateLock.unlock()
            ready.signal()
            while true {
                self.stateLock.lock(); let alive = self.runID == myRun && self.thread != nil; self.stateLock.unlock()
                if !alive { break }
                RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
            }
            l.invalidate()
            self.stateLock.lock(); if self.runID == myRun { self.link = nil }; self.stateLock.unlock()
        }
        th.name = "objekat.video.display"
        th.qualityOfService = .userInitiated
        thread = th
        stateLock.unlock()
        th.start()
        ready.wait()
    }

    /// `CVDisplayLink`: its output handler runs on CoreVideo's own thread, once per refresh of the
    /// screen it is attached to. Called with `stateLock` held, releases it.
    private func startLegacy(run myRun: Int) {
        var created: CVDisplayLink?
        guard CVDisplayLinkCreateWithActiveCGDisplays(&created) == kCVReturnSuccess, let l = created else {
            stateLock.unlock()
            return
        }
        if let id = displayID { CVDisplayLinkSetCurrentCGDisplay(l, id) }
        CVDisplayLinkSetOutputHandler(l) { [weak self] _, _, outputTime, _, _ in
            self?.legacyTick(run: myRun, outputTime: outputTime.pointee)
            return kCVReturnSuccess
        }
        cvLink = l
        stateLock.unlock()
        CVDisplayLinkStart(l)
    }

    func stop() {
        stateLock.lock()
        runID += 1
        thread = nil
        let legacy = cvLink
        cvLink = nil
        stateLock.unlock()
        // The Metal thread leaves within one run-loop slice; the link is invalidated there.
        if let legacy { CVDisplayLinkStop(legacy) }
    }

    /// One refresh of the legacy link: the target is the instant the frame will be on the glass.
    private func legacyTick(run myRun: Int, outputTime: CVTimeStamp) {
        stateLock.lock(); let alive = runID == myRun && cvLink != nil; stateLock.unlock()
        guard alive else { return }
        let target = outputTime.hostTime != 0 ? CVLinkClock.seconds(hostTime: outputTime.hostTime)
                                              : CACurrentMediaTime() + 1.0 / 60.0
        let size = layer.drawableSize
        autoreleasepool {
            render(target: target, width: Int(size.width), height: Int(size.height),
                   drawable: { self.layer.nextDrawable() })
        }
    }

    // MARK: One tick

    /// What one display tick does, whatever drives it: resolve the picture at `target` (machine time
    /// the frame will be on the glass), follow with the players, compose into the drawable.
    /// `width`/`height` are the target's size in pixels, known BEFORE a drawable is taken: a tick that
    /// changes nothing never asks for one (the legacy link would otherwise acquire and drop a drawable
    /// at every refresh).
    fileprivate func render(target: Double, width: Int, height: Int, drawable: () -> CAMetalDrawable?) {
        let now = CACurrentMediaTime()
        let reading = anchor.read()
        let t = reading.position(atHost: target)
        stateLock.lock(); let idx = index; stateLock.unlock()
        let layers = VideoResolver.layers(at: t, in: idx)
        let prepared = engine.prepare(layers: layers, reading: reading, target: target, now: now)

        let changed = prepared.signature != lastSignature || width != lastWidth
            || height != lastHeight || !hasPresented
        statsLock.lock()
        ticks += 1
        lastLayerCount = layers.count
        if changed { presented += 1 } else { skipped += 1 }
        statsLock.unlock()
        guard changed, let drawable = drawable() else { return }
        lastSignature = prepared.signature
        lastWidth = width
        lastHeight = height
        hasPresented = true

        guard let cb = composer.queue.makeCommandBuffer() else { return }
        composer.encode(prepared.inputs, into: drawable.texture, commandBuffer: cb)
        cb.present(drawable)
        cb.commit()
    }
}

// MARK: CAMetalDisplayLinkDelegate (macOS 14+)

@available(macOS 14, *)
nonisolated extension VideoDisplay: CAMetalDisplayLinkDelegate {
    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        let tex = update.drawable.texture
        render(target: update.targetPresentationTimestamp, width: tex.width, height: tex.height,
               drawable: { update.drawable })
    }
}
