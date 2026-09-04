import Foundation

// Editing notes in the piano roll (step C): navigation (an octave shift with the visible
// window following), copy/paste of notes, and duplication in place (alt-drag). All these
// operations line up with the conventions already in place for clips/groups.
// See project_midi_integration.
extension EditViewModel {

    /// The default pitch at the bottom of the piano roll's window (C3). The window shows 2 octaves.
    static let pianoRollDefaultBasePitch = 48
    /// The highest possible bottom pitch: 24 semitones are shown above it, capped at 127.
    static let pianoRollMaxBasePitch = 127 - 24

    // MARK: - The note clipboard

    /// The copied notes, normalised so that the earliest starts at beat 0 (the pitches
    /// stay absolute). `sourceClipID` = the clip of origin, the default paste target.
    struct MidiNotesClipboard {
        var notes: [MidiNote]
        var sourceClipID: UUID
    }

    /// Every MIDI clip in the project (top-level + descendants of groups), flattened.
    private func forEachMidiClip(_ body: (SoundObject) -> Void) {
        func walk(_ arr: [SoundObject]) {
            for o in arr {
                if o.isMIDI { body(o) }
                if case .group(let ch, _) = o.kind { walk(ch) }
            }
        }
        walk(items)
    }

    /// Groups the selected notes by the MIDI clip that owns them.
    private func selectedMidiNotesByClip() -> [UUID: Set<UUID>] {
        var byClip: [UUID: Set<UUID>] = [:]
        forEachMidiClip { o in
            let owned = Set(o.midiNotes.map(\.id)).intersection(selectedMidiNoteIDs)
            if !owned.isEmpty { byClip[o.id] = owned }
        }
        return byClip
    }

    // MARK: - Copy / paste

    /// Copies the selected notes (normalised from beat 0). The default paste target clip
    /// = that of the first note met.
    func copySelectedMidiNotes() {
        guard !selectedMidiNoteIDs.isEmpty else { return }
        let byClip = selectedMidiNotesByClip()
        guard !byClip.isEmpty else { return }

        var collected: [MidiNote] = []
        var sourceClipID: UUID? = nil
        forEachMidiClip { o in
            guard let ids = byClip[o.id] else { return }
            if sourceClipID == nil { sourceClipID = o.id }
            collected.append(contentsOf: o.midiNotes.filter { ids.contains($0.id) })
        }
        guard let src = sourceClipID, let minBeat = collected.map(\.startBeat).min() else { return }

        midiNotesClipboard = MidiNotesClipboard(
            notes: collected.map { n in
                var c = n; c.startBeat = max(0, n.startBeat - minBeat); return c
            },
            sourceClipID: src
        )
    }

    /// The paste's target clip: the source clip if it still exists and is still MIDI, otherwise a
    /// MIDI clip taken from the current clip selection.
    private func midiPasteTargetClipID(_ cb: MidiNotesClipboard) -> UUID? {
        if let src = find(id: cb.sourceClipID), src.isMIDI { return cb.sourceClipID }
        var fallback: UUID? = nil
        forEachMidiClip { o in if fallback == nil, selectedIDs.contains(o.id) { fallback = o.id } }
        return fallback
    }

    /// True if pasting notes is possible (a non-empty clipboard + a resolved target clip).
    var canPasteMidiNotes: Bool {
        guard let cb = midiNotesClipboard else { return false }
        return midiPasteTargetClipID(cb) != nil
    }

    /// Pastes the clipboard's notes into the target clip, at the playhead (the black cursor),
    /// snapped to the grid. Pitches kept; relative timing kept. Selects the copies.
    func pasteMidiNotes() {
        guard let cb = midiNotesClipboard, !cb.notes.isEmpty,
              let targetID = midiPasteTargetClipID(cb),
              let clip = find(id: targetID), clip.isMIDI else { return }

        let secPerBeat = 60.0 / tempo
        let g = effectiveSnapGrid
        let snappedAbs = (effectiveSnapEnabled && g > 0)
            ? (cursorPosition / g).rounded() * g : cursorPosition
        let anchorBeat = max(0, (snappedAbs - clip.startTime) / secPerBeat)

        pushUndo()
        var newIDs: Set<UUID> = []
        update(id: targetID) { obj in
            guard obj.isMIDI else { return }
            for n in cb.notes {
                var c = n
                c.id = UUID()
                c.startBeat = max(0, anchorBeat + n.startBeat)
                obj.midiNotes.append(c)
                newIDs.insert(c.id)
            }
        }
        if let obj = find(id: targetID) { syncMidiNotes(obj) }
        selectedMidiNoteIDs = newIDs
        isDirty = true
    }

    // MARK: - Transposition (semitone / octave)

    /// Transposes the selected notes by `delta` semitones. If `followWindow` is true (an octave
    /// shift), the piano roll's visible window follows by the same delta so that the notes stay
    /// on screen in the same place (only the octave labels change).
    func transposeSelectedMidiNotes(bySemitones delta: Int, followWindow: Bool = false) {
        guard !selectedMidiNoteIDs.isEmpty, delta != 0 else { return }
        let byClip = selectedMidiNotesByClip()
        guard !byClip.isEmpty else { return }

        pushUndo()
        for (clipID, noteIDs) in byClip {
            update(id: clipID) { obj in
                guard obj.isMIDI else { return }
                for i in obj.midiNotes.indices where noteIDs.contains(obj.midiNotes[i].id) {
                    obj.midiNotes[i].pitch = (obj.midiNotes[i].pitch + delta).clamped(to: 0...127)
                }
            }
            if let obj = find(id: clipID) { syncMidiNotes(obj) }
            if followWindow {
                let base = pianoRollBasePitchByClip[clipID] ?? Self.pianoRollDefaultBasePitch
                pianoRollBasePitchByClip[clipID] =
                    (base + delta).clamped(to: 0...Self.pianoRollMaxBasePitch)
            }
        }
        isDirty = true
    }

    /// A shift of one octave (`direction` = +1 / -1), with the window following. See `transposeSelectedMidiNotes`.
    func shiftSelectedMidiNotesByOctave(_ direction: Int) {
        transposeSelectedMidiNotes(bySemitones: direction * 12, followWindow: true)
    }

    // MARK: - Piano roll display settings (oct / crop / zoom)

    /// The bounds of a row's height (zoom +/-). To be adjusted as needed (see the specification).
    static let pianoRollMinRowHeight: Double = 4
    static let pianoRollMaxRowHeight: Double = 48

    /// Zoom +/-: adjusts the GLOBAL height per note (thinner / thicker notes). It does NOT
    /// affect the band's height (which depends on the blockHeight vertical zoom): only the row
    /// density changes. Pure UI.
    func pianoRollZoom(_ direction: Int) {
        let factor = direction > 0 ? 1.2 : 1.0 / 1.2
        pianoRollRowHeight = (pianoRollRowHeight * factor)
            .clamped(to: Self.pianoRollMinRowHeight...Self.pianoRollMaxRowHeight)
    }

    /// oct +/-: moves a clip's piano roll VIEW (without transposing the notes). In normal mode it
    /// shifts the pitch window by an octave (bounded 0...127, the fine reframing done at display time).
    /// In crop mode it scrolls through the list of pitches in use (an "octave" step means nothing
    /// on a non-linear axis). Pure UI.
    func shiftPianoRollView(clipID: UUID, direction: Int) {
        if pianoRollCropByClip[clipID] ?? false {
            let cur = pianoRollCropOffsetByClip[clipID] ?? 0
            pianoRollCropOffsetByClip[clipID] = max(0, cur + direction)
        } else {
            let base = pianoRollBasePitchByClip[clipID] ?? Self.pianoRollDefaultBasePitch
            pianoRollBasePitchByClip[clipID] = (base + direction * 12).clamped(to: 0...127)
        }
    }

    /// Toggles a clip's crop mode (the pitches in use only).
    func togglePianoRollCrop(clipID: UUID) {
        pianoRollCropByClip[clipID] = !(pianoRollCropByClip[clipID] ?? false)
        pianoRollCropOffsetByClip[clipID] = 0   // starts again from the top of the list
    }

    // MARK: - Cut / duplicate

    /// Cut = copy the note selection then delete it (a single undo, carried by the
    /// deletion). See `copySelectedMidiNotes` / `deleteSelectedMidiNotes`.
    func cutSelectedMidiNotes() {
        guard !selectedMidiNoteIDs.isEmpty else { return }
        copySelectedMidiNotes()
        deleteSelectedMidiNotes()
    }

    /// Duplicates the selected notes, shifted to just after the selection (offset = the selection's
    /// total duration, in beats); the copies become the new selection. A single undo.
    func duplicateSelectedMidiNotes() {
        guard !selectedMidiNoteIDs.isEmpty else { return }
        let byClip = selectedMidiNotesByClip()
        guard !byClip.isEmpty else { return }

        // The global offset = the selection's span (max end − min start) across every clip, so as to
        // keep the copies in step when the selection covers several clips.
        var minStart =  Double.greatestFiniteMagnitude
        var maxEnd   = -Double.greatestFiniteMagnitude
        forEachMidiClip { o in
            guard let ids = byClip[o.id] else { return }
            for n in o.midiNotes where ids.contains(n.id) {
                minStart = min(minStart, n.startBeat)
                maxEnd   = max(maxEnd, n.startBeat + n.lengthBeats)
            }
        }
        let offset = max(0, maxEnd - minStart)
        guard offset > 0 else { return }

        pushUndo()
        var newIDs: Set<UUID> = []
        for (clipID, ids) in byClip {
            update(id: clipID) { obj in
                guard obj.isMIDI else { return }
                let originals = obj.midiNotes.filter { ids.contains($0.id) }
                for o in originals {
                    var c = o
                    c.id = UUID()
                    c.startBeat = max(0, o.startBeat + offset)
                    obj.midiNotes.append(c)
                    newIDs.insert(c.id)
                }
            }
            if let obj = find(id: clipID) { syncMidiNotes(obj) }
        }
        selectedMidiNoteIDs = newIDs
        isDirty = true
    }

    // MARK: - Duplication in place (alt-drag)

    /// Duplicates notes IN PLACE (the same positions, new ids) inside `id`, to prime an
    /// alt-drag: the copies will then be moved while the originals stay. Pushes the
    /// undo (the drag that follows mutates live, with no further undo). Returns the notes created
    /// + the old→new id table (to find the note that was grabbed).
    func duplicateMidiNotesInPlace(inObject id: UUID, noteIDs: Set<UUID>)
        -> (newNotes: [MidiNote], oldToNew: [UUID: UUID]) {
        guard !noteIDs.isEmpty else { return ([], [:]) }
        pushUndo()
        var oldToNew: [UUID: UUID] = [:]
        var newNotes: [MidiNote] = []
        update(id: id) { obj in
            guard obj.isMIDI else { return }
            for o in obj.midiNotes where noteIDs.contains(o.id) {
                var c = o
                c.id = UUID()
                oldToNew[o.id] = c.id
                newNotes.append(c)
            }
            obj.midiNotes.append(contentsOf: newNotes)
        }
        if let obj = find(id: id) { syncMidiNotes(obj) }
        isDirty = true
        return (newNotes, oldToNew)
    }
}
