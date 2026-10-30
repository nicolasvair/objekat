import Foundation

// MARK: - MIDI recording zones (rec3-midi)
//
// A MIDI recording zone is a GROUP with a `recordMidiInput` (the counterpart of `recordInput`), recorded
// with the same transport button into the same kind of take: a child with handles, on the top lane, the
// previous takes muted or not by the zone's take mode, ONE undo. Where it differs:
//
//  - the source is a MIDI input the ENGINE lists (`midiInputs`), found again by id then by name;
//  - the zone may carry an INSTRUMENT (`SoundObject.instruments`, saved as `zoneInstruments`), put on the
//    group's own container like any group's: it plays the notes of the EMPTY clips below it, takes included.
//    A take is therefore always an empty clip (no instrument of its own). The armed zone owns a hidden track
//    the device is targeted at (`OBJEngineCore.setMidiZones:`) to capture, and that track plays nothing;
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
                self.syncInputChains()      // a device that comes back finds its instrument again (E9)
            }
        }
        AudioDeviceStatus.shared.onSnapshotChange = { [weak self] in
            MainActor.assumeIsolated { self?.syncInputChains() }
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

    /// What a drag that starts on `row` carries: when the row is part of the selection, every selected input
    /// (the MIDI ones first, in the order of the list, then the card's by channel); otherwise the row alone.
    /// The two lists share one gesture, so a selection holding both kinds is dragged whole.
    func draggedSources(startingFrom row: RecordSource) -> [RecordSource] {
        let inSelection: Bool
        switch row {
        case .audio(let r): inSelection = selectedRecordInputs.contains(r)
        case .midi(let m): inSelection = selectedMidiInputs.contains(m.id)
        }
        guard inSelection else { return [row] }
        let midi = midiInputs.filter { selectedMidiInputs.contains($0.id) }.map { RecordSource.midi($0.ref) }
        return midi + selectedRecordInputs.sorted().map { RecordSource.audio($0) }
    }

    // MARK: Capturing with the armed zones

    /// Tells the engine which MIDI zones are armed (zone + device), so that each one has the hidden track its
    /// device is targeted at, to capture the take. The track plays nothing: a zone's instrument lives on the
    /// group's own container and is heard through the take, never live (arming is not hearing).
    func syncMidiZones() {
        guard !isRecording, let engine else { return }
        var wanted: [[String: Any]] = []
        for id in Set(armedRecordZones) {
            guard let zone = find(id: id), let ref = zone.recordMidiInput,
                  let device = resolvedMidiInput(ref) else { continue }
            wanted.append(["zone": id.uuidString, "device": device.id])
        }
        engine.setMidiZones(wanted)
    }

    // MARK: Finishing

    /// The tempo the notes of a take are expressed against (`MidiNote` is in beats).
    private var recordingBPM: Double { engine?.getTempo() ?? 120 }

    /// The take a MIDI zone receives, as a model object: the notes in beats relative to the take's start
    /// (handles negative). An EMPTY clip: the instrument stays on the zone and plays the take. nil when there
    /// is no note (no take).
    func midiTakeObject(from midi: RecordedMidi, zone: SoundObject, plan: RecordTakePlanner.Plan) -> SoundObject? {
        let bpm = recordingBPM
        guard let notes = MidiTakePlanner.notes(midi.notes, pedal: midi.pedal, takeStart: plan.take.start,
                                                captureEnd: midi.origin + midi.length, bpm: bpm) else { return nil }
        let lengthBeats = max(1.0, plan.take.duration * bpm / 60.0)
        var take = SoundObject(id: UUID(), startTime: plan.take.start, duration: plan.take.duration,
                               lane: plan.take.lane, kind: .midiClip(notes: notes, lengthBeats: lengthBeats))
        return take
    }
}
