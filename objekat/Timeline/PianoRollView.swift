import SwiftUI
import AppKit

/// The piano roll for editing a MIDI clip's notes, unfolded INLINE under the clip (in the band
/// of sub-lanes `SoundObject.expandedSpan` reserves). Rendered as an overlay positioned by
/// `TimelineView`; its width = the clip's, its height = the reserved band.
///
/// Conventions (see project_midi_integration):
/// - The height PER NOTE = the global `pianoRollRowHeight` state (the band's zoom +/-),
///   DECOUPLED from the band's height: the number of visible rows follows from the band's height
///   (shift+R/T grows the band → more notes, the size per note unchanged). The default window is around C3.
/// - A control band at the bottom: oct +/- (moves the view), crop (present pitches only, per
///   clip), zoom +/- (the height per note). See `controlStrip`.
/// - Local geometry: x=0 = the clip's start; time in beats at the current tempo.
/// - Creating = a double click on the background; deleting = a double click on a note;
///   the left/right handles = resize; ⌘+a vertical drag on the body = velocity;
///   dragging the body = moving (pitch plus time).
///
/// Gestures: a single (high-priority) `DragGesture` branching on the starting zone plus ⌘,
/// plus a plain `SpatialTapGesture` with manual double-click detection. That choice avoids the
/// '50%' bug of competing `DragGesture`s (see feedback_swiftui_gestures) and consumes the plain
/// clicks so that they do not fall through onto the timeline's canvas.
struct PianoRollView: View {
    var viewModel: EditViewModel
    let object: SoundObject
    let pixelsPerSecond: Double
    let secPerBeat: Double
    let bandHeight: Double
    /// Moves the playback cursor to the ABSOLUTE time clicked (a click on the empty background), so
    /// as to be able to start playback from there. Wired by TimelineView (seek + cursor).
    var onSeekToTime: (Double) -> Void = { _ in }

    /// The fixed height of the control band (oct / crop / zoom) at the bottom of the piano roll.
    private let controlStripHeight: Double = 20

    /// The height reserved for drawing the notes (the band minus the control band).
    private var noteAreaHeight: Double { max(rowHeight, bandHeight - controlStripHeight) }

    // The height PER NOTE: a GLOBAL state set by zoom +/-, DECOUPLED from the band's height. The
    // number of visible rows follows from it (the taller the band through shift+R/T, the more
    // notes one sees; the height per note does not move).
    private var rowHeight: Double {
        viewModel.pianoRollRowHeight
            .clamped(to: EditViewModel.pianoRollMinRowHeight...EditViewModel.pianoRollMaxRowHeight)
    }
    private var visibleRowCount: Int { max(1, Int((noteAreaHeight / rowHeight).rounded(.down))) }

    private var cropOn: Bool { viewModel.pianoRollCropByClip[object.id] ?? false }

    /// The notes the clip really PLAYS: those whose attack falls between its two edges.
    /// A note hidden by the left trim still lives in the model (reopening the edge gives it back,
    /// see `updateTrim`) but is not pushed to the engine — so it must neither show, nor be
    /// selectable, nor weigh on the crop mode's axis.
    private var visibleNotes: [MidiNote] {
        object.midiNotes.filter { n in
            let x = n.startBeat * secPerBeat * pixelsPerSecond
            return x >= 0 && x < width
        }
    }

    /// The sorted (ascending) list of the pitches really present in the clip — the crop mode's axis.
    private var usedPitches: [Int] { Array(Set(visibleNotes.map(\.pitch))).sorted() }

    /// The pitch at the bottom of the window (normal mode), bounded to stay within 0...127.
    private var basePitch: Int {
        let stored = viewModel.pianoRollBasePitchByClip[object.id] ?? EditViewModel.pianoRollDefaultBasePitch
        return stored.clamped(to: 0...max(0, 127 - (visibleRowCount - 1)))
    }

    /// The pitches shown from TOP to BOTTOM (rowPitches[0] = the top row). In crop mode it holds
    /// only the pitches used (a scrollable window); in normal mode, a continuous range.
    private var rowPitches: [Int] {
        if cropOn {
            let used = usedPitches
            if used.isEmpty { return normalRowPitches() }
            let maxOff = max(0, used.count - visibleRowCount)
            let off = (viewModel.pianoRollCropOffsetByClip[object.id] ?? 0).clamped(to: 0...maxOff)
            let hi = min(used.count, off + visibleRowCount)
            return used[off..<hi].reversed().map { $0 }   // the highest pitch first
        }
        return normalRowPitches()
    }
    private func normalRowPitches() -> [Int] {
        let base = basePitch
        let top  = base + visibleRowCount - 1
        return (base...top).reversed().map { $0 }
    }

    private var width: Double { max(1, object.duration * pixelsPerSecond) }

    private var snapOn: Bool { viewModel.effectiveSnapEnabled }
    private var snapGrid: Double { viewModel.effectiveSnapGrid }       // in SECONDS
    private var minLenBeats: Double {
        snapOn && snapGrid > 0 ? max(0.05, snapGrid / secPerBeat) : 0.05
    }

    @State private var lastTap: (time: Date, loc: CGPoint) = (.distantPast, .zero)
    @State private var drag: NoteDrag? = nil
    @State private var rubber: RubberState? = nil

    private struct NoteDrag {
        enum Mode { case moveBody, resizeL, resizeR, velocity }
        let grabbedID: UUID
        let mode:   Mode
        let origs:  [UUID: MidiNote]   // snapshots of the notes the gesture affects
        let start:  CGPoint
        // The vertical movement axis frozen at the start of the gesture: the list of pitches used in
        // crop mode (the axis must not move under the cursor during the drag), empty in normal mode
        // (movement by semitone bounded by the visible window).
        var pitchAxis: [Int] = []
    }

    /// A rubber-band selection under way. `base` = the pre-existing selection to preserve when
    /// ⌘/⇧ is held (an additive selection).
    private struct RubberState {
        var origin:  CGPoint
        var current: CGPoint
        var base:    Set<UUID>
        var rect: CGRect {
            CGRect(x: min(origin.x, current.x), y: min(origin.y, current.y),
                   width: abs(origin.x - current.x), height: abs(origin.y - current.y))
        }
    }

    private var selectedIDs: Set<UUID> { viewModel.selectedMidiNoteIDs }

    var body: some View {
        VStack(spacing: 0) {
            noteArea
                .frame(width: width, height: noteAreaHeight, alignment: .topLeading)
            controlStrip
                .frame(width: width, height: controlStripHeight)
        }
        .frame(width: width, height: bandHeight, alignment: .topLeading)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.85))
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .stroke(Color.primary.opacity(0.18), lineWidth: 1)
        )
        .clipped()
    }

    // MARK: - Note area (grid + notes + interaction)

    private var noteArea: some View {
        ZStack(alignment: .topLeading) {
            Canvas { ctx, size in drawGrid(ctx, size: size) }
                .allowsHitTesting(false)

            ForEach(object.midiNotes) { note in
                if let r = rect(for: note) {
                    let isSel = selectedIDs.contains(note.id)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(noteColor(note))
                        .overlay(
                            RoundedRectangle(cornerRadius: 2)
                                .stroke(isSel ? Color.yellow : Color.black.opacity(0.45),
                                        lineWidth: isSel ? 1.5 : 0.5)
                        )
                        .frame(width: r.width, height: r.height)
                        .offset(x: r.minX, y: r.minY)
                        .allowsHitTesting(false)
                }
            }

            // The selection rectangle (rubber band)
            if let rb = rubber {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.12))
                    .overlay(Rectangle().stroke(Color.accentColor.opacity(0.7), lineWidth: 1))
                    .frame(width: rb.rect.width, height: rb.rect.height)
                    .offset(x: rb.rect.minX, y: rb.rect.minY)
                    .allowsHitTesting(false)
            }

            // The interaction layer: it catches taps and drags over the note area.
            Color.clear
                .contentShape(Rectangle())
                .gesture(SpatialTapGesture().onEnded { handleTap(at: $0.location) })
                .highPriorityGesture(
                    DragGesture(minimumDistance: 4)
                        .onChanged { handleDragChanged($0) }
                        .onEnded   { _ in drag = nil; rubber = nil }
                )
                .onContinuousHover { phase in
                    guard drag == nil, rubber == nil else { return }
                    switch phase {
                    // The cursors go through `TimelineCursorKeeper`: it is what has AppKit claim the
                    // point, without which the arrow would come back as soon as the mouse stopped
                    // during playback (@see CursorClaim).
                    case .active(let p):
                        if NSEvent.modifierFlags.contains(.command) {
                            TimelineCursorKeeper.set(.resizeUpDown)   // ⌘ = velocity (a vertical drag)
                        } else if let (_, zone) = hitZone(at: p) {
                            switch zone {
                            case .left, .right: TimelineCursorKeeper.set(.resizeLeftRight)
                            case .body:
                                // ⌥ on the body = an alt-drag (duplication) → a 'copy' cursor.
                                TimelineCursorKeeper.set(NSEvent.modifierFlags.contains(.option)
                                                         ? .dragCopy : .openHand)
                            }
                        } else {
                            TimelineCursorKeeper.set(.arrow)
                        }
                    case .ended:
                        // Nothing to do: the hover that follows sets its own cursor (the timeline covers
                        // the whole canvas), and leaving the timeline goes through the tracking view's
                        // `mouseExited`, which hands back. Handing back here would even be risky — this
                        // `.ended` can arrive AFTER the hover that succeeds it, and would take its claim
                        // away from it.
                        break
                    }
                }
        }
    }

    // MARK: - Control band (oct / crop / zoom)

    private var controlStrip: some View {
        HStack(spacing: 10) {
            // Oct +/-: moves the view (no transposition). In crop, it scrolls the list of pitches.
            HStack(spacing: 2) {
                Text(L("pianoRoll.octave")).font(.system(size: 9)).foregroundStyle(.white.opacity(0.55))
                stripButton("chevron.up")   { viewModel.shiftPianoRollView(clipID: object.id, direction: +1) }
                stripButton("chevron.down") { viewModel.shiftPianoRollView(clipID: object.id, direction: -1) }
            }

            // Crop: shows only the pitches present in the clip.
            Toggle(isOn: Binding(
                get: { cropOn },
                set: { _ in viewModel.togglePianoRollCrop(clipID: object.id) }
            )) {
                Text(L("pianoRoll.crop")).font(.system(size: 9)).foregroundStyle(.white.opacity(0.85))
            }
            .toggleStyle(.checkbox)
            .controlSize(.mini)

            // Zoom +/-: the height per note (global), decoupled from the vertical zoom.
            HStack(spacing: 2) {
                Text(L("pianoRoll.zoom")).font(.system(size: 9)).foregroundStyle(.white.opacity(0.55))
                stripButton("minus") { viewModel.pianoRollZoom(-1) }
                stripButton("plus")  { viewModel.pianoRollZoom(+1) }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(white: 0.30))
        .overlay(alignment: .top) {
            Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 0.5)
        }
    }

    private func stripButton(_ systemName: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName).font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 14, height: 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Geometry

    /// The y (from the top) of a pitch's row, or nil if the pitch is not shown
    /// (outside the window in normal mode, or an unused pitch in crop mode).
    private func rowIndex(ofPitch p: Int) -> Int? { rowPitches.firstIndex(of: p) }

    /// A note's rectangle, or nil if it is not in the visible window — vertically (a pitch outside
    /// the window / off the crop axis) as horizontally (an attack outside the clip's edges, see
    /// `visibleNotes`). A compulsory passage for the drawing AND for both hover tests (the click,
    /// the selection rectangle): filtering here covers them all.
    private func rect(for n: MidiNote) -> CGRect? {
        guard let row = rowIndex(ofPitch: n.pitch) else { return nil }
        let x = n.startBeat * secPerBeat * pixelsPerSecond
        guard x >= 0, x < width else { return nil }
        let w = max(3, n.lengthBeats * secPerBeat * pixelsPerSecond)
        let y = Double(row) * rowHeight
        return CGRect(x: x, y: y, width: w, height: max(2, rowHeight - 1))
    }

    private func pitch(atY y: Double) -> Int {
        guard !rowPitches.isEmpty else { return basePitch }
        let i = Int((y / rowHeight).rounded(.down)).clamped(to: 0...(rowPitches.count - 1))
        return rowPitches[i]
    }

    /// The new pitch of a note moved vertically by `dRows` rows. In normal mode (an empty `axis`),
    /// movement by semitone bounded by the visible window. In crop mode, one moves along the frozen
    /// axis of the pitches used (skipping the absent ones).
    private func movedPitch(from orig: Int, dRows: Int, axis: [Int]) -> Int {
        if axis.isEmpty {
            let lo = rowPitches.min() ?? 0
            let hi = rowPitches.max() ?? 127
            return (orig - dRows).clamped(to: lo...hi)
        }
        guard let idx = axis.firstIndex(of: orig) else { return orig }
        return axis[(idx - dRows).clamped(to: 0...(axis.count - 1))]
    }

    private func note(at p: CGPoint) -> MidiNote? {
        object.midiNotes.first {
            guard let r = rect(for: $0) else { return false }
            return r.insetBy(dx: 0, dy: -0.5).contains(p)
        }
    }

    private enum Zone { case left, right, body }

    /// The width of a resize handle: proportional so as to stay grabbable on short notes, but
    /// bounded so that a body (for moving) is always left in the middle.
    private func handleW(_ noteWidth: Double) -> Double {
        min(8, max(3, noteWidth * 0.3))
    }

    /// The note under the point plus the zone (left handle / right handle / body), for the cursor and the drag.
    private func hitZone(at p: CGPoint) -> (note: MidiNote, zone: Zone)? {
        guard let n = note(at: p), let r = rect(for: n) else { return nil }
        let lx = p.x - r.minX
        let hw = handleW(r.width)
        if lx <= hw            { return (n, .left) }
        if lx >= r.width - hw  { return (n, .right) }
        return (n, .body)
    }

    /// Snaps an ABSOLUTE second to the grid (round = the nearest edge).
    private func snapAbs(_ s: Double) -> Double {
        snapOn && snapGrid > 0 ? (s / snapGrid).rounded() * snapGrid : s
    }

    /// localX → a beat relative to the clip, snapped to the grid (rounded down = the cell clicked).
    private func snappedStartBeat(atX x: Double, floor: Bool) -> Double {
        let absSec = object.startTime + x / pixelsPerSecond
        let snapped: Double
        if snapOn && snapGrid > 0 {
            let f = absSec / snapGrid
            snapped = (floor ? f.rounded(.down) : f.rounded()) * snapGrid
        } else {
            snapped = absSec
        }
        return max(0, (snapped - object.startTime) / secPerBeat)
    }

    // MARK: - Grid rendering

    private func drawGrid(_ ctx: GraphicsContext, size: CGSize) {
        // Horizontal bands: shaded black keys plus separators; a stronger line on C.
        // We iterate the SHOWN rows (continuous in normal mode, the pitches used in crop).
        let blackKeys: Set<Int> = [1, 3, 6, 8, 10]
        for (row, p) in rowPitches.enumerated() {
            let y = Double(row) * rowHeight
            if blackKeys.contains(((p % 12) + 12) % 12) {
                let rect = CGRect(x: 0, y: y, width: size.width, height: rowHeight)
                ctx.fill(Path(rect), with: .color(.primary.opacity(0.07)))
            }
            var sep = Path()
            sep.move(to: CGPoint(x: 0, y: y))
            sep.addLine(to: CGPoint(x: size.width, y: y))
            let isC = (((p % 12) + 12) % 12) == 0
            ctx.stroke(sep, with: .color(.primary.opacity(isC ? 0.22 : 0.07)), lineWidth: isC ? 1 : 0.5)
            if isC {
                let octave = p / 12 - 1
                ctx.draw(Text(verbatim: "C\(octave)").font(.system(size: 8)).foregroundColor(.secondary),
                         at: CGPoint(x: 13, y: y + rowHeight / 2), anchor: .center)
            }
        }

        // The vertical lines of the beat grid, aligned on the global ruler (absolute time).
        for level in viewModel.gridLevels where level.interval > 0 {
            let stepPx = level.interval * pixelsPerSecond
            guard stepPx > 1 else { continue }
            var idx = Int(ceil(object.startTime / level.interval))
            while true {
                let xLocal = (Double(idx) * level.interval - object.startTime) * pixelsPerSecond
                if xLocal > size.width + 1 { break }
                if xLocal >= -1 {
                    var line = Path()
                    line.move(to: CGPoint(x: xLocal, y: 0))
                    line.addLine(to: CGPoint(x: xLocal, y: size.height))
                    ctx.stroke(line, with: .color(.primary.opacity(level.opacity)), lineWidth: 0.5)
                }
                idx += 1
            }
        }
    }

    private func noteColor(_ n: MidiNote) -> Color {
        let v = Double(n.velocity) / 127.0
        return Color.accentColor.opacity(0.40 + 0.55 * v)
    }

    // MARK: - Taps (creating / deleting)

    private func handleTap(at p: CGPoint) {
        viewModel.focusedMidiClipID = object.id   // enters this clip's piano-roll context
        let now = Date()
        let isDouble = now.timeIntervalSince(lastTap.time) < 0.35
            && hypot(p.x - lastTap.loc.x, p.y - lastTap.loc.y) < 18
        lastTap = (now, p)
        let cmd   = NSEvent.modifierFlags.contains(.command)
        let shift = NSEvent.modifierFlags.contains(.shift)

        if isDouble {
            if let hit = note(at: p) {
                // A double click on a note inside a multiple selection → it deletes the whole selection.
                if selectedIDs.contains(hit.id) && selectedIDs.count > 1 {
                    viewModel.deleteMidiNotes(fromObject: object.id, noteIDs: selectedIDs)
                } else {
                    viewModel.deleteMidiNote(fromObject: object.id, noteID: hit.id)
                }
            } else {
                let pitch = pitch(atY: p.y)
                let startBeat = snappedStartBeat(atX: p.x, floor: true)
                let length = max(0.05, snapOn && snapGrid > 0 ? snapGrid / secPerBeat : 1.0)
                viewModel.addMidiNote(toObject: object.id, pitch: pitch,
                                      startBeat: startBeat, lengthBeats: length)
            }
            return
        }

        // A plain click: selecting notes (the same logic as clips). It also consumes the
        // event so as not to move the cursor through the timeline's canvas.
        if let hit = note(at: p) {
            if cmd {
                if selectedIDs.contains(hit.id) { viewModel.selectedMidiNoteIDs.remove(hit.id) }
                else { viewModel.selectedMidiNoteIDs.insert(hit.id) }
            } else if shift {
                selectRange(to: hit)
            } else {
                viewModel.selectedMidiNoteIDs = [hit.id]
                viewModel.select(object.id, additive: false)
            }
        } else if !cmd && !shift {
            // A click on the empty background: it deselects the notes AND lays the playback cursor
            // at the time clicked (so as to play from there).
            viewModel.selectedMidiNoteIDs = []
            viewModel.select(object.id, additive: false)
            // The black cursor (the playhead) snapped to the grid, as in the timeline.
            onSeekToTime(max(0, snapAbs(object.startTime + p.x / pixelsPerSecond)))
        }
    }

    /// A ⇧ selection: it takes in every note inside the box (time × pitch) between the current
    /// selection and the note clicked (the counterpart of the shift extension on clips).
    private func selectRange(to hit: MidiNote) {
        let sel = object.midiNotes.filter { selectedIDs.contains($0.id) }
        guard !sel.isEmpty else { viewModel.selectedMidiNoteIDs = [hit.id]; return }
        let beatLo = min(sel.map(\.startBeat).min()!, hit.startBeat)
        let beatHi = max(sel.map { $0.startBeat + $0.lengthBeats }.max()!,
                         hit.startBeat + hit.lengthBeats)
        let pLo = min(sel.map(\.pitch).min()!, hit.pitch)
        let pHi = max(sel.map(\.pitch).max()!, hit.pitch)
        viewModel.selectedMidiNoteIDs = Set(
            visibleNotes.filter {
                $0.startBeat < beatHi && ($0.startBeat + $0.lengthBeats) > beatLo
                && $0.pitch >= pLo && $0.pitch <= pHi
            }.map(\.id)
        )
    }

    // MARK: - Drag (resize / move / velocity)

    private func handleDragChanged(_ value: DragGesture.Value) {
        // ── Initialisation ──────────────────────────────────────────────────────
        if drag == nil && rubber == nil {
            viewModel.focusedMidiClipID = object.id   // this clip's piano-roll context
            let cmd   = NSEvent.modifierFlags.contains(.command)
            let shift = NSEvent.modifierFlags.contains(.shift)
            if let (hit, zone) = hitZone(at: value.startLocation) {
                let option = NSEvent.modifierFlags.contains(.option)
                // ⌘ does not mean the same thing depending on where one grabbed — and above all, the
                // ZONE is the only thing this gesture knows from the click onwards: the modifiers are
                // read on the FIRST MOVEMENT (the drag starts at 4 px), so much later.
                // Deciding 'velocity' on ⌘ whatever the place made resizing impossible as soon as ⌘
                // was pressed between the click on the edge and the movement: the gesture flipped to
                // velocity. On an edge, ⌘ means 'leave the grid' (`effectiveSnapEnabled` inverts the
                // snap, reread continuously during the drag); velocity, for its part, stays the ⌘ of
                // the note's BODY.
                let mode: NoteDrag.Mode
                switch zone {
                case .left:  mode = .resizeL
                case .right: mode = .resizeR
                case .body:  mode = cmd ? .velocity : .moveBody
                }
                let isResize = (mode == .resizeL || mode == .resizeR)

                // The note grabbed enters the selection if it was not in it. On a resize, ⌘ no longer
                // means 'additive' (it serves the grid) — and in any case a resize only touches the
                // note grabbed.
                if !selectedIDs.contains(hit.id) {
                    if (cmd && !isResize) || shift { viewModel.selectedMidiNoteIDs.insert(hit.id) }
                    else                           { viewModel.selectedMidiNoteIDs = [hit.id] }
                }

                if option, mode == .moveBody {
                    // An alt-drag = it duplicates the selection IN PLACE then moves the copies (the
                    // originals stay put), like the clips' alt-drag. The undo is pushed by the
                    // duplication; so we do not call beginMidiNoteEdit.
                    let affectedIDs = selectedIDs.union([hit.id])
                    let (newNotes, oldToNew) = viewModel.duplicateMidiNotesInPlace(
                        inObject: object.id, noteIDs: affectedIDs)
                    if !newNotes.isEmpty {
                        viewModel.selectedMidiNoteIDs = Set(newNotes.map(\.id))
                        let origs = Dictionary(uniqueKeysWithValues: newNotes.map { ($0.id, $0) })
                        let grab  = oldToNew[hit.id] ?? newNotes[0].id
                        drag = NoteDrag(grabbedID: grab, mode: .moveBody,
                                        origs: origs, start: value.startLocation,
                                        pitchAxis: cropOn ? usedPitches : [])
                    }
                } else {
                    // resize = the grabbed note alone; move/velocity = the whole selection.
                    let affectedIDs: Set<UUID> = (mode == .resizeL || mode == .resizeR)
                        ? [hit.id] : selectedIDs.union([hit.id])
                    let origs = Dictionary(uniqueKeysWithValues:
                        object.midiNotes.filter { affectedIDs.contains($0.id) }.map { ($0.id, $0) })
                    drag = NoteDrag(grabbedID: hit.id, mode: mode, origs: origs, start: value.startLocation,
                                    pitchAxis: cropOn ? usedPitches : [])
                    viewModel.beginMidiNoteEdit()
                }
            } else {
                // An empty background → a rubber band. ⌘/⇧ = additive (it preserves the current selection).
                rubber = RubberState(origin: value.startLocation, current: value.startLocation,
                                     base: (cmd || shift) ? selectedIDs : [])
            }
        }

        // ── Rubber band ─────────────────────────────────────────────────────────
        if rubber != nil {
            rubber!.current = value.location
            let box = rubber!.rect
            let inBox = Set(object.midiNotes.filter { rect(for: $0)?.intersects(box) ?? false }.map(\.id))
            viewModel.selectedMidiNoteIDs = rubber!.base.union(inBox)
            return
        }

        // ── Dragging note(s) ─────────────────────────────────────────────────────
        guard let d = drag, let grab = d.origs[d.grabbedID] else { return }
        let dx = value.location.x - d.start.x
        let dy = value.location.y - d.start.y

        switch d.mode {
        case .resizeR:
            let endSec = object.startTime
                + (grab.startBeat + grab.lengthBeats) * secPerBeat + dx / pixelsPerSecond
            let newLen = max(minLenBeats, (snapAbs(endSec) - object.startTime) / secPerBeat - grab.startBeat)
            viewModel.updateMidiNote(inObject: object.id, noteID: d.grabbedID) { $0.lengthBeats = newLen }

        case .resizeL:
            let startSec = object.startTime + grab.startBeat * secPerBeat + dx / pixelsPerSecond
            let newStart = max(0, (snapAbs(startSec) - object.startTime) / secPerBeat)
            let origEnd  = grab.startBeat + grab.lengthBeats
            let clampedStart = min(newStart, origEnd - minLenBeats)
            viewModel.updateMidiNote(inObject: object.id, noteID: d.grabbedID) {
                $0.startBeat = max(0, clampedStart)
                $0.lengthBeats = max(minLenBeats, origEnd - max(0, clampedStart))
            }

        case .moveBody:
            // A common delta computed on the grabbed note (snapped), applied to the whole selection.
            let startSec   = object.startTime + grab.startBeat * secPerBeat + dx / pixelsPerSecond
            let newGrabbed = max(0, (snapAbs(startSec) - object.startTime) / secPerBeat)
            let deltaBeats = newGrabbed - grab.startBeat
            let dRows      = Int((dy / rowHeight).rounded())
            let origs = d.origs
            let axis  = d.pitchAxis
            viewModel.updateMidiNotes(inObject: object.id) { notes in
                for i in notes.indices {
                    guard let o = origs[notes[i].id] else { continue }
                    notes[i].startBeat = max(0, o.startBeat + deltaBeats)
                    notes[i].pitch     = movedPitch(from: o.pitch, dRows: dRows, axis: axis)
                }
            }

        case .velocity:
            let dv = Int((-dy / noteAreaHeight * 127).rounded())
            let origs = d.origs
            viewModel.updateMidiNotes(inObject: object.id) { notes in
                for i in notes.indices {
                    guard let o = origs[notes[i].id] else { continue }
                    notes[i].velocity = (o.velocity + dv).clamped(to: 0...127)
                }
            }
        }
    }
}
