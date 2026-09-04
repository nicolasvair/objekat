import Foundation

// MIDI integration — step A: creating a MIDI clip playing a virtual instrument.
// A MIDI clip = a dedicated AudioTrack (like an audio clip) carrying a te::MidiClip; the instrument
// sits at the head of the chain (index 0, outside the FX rack) on the engine side. The note-editing
// piano roll is step C: to validate the audio right away, a test pattern is sown (a C major scale).
// See project_midi_integration.
extension EditViewModel {

    // MARK: - Creating a MIDI clip

    /// Creates a MIDI clip from a time selection (the same UX as an aux: right-click on
    /// the selection). Its window = the range, on the topmost lane. Notes = the test pattern sown.
    func createMidiClipFromTimeSelection(_ sel: TimeSelection) {
        let t1 = sel.timeRange.lowerBound
        let t2 = sel.timeRange.upperBound
        guard t2 > t1 else { return }
        createMidiClip(startTime: t1, duration: t2 - t1, displayLane: sel.lanes.min() ?? 0)
        timeSelection = nil
    }

    /// Creates a MIDI clip at the caret (the lane+time insertion point) with a default duration.
    func createMidiClipAtCaret() {
        let start = cursorPosition
        let lane  = caretLane ?? 0
        let bpm   = engine?.getTempo() ?? 120
        let duration = 4.0 * 60.0 / bpm   // 4 beats by default
        createMidiClip(startTime: start, duration: duration, displayLane: lane)
    }

    /// The heart of creation: materialises the `.midiClip` SoundObject, places it (model + syncAdd →
    /// engineAddMidiClip) and selects it. The musical length (in beats) is derived from the tempo.
    private func createMidiClip(startTime: Double, duration: Double, displayLane: Int) {
        pushUndo()
        let bpm = engine?.getTempo() ?? 120
        let lengthBeats = max(1.0, duration * bpm / 60.0)
        // An empty clip: the notes get entered in the piano roll (double-click to open it).
        let midi = SoundObject(startTime: startTime, duration: duration, lane: displayLane,
                               kind: .midiClip(notes: [], lengthBeats: lengthBeats))
        let placed = placeClip(midi, snapshot: laneEntries)   // model + syncAdd → engineAddMidiClip
        selectedIDs = [placed.id]
        isDirty = true
    }

    // MARK: - Piano roll (step C): opening inline + editing the notes

    /// Unfolds/folds a MIDI clip's piano roll under the clip (reserves a band of sub-lanes,
    /// like an expanded group). Pure UI: no engine call, only the open state is persisted.
    func togglePianoRoll(id: UUID) {
        // The automation band is open: it has taken the piano roll's place. Toggling
        // `pianoRollOpen` would be invisible — we go back to the content first (@see
        // toggleGroupExpansion, which applies the same rule to groups).
        if find(id: id)?.automationOpen == true {
            setAutomationOpen(id: id, false)
            return
        }
        update(id: id) { obj in
            guard obj.isMIDI else { return }
            obj.pianoRollOpen.toggle()
        }
        selectedMidiNoteIDs.removeAll()
        if focusedMidiClipID == id { focusedMidiClipID = nil }
        isDirty = true
    }

    /// Returns the same notes with FRESH ids. Mandatory as soon as a MIDI clip is duplicated:
    /// a `MidiNote.id` names a note ACROSS THE WHOLE PROJECT (`selectedMidiNoteIDs` is
    /// global, and transposing / deleting / duplicating notes resolves the selection by sweeping
    /// EVERY clip — see `selectedMidiNotesByClip`). Two clips carrying the same id means
    /// a note edited in both at once. The same requirement as `splitMidiNotes` for the
    /// right-hand half of a cut.
    static func freshNoteIDs(_ notes: [MidiNote]) -> [MidiNote] {
        notes.map { n in
            MidiNote(pitch: n.pitch, startBeat: n.startBeat,
                     lengthBeats: n.lengthBeats, velocity: n.velocity)
        }
    }

    /// Creates a note in the MIDI clip and pushes it to the engine (undo grouped into one step).
    func addMidiNote(toObject id: UUID, pitch: Int, startBeat: Double,
                     lengthBeats: Double, velocity: Int = 100) {
        pushUndo()
        update(id: id) { obj in
            guard obj.isMIDI else { return }
            var notes = obj.midiNotes
            notes.append(MidiNote(pitch: pitch.clamped(to: 0...127),
                                  startBeat: max(0, startBeat),
                                  lengthBeats: max(0.01, lengthBeats),
                                  velocity: velocity.clamped(to: 0...127)))
            obj.midiNotes = notes
        }
        if let obj = find(id: id) { syncMidiNotes(obj) }
        isDirty = true
    }

    /// Deletes a note from the MIDI clip and resynchronises the engine.
    func deleteMidiNote(fromObject id: UUID, noteID: UUID) {
        deleteMidiNotes(fromObject: id, noteIDs: [noteID])
    }

    /// Deletes a batch of notes (a single undo) and resynchronises the engine.
    func deleteMidiNotes(fromObject id: UUID, noteIDs: Set<UUID>) {
        guard !noteIDs.isEmpty else { return }
        pushUndo()
        update(id: id) { obj in
            guard obj.isMIDI else { return }
            obj.midiNotes.removeAll { noteIDs.contains($0.id) }
        }
        selectedMidiNoteIDs.subtract(noteIDs)
        if let obj = find(id: id) { syncMidiNotes(obj) }
        isDirty = true
    }

    /// Deletes every currently selected note (potentially spread across
    /// several MIDI clips). A single undo. Called by Backspace when a note selection
    /// exists (otherwise Backspace deletes the selected clips, see TimelineKeyHandler).
    func deleteSelectedMidiNotes() {
        guard !selectedMidiNoteIDs.isEmpty else { return }
        var byClip: [UUID: Set<UUID>] = [:]
        func scan(_ arr: [SoundObject]) {
            for o in arr {
                if o.isMIDI {
                    let owned = Set(o.midiNotes.map(\.id)).intersection(selectedMidiNoteIDs)
                    if !owned.isEmpty { byClip[o.id, default: []].formUnion(owned) }
                }
                if case .group(let ch, _) = o.kind { scan(ch) }
            }
        }
        scan(items)
        guard !byClip.isEmpty else { selectedMidiNoteIDs.removeAll(); return }
        pushUndo()
        for (clipID, noteIDs) in byClip {
            update(id: clipID) { obj in
                guard obj.isMIDI else { return }
                obj.midiNotes.removeAll { noteIDs.contains($0.id) }
            }
            if let obj = find(id: clipID) { syncMidiNotes(obj) }
        }
        selectedMidiNoteIDs.removeAll()
        isDirty = true
    }

    /// The start of a note drag (resize / move / velocity): captures the undo ONCE
    /// for the whole gesture. The following frames go through `updateMidiNote` (with no undo).
    func beginMidiNoteEdit() { pushUndo() }

    /// A live mutation of ONE note during a drag (no pushUndo: already done by
    /// `beginMidiNoteEdit`). Resynchronises the engine on every frame.
    func updateMidiNote(inObject id: UUID, noteID: UUID,
                        _ transform: (inout MidiNote) -> Void) {
        updateMidiNotes(inObject: id) { notes in
            guard let idx = notes.firstIndex(where: { $0.id == noteID }) else { return }
            transform(&notes[idx])
        }
    }

    /// A live mutation of SEVERAL notes in one pass (moving / velocity of a selection),
    /// with a single engine resync. No pushUndo (already done by `beginMidiNoteEdit`).
    func updateMidiNotes(inObject id: UUID, _ transform: (inout [MidiNote]) -> Void) {
        update(id: id) { obj in
            guard obj.isMIDI else { return }
            var notes = obj.midiNotes
            transform(&notes)
            // A guard over the WHOLE list, hence over notes the gesture never touched:
            // no `max(0, startBeat)` here. A negative startBeat is legitimate, coming from the
            // non-destructive left trim (a note masked before the edge, see `updateTrim`) — clamping it
            // would bring every masked note in the clip back onto the edge at the first note
            // move. The piano roll's gestures already bound their own note.
            for i in notes.indices {
                notes[i].pitch       = notes[i].pitch.clamped(to: 0...127)
                notes[i].velocity    = notes[i].velocity.clamped(to: 0...127)
                notes[i].lengthBeats = max(0.01, notes[i].lengthBeats)
            }
            obj.midiNotes = notes
        }
        if let obj = find(id: id) { syncMidiNotes(obj) }
        isDirty = true
    }
}
