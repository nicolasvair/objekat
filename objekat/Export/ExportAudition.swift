import AVFoundation
import AudioToolbox
import CoreAudio
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
// and the two must not be entangled. A separate `AVAudioEngine` is one more client of the device,
// which CoreAudio has always allowed.
//
// WHICH DEVICE. Not the system's default output: the sound card OBJEKAT itself opened (the name
// `AudioDeviceStatus` publishes) — otherwise a project working on an interface would be listened
// to through the laptop's speakers. The name is resolved to an `AudioDeviceID` through CoreAudio
// (devices with an output stream) and set on the output node's AudioUnit BEFORE the engine starts;
// a name that cannot be found falls back on the default output, said in the log. If OBJEKAT's
// card changes while one listens, the pass stops, is reconfigured and picks up at the same
// position.
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
    /// A restart for a device change is under way: our own stop/start must not re-enter it.
    @ObservationIgnored private var restarting = false
    /// An observation of `AudioDeviceStatus` is armed (it fires ONCE per arming).
    @ObservationIgnored private var observingDevice = false
    @ObservationIgnored private var configObserver: NSObjectProtocol?

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

        // The device first, THEN the graph: changing the output node's device moves its format
        // (another card, another rate), and the mixer must be plugged again on what it now is.
        applyOutputDevice()
        if !attached { engine.attach(player); attached = true }
        reconnectGraph(playerFormat: fmt)
        do { try engine.start() } catch {
            NSLog("[EXPORT-AUDITION] engine.start failed: %@", String(describing: error))
            return false
        }

        topUp()
        player.play()
        isPlaying = true
        startTicking()
        watchDevice()
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

    /// The name of the device the listening goes out on, READ BACK from the output node's
    /// AudioUnit — not from what was asked for, so a caller can tell the resolution from the
    /// intention. While no pass runs the device is (re)applied first, so the answer is what the
    /// NEXT pass would use. `nil` when the unit cannot be read.
    func outputDeviceName() -> String? {
        if !engine.isRunning { applyOutputDevice() }
        guard let id = currentOutputDeviceID() else { return nil }
        return Self.deviceName(id)
    }

    /// Everything goes: called when the job's files are about to disappear.
    func forget() {
        stop()
        source = nil
        format = nil
        position = 0
        availableDuration = 0
    }

    // MARK: - Output device

    /// Points the output node at the card OBJEKAT has open. Only while the engine is stopped:
    /// the property is meant to be set before start, and doing it on a running engine would be
    /// answered by a configuration change of our own making.
    private func applyOutputDevice() {
        guard !engine.isRunning else { return }
        guard let unit = engine.outputNode.audioUnit else {
            NSLog("[EXPORT-AUDITION] output node has no AudioUnit: system default output")
            return
        }
        let wanted = AudioDeviceStatus.shared.snapshot.name
        var target: AudioDeviceID?
        if let wanted, let id = Self.outputDeviceID(named: wanted) {
            target = id
        } else {
            // Not resolved: the system default. It is also an explicit set — a previous pass may
            // have left the unit on a card that has since stopped being OBJEKAT's.
            NSLog("[EXPORT-AUDITION] device %@ not found among the output devices: default output",
                  wanted ?? "(none published)")
            target = Self.defaultOutputDeviceID()
        }
        guard var device = target else { return }
        if currentOutputDeviceID() == device { return }
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global, 0, &device,
                                          UInt32(MemoryLayout<AudioDeviceID>.size))
        if status != noErr {
            NSLog("[EXPORT-AUDITION] setting the output device failed (%d): left as it was",
                  Int(status))
        }
    }

    /// Plugs player → mixer → output again, on the formats the (possibly new) device now has.
    private func reconnectGraph(playerFormat fmt: AVAudioFormat) {
        let out = engine.outputNode.inputFormat(forBus: 0)
        if out.sampleRate > 0, out.channelCount > 0 {
            engine.connect(engine.mainMixerNode, to: engine.outputNode, format: out)
        }
        engine.connect(player, to: engine.mainMixerNode, format: fmt)
    }

    private func currentOutputDeviceID() -> AudioDeviceID? {
        guard let unit = engine.outputNode.audioUnit else { return nil }
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global, 0, &id, &size)
        return status == noErr && id != 0 ? id : nil
    }

    static func defaultOutputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                                0, nil, &size, &id)
        return status == noErr && id != 0 ? id : nil
    }

    /// Every device that has at least one OUTPUT stream (an input-only interface is not a place
    /// to send sound to, even if a name matches).
    static func outputDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address,
                                             0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                         0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter { id in
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                     mScope: kAudioObjectPropertyScopeOutput,
                                                     mElement: kAudioObjectPropertyElementMain)
            var n: UInt32 = 0
            return AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &n) == noErr && n > 0
        }
    }

    static func deviceName(_ id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name)
        guard status == noErr, let name else { return nil }
        return name.takeRetainedValue() as String
    }

    /// The exact name first; a name that differs only by case or by surrounding blanks second.
    static func outputDeviceID(named wanted: String) -> AudioDeviceID? {
        let candidates = outputDeviceIDs().compactMap { id in deviceName(id).map { (id, $0) } }
        if let hit = candidates.first(where: { $0.1 == wanted }) { return hit.0 }
        let plain = wanted.trimmingCharacters(in: .whitespacesAndNewlines)
        return candidates.first(where: {
            $0.1.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(plain) == .orderedSame
        })?.0
    }

    // MARK: - Following the card

    /// Two doors say the card moved: OBJEKAT's own device changing (`AudioDeviceStatus`) and the
    /// engine's configuration changing under us (the card we are bound to went away).
    private func watchDevice() {
        if configObserver == nil {
            configObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.deviceMayHaveChanged(forced: true) }
            }
        }
        guard !observingDevice else { return }
        observingDevice = true
        withObservationTracking {
            _ = AudioDeviceStatus.shared.generation
        } onChange: { [weak self] in
            // Called on `willSet`: hop, so that the new snapshot is what is read.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.observingDevice = false
                    self.deviceMayHaveChanged(forced: false)
                    if self.isPlaying { self.watchDevice() }
                }
            }
        }
    }

    /// Stop, reconfigure, resume at the same position — but only when the device it would go out
    /// on is not the one it is on (a change of rate or buffer alone moves nothing here).
    private func deviceMayHaveChanged(forced: Bool) {
        guard isPlaying, !restarting, let url = source else { return }
        if !forced {
            // The restart gap of a card (stopped, then running again) is not a new card: wait.
            let snap = AudioDeviceStatus.shared.snapshot
            guard snap.running, let name = snap.name else { return }
            guard let id = Self.outputDeviceID(named: name), id != currentOutputDeviceID() else { return }
        }
        updatePosition()
        let resumeAt = position
        restarting = true
        defer { restarting = false }
        NSLog("[EXPORT-AUDITION] device changed: reconfiguring, resuming at %.2f s", resumeAt)
        start(source: url, from: resumeAt)
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
