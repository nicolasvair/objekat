import Foundation
import QuartzCore

// MARK: - The preview's owner (plan-video §4.4, §6)
//
// One object ties the pieces together and knows the session: the clock (main-thread half), the
// players, the composer and the display link. It is the ONLY place that reads the view-model for the
// picture, and it does so on the main thread, a few times a second, handing the render thread a COPY
// of the index — the render thread never touches the document.
//
//   - The window (`VideoPreviewWindow`) gives it a `CAMetalLayer` with `attach(layer:)` and takes it
//     back with `detach()`. Nothing runs while no layer is attached: no timer, no link, no player.
//   - `watch()` runs at 10 Hz as long as there is an interface. It carries the index across and
//     notices two things: a project (re)load — which ends every player, so that none is opened
//     before the load is finished (a player opened on a half-built document would decode for
//     nothing) — and the first picture object appearing, which asks the window to show itself.
//   - Under `--headless` it is never started: there is no window and nothing to watch. The commands
//     (`video.layers`, `video.render_frame`, `video.clock`) read the view-model directly and use the
//     SAME resolver and composer.

@MainActor
final class VideoPreviewController {

    private unowned let session: ObjekatSession

    let clock: VideoClock
    let engine = VideoPlayerEngine()
    /// nil only where Metal is unavailable.
    let composer: VideoComposer?

    private var display: VideoDisplay?
    private(set) var attachedLayer: CAMetalLayer?
    private var watchTimer: Timer?

    private var lastWrites = -1
    private var lastAudibility = -1
    private var lastToken = -1
    private var wasLoading = false
    private var hadPicture = false

    /// Called (once per appearance) when a picture object shows up in the document and the preview is
    /// closed. The window installs it.
    var showRequest: (() -> Void)?

    init(session: ObjekatSession) {
        self.session = session
        clock = VideoClock(engine: session.engine)
        composer = VideoComposer()
        clock.stoppedPosition = { [weak session] in session?.displayedPosition ?? 0 }
        if let composer {
            DispatchQueue.global(qos: .utility).async { composer.prewarm() }
        }
    }

    var isOpen: Bool { attachedLayer != nil }

    // MARK: Watching

    /// Starts the 10 Hz watch. Idempotent; never called without an interface.
    func startWatching() {
        guard watchTimer == nil else { return }
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.watch() }
        }
        RunLoop.main.add(t, forMode: .common)
        watchTimer = t
    }

    func watch() {
        let vm = session.viewModel
        if vm.isLoadingProject {
            if !wasLoading {
                wasLoading = true
                engine.flush()
                display?.setIndex(VideoObjectIndex())
            }
            return
        }
        let reloaded = wasLoading || vm.projectLoadToken != lastToken
        wasLoading = false
        if reloaded {
            lastToken = vm.projectLoadToken
            engine.flush()
            lastWrites = -1
            lastAudibility = -1
            hadPicture = false
            clock.reset()
        }
        guard vm.itemsWriteCount != lastWrites || vm.videoAudibilityRevision != lastAudibility else { return }
        lastWrites = vm.itemsWriteCount
        lastAudibility = vm.videoAudibilityRevision
        let index = vm.videoObjectIndex
        display?.setIndex(index)
        let has = !index.isEmpty
        if has && !hadPicture && !isOpen { showRequest?() }
        hadPicture = has
    }

    // MARK: The window's side

    /// Starts the clock, the players and the display link on `layer`.
    func attach(layer: CAMetalLayer) {
        detach()
        guard let composer else { return }
        layer.device = composer.device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = false
        layer.maximumDrawableCount = 3
        layer.displaySyncEnabled = true
        attachedLayer = layer
        let d = VideoDisplay(layer: layer, composer: composer, engine: engine, anchor: clock.anchor)
        d.setIndex(session.viewModel.videoObjectIndex)
        display = d
        session.viewModel.videoFadePreviewSink = { [weak self] index in self?.display?.setIndex(index) }
        clock.start()
        d.start()
    }

    func detach() {
        session.viewModel.videoFadePreviewSink = nil
        display?.stop()
        display = nil
        clock.stop()
        engine.flush()
        attachedLayer = nil
    }

    // MARK: For the commands

    var displayStats: (ticks: Int, presented: Int, skipped: Int, layers: Int)? { display?.stats }

    /// "metal", "cv" or "none" (no window): which driver feeds the preview.
    var displayMode: String { display?.mode ?? "none" }

    /// The screen the window is on: the legacy link (CVDisplayLink) follows it.
    func setDisplayID(_ id: CGDirectDisplayID) { display?.setDisplayID(id) }
}
