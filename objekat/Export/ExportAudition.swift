import AVFoundation
import Observation

// LISTENING TO AN EXPORT WHILE IT IS BEING MADE.
//
// Not a monitor of the render: the render runs as fast as it can, which is rarely real time. This
// plays the BEGINNING of the file that is being written, at its own speed, while the rest goes on
// being rendered behind it. So one hears what came out, minutes before the file is finished — and
// a fade, a transition or a mastering chain can be judged without waiting for the end.
//
// WHAT MAKES IT CHEAP, and it is worth knowing before touching anything here: the engine's
// temporary wave is a VALID wave from end to end. Tracktion's `AudioFileWriter` rewrites the
// header with the current length every six seconds of audio (`numSamplesPerFlush`) and seeks back
// to go on writing — so a plain `AVAudioFile` opened on the file in progress reads exactly what
// has been flushed, and reading it again later sees more. No engine patch, no partial-header
// parsing, no second copy of the audio in memory: the file is the buffer.
//
// The price of that is granularity: nothing can be heard before the first flush, so the first six
// seconds of rendered audio arrive at once. And a render SLOWER than real time lets the play head
// catch up with what has been written — the player simply runs dry (`starved`) and picks up again
// at the next top-up. The gap is audible, and it is the honest thing to show: a silence that says
// the render is behind.
//
// Deliberately NOT the project's engine: Tracktion is either rendering or playing something else,
// and the two must not be entangled. A separate `AVAudioEngine` on the default output is one more
// client of the device, which CoreAudio has always allowed.
@MainActor
@Observable
final class ExportAudition {

    /// Is a pass under way? (True even while starved — the render is simply behind.)
    private(set) var isPlaying = false
    /// Where the listening is, in seconds from the start of the rendered range.
    private(set) var position: Double = 0
    /// How much of the file can be heard right now: what the last flush put on disk.
    private(set) var availableDuration: Double = 0
    /// The play head has caught the render up: nothing more to schedule, we are waiting.
    private(set) var starved = false

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let player = AVAudioPlayerNode()
    @ObservationIgnored private var attached = false

    @ObservationIgnored private var source: URL?
    @ObservationIgnored private var format: AVAudioFormat?
    /// The frame this pass started at: `AVAudioPlayerNode` counts its own time from `play()`,
    /// so the position on screen is this plus what the node says.
    @ObservationIgnored private var startFrame: AVAudioFramePosition = 0
    /// How far the file has been handed to the player. What lies beyond has not been flushed yet.
    @ObservationIgnored private var scheduledFrames: AVAudioFramePosition = 0
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var lastProbe: Date = .distantPast

    /// The longest slice handed over at once. Short enough that the play head never lags far
    /// behind what is on disk, long enough that the top-up is four times a second at most.
    private static let chunkSeconds: Double = 4

    // MARK: - Driving

    /// Starts (or restarts) listening to `url` from `seconds`. Does nothing — and says so by
    /// leaving `isPlaying` false — while the file holds nothing to hear yet: before the render's
    /// first flush there is a header and no audio.
    @discardableResult
    func start(source url: URL, from seconds: Double = 0) -> Bool {
        stop()
        source = url
        guard let file = try? AVAudioFile(forReading: url) else { return false }
        let fmt = file.processingFormat
        guard fmt.sampleRate > 0 else { return false }
        let from = AVAudioFramePosition(max(0, seconds) * fmt.sampleRate)
        guard file.length > from else { return false }

        format = fmt
        startFrame = from
        scheduledFrames = from
        position = Double(from) / fmt.sampleRate

        if !attached { engine.attach(player); attached = true }
        engine.connect(player, to: engine.mainMixerNode, format: fmt)
        do { try engine.start() } catch { return false }

        topUp()
        player.play()
        isPlaying = true
        startTicking()
        return true
    }

    func stop() {
        ticker?.invalidate()
        ticker = nil
        if attached { player.stop() }
        if engine.isRunning { engine.stop() }
        isPlaying = false
        starved = false
    }

    /// The file changed under our feet — the render has finished and its temporary wave has been
    /// put in place under the name that was asked for. The same sound, so we pick up at the same
    /// instant rather than stopping the listener in mid-phrase.
    func switchSource(to url: URL) {
        let resumeAt = position
        source = url
        guard isPlaying else { return }
        start(source: url, from: resumeAt)
    }

    /// Updates `availableDuration` WITHOUT playing: how much of the file could be heard right now.
    /// It is what decides whether the listen button means anything — before the render's first
    /// flush there is a header and no audio, and a button that would do nothing must say so.
    /// Throttled: reopening the file is cheap, not free, and the progress poll beats at 10 Hz.
    func probe(source url: URL, force: Bool = false) {
        guard !isPlaying else { return }          // topUp already keeps it fresh
        let now = Date()
        guard force || now.timeIntervalSince(lastProbe) > 0.3 else { return }
        lastProbe = now
        source = url
        guard let file = try? AVAudioFile(forReading: url),
              file.processingFormat.sampleRate > 0 else { availableDuration = 0; return }
        availableDuration = Double(file.length) / file.processingFormat.sampleRate
    }

    /// Everything goes: called when the job's files are about to disappear.
    func forget() {
        stop()
        source = nil
        format = nil
        position = 0
        availableDuration = 0
    }

    // MARK: - Feeding

    private func startTicking() {
        ticker?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        ticker = t
        RunLoop.main.add(t, forMode: .common)   // goes on beating while a menu is open
    }

    private func tick() {
        guard isPlaying else { return }
        updatePosition()
        topUp()
        // Dry: the play head has reached what was flushed. Not a failure — the render is simply
        // slower than real time here, and the next flush starts the sound again.
        starved = position >= availableDuration - 0.01
    }

    private func updatePosition() {
        guard let fmt = format,
              let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime),
              playerTime.sampleRate > 0 else { return }
        position = Double(startFrame) / fmt.sampleRate
            + Double(playerTime.sampleTime) / playerTime.sampleRate
    }

    /// Hands the player whatever the file has gained since last time. Re-OPENING is the point:
    /// `AVAudioFile` reads its length once, at opening — an instance kept around would never see
    /// the file grow.
    private func topUp() {
        guard let url = source, let fmt = format else { return }
        guard let file = try? AVAudioFile(forReading: url) else { return }
        availableDuration = Double(file.length) / fmt.sampleRate

        guard file.length > scheduledFrames,
              file.processingFormat.sampleRate == fmt.sampleRate,
              file.processingFormat.channelCount == fmt.channelCount else { return }

        let want = min(file.length - scheduledFrames,
                       AVAudioFramePosition(fmt.sampleRate * Self.chunkSeconds))
        guard want > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(want))
        else { return }

        file.framePosition = scheduledFrames
        do { try file.read(into: buffer, frameCount: AVAudioFrameCount(want)) } catch { return }
        guard buffer.frameLength > 0 else { return }

        player.scheduleBuffer(buffer, completionHandler: nil)
        scheduledFrames += AVAudioFramePosition(buffer.frameLength)
    }
}
