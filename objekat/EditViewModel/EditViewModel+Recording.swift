import Foundation

// MARK: - Recording: the armed zones receive a take
//
// The transport's record button (and `rec.start`) records the INPUTS of the armed zones: the engine writes
// one 32-bit float WAV per input in `<project>/samples/rec/` (named by `RecordFileNaming`), shared by every
// zone armed on that input. When the recording ends — however it ends — each armed zone gets one take, a
// child of the group (`RecordTakePlanner` decides where, how long, on which lane, and which previous
// children are muted), all of it in ONE undo point.
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
struct RecordProgressBlock: Equatable {
    let group: UUID
    let displayLane: Int
    let start: Double
    let end: Double
}

/// What `beginRecording` did to the model, so that `completeRecording` can finish or undo it: the previous
/// takes muted per zone, and the undo stack's depth right after the point pushed for them.
struct RecordingMuteLog: Equatable {
    var mutedByZone: [UUID: [UUID]] = [:]
    var undoDepthAfterPush: Int? = nil
    var wasDirty = false
}

extension EditViewModel {

    // MARK: What the planners read

    private func takePlannerChildren(_ children: [SoundObject]) -> [RecordTakePlanner.Child] {
        children.map {
            .init(id: $0.id, start: $0.startTime, end: $0.startTime + $0.duration, lane: $0.lane, isMuted: $0.isMuted)
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

        // The previous takes are muted now: ONE undo point, pushed before the first change.
        var log = RecordingMuteLog(wasDirty: isDirty)
        for zone in zones {
            guard let group = find(id: zone.id), case .group(let children, _) = group.kind else { continue }
            let window = recordWindow(of: group)
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
        isRecording = true
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

    /// Undoes what `beginRecording` muted, and drops its undo point when nothing else was pushed on top.
    private func giveBackMutes(_ log: RecordingMuteLog) {
        for ids in log.mutedByZone.values { setMuted(ids, false) }
        if let depth = log.undoDepthAfterPush, undoStack.count == depth {
            undoStack.removeLast()
            isDirty = log.wasDirty
        }
    }

    // MARK: Drawing the take in progress

    /// The red blocks of the zones being recorded, with the playhead at `head`: one per zone, on the lane
    /// its take will land on, from the press to the head, inside the zone's window. Empty when not
    /// recording. The overlay and `rec.status` both read this.
    func recordProgressBlocks(head: Double) -> [RecordProgressBlock] {
        guard isRecording, let from = recordingStartTime else { return [] }
        return recordingZones.compactMap { zone in
            guard let e = laneEntry(forID: zone.id), case .group(let children, _) = e.item.kind else { return nil }
            let window = recordWindow(of: e.item)
            guard let span = RecordProgress.span(recordStart: from, head: head,
                                                 windowStart: window.start, windowEnd: window.end) else { return nil }
            let lane = RecordProgress.displayLane(
                groupDisplayLane: e.displayLane, opensInline: e.item.showsChildrenInline,
                takeLane: RecordTakePlanner.takeLane(children: takePlannerChildren(children)))
            return RecordProgressBlock(group: zone.id, displayLane: lane, start: span.start, end: span.end)
        }
    }

    // MARK: Finishing

    /// The engine says the recording is over, with the files it wrote. Each frozen zone that is still a
    /// recordable group gets its take — one undo point for the lot (the one `beginRecording` pushed for
    /// the mutes, when there was one), none if nothing was recorded: then the mutes are given back.
    func completeRecording(files: [RecordedFile], midi: [RecordedMidi] = [],
                           journal: [RecordLoopPlanner.JournalPoint] = []) {
        guard isRecording else { return }
        let zones = recordingZones
        let log = recordingMuteLog
        isRecording = false
        recordingZones = []
        recordingStartTime = nil
        recordingMuteLog = RecordingMuteLog()
        var reports: [RecordTakeReport] = []
        // The point of the start is still ours as long as the stack has not gone back under it.
        var pushed = log.undoDepthAfterPush.map { undoStack.count >= $0 } ?? false

        for zone in zones {
            let early = log.mutedByZone[zone.id] ?? []
            let file = zone.ref.flatMap { r in files.first(where: { $0.ref == r }) }
            let capture = midi.first(where: { $0.zone == zone.id })
            guard file != nil || capture != nil,
                  let group = find(id: zone.id), case .group(let children, _) = group.kind else {
                // No take for this zone: what was muted for it is heard again.
                if !early.isEmpty { setMuted(early, false) }
                continue
            }
            let window = recordWindow(of: group)
            let kids = takePlannerChildren(children)

            // What this zone receives: one or several takes (one per pass through a loop), each with the lane, the
            // audibility and the report that goes with it.
            struct Made { let object: SoundObject; let take: RecordLoopPlanner.Take; var notes = 0 }
            var madeTakes: [Made] = []
            var muteIDs: [UUID] = [], unmuteIDs: [UUID] = [], shiftIDs: [UUID] = []
            var path = ""
            var passCount = 1
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
                    madeTakes.append(Made(object: o, take: t))
                }
                muteIDs = plan.mutedIDs; unmuteIDs = plan.unmuteIDs; shiftIDs = plan.shiftIDs
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
                    madeTakes.append(Made(object: m, take: t, notes: n))
                    muteIDs = plan.mutedIDs; unmuteIDs = plan.unmuteIDs; shiftIDs = plan.shiftIDs
                }
            }
            if madeTakes.isEmpty {
                if !early.isEmpty { setMuted(early, false) }
                continue
            }
            if !pushed { pushUndo(); pushed = true }   // BEFORE the first change
            setMuted(muteIDs.filter { id in !early.contains(id) }, true)   // those muted at the start are
            setMuted(unmuteIDs, false)
            // The newest on top: the previous takes go down by one lane per take, the takes take the top lanes.
            let down = madeTakes.count
            updateMany(Set(shiftIDs)) { $0.lane += down }
            for m in madeTakes {                      // oldest first: the newest is the last one added
                addChild(m.object, toGroupID: zone.id)
                reports.append(RecordTakeReport(group: zone.id, object: m.object.id, path: path,
                                                start: m.take.start, duration: m.take.duration,
                                                sourceOffset: m.take.sourceOffset, lane: m.take.lane,
                                                outsideWindow: m.take.outsideWindow, muted: muteIDs,
                                                notes: m.notes, pass: m.take.pass, passes: passCount,
                                                partial: passCount > 1 && m.take.pass == passCount - 1,
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
}
