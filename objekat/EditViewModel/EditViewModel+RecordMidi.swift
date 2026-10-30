import Foundation

// MARK: - MIDI recording zones (rec3-midi)
//
// A MIDI recording zone is a GROUP with a `recordMidiInput` (the counterpart of `recordInput`), recorded
// with the same transport button into the same kind of take: a child with handles, on the top lane, the
// previous takes muted or not by the zone's take mode, ONE undo. Where it differs:
//
//  - the source is a MIDI input the ENGINE lists (`midiInputs`), found again by id then by name;
//  - the zone has an INSTRUMENT (`SoundObject.instruments`, saved as `zoneInstruments`), played live while the
//    zone is armed on a hidden track the engine owns, one per zone (`OBJEngineCore.setMidiZones:`), and COPIED
//    into every take at the stop (`copiedInstruments`: new id, the live state). Never put on the group's own
//    container: an instrument writes its buffer and would overwrite the sum of the audio children;
//  - a take is a `.midiClip` whose notes the engine read off Tracktion's clip (`MidiTakePlanner` puts them in
//    beats relative to the take; a note before the take's start is a handle);
//  - no file: nothing to write in `samples/rec/`, so a MIDI-only recording does not need a saved project.

/// What the engine read off a MIDI zone's recording: the notes in seconds on the timeline.
struct RecordedMidi: Equatable {
    let zone: UUID
    let origin: Double
    let length: Double
    let notes: [MidiTakePlanner.RawNote]
    let pedal: [MidiTakePlanner.Pedal]
}

extension EditViewModel {

    // MARK: The devices

    /// Reads the engine's list of MIDI inputs into `midiInputs`.
    func refreshMidiInputs() {
        guard let engine else { midiInputs = []; return }
        let list = engine.midiInputDevices().compactMap { d -> MidiInputInfo? in
            guard let id = d["id"] as? String else { return nil }
            return MidiInputInfo(id: id, name: d["name"] as? String ?? id,
                                 isVirtual: (d["virtual"] as? NSNumber)?.boolValue ?? false,
                                 enabled: (d["enabled"] as? NSNumber)?.boolValue ?? false)
        }
        let ordered = MidiInputResolver.ordered(list)
        if ordered != midiInputs { midiInputs = ordered }
    }

    /// Listens to the engine's MIDI device list: refreshes it, re-arms the zones (the engine rebuilt its
    /// attachments) and re-checks which armed zones are still able to record. Idempotent.
    func installMidiHooks() {
        guard let engine else { return }
        engine.onMidiDevicesChanged = { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refreshMidiInputs()
                self.armedGroupIDs = self.armedGroupIDs.filter { self.armRefusal(of: $0) == nil }
                self.syncMidiZones()
            }
        }
        refreshMidiInputs()
    }

    /// The present device `ref` stands for.
    func resolvedMidiInput(_ ref: MidiInputRef) -> MidiInputInfo? {
        MidiInputResolver.resolve(ref, in: midiInputs)
    }

    /// The name to show for a MIDI input: the present device's, else the one the project remembers.
    func midiInputName(_ ref: MidiInputRef) -> String {
        if let d = resolvedMidiInput(ref) { return d.id == MidiInputResolver.allInputsID ? L("midi.all_inputs") : d.name }
        return ref.name.isEmpty ? L("midi.input.unnamed") : ref.name
    }

    /// The name to show for a source, audio or MIDI.
    func sourceName(_ source: RecordSource) -> String {
        switch source {
        case .audio(let ref): return inputName(ref)
        case .midi(let ref): return midiInputName(ref)
        }
    }

    /// Whether the source is there right now (the card has the input / the MIDI device is listed).
    func isRecordSourcePresent(_ source: RecordSource) -> Bool {
        switch source {
        case .audio(let ref): return isRecordInputPresent(ref)
        case .midi(let ref): return resolvedMidiInput(ref) != nil
        }
    }

    /// The loudest velocity played on each MIDI input since the last read (the engine clears it).
    func midiActivity() -> [String: Int] {
        (engine?.midiInputActivity() ?? [:]).mapValues { $0.intValue }
    }

    // MARK: Playing the armed zones

    /// Tells the engine which MIDI zones are armed (device + instrument), so that each plays live. Before a
    /// zone's hidden track goes away, its instrument's state is taken back into the model: whatever was
    /// turned in the editor while armed is what the next arming (and the next take) finds.
    func syncMidiZones() {
        guard !isRecording, let engine else { return }
        var wanted: [[String: Any]] = []
        var active: Set<UUID> = []
        for id in armedRecordZones {
            guard let zone = find(id: id), let ref = zone.recordMidiInput,
                  let device = resolvedMidiInput(ref) else { continue }
            var entry: [String: Any] = ["zone": id.uuidString, "device": device.id]
            if let inst = zone.instruments.first {
                var info: [String: Any] = ["pluginKey": inst.id.uuidString, "identifier": inst.identifier,
                                           "format": inst.formatName, "name": inst.name]
                if let state = inst.stateXML, !state.isEmpty { info["stateXML"] = state }
                entry["instrument"] = info
            }
            wanted.append(entry)
            active.insert(id)
        }
        for gone in activeMidiZoneIDs.subtracting(active) { keepZoneInstrumentState(of: gone) }
        activeMidiZoneIDs = active
        engine.setMidiZones(wanted)
    }

    /// Writes the live state of a zone's instrument back into the model (no undo point, not an edit).
    private func keepZoneInstrumentState(of id: UUID) {
        guard let inst = find(id: id)?.instruments.first,
              let live = engine?.getPluginStateXML(inst.id.uuidString), !live.isEmpty,
              live != inst.stateXML else { return }
        update(id: id) { o in
            o.instruments = o.instruments.map { p in
                guard p.id == inst.id else { return p }
                var q = p
                q.stateXML = live
                return q
            }
        }
        isDirty = true
    }

    // MARK: The zone's instrument

    /// Whether a group can take an instrument: a MIDI recording zone.
    func canHaveZoneInstrument(_ id: UUID) -> Bool {
        guard let g = find(id: id) else { return false }
        return g.isGroup && g.recordMidiInput != nil
    }

    /// Gives a MIDI zone its instrument (replacing the previous one). One undo point.
    func setZoneInstrument(groupID: UUID, available: AvailablePlugin) {
        guard canHaveZoneInstrument(groupID), engine != nil else { return }
        let inst = freshPlugin(available)
        pushUndo()
        update(id: groupID) { $0.instruments = [inst] }
        isDirty = true
        syncMidiZones()
    }

    /// Removes a MIDI zone's instrument. One undo point.
    func removeZoneInstrument(groupID: UUID) {
        guard canHaveZoneInstrument(groupID), find(id: groupID)?.instruments.isEmpty == false else { return }
        pushUndo()
        if let key = find(id: groupID)?.instruments.first?.id { _ = key }
        update(id: groupID) { $0.instruments = [] }
        isDirty = true
        syncMidiZones()
    }

    // MARK: Finishing

    /// The tempo the notes of a take are expressed against (`MidiNote` is in beats).
    private var recordingBPM: Double { engine?.getTempo() ?? 120 }

    /// The take a MIDI zone receives, as a model object: the notes in beats relative to the take's start
    /// (handles negative), a COPY of the zone's instrument under a new id with its live state. nil when there is
    /// no note (no take).
    func midiTakeObject(from midi: RecordedMidi, zone: SoundObject, plan: RecordTakePlanner.Plan) -> SoundObject? {
        let bpm = recordingBPM
        guard let notes = MidiTakePlanner.notes(midi.notes, pedal: midi.pedal, takeStart: plan.take.start,
                                                captureEnd: midi.origin + midi.length, bpm: bpm) else { return nil }
        let lengthBeats = max(1.0, plan.take.duration * bpm / 60.0)
        var take = SoundObject(id: UUID(), startTime: plan.take.start, duration: plan.take.duration,
                               lane: plan.take.lane, kind: .midiClip(notes: notes, lengthBeats: lengthBeats))
        take.instruments = copiedInstruments(of: zone)
        return take
    }
}
