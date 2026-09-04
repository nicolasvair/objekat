import Foundation
import Observation

/// An Objekat session: the engine, the document, and the TRANSPORT state that ties them.
///
/// WHY THIS TYPE — that transport state (`isPlaying`, playhead position, pause, temporary solo,
/// the Tracktion loop) used to live as `@State` in `ContentView`. Two consequences: it only
/// existed while a view was showing it, and nothing outside the view could read or write it —
/// a `transport.play` command did start the sound, but the button stayed on ▶ and the playhead
/// did not run, since nobody had touched the view's `@State`.
///
/// Lifted up here, the same truth serves the interface AND external driving: `ContentView`
/// OBSERVES it instead of owning it, and the commands call the same methods as the buttons. It
/// is also what will make a windowless mode possible — the session needs no view at all to run.
@MainActor
@Observable
final class ObjekatSession {

    let engine: OBJEngineCore
    let viewModel: EditViewModel

    // MARK: - Transport state

    var isPlaying = false
    var playheadPosition: Double = 0

    /// Playback suspended by ⇧space: the position where it was cut, and where it will resume.
    /// nil = not paused (a normal stop, or playback under way).
    var pausedAt: Double? = nil

    /// The end (in seconds) of the temporary solo window during playback; nil = no temporary solo,
    /// or playback to the end. The playhead tick stops playback when it reaches it.
    var tempSoloEnd: Double? = nil

    /// Distinct from `viewModel.loopModeEnabled`: that one is the user's INTENT (it can be true
    /// before the loopIn is even reached), this one only becomes true once the Tracktion engine is
    /// really looping.
    var tracktionLoopActive = false

    /// The playhead's refresh rate. Unchanged (50 ms).
    private static let playheadInterval: TimeInterval = 0.05
    private var playheadTimer: Timer?

    // MARK: - Lifecycle

    /// The default values are `nil` and not `OBJEngineCore()` / `EditViewModel()`: a default value
    /// is evaluated AT THE CALL SITE, hence outside the class's `@MainActor`, while those two
    /// initialisers are isolated to it. Built in the body, we really are isolated.
    init(engine: OBJEngineCore? = nil, viewModel: EditViewModel? = nil) {
        self.engine = engine ?? OBJEngineCore()
        self.viewModel = viewModel ?? EditViewModel()
    }

    /// Wires the engine to the document and arms the playhead tracking. Idempotent: callable from
    /// the view's `.onAppear` as from a windowless launch.
    func start() {
        viewModel.engine = engine
        guard playheadTimer == nil else { return }
        // `.common` mode — and not the default one: without it, the playhead freezes while tracking
        // a menu or scrolling. It was already the mode of the view's `Timer.publish`, and keeping it
        // is what makes the movement invisible on screen.
        let timer = Timer(timeInterval: Self.playheadInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickPlayhead() }
        }
        RunLoop.main.add(timer, forMode: .common)
        playheadTimer = timer
    }

    func stopSession() {
        playheadTimer?.invalidate()
        playheadTimer = nil
    }

    // MARK: - Playhead tracking

    /// One tick: advances the playhead, stops at the end of a temporary solo window, and arms the
    /// Tracktion loop when the playhead enters the region.
    func tickPlayhead() {
        guard isPlaying else { return }
        playheadPosition = engine.currentPlaybackPosition()
        // An automated parameter moves on its own during playback: the inspector has to show that,
        // not the static setting the curve has replaced.
        viewModel.refreshLiveAutomation(at: playheadPosition)

        // Temporary solo over a range: an automatic stop at the end of the window.
        if let end = tempSoloEnd, playheadPosition >= end {
            stop()
            return
        }

        // Objekat's loop mode is on but Tracktion is not looping yet: we turn it on as soon as the
        // playhead ENTERS the region. The end bound is EXCLUDED — a cursor sitting exactly on the
        // loop's end is AFTER it (like a clip's right edge), and we read straight on.
        if viewModel.loopModeEnabled,
           !tracktionLoopActive,
           let r = viewModel.loopRegion,
           playheadPosition >= r.lowerBound,
           playheadPosition < r.upperBound {
            engine.setTracktionLoopRegionFrom(r.lowerBound, to: r.upperBound)
            engine.activateTracktionLoop()
            tracktionLoopActive = true
        }
    }

    // MARK: - Transport commands

    /// Normal playback: clears any temporary solo (restoring the mix / the committed solo).
    func play() {
        viewModel.endTemporarySolo()
        tempSoloEnd = nil
        pausedAt = nil   // a plain playback starts from the cursor, not from the pause
        playheadPosition = viewModel.cursorPosition
        engine.seek(to: playheadPosition)
        isPlaying = true
        engine.play()
    }

    /// ⇧+space: arms the temporary solo (through the view-model) and plays the selection/range —
    /// added to whatever is already soloed, the two layers summing.
    func soloPlay() {
        guard let win = viewModel.beginTemporarySolo() else { return }
        tempSoloEnd = win.end
        playheadPosition = win.start
        engine.seek(to: win.start)
        isPlaying = true
        engine.play()
    }

    /// ⇧space: suspends playback WITHOUT moving the playhead, and resumes exactly there.
    /// Any temporary solo is kept during the suspension — resuming must give back the same
    /// listening as before. On a plain stop (space), everything returns to the cursor.
    func togglePause() {
        if isPlaying {
            engine.stop()
            isPlaying = false
            pausedAt = playheadPosition
        } else {
            let t = pausedAt ?? playheadPosition
            pausedAt = nil
            playheadPosition = t
            engine.seek(to: t)
            isPlaying = true
            engine.play()
        }
    }

    func stop() {
        engine.stop()
        isPlaying = false
        pausedAt = nil
        // End of playback: clears the temporary solo (restoring the mix / the committed solo).
        viewModel.endTemporarySolo()
        tempSoloEnd = nil
        playheadPosition = viewModel.cursorPosition
        // Resets the Tracktion loop for the next play (`loopModeEnabled` stays untouched — that is
        // the user's intent).
        if tracktionLoopActive {
            engine.deactivateTracktionLoop()
            tracktionLoopActive = false
        }
    }

    func returnToZero() {
        engine.stop()
        engine.seek(to: 0)
        isPlaying = false
        pausedAt = nil
        playheadPosition = 0
        viewModel.cursorPosition = 0
    }

    /// Moves the cursor AND the playhead. It is the path `transport.seek` takes: setting the
    /// cursor without moving the playhead would leave the screen at odds with the engine.
    func seek(to seconds: Double) {
        let t = max(0, seconds)
        viewModel.cursorPosition = t
        playheadPosition = t
        pausedAt = nil
        engine.seek(to: t)
    }

    // MARK: - Reacting to changes in the document

    /// `viewModel.seekRequest` is the channel through which the interface asks for a move.
    /// Drains the pending request, if there is one.
    func applyPendingSeekRequest() {
        guard let req = viewModel.seekRequest else { return }
        viewModel.cursorPosition = req
        viewModel.seekRequest = nil
    }

    /// Resyncs the Tracktion region on the fly if the engine loop is already active.
    func loopRegionChanged(_ newRegion: ClosedRange<Double>?) {
        if tracktionLoopActive, let r = newRegion {
            engine.setTracktionLoopRegionFrom(r.lowerBound, to: r.upperBound)
        }
    }

    /// Loop mode switched off during playback: we cut the Tracktion loop straight away, without
    /// waiting for the next stop.
    func loopModeChanged(_ enabled: Bool) {
        if !enabled && tracktionLoopActive {
            engine.deactivateTracktionLoop()
            tracktionLoopActive = false
        }
    }
}
