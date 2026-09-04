import Foundation

extension EditViewModel {

    // MARK: - Undo / Redo

    func undo() {
        guard let snapshot = undoStack.popLast() else { return }
        // The snapshot of the LIVE state serves twice: it goes onto the redo stack, and it serves
        // as the reference `applySnapshot` compares against (rebuild only what differs).
        let live = currentSnapshot()
        redoStack.append(live)
        applySnapshot(snapshot, live: live)
    }

    func redo() {
        guard let snapshot = redoStack.popLast() else { return }
        let live = currentSnapshot()
        undoStack.append(live)
        applySnapshot(snapshot, live: live)
    }

    func edit(_ action: () -> Void) {
        pushUndo()
        action()
    }

    func pushUndo() {
        undoStack.append(currentSnapshot())
        redoStack = []
        if undoStack.count > 50 { undoStack.removeFirst() }
        isDirty = true
    }

    /// The snapshot captures `stateXML` LIVE from the engine (items + stems): the
    /// settings made in a native plugin editor do not pass through the model, so
    /// without this capture a later action (moving a clip…) would freeze a stale
    /// stateXML and its undo would crush those settings — `applySnapshot` rebuilds the engine
    /// from the model. With the capture, undo gives back the real state at the moment of the push.
    ///
    /// This capture sweeps the WHOLE project on every undoable gesture (`pushUndo`), and an AU's
    /// `getPluginStateXML` costs a `getStateInformation` + an XML serialisation of the binary
    /// chunk + two string copies. Hence the log: it is the first suspect when an
    /// innocuous action drags in a project loaded with plugins.
    func currentSnapshot() -> EditSnapshot {
        let t0 = CFAbsoluteTimeGetCurrent()
        pluginStateCaptureCount = 0
        let snapshot = EditSnapshot(items: itemsWithCapturedPluginStates(),
                                    stems: stemsWithCapturedPluginStates(),
                                    objectDefinitions: objectDefinitions,
                                    tempo: tempo,
                                    timeSigNumerator: timeSigNumerator,
                                    timeSigDenominator: timeSigDenominator)
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        if ms >= 1 {
            NSLog("[PERF] snapshot: %d plugin state(s) re-read in %.0f ms",
                  pluginStateCaptureCount, ms)
        }
        return snapshot
    }

    /// Restores a complete state of the model and reconciles the engine with it.
    ///
    /// DIFFERENTIAL REBUILD — an undo used to undo a single gesture but paid for the engine
    /// rebuild of the WHOLE project: every object destroyed then recreated, hence every
    /// audio clip reopened and every AU/VST plugin re-instantiated from its `stateXML`. Hence the
    /// seconds of freeze on undoing a group creation, a MIDI clip resize or
    /// a note deletion, where the rest of the project had not moved at all.
    ///
    /// Now: any TOP-LEVEL sub-tree whose live state is identical (deep
    /// equality, `stateXML` included — captured on both sides by `currentSnapshot`) is left
    /// IN PLACE on the engine side. Only the objects that really differ (plus those that
    /// appear / disappear) are destroyed and recreated. The cost follows the size of the gesture,
    /// not that of the project.
    ///
    /// `live`: the live state ALREADY captured by the caller (undo/redo), so as not to re-read the
    /// state of every plugin twice. Absent ⇒ captured here.
    func applySnapshot(_ snapshot: EditSnapshot, live: EditSnapshot? = nil) {
        let t0 = CFAbsoluteTimeGetCurrent()
        let live = live ?? currentSnapshot()

        // Tempo / time signature first: the engine must have the right tempo BEFORE the clips
        // (MIDI ones in particular, whose notes are in beats) are recreated. A restoration ⇒
        // no remap: the snapshot's positions are already those of that tempo.
        isRestoringTransport = true
        if let t = snapshot.tempo { tempo = t }
        if let n = snapshot.timeSigNumerator { timeSigNumerator = n }
        if let d = snapshot.timeSigDenominator { timeSigDenominator = d }
        isRestoringTransport = false

        // A tempo change remaps the positions on the engine side without going through the model:
        // nothing is "untouched" there any more, so everything is pushed again.
        let tempoChanged = (snapshot.tempo ?? live.tempo) != live.tempo

        var liveTop: [UUID: SoundObject] = [:]
        for item in live.items { liveTop[item.id] = item }
        var intact: Set<UUID> = []     // identical: nothing to do on the engine side
        var patched: Set<UUID> = []    // kept: the differences get pushed in place
        if !tempoChanged {
            for item in snapshot.items {
                guard let old = liveTop[item.id] else { continue }
                if old == item { intact.insert(item.id) }
                else if Self.isPatchable(old, item) { patched.insert(item.id) }
            }
        }
        let kept = intact.union(patched)

        for item in live.items where !kept.contains(item.id) { removeFromEngine(item) }
        items = snapshot.items

        // The BUSES first, the objects after: `syncAdd` assigns each object to its stem, and
        // the engine refuses an assignment towards a bus that does not exist yet. Without this, undoing
        // a stem deletion gave its objects back to the Main in silence.
        if let snapStems = snapshot.stems {
            let restoredIDs = Set(snapStems.map(\.id))
            // Buses absent from the snapshot (undoing an "add a stem"): undo them, otherwise orphan
            // FolderTracks pile up in the engine.
            for old in stems.dropFirst() where !restoredIDs.contains(old.id) {
                engine?.disbandStemBus(old.id.uuidString, memberIDs: [])
            }
            var liveStems: [UUID: Stem] = [:]
            for s in (live.stems ?? stems) { liveStems[s.id] = s }
            stems = snapStems
            for stem in stems.dropFirst() { engine?.createStemBus(stem.id.uuidString) }  // idempotent
            // INC 2: restores the bus FX chains then recompiles the stems (master included) whose
            // rack has changed — including to empty a rack whose plugins the undo removed.
            // A bus whose rack is identical keeps its own: recompiling would only rebuild
            // the graph for nothing.
            for stem in stems where liveStems[stem.id] != stem { compileRack(objectID: stem.id) }
            syncStemGains()     // bus gains restored in the model → pushed back to the engine
            syncStemRouting()   // the same for the buses detached from the Main
            refreshAudibility() // bus mutes restored → recomposes the silence of every object
        }

        for item in items where !intact.contains(item.id) {
            if patched.contains(item.id) { pushPatch(item) } else { syncAdd(item) }
        }

        if let snapDefs = snapshot.objectDefinitions {
            objectDefinitions = snapDefs
        }

        // A REBUILT aux is a new clip on the engine side: the send of a KEPT sender
        // still points at the old one, and the engine believes it wired (the send registry) — it would
        // merely set its level. So it is explicitly unwired; `resyncAllSends`
        // makes it afresh towards the right aux.
        if !kept.isEmpty {
            let keptRoots = items.filter { kept.contains($0.id) }
            var preserved: Set<UUID> = []
            func collect(_ arr: [SoundObject]) {
                for o in arr {
                    preserved.insert(o.id)
                    if case .group(let children, _) = o.kind { collect(children) }
                }
            }
            collect(keptRoots)

            func dropStaleSends(_ arr: [SoundObject]) {
                for o in arr {
                    for s in o.sends where !preserved.contains(s.auxID) {
                        engine?.removeSend(o.id.uuidString, toAux: s.auxID.uuidString)
                    }
                    if case .group(let children, _) = o.kind { dropStaleSends(children) }
                }
            }
            dropStaleSends(keptRoots)
        }

        resyncAllSends()   // every aux now exists → rewire the sends

        let rebuilt = items.count - kept.count
        NSLog("[UNDO] restored in %.0f ms — top-level: %d rebuilt, %d patched, %d untouched",
              (CFAbsoluteTimeGetCurrent() - t0) * 1000, rebuilt, patched.count, intact.count)
    }

    // MARK: - Updating IN PLACE (instead of destroying / recreating)

    /// True if everything separating `old` (what the engine is playing) from `new` (what has to be
    /// restored) can be pushed without destroying the object: position, duration, lane, source offset,
    /// fades, volume/pan/mute, MIDI notes, and the purely visual fields. As soon as anything else
    /// differs — file, speed, playback direction, plugins, instrument, chain gains, stem,
    /// sends, sound-object link, a group's composition — `false` is returned: the object will be
    /// rebuilt as before.
    ///
    /// The method is deliberately "by subtraction": only the recoverable fields are copied into a
    /// probe, and then STRICT equality with the target is required. A field added later
    /// to `SoundObject` will therefore make the comparison fail (⇒ a rebuild, the earlier
    /// behaviour) instead of silently slipping through.
    static func isPatchable(_ old: SoundObject, _ new: SoundObject) -> Bool {
        guard old.id == new.id else { return false }
        var probe = old
        probe.startTime     = new.startTime
        probe.duration      = new.duration
        probe.lane          = new.lane
        probe.volume        = new.volume
        probe.pan           = new.pan
        probe.fadeIn        = new.fadeIn
        probe.fadeOut       = new.fadeOut
        probe.isMuted       = new.isMuted
        probe.label         = new.label
        probe.colorIndex    = new.colorIndex
        probe.pianoRollOpen = new.pianoRollOpen
        // `automationOpen` is purely visual (like `pianoRollOpen`): opening/closing a band
        // must not rebuild the object on the engine side. `automation` (the points) has become
        // so too: a curve is pushed to the engine WHOLESALE (`pushAutomation`), so an
        // undo of an automation gesture no longer has to destroy the object and re-instantiate its plugins.
        // `pushPatch` takes care of it.
        probe.automationOpen = new.automationOpen
        probe.automation     = new.automation

        switch (old.kind, new.kind) {
        case let (.clip(f0, _, fd0, sr0, rev0), .clip(f1, _, fd1, sr1, rev1)):
            // Only `sourceOffset` is recoverable (updatePosition carries it); changing the file,
            // the varispeed or the direction forces the clip to be remade.
            guard f0 == f1, fd0 == fd1, sr0 == sr1, rev0 == rev1 else { return false }
            probe.kind = new.kind
        case (.midiClip, .midiClip):
            // Notes: rewritten wholesale (setMidiNotes). `lengthBeats` is a MODEL fact —
            // the engine takes the MIDI clip's length from the container's duration.
            probe.kind = new.kind
        case (.aux, .aux):
            break
        case let (.group(c0, _), .group(c1, _)):
            guard c0.count == c1.count else { return false }
            for (a, b) in zip(c0, c1) where !isPatchable(a, b) { return false }
            probe.kind = new.kind
        default:
            return false
        }
        return probe == new
    }

    /// Pushes to the engine the differences of an object declared recoverable by `isPatchable`.
    /// Volume / pan / mute are not there: `refreshAudibility()` already recomposes them for the
    /// WHOLE project higher up in `applySnapshot`.
    ///
    /// The automation CURVES, on the other hand, are: they follow the geometry (relative time → edit time) and
    /// the undone gesture may be the editing of the curve itself. `syncPosition` already pushes
    /// some for the cases that go through it; the final call covers the others (a group, whose
    /// children are walked by hand) and costs nothing when it duplicates one.
    func pushPatch(_ object: SoundObject) {
        defer { pushAutomationTree(object) }
        switch object.kind {
        case .clip, .midiClip:
            syncPosition(object)   // position + duration + source offset + lane
            // Window/fades: AFTER the position, the engine sets them on the clip's span.
            engine?.updateFade(in: object.fadeIn, fadeOut: object.fadeOut,
                               forID: object.id.uuidString)
            if case .midiClip = object.kind { syncMidiNotes(object) }
        case .aux:
            syncPosition(object)   // = the aux's window + fades, then the lane
        case .group(let children, _):
            // Not `syncPosition`: it would reposition the descendants without touching their
            // fades or their notes. We walk down ourselves, then close on the group.
            for child in children { pushPatch(child) }
            engine?.setLane(object.lane, forID: object.id.uuidString)
            syncGroupWindow(object)
        }
    }
}
