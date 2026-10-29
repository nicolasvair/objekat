import Foundation

// MARK: - Recording: the armed zones receive a take
//
// The transport's record button (and `rec.start`) records the INPUTS of the armed zones: the engine writes
// one 32-bit float WAV per input in `<project>/samples/rec/` (named by `RecordFileNaming`), shared by every
// zone armed on that input. When the recording ends — however it ends — each armed zone gets one take, a
// child of the group (`RecordTakePlanner` decides where, how long, on which lane, and which previous
// children are muted), all of it in ONE undo point.
//
// What lives here is the session's side of that: which zones a recording was started for (frozen at the
// press — arming may move meanwhile), and the model work at the end. The engine side is
// `OBJEngineCore.startRecordingInputs:` / `onRecordingFinished`; the transport side is `ObjekatSession`.

/// A zone and the input it records, as they were when "record" was pressed.
struct RecordingZone: Equatable {
    let id: UUID
    let ref: InputRef
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
}

extension EditViewModel {

    // MARK: Telling the engine which inputs are about to record

    /// Prepares the hidden tracks of the armed zones' inputs, so that pressing "record" — above all in the
    /// middle of a playback — finds them ready and rebuilds nothing. Harmless when the inputs are closed.
    func syncArmedInputs() {
        guard !isRecording, let engine else { return }
        let refs = Set(armedRecordZones.compactMap { find(id: $0)?.recordInput })
        engine.setAudioInputsArmed(refs.sorted { ($0.first, $0.count) < ($1.first, $1.count) }.map {
            ["first": NSNumber(value: $0.first), "count": NSNumber(value: $0.count)]
        })
    }

    // MARK: Starting

    /// Starts recording the armed zones' inputs. The transport is the session's business (it positions
    /// the playhead before this and marks itself playing after): this only talks to the engine. nil on
    /// success, otherwise why not.
    func beginRecording(date: Date = Date()) -> String? {
        guard !isRecording else { return "already recording" }
        guard let engine else { return "no engine" }
        guard let folder = projectFolder else { return "the project has not been saved: there is no folder for the takes" }
        let zones: [RecordingZone] = armedRecordZones.compactMap { id in
            find(id: id)?.recordInput.map { RecordingZone(id: id, ref: $0) }
        }
        guard !zones.isEmpty else { return "no zone is armed" }

        // One file per input and per take, whatever the number of zones on it.
        let recFolder = ConsolidateFolders.recordingsFolder(projectFolder: folder)
        var used = Set<String>()
        var inputs: [[String: Any]] = []
        for ref in Set(zones.map(\.ref)).sorted(by: { ($0.first, $0.count) < ($1.first, $1.count) }) {
            let name = RecordFileNaming.name(inputName: inputName(ref), date: date) { candidate in
                used.contains(candidate)
                    || FileManager.default.fileExists(atPath: recFolder.appendingPathComponent(candidate).path)
            }
            used.insert(name)
            inputs.append(["first": ref.first, "count": ref.count,
                           "path": recFolder.appendingPathComponent(name).path])
        }
        if let why = engine.startRecordingInputs(inputs) { return why }
        recordingZones = zones
        lastRecordingTakes = []
        isRecording = true
        return nil
    }

    // MARK: Finishing

    /// The engine says the recording is over, with the files it wrote. Each frozen zone that is still a
    /// recordable group gets its take — one undo point for the lot, none if nothing was recorded.
    func completeRecording(files: [RecordedFile]) {
        guard isRecording else { return }
        let zones = recordingZones
        isRecording = false
        recordingZones = []
        var reports: [RecordTakeReport] = []
        var pushed = false

        for zone in zones {
            guard let file = files.first(where: { $0.ref == zone.ref }),
                  let group = find(id: zone.id), case .group(let children, _) = group.kind else { continue }
            let windowStart = laneEntry(forID: zone.id)?.absStart ?? group.startTime
            let plan = RecordTakePlanner.plan(
                windowStart: windowStart, windowEnd: windowStart + group.duration,
                children: children.map {
                    .init(id: $0.id, start: $0.startTime, end: $0.startTime + $0.duration,
                          lane: $0.lane, isMuted: $0.isMuted)
                },
                capture: .init(origin: file.origin, length: file.length))

            if !pushed { pushUndo(); pushed = true }   // BEFORE the first change
            var take = SoundObject(id: UUID(), startTime: plan.take.start, duration: plan.take.duration,
                                   lane: plan.take.lane,
                                   kind: .clip(filePath: file.path, sourceOffset: plan.take.sourceOffset,
                                               fileDuration: file.length, speedRatio: 1.0, isReversed: false))
            take.fileSize = Self.fileSize(atPath: file.path)
            for id in plan.mutedIDs {
                update(id: id) { $0.isMuted = true }
                pushMix(id)
            }
            addChild(take, toGroupID: zone.id)
            reports.append(RecordTakeReport(group: zone.id, object: take.id, path: file.path,
                                            start: plan.take.start, duration: plan.take.duration,
                                            sourceOffset: plan.take.sourceOffset, lane: plan.take.lane,
                                            outsideWindow: plan.take.outsideWindow, muted: plan.mutedIDs))
        }
        lastRecordingTakes = reports
        syncArmedInputs()
    }
}
