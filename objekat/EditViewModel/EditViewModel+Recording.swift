import Foundation

// MARK: - Recording: the armed zones receive a take
//
// The transport's record button (and `rec.start`) records the INPUTS of the armed zones: the engine writes
// one 32-bit float WAV per input in `<project>/samples/rec/` (named by `RecordFileNaming`), shared by every
// zone armed on that input. When the recording ends — however it ends — each armed zone gets one take, a
// child of the group (`RecordTakePlanner` decides where, how long, on which lane, and which previous
// children are muted), all of it in ONE undo point — except a recording through a loop, which leaves one
// point PER PASS (`completeRecording`, `RecordLoopPlanner.passSteps`).
//
// The take lands on the TOP lane of the group's takes and the previous ones go down by one lane (the
// newest on top), in whatever take mode the zone has.
//
// In the default take mode ("mute") the previous takes the new one will replace are muted when the
// recording STARTS (they would be heard while the next one is played), in the same undo point as the
// take: `beginRecording` pushes it BEFORE the first change, `completeRecording` adds the takes to it —
// or, when nothing was recorded, gives the mutes back and drops the point. In the other mode ("add",
// `SoundObject.recordTakeMode`) nothing is muted: the older takes stay audible. The mode is read at the
// press and kept in `RecordingZone`, so changing it during a recording only counts for the next one.
//
// While the take is made, the zone's PREVIOUS children are already one lane down (and one more for every finished
// pass of a loop): the lane the take will land on is empty and the timeline can show the take there, with a ghost of
// each finished pass under it. The shift is real, in the model, inside the same undo point as the mutes, and
// `completeRecording` takes it into account (it reads the lanes with the shift off, and moves the children by the
// difference); a recording that gives nothing gives it back.
//
// What lives here is the session's side of that: which zones a recording was started for (frozen at the
// press — arming may move meanwhile), and the model work at the start and at the end. The engine side is
// `OBJEngineCore.startRecordingInputs:` / `onRecordingFinished`; the transport side is `ObjekatSession`.

/// A zone, the input it records and its take mode, as they were when "record" was pressed.
struct RecordingZone: Equatable {
    let id: UUID
    let source: RecordSource
    var mode: RecordTakeMode = .mute

    /// The card input, for an audio zone.
    var ref: InputRef? { if case .audio(let r) = source { return r } else { return nil } }
}

/// A file the engine finished writing: its input, where it is, the timeline instant of its first sample
/// and its length in seconds.
struct RecordedFile: Equatable {
    let ref: InputRef
    let path: String
    let origin: Double
    let length: Double
    let sampleRate: Double
}

/// A MIDI zone's capture, notes included (rec3-midi): `RecordedMidi` is in EditViewModel+RecordMidi.

/// What one zone received (`rec.stop` and `rec.status` answer with it).
struct RecordTakeReport: Equatable {
    let group: UUID
    let object: UUID
    let path: String
    let start: Double
    let duration: Double
    let sourceOffset: Double
    let lane: Int
    let outsideWindow: Bool
    let muted: [UUID]
    /// The notes of a MIDI take (0 for an audio one); the path is empty for it.
    var notes: Int = 0
    /// Recording through a loop (engine patch 0050): the pass this take is (0 = the first), how many passes the zone
    /// got, whether this take is the pass the stop cut short, and whether it is heard. A linear recording is one pass.
    var pass: Int = 0
    var passes: Int = 1
    var partial = false
    var audible = true
}

/// The block the timeline draws for a zone while it records (@see RecordProgress).
/// The current pass is `current`; through a loop each finished pass that crossed the window leaves a GHOST (`current`
/// false), `pass` being its index among the passes that crossed (for the current block: the lap the head is on).
struct RecordProgressBlock: Equatable, Identifiable {
    let group: UUID
    let displayLane: Int
    let start: Double
    let end: Double
    var current = true
    var pass = 0

    /// One zone shows several blocks through a loop: the current one and its ghosts.
    var id: String { current ? "\(group.uuidString)-now" : "\(group.uuidString)-\(pass)" }
}

/// What `beginRecording` did to the model, so that `completeRecording` can finish or undo it: the previous
/// takes muted per zone, the lanes they were pushed down by, and the undo stack's depth right after the point pushed
/// for them.
struct RecordingMuteLog: Equatable {
    var mutedByZone: [UUID: [UUID]] = [:]
    /// How many lanes the previous children of each zone are pushed down by right now: 1 from the press (the zones the
    /// head can reach with something to push), one more for every finished pass of a loop that crossed the window.
    var laneShiftByZone: [UUID: Int] = [:]
    var undoDepthAfterPush: Int? = nil
    var wasDirty = false
}

extension EditViewModel {

    // MARK: What the planners read

    /// `laneShift`: the lanes the children are pushed down by during a recording (@see `RecordingMuteLog.laneShiftByZone`),
    /// taken off so that the planners see the zone as it was at the press.
    private func takePlannerChildren(_ children: [SoundObject], laneShift: Int = 0) -> [RecordTakePlanner.Child] {
        children.map {
            .init(id: $0.id, start: $0.startTime, end: $0.startTime + $0.duration, lane: $0.lane - laneShift,
                  isMuted: $0.isMuted)
        }
    }

    /// The window of a zone on the timeline (absolute), the one the take is cropped to.
    private func recordWindow(of group: SoundObject) -> (start: Double, end: Double) {
        let start = laneEntry(forID: group.id)?.absStart ?? group.startTime
        return (start, start + group.duration)
    }

    // MARK: The zone's take mode

    /// What a new take does to the takes already in `id`'s zone (the default, `.mute`, when it never chose).
    func recordTakeMode(of id: UUID) -> RecordTakeMode { find(id: id)?.recordTakeMode ?? .mute }

    /// Sets the take mode of several zones at once ("mute the previous takes" / "add, mute nothing"). ONE
    /// undo point, pushed before the first change and not at all when no zone changes. Refused (false, nothing
    /// done) when `groups` is empty or one of them is not a group that can record (an infinite, looping or
    /// consolidated group, a clip…). A recording under way is not touched: it keeps the mode read at the press.
    @discardableResult
    func setRecordTakeMode(_ mode: RecordTakeMode, groups ids: [UUID]) -> Bool {
        guard !ids.isEmpty,
              ids.allSatisfy({ id in find(id: id).map(Self.isRecordableZone) ?? false }) else { return false }
        let changing = ids.filter { recordTakeMode(of: $0) != mode }
        guard !changing.isEmpty else { return true }
        pushUndo()
        for id in changing { update(id: id) { $0.recordTakeMode = mode.stored } }
        isDirty = true
        return true
    }

    // MARK: Telling the engine which inputs are about to record

    /// Prepares the hidden tracks of the armed zones' inputs, so that pressing "record" — above all in the
    /// middle of a playback — finds them ready and rebuilds nothing. Harmless when the inputs are closed.
    func syncArmedInputs() {
        guard !isRecording, let engine else { return }
        let refs = Set(armedRecordZones.compactMap { find(id: $0)?.recordInput })   // audio zones only
        engine.setAudioInputsArmed(refs.sorted { ($0.first, $0.count) < ($1.first, $1.count) }.map {
            ["first": NSNumber(value: $0.first), "count": NSNumber(value: $0.count)]
        })
    }

    // MARK: Moving the engine's playhead from the interface

    /// Moves the ENGINE's playhead for a click on the timeline (the sound list, the ruler, a marker, a selection:
    /// "go and listen there"). While a recording is under way it does nothing at all: Tracktion ends a take on any
    /// position change, so a click must only move the caret (the caller does that). The deliberate gestures that
    /// are allowed to end the take go through the session (`seek(to:)`, `jumpPlayhead(to:)`, `returnToZero()`).
    func seekEngineUnlessRecording(to seconds: Double) {
        guard !isRecording else { return }
        engine?.seek(to: seconds)
    }

    // MARK: Starting

    /// Starts recording the armed zones' inputs, from `startTime` (the instant of the press on the
    /// timeline). The transport is the session's business (it positions the playhead before this and
    /// marks itself playing after): this talks to the engine, and mutes the previous takes of the zones
    /// the new one will replace — before the engine starts, so that they are silent from the first
    /// instant. nil on success, otherwise why not.
    func beginRecording(startTime: Double, date: Date = Date()) -> String? {
        guard !isRecording else { return "already recording" }
        guard let engine else { return "no engine" }
        let zones: [RecordingZone] = armedRecordZones.compactMap { id in
            guard let zone = find(id: id), let source = zone.recordSource else { return nil }
            return RecordingZone(id: id, source: source, mode: zone.recordTakeMode ?? .mute)
        }
        guard !zones.isEmpty else { return "no zone is armed" }

        // One file per audio input and per take, whatever the number of zones on it. A MIDI zone writes no
        // file: the project's folder is needed only when an audio zone is armed.
        let audioRefs = Set(zones.compactMap(\.ref)).sorted(by: { ($0.first, $0.count) < ($1.first, $1.count) })
        var used = Set<String>()
        var inputs: [[String: Any]] = []
        if !audioRefs.isEmpty {
            guard let folder = projectFolder else { return "the project has not been saved: there is no folder for the takes" }
            let recFolder = ConsolidateFolders.recordingsFolder(projectFolder: folder)
            for ref in audioRefs {
                let name = RecordFileNaming.name(inputName: inputName(ref), date: date) { candidate in
                    used.contains(candidate)
                        || FileManager.default.fileExists(atPath: recFolder.appendingPathComponent(candidate).path)
                }
                used.insert(name)
                inputs.append(["first": ref.first, "count": ref.count,
                               "path": recFolder.appendingPathComponent(name).path])
            }
        }
        // One entry per MIDI zone: the device it listens to (resolved now — the id may differ from the saved one).
        for zone in zones {
            guard case .midi(let ref) = zone.source else { continue }
            guard let device = resolvedMidiInput(ref) else { return "the MIDI input of a zone is not there" }
            inputs.append(["midi": device.id, "zone": zone.id.uuidString])
        }

        // The previous takes are pushed down a lane and muted now: ONE undo point, pushed before the first change.
        var log = RecordingMuteLog(wasDirty: isDirty)
        let reach = RecordLoopPlanner.reachableRange(startPosition: startTime,
                                                     loop: loopModeEnabled ? loopRegion : nil)
        for zone in zones {
            guard let group = find(id: zone.id), case .group(let children, _) = group.kind else { continue }
            let window = recordWindow(of: group)
            // The head is going to walk through the window: the take will land on the top lane, which is left empty
            // from now on (lanes inside a group are model-only: no engine call). A zone with nothing to push, or that
            // the head cannot reach, keeps its lanes (and a lap never moves them either: no point to put them back from).
            if !children.isEmpty, reach.lowerBound < window.end, reach.upperBound > window.start {
                if log.undoDepthAfterPush == nil { pushUndo(); log.undoDepthAfterPush = undoStack.count }
                updateMany(Set(children.map(\.id))) { $0.lane += 1 }
                log.laneShiftByZone[zone.id] = 1
            }
            // The loop (when on) is going to bring the head back through the window: a press beyond it is no reason to
            // leave the previous takes audible.
            let ids = RecordLoopPlanner.mutesAtStart(windowStart: window.start, windowEnd: window.end,
                                                     children: takePlannerChildren(children),
                                                     startPosition: startTime,
                                                     loop: loopModeEnabled ? loopRegion : nil,
                                                     mutesPrevious: zone.mode.mutesPrevious)
            guard !ids.isEmpty else { continue }
            if log.undoDepthAfterPush == nil { pushUndo(); log.undoDepthAfterPush = undoStack.count }
            setMuted(ids, true)
            log.mutedByZone[zone.id] = ids
        }

        if let why = engine.startRecordingInputs(inputs) {
            giveBackMutes(log)   // nothing is recording: the zones are as they were
            return why
        }
        recordingZones = zones
        recordingStartTime = startTime
        recordingMuteLog = log
        lastRecordingTakes = []
        recordingDoneSpans = [:]
        recordingSeenLaps = 0
        recordingPassStart = startTime
        recordingLive = Dictionary(uniqueKeysWithValues: zones.map { ($0.id, RecordLiveCapture()) })
        recordingLiveRevision = 0
        isRecording = true
        startRecordingTimer()
        return nil
    }

    /// A loop edit under a recording (a bound moved, the loop switched on…) can make the head join a zone it was not going to
    /// reach: the previous takes it will replace are muted at once, in the SAME undo point as the start's. `head` is the
    /// playhead now. Does nothing when not recording or for a zone in "add" mode.
    func retakeRecordingMutes(head: Double) {
        guard isRecording else { return }
        var log = recordingMuteLog
        var changed = false
        for zone in recordingZones where zone.mode.mutesPrevious {
            guard let group = find(id: zone.id), case .group(let children, _) = group.kind else { continue }
            let window = recordWindow(of: group)
            let ids = RecordLoopPlanner.mutesAtStart(windowStart: window.start, windowEnd: window.end,
                                                     children: takePlannerChildren(children), startPosition: head,
                                                     loop: loopModeEnabled ? loopRegion : nil, mutesPrevious: true)
            guard !ids.isEmpty else { continue }
            if log.undoDepthAfterPush == nil { log.wasDirty = isDirty; pushUndo(); log.undoDepthAfterPush = undoStack.count }
            setMuted(ids, true)
            log.mutedByZone[zone.id, default: []] += ids
            changed = true
        }
        if changed { recordingMuteLog = log }
    }

    /// Mutes or unmutes objects, in the model and in the engine.
    private func setMuted(_ ids: [UUID], _ muted: Bool) {
        for id in ids {
            update(id: id) { $0.isMuted = muted }
            pushMix(id)
        }
    }

    /// Moves the direct children of a zone by `delta` lanes (model only). The zone's CURRENT children: nothing is
    /// added to a zone while it records but the takes, which come after.
    private func shiftChildLanes(of zoneID: UUID, by delta: Int) {
        guard delta != 0, let group = find(id: zoneID), case .group(let children, _) = group.kind else { return }
        updateMany(Set(children.map(\.id))) { $0.lane += delta }
    }

    /// Undoes what `beginRecording` muted and pushed down, and drops its undo point when nothing else was pushed on top.
    private func giveBackMutes(_ log: RecordingMuteLog) {
        for ids in log.mutedByZone.values { setMuted(ids, false) }
        for (zoneID, shift) in log.laneShiftByZone { shiftChildLanes(of: zoneID, by: -shift) }
        if let depth = log.undoDepthAfterPush, undoStack.count == depth {
            undoStack.removeLast()
            isDirty = log.wasDirty
        }
    }

    // MARK: The laps of a recording through a loop

    /// The tick's period: 30 Hz. A lap lasts at least `RecordLoopPlanner.minimumLoopLength` (250 ms) and the ghost it leaves
    /// only has to appear within a few frames; the picture of the take (notes, loudness) is what asks for the rate.
    static let recordingTickInterval: TimeInterval = 1.0 / 30.0

    /// Starts the recording's tick (@see `recordingTick`). `.common`: it goes on while a menu is open or a mouse button is
    /// held. Stopped by `completeRecording`, the one door every recording ends through.
    private func startRecordingTimer() {
        recordingTimer?.invalidate()
        let timer = Timer(timeInterval: Self.recordingTickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.recordingTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        recordingTimer = timer
    }

    /// The device a zone listens to, for the live capture (nil: an audio zone, or a MIDI input that is not there).
    private func liveMidiDevice(of zone: RecordingZone) -> String? {
        guard case .midi(let ref) = zone.source else { return nil }
        return resolvedMidiInput(ref)?.id
    }

    /// One reading of the engine while a recording runs, in two parts.
    ///
    /// THE LAPS. When the head has jumped back (a lap), each finished pass that crossed a zone's window pushes the zone's
    /// previous takes ONE more lane down and leaves a ghost of itself on the lane it will have at the stop (@see
    /// `RecordProgress`): the final layout, built as it grows. Only the zones `beginRecording` already pushed down are
    /// touched — the undo point that covers them is that one; a zone the head could not reach at the press, or with
    /// nothing to push, is left alone. The model changes are not undo points (undo is refused while recording) and
    /// `completeRecording` moves the children by the DIFFERENCE with what it finds, so a lap this tick missed costs a
    /// lane that is wrong for a moment and never at the end.
    ///
    /// THE PICTURE (L11). The notes played since the last tick and the loudness of the audio inputs are drained from the
    /// engine and handed to each zone's `RecordLiveCapture`, dated from the head. A drain that straddles a lap is split
    /// around the jump (the notes played before it belong to the pass that ended). The capture of a pass that left a ghost
    /// goes with it (`newPass(keep: true)`), the others are forgotten. None of it reaches the recording.
    func recordingTick() {
        guard isRecording, let engine else { return }
        let head = engine.currentPlaybackPosition()

        var eventsByDevice: [String: [RecordLiveCapture.Event]] = [:]
        for (device, list) in engine.drainLiveRecordMidi() {
            eventsByDevice[device] = list.map {
                RecordLiveCapture.Event(pitch: $0["pitch"]?.intValue ?? 0, velocity: $0["velocity"]?.intValue ?? 0,
                                        on: $0["on"]?.boolValue ?? false,
                                        ageSeconds: ($0["age_ms"]?.doubleValue ?? 0) / 1000)
            }
        }
        let peaks = engine.audioInputRecordPeaksDb().map { $0.floatValue }

        if let pass = engine.recordPassNow(),
           let laps = pass["laps"]?.intValue, let currentStart = pass["start"]?.doubleValue {
            if laps > recordingSeenLaps {
                // The pass that just ended began at the last tick's pass start; the ones after it (several laps in one tick)
                // began at the loop's start, which is where the current pass began.
                let loopEnd = loopRegion?.upperBound
                if let ended = loopEnd {
                    // What was played before the jump belongs to the pass that ended; dated from the loop's end.
                    let sinceJump = max(0, head - currentStart)
                    for (device, events) in eventsByDevice {
                        let (before, after) = RecordLiveCapture.split(events: events, sinceJump: sinceJump)
                        eventsByDevice[device] = after
                        guard !before.isEmpty else { continue }
                        for z in recordingZones where liveMidiDevice(of: z) == device {
                            recordingLive[z.id]?.ingest(events: before, head: ended)
                        }
                    }
                }
                for lap in recordingSeenLaps..<laps {
                    let began = lap == recordingSeenLaps ? (recordingPassStart ?? currentStart) : currentStart
                    for zone in recordingZones {
                        var kept = false
                        if let ended = loopEnd, ended > began,
                           recordingMuteLog.laneShiftByZone[zone.id] != nil,
                           let group = find(id: zone.id), case .group = group.kind {
                            let window = recordWindow(of: group)
                            if let span = RecordProgress.span(recordStart: began, head: ended,
                                                              windowStart: window.start, windowEnd: window.end) {
                                shiftChildLanes(of: zone.id, by: 1)
                                recordingMuteLog.laneShiftByZone[zone.id, default: 0] += 1
                                recordingDoneSpans[zone.id, default: []].append(span)
                                kept = true
                            }
                        }
                        // The ghost keeps what its pass drew; a pass with no ghost is forgotten.
                        recordingLive[zone.id]?.newPass(at: loopEnd, keep: kept)
                    }
                }
                recordingSeenLaps = laps
            }
            recordingPassStart = currentStart
        }

        for zone in recordingZones {
            switch zone.source {
            case .midi:
                guard let device = liveMidiDevice(of: zone), let events = eventsByDevice[device], !events.isEmpty else { continue }
                recordingLive[zone.id]?.ingest(events: events, head: head)
            case .audio(let ref):
                // A stereo input is as loud as its louder channel.
                let hi = min(peaks.count, ref.first + ref.count)
                guard ref.first >= 0, ref.first < hi, let loudest = peaks[ref.first..<hi].max() else { continue }
                recordingLive[zone.id]?.ingest(peakDb: loudest, head: head)
            }
        }
        recordingLiveRevision &+= 1
    }

    /// What a red block draws inside itself: the pass it stands for — the capture of the pass in progress for the current
    /// block, the finished one for a ghost (`pass` is its index among the ghosts). nil when there is nothing to show.
    func recordLivePass(for block: RecordProgressBlock) -> RecordLiveCapture.Pass? {
        guard let capture = recordingLive[block.group] else { return nil }
        if block.current { return capture.current }
        return block.pass < capture.done.count ? capture.done[block.pass] : nil
    }

    // MARK: Drawing the take in progress

    /// The red blocks of the zones being recorded, with the playhead at `head`: per zone the CURRENT pass, from the press
    /// (or the start of the pass) to the head, inside the zone's window, on the top lane of the zone — which is empty, the
    /// previous takes being pushed down since the press — and, through a loop, a ghost for each finished pass that
    /// crossed the window, on the lane it will have at the stop (the ghosts only on an open zone, and only on rows it
    /// reserves). Empty when not recording. The overlay and `rec.status` both read this.
    func recordProgressBlocks(head: Double) -> [RecordProgressBlock] {
        guard isRecording, let pressed = recordingStartTime else { return [] }
        // Through a loop the head goes back: the block grows from where the CURRENT pass began (the press while
        // the clock is not anchored yet, or when nothing looped).
        let now = engine?.recordPassNow()
        let from = now?["start"]?.doubleValue ?? pressed
        let lap = now?["laps"]?.intValue ?? 0
        return recordingZones.flatMap { zone -> [RecordProgressBlock] in
            guard let e = laneEntry(forID: zone.id), case .group(let children, _) = e.item.kind else { return [] }
            let window = recordWindow(of: e.item)
            let shift = recordingMuteLog.laneShiftByZone[zone.id] ?? 0
            let top = RecordTakePlanner.takeLane(children: takePlannerChildren(children, laneShift: shift))
            let opens = e.item.showsChildrenInline
            var out: [RecordProgressBlock] = []
            let done = recordingDoneSpans[zone.id] ?? []
            if opens {
                for (i, s) in done.enumerated() {
                    let lane = RecordProgress.ghostLane(top: top, finished: done.count, pass: i)
                    guard RecordProgress.isReserved(lane: lane, reservedRows: e.item.childLaneCount) else { continue }
                    out.append(RecordProgressBlock(
                        group: zone.id,
                        displayLane: RecordProgress.displayLane(groupDisplayLane: e.displayLane, opensInline: true,
                                                                takeLane: lane),
                        start: s.start, end: s.end, current: false, pass: i))
                }
            }
            if let span = RecordProgress.span(recordStart: from, head: head,
                                              windowStart: window.start, windowEnd: window.end) {
                let lane = RecordProgress.displayLane(groupDisplayLane: e.displayLane, opensInline: opens, takeLane: top)
                out.append(RecordProgressBlock(group: zone.id, displayLane: lane, start: span.start, end: span.end,
                                               current: true, pass: lap))
            }
            return out
        }
    }

    // MARK: Finishing

    /// The engine says the recording is over, with the files it wrote. Each frozen zone that is still a
    /// recordable group gets its take(s) — one undo point for the lot (the one `beginRecording` pushed for
    /// the mutes, when there was one), none if nothing was recorded: then the mutes are given back.
    ///
    /// Recorded THROUGH a loop (several passes crossing a window) the takes are laid down PASS BY PASS, one undo
    /// point per pass (`RecordLoopPlanner.passSteps`): ⌘Z takes the last pass away and leaves the zone as it was when
    /// that pass was the last one — the previous take on top again, and audible in "mute" mode — and the next ⌘Z does
    /// the same with the pass before. The file (or the MIDI sequence) stays whatever the undo, so the takes that
    /// remain can still be pulled out into it. A recording with one pass (every linear recording) stays ONE point.
    func completeRecording(files: [RecordedFile], midi: [RecordedMidi] = [],
                           journal: [RecordLoopPlanner.JournalPoint] = []) {
        guard isRecording else { return }
        let zones = recordingZones
        let log = recordingMuteLog
        recordingTimer?.invalidate()
        recordingTimer = nil
        recordingDoneSpans = [:]
        recordingLive = [:]
        recordingSeenLaps = 0
        recordingPassStart = nil
        isRecording = false
        recordingZones = []
        recordingStartTime = nil
        recordingMuteLog = RecordingMuteLog()
        var reports: [RecordTakeReport] = []
        // The point of the start is still ours as long as the stack has not gone back under it.
        var pushed = log.undoDepthAfterPush.map { undoStack.count >= $0 } ?? false

        // PHASE 1 — what each zone receives, computed from the model as it is NOW; nothing is applied yet.
        var work: [ZoneTakes] = []
        for zone in zones {
            let early = log.mutedByZone[zone.id] ?? []
            let shift = log.laneShiftByZone[zone.id] ?? 0     // the previous children are this far down (L9)
            let file = zone.ref.flatMap { r in files.first(where: { $0.ref == r }) }
            let capture = midi.first(where: { $0.zone == zone.id })
            guard file != nil || capture != nil,
                  let group = find(id: zone.id), case .group(let children, _) = group.kind else {
                // No take for this zone: what was muted for it is heard again, and its children go back up.
                if !early.isEmpty { setMuted(early, false) }
                shiftChildLanes(of: zone.id, by: -shift)
                continue
            }
            let window = recordWindow(of: group)
            let kids = takePlannerChildren(children, laneShift: shift)

            // What this zone receives: one or several takes (one per pass through a loop), each with the lane, the
            // audibility and the report that goes with it.
            var madeTakes: [MadeTake] = []
            var muteIDs: [UUID] = [], unmuteIDs: [UUID] = [], shiftIDs: [UUID] = []
            var path = ""
            var passCount = 1
            var newSequence: MidiSequence? = nil     // a MIDI recording through a loop: what its takes look through
            if let file {
                // A recording is a succession of passes (one when nothing looped): the engine's journal says which.
                let segments = RecordLoopPlanner.segments(journal: journal, origin: file.origin, length: file.length)
                let plan = RecordLoopPlanner.plan(windowStart: window.start, windowEnd: window.end, children: kids,
                                                  segments: segments, mutesPrevious: zone.mode.mutesPrevious,
                                                  mutedAtStart: Set(early))
                passCount = segments.count
                path = file.path
                for t in plan.takes {
                    var o = SoundObject(id: UUID(), startTime: t.start, duration: t.duration, lane: t.lane,
                                        kind: .clip(filePath: file.path, sourceOffset: t.sourceOffset,
                                                    fileDuration: file.length, speedRatio: 1.0, isReversed: false))
                    o.fileSize = Self.fileSize(atPath: file.path)
                    o.isMuted = !t.audible
                    madeTakes.append(MadeTake(object: o, take: t))
                }
                muteIDs = plan.mutedIDs; unmuteIDs = plan.unmuteIDs; shiftIDs = plan.shiftIDs
            } else if let capture,
                      case let segments = RecordLoopPlanner.segments(journal: journal, origin: capture.origin,
                                                                     length: capture.length),
                      segments.count > 1 {
                // Recorded through a loop: one take per pass, all looking through ONE sequence of the whole capture.
                let plan = RecordLoopPlanner.plan(windowStart: window.start, windowEnd: window.end, children: kids,
                                                  segments: segments, mutesPrevious: zone.mode.mutesPrevious,
                                                  mutedAtStart: Set(early))
                if let made = midiLoopTakes(from: capture, plan: plan) {
                    passCount = segments.count
                    newSequence = made.sequence
                    for (o, t) in zip(made.objects, plan.takes) {
                        madeTakes.append(MadeTake(object: o, take: t, notes: o.midiNotes.count))
                    }
                    muteIDs = plan.mutedIDs; unmuteIDs = plan.unmuteIDs; shiftIDs = plan.shiftIDs
                }
            } else if let capture {
                let plan = RecordTakePlanner.plan(
                    windowStart: window.start, windowEnd: window.end, children: kids,
                    capture: .init(origin: capture.origin, length: capture.length),
                    mutesPrevious: zone.mode.mutesPrevious, mutedAtStart: Set(early))
                // A MIDI take is made BEFORE the undo point is pushed: no note, no take (the mutes are given back).
                if let m = midiTakeObject(from: capture, zone: group, plan: plan) {
                    var n = 0
                    if case .midiClip(let notes, _) = m.kind { n = notes.count }
                    let t = RecordLoopPlanner.Take(start: plan.take.start, duration: plan.take.duration,
                                                   sourceOffset: plan.take.sourceOffset, lane: plan.take.lane,
                                                   outsideWindow: plan.take.outsideWindow, audible: true, pass: 0)
                    madeTakes.append(MadeTake(object: m, take: t, notes: n))
                    muteIDs = plan.mutedIDs; unmuteIDs = plan.unmuteIDs; shiftIDs = plan.shiftIDs
                }
            }
            if madeTakes.isEmpty {
                if !early.isEmpty { setMuted(early, false) }
                shiftChildLanes(of: zone.id, by: -shift)
                continue
            }
            work.append(ZoneTakes(zoneID: zone.id, mode: zone.mode, early: early, takes: madeTakes,
                                  muteIDs: muteIDs, unmuteIDs: unmuteIDs, shiftIDs: shiftIDs, path: path,
                                  passCount: passCount, newSequence: newSequence,
                                  baseLane: RecordTakePlanner.takeLane(children: kids), laneShift: shift))
        }

        // PHASE 2 — applying them. One point for the whole recording, unless a zone got several takes (a loop) and
        // none of them lies outside its window: then one point per pass.
        let byPasses = work.contains { $0.takes.count > 1 } && !work.contains { $0.takes.contains { $0.take.outsideWindow } }
        if !byPasses {
            for w in work {
                if !pushed { pushUndo(); pushed = true }   // BEFORE the first change
                if let seq = w.newSequence { midiSequences[seq.id] = seq }   // immutable, outside the undo
                setMuted(w.muteIDs.filter { id in !w.early.contains(id) }, true)   // those muted at the start are
                setMuted(w.unmuteIDs, false)
                // The newest on top: the previous takes go down by one lane per take, the takes take the top lanes.
                // They are already `laneShift` lanes down (the press and the laps): only the difference is left.
                let down = w.takes.count - w.laneShift
                if down != 0 { updateMany(Set(w.shiftIDs)) { $0.lane += down } }
                for m in w.takes {                    // oldest first: the newest is the last one added
                    addChild(m.object, toGroupID: w.zoneID)
                }
            }
        } else {
            layDownByPasses(work, alreadyPushed: pushed)
        }
        for w in work {
            for m in w.takes {
                reports.append(RecordTakeReport(group: w.zoneID, object: m.object.id, path: w.path,
                                                start: m.take.start, duration: m.take.duration,
                                                sourceOffset: m.take.sourceOffset, lane: m.take.lane,
                                                outsideWindow: m.take.outsideWindow, muted: w.muteIDs,
                                                notes: m.notes, pass: m.take.pass, passes: w.passCount,
                                                partial: w.passCount > 1 && m.take.pass == w.passCount - 1,
                                                audible: m.take.audible))
            }
        }
        // Nothing recorded at all: the point pushed for the mutes holds a state identical to this one.
        if reports.isEmpty, let depth = log.undoDepthAfterPush, undoStack.count == depth {
            undoStack.removeLast()
            isDirty = log.wasDirty
        }
        lastRecordingTakes = reports
        syncArmedInputs()
        syncMidiZones()
    }

    /// Lays the takes of a recording through a loop down one STEP at a time (`RecordLoopPlanner.passSteps`), a
    /// point of the undo stack between two steps. After step `s` a zone holds the takes of the passes up to the
    /// step's last one, in the layout `prefixLayout` gives (the newest on the top lane, in "mute" the newest only
    /// audible, the zone's previous children pushed down by as many lanes as takes); the next step moves what is
    /// already there (lanes, audibility) and adds its own takes. The final state is the plan's, to the lane.
    ///
    /// The lanes are never re-read from the model between two steps: each zone's progress is counted here
    /// (`placed`), and the deltas computed from the layouts alone.
    private func layDownByPasses(_ work: [ZoneTakes], alreadyPushed: Bool) {
        var pushed = alreadyPushed
        let steps = RecordLoopPlanner.passSteps(passes: work.flatMap { $0.takes.map { $0.take.pass } })
        var placed: [UUID: Int] = [:]                  // how many takes of each zone are in the model
        var childShift: [UUID: Int] = [:]              // how far down each zone's previous children are
        for (si, step) in steps.enumerated() {
            guard let cutoff = step.max() else { continue }
            // The point holds the state of the step before (or, for the first step, the one of the start).
            if si == 0 { if !pushed { pushUndo(); pushed = true } } else { pushUndo() }
            for w in work {
                let count = w.takes.filter { $0.take.pass <= cutoff }.count    // the passes ascend: a prefix
                let prior = placed[w.zoneID] ?? 0
                guard count > prior else { continue }
                if prior == 0 {
                    if let seq = w.newSequence { midiSequences[seq.id] = seq }   // immutable, outside the undo
                    setMuted(w.muteIDs.filter { id in !w.early.contains(id) }, true)
                    setMuted(w.unmuteIDs, false)
                }
                let was = RecordLoopPlanner.prefixLayout(takeCount: prior, baseLane: w.baseLane,
                                                         mutesPrevious: w.mode.mutesPrevious)
                let now = RecordLoopPlanner.prefixLayout(takeCount: count, baseLane: w.baseLane,
                                                         mutesPrevious: w.mode.mutesPrevious)
                // The takes already there move down / change audibility with the new one on top…
                var newLanes: [UUID: Int] = [:]
                for n in 0..<prior {
                    let id = w.takes[n].object.id
                    if was[n].lane != now[n].lane { newLanes[id] = now[n].lane }
                    if was[n].audible != now[n].audible { setMuted([id], !now[n].audible) }
                }
                if !newLanes.isEmpty {
                    updateMany(Set(newLanes.keys)) { if let l = newLanes[$0.id] { $0.lane = l } }
                }
                // …so do the zone's previous children (already `laneShift` lanes down since the press)…
                let down = count - (childShift[w.zoneID] ?? w.laneShift)
                if down != 0 { updateMany(Set(w.shiftIDs)) { $0.lane += down } }
                childShift[w.zoneID] = count
                // …and the step's own takes arrive, oldest first.
                for n in prior..<count {
                    var o = w.takes[n].object
                    o.lane = now[n].lane
                    o.isMuted = !now[n].audible
                    addChild(o, toGroupID: w.zoneID)
                }
                placed[w.zoneID] = count
            }
        }
    }
}

/// A take a finished recording is going to add to a zone: the object, what the planner decided for it, and the
/// number of notes of a MIDI one.
private struct MadeTake {
    let object: SoundObject
    let take: RecordLoopPlanner.Take
    var notes = 0
}

/// What one zone receives from a finished recording, computed before anything is applied (@see
/// `EditViewModel.completeRecording`). `takes` are oldest first; `baseLane` is the zone's top lane BEFORE any
/// change (the planner's reference for every layout).
private struct ZoneTakes {
    let zoneID: UUID
    let mode: RecordTakeMode
    /// The children `beginRecording` muted for this zone.
    let early: [UUID]
    let takes: [MadeTake]
    let muteIDs: [UUID]
    let unmuteIDs: [UUID]
    let shiftIDs: [UUID]
    let path: String
    let passCount: Int
    let newSequence: MidiSequence?
    let baseLane: Int
    /// How many lanes the previous children were pushed down by while the recording ran.
    let laneShift: Int
}
