import AVFoundation
import AudioToolbox
import CoreAudio

// MARK: - Listening inside a canvas window

/// What a canvas window plays: the three files the script supplied (@see CanvasSlot — the original,
/// the result, the delta), through a SECOND `AVAudioEngine` that has nothing to do with the project's
/// (Tracktion is either playing something else or not at all, and the two must not be entangled — the
/// reasoning of `ExportAudition`, whose device resolvers this reuses).
///
/// THE STORE IS THE AUTHORITY, this is a follower. The transport model (@see ScriptCanvasTransport,
/// §2.8) says what is playing, from where, and what is heard; `follow(_:)` is called on every
/// `transportChanged` and brings the sound in line. Nothing here decides a position or a state.
///
/// ONE NODE PER SLOT, ALL STARTED AT THE SAME HOST TIME, all three always running in step. A/B and
/// Delta are node VOLUMES (1 for the slot that is heard, 0 for the others), so a switch is instant
/// and sample-accurate by construction: the position never moves. What does move a node is a slot
/// whose FILE changed — the script delivered a new result while it plays. That one node is stopped,
/// re-scheduled at the position the others will have `swapLead` seconds from now, and started at
/// exactly that host time. A format that differs from the old file's (another rate, another channel
/// count), or a slot that had no node yet, falls back on restarting everything at the same position.
/// The swap is the risk the plan names (R4: it may click, or leave a gap of the lead's length on the
/// slot that changes) — and the thing to listen for.
///
/// THE SOUND STARTS WHERE THE MODEL WILL BE, not where it was: playback begins `startLead` seconds
/// after the call (the engine needs the time to be ready), so the first sample played is the one the
/// model's clock will reach at that instant — the playhead and the sound agree, instead of the
/// playhead leading by the lead.
///
/// THE MONITORING LEVEL (revision 5) is applied HERE, at the output, and nowhere else: an
/// `AVAudioUnitEQ` between the main mixer and the output node, its `globalGain` (dB, −96…+24, so the
/// ±20 dB of the hand's slider fits) set from `ScriptCanvasTransport.monitorDB`. It is a gain on what is
/// HEARD — Original, Result and Difference alike, instantly, no file re-rendered — and never reaches a
/// file the script wrote or what Validate lays back. (A player node's `volume` stops at 1, so it cannot
/// amplify; the EQ unit's global gain was checked offline: exact at ±6 and ±20 dB.)
///
/// WHICH DEVICE: the card OBJEKAT itself opened (`AudioDeviceStatus`), resolved through
/// `ExportAudition`'s helpers and set on the output node before the engine starts. Created only by
/// the window layer, and never under `--headless` or `--no-audio`.
@MainActor
final class ScriptCanvasAudition {

    /// Between the call and the first sample.
    static let startLead = 0.05
    /// Between a slot's new file arriving and its first sample.
    static let swapLead = 0.1

    private let engine = AVAudioEngine()
    /// The monitoring level's stage (no band enabled: only its global gain acts).
    private let monitor: AVAudioUnitEQ = {
        let unit = AVAudioUnitEQ(numberOfBands: 1)
        unit.bands[0].bypass = true
        unit.globalGain = 0
        return unit
    }()
    private var players: [CanvasSlot: AVAudioPlayerNode] = [:]
    /// The file each node is playing, and its path.
    private var files: [CanvasSlot: AVAudioFile] = [:]
    private var paths: [CanvasSlot: String] = [:]
    /// The transport as of the last `follow` — what a restart for a device change starts from.
    private var last = ScriptCanvasTransport()
    private(set) var isPlaying = false
    /// The host time of the first sample, and the transport position (x units) it carries.
    private var startHost: UInt64 = 0
    private var startPosition = 0.0
    /// The model's anchor this pass started from: a different one is a seek while playing.
    private var startAnchor: Date? = nil
    private var restarting = false
    private var configObserver: NSObjectProtocol?

    init() {
        engine.attach(monitor)
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            // The card moved or went away under the engine, which stopped itself: pick up at the
            // position the model has reached.
            MainActor.assumeIsolated {
                guard let self, self.isPlaying, !self.restarting else { return }
                self.restarting = true
                defer { self.restarting = false }
                NSLog("[CANVAS-AUDITION] configuration changed: restarting")
                self.start(self.last)
            }
        }
    }

    /// Everything goes: the window is closing.
    func shutdown() {
        stop()
        if let o = configObserver { NotificationCenter.default.removeObserver(o) }
        configObserver = nil
    }

    // MARK: Following

    /// Brings the sound in line with the transport.
    func follow(_ t: ScriptCanvasTransport) {
        let previous = last
        last = t
        guard t.playing else {
            if isPlaying { stop() }
            return
        }
        if !isPlaying || t.anchorSince != startAnchor || t.offset != previous.offset {
            start(t)   // a play, or a seek while playing (the anchor moved)
            return
        }
        for slot in CanvasSlot.allCases where t.slots[slot] != paths[slot] {
            swap(slot, to: t.slots[slot], t)
            if !isPlaying { return }   // the swap fell back on a restart that failed, or stopped
        }
        setAudible(t)
    }

    /// Where the sound is, in transport units, read off the host clock. nil when nothing plays.
    var position: Double? {
        guard isPlaying else { return nil }
        return startPosition + Self.seconds(from: startHost, to: mach_absolute_time())
    }

    func stop() {
        for p in players.values { p.stop() }
        if engine.isRunning { engine.stop() }
        isPlaying = false
    }

    // MARK: Starting

    /// (Re)starts every node at the position the model will have `startLead` from now.
    private func start(_ t: ScriptCanvasTransport) {
        stop()
        files = [:]
        paths = [:]
        for slot in CanvasSlot.allCases {
            guard let path = t.slots[slot] else { continue }
            if let f = try? AVAudioFile(forReading: URL(fileURLWithPath: path)), f.processingFormat.sampleRate > 0,
               f.processingFormat.channelCount > 0 {
                files[slot] = f
                paths[slot] = path
            } else {
                NSLog("[CANVAS-AUDITION] cannot read %@", path)
            }
        }
        guard files[.original] != nil else { return }

        // The device first, THEN the graph: another card moves the output's format.
        let deviceName = applyOutputDevice()
        for slot in CanvasSlot.allCases {
            let node: AVAudioPlayerNode
            if let existing = players[slot] {
                node = existing
            } else {
                node = AVAudioPlayerNode()
                engine.attach(node)
                players[slot] = node
            }
            if let f = files[slot] {
                engine.connect(node, to: engine.mainMixerNode, format: f.processingFormat)
            } else {
                engine.disconnectNodeOutput(node)
            }
        }
        let out = engine.outputNode.inputFormat(forBus: 0)
        if out.sampleRate > 0, out.channelCount > 0 {
            engine.connect(engine.mainMixerNode, to: monitor, format: out)
            engine.connect(monitor, to: engine.outputNode, format: out)
        }
        do { try engine.start() } catch {
            NSLog("[CANVAS-AUDITION] engine.start failed: %@", String(describing: error))
            return
        }

        startHost = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: Self.startLead)
        startPosition = t.position(at: Date().addingTimeInterval(Self.startLead))
        startAnchor = t.anchorSince
        for (slot, f) in files {
            schedule(slot, f, atPosition: startPosition, host: startHost, offset: t.offset)
        }
        setAudible(t)
        isPlaying = true
        NSLog("[CANVAS-AUDITION] playing %d slot(s) from %.3f s on %@", files.count, startPosition,
              deviceName ?? "(unknown device)")
    }

    /// Hands a node its file from the transport position `p`, and starts it at `host`. A file that
    /// begins after `p` (a positive offset) starts later; one that has ended has nothing to play.
    private func schedule(_ slot: CanvasSlot, _ f: AVAudioFile, atPosition p: Double, host: UInt64,
                          offset: Double) {
        guard let node = players[slot] else { return }
        let rate = f.processingFormat.sampleRate
        var fileTime = p - offset
        var begin = host
        if fileTime < 0 {
            begin = host + AVAudioTime.hostTime(forSeconds: -fileTime)
            fileTime = 0
        }
        let frame = AVAudioFramePosition((fileTime * rate).rounded())
        let remaining = f.length - frame
        guard remaining > 0, remaining < Int64(UInt32.max) else { return }
        node.scheduleSegment(f, startingFrame: frame, frameCount: AVAudioFrameCount(remaining),
                             at: nil, completionHandler: nil)
        node.play(at: AVAudioTime(hostTime: begin))
    }

    // MARK: Listening

    /// The three-state switch (Original / Result / Delta): the slot that is heard has its node at 1,
    /// the others at 0. `listen` alone says which (an empty slot falls back to the original).
    private func setAudible(_ t: ScriptCanvasTransport) {
        monitor.globalGain = Float(t.monitorDB)   // listening only: the files are untouched
        let named = CanvasSlot(rawValue: t.listen.rawValue) ?? .original
        let heard: CanvasSlot = t.slots[named] != nil ? named : .original
        for slot in CanvasSlot.allCases { players[slot]?.volume = slot == heard ? 1 : 0 }
    }

    // MARK: A slot's file changed

    /// Re-schedules ONE node, aligned on the others: stopped, then handed the new file from the
    /// position everyone will be at `swapLead` from now, and started at that host time. Anything that
    /// cannot be done that way restarts every node.
    private func swap(_ slot: CanvasSlot, to path: String?, _ t: ScriptCanvasTransport) {
        guard let path else {
            // Cleared: the node falls silent. (A cleared original stops the store's transport too.)
            players[slot]?.stop()
            files.removeValue(forKey: slot)
            paths.removeValue(forKey: slot)
            return
        }
        guard let node = players[slot], let old = files[slot],
              let f = try? AVAudioFile(forReading: URL(fileURLWithPath: path)),
              f.processingFormat.isEqual(old.processingFormat) else {
            start(t)
            return
        }
        node.stop()
        let host = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: Self.swapLead)
        let p = startPosition + Self.seconds(from: startHost, to: host)
        files[slot] = f
        paths[slot] = path
        schedule(slot, f, atPosition: p, host: host, offset: t.offset)
    }

    // MARK: Device

    /// Points the output node at the card OBJEKAT has open, the way `ExportAudition` does, and
    /// returns its name. Only while the engine is stopped.
    @discardableResult
    private func applyOutputDevice() -> String? {
        guard !engine.isRunning else { return nil }
        guard let unit = engine.outputNode.audioUnit else {
            NSLog("[CANVAS-AUDITION] output node has no AudioUnit: system default output")
            return nil
        }
        let wanted = AudioDeviceStatus.shared.snapshot.name
        var target: AudioDeviceID?
        if let wanted, let id = ExportAudition.outputDeviceID(named: wanted) {
            target = id
        } else {
            NSLog("[CANVAS-AUDITION] device %@ not found among the output devices: default output",
                  wanted ?? "(none published)")
            target = ExportAudition.defaultOutputDeviceID()
        }
        guard var device = target else { return nil }
        var current = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let read = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                        kAudioUnitScope_Global, 0, &current, &size)
        if read != noErr || current != device {
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                              kAudioUnitScope_Global, 0, &device,
                                              UInt32(MemoryLayout<AudioDeviceID>.size))
            if status != noErr {
                NSLog("[CANVAS-AUDITION] setting the output device failed (%d): left as it was", Int(status))
            }
        }
        return ExportAudition.deviceName(device)
    }

    // MARK: Host time

    /// Seconds from host time `a` to host time `b` (negative when `b` is earlier).
    private static func seconds(from a: UInt64, to b: UInt64) -> Double {
        b >= a ? AVAudioTime.seconds(forHostTime: b - a) : -AVAudioTime.seconds(forHostTime: a - b)
    }
}
