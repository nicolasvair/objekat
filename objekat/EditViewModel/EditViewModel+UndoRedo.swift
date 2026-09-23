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
                                    timeSigDenominator: timeSigDenominator,
                                    markerLanes: markerLanes,
                                    comments: comments)
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
            if patched.contains(item.id) { pushPatch(item, live: liveTop[item.id]) } else { syncAdd(item) }
        }

        // The annotations: restored flat, with no engine reconciliation to do — a marker and a
        // comment have no engine object. Restored even when equal: comparing them would cost more
        // than assigning them.
        if let lanes = snapshot.markerLanes { markerLanes = lanes }
        if let cs = snapshot.comments { comments = cs }
        if let sel = selectedAnnotation, !annotationExists(sel) { selectedAnnotation = nil }
        // The automation points selected: dropped WHOLESALE rather than pruned. They are named by
        // STORAGE INDEX (@see AutomationPointRef), and a snapshot restores curves whose points
        // have been added, removed or reordered by the very edit being taken back — so an index
        // that survives does not name a point that no longer exists, it names SOMEBODY ELSE, which
        // is worse. Pruning would have to compare the curves point by point to know the
        // difference; letting go costs one rectangle.
        clearAutomationPointSelection()

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
        // The plugins' STATE, on the other hand, is recoverable: `applyPluginStateXML` re-applies
        // it to the live instance. Only the state — the chain's composition, its order, its ids,
        // its racks and its links are compared as before, and any difference there rebuilds
        // (@see adoptingPluginStates, which refuses as soon as the shape moves).
        guard let plugins = adoptingPluginStates(old.plugins, new.plugins),
              let instruments = adoptingPluginStates(old.instruments, new.instruments)
        else { return false }
        probe.plugins     = plugins
        probe.instruments = instruments
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
        // The TOUCH memory is of the same class as `automationOpen`, and its own comment says so:
        // a trace of a gesture, persisted, that the engine knows nothing about. It is recorded
        // WITHOUT an undo point on purpose (touching a fader is not an edit) — so it moves between
        // two undo points and, left out of here, it alone made an object unrecoverable. Every
        // parameter touched between two ⌘Z was rebuilding its object, for the memory of having
        // touched it.
        probe.automationTouchOrder = new.automationTouchOrder

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

    /// `old`'s chain wearing `new`'s STATES — nil as soon as the two chains are not the same
    /// chain: a different number of plugins, an id that has moved, a rack facing a plain plugin,
    /// a rack with another number of branches. Everything else about a plugin (its name, its
    /// format, its bypass, its links, its colour) is left as `old` has it, so the strict equality
    /// `isPatchable` closes on still has to hold for all of it.
    ///
    /// Why the state deserves this, when it used to force a rebuild: a plugin's state is an
    /// opaque chunk on the model's side, so the model cannot say "put that parameter back" — but
    /// it does not have to, the engine can be handed the whole chunk for the LIVE instance
    /// (@see OBJEngineCore.applyPluginStateXML:forPlugin:). Destroying the object to get a plugin
    /// back to a former state was reloading an AU — 757 ms for a UADx Anthem Synth — to end up
    /// doing, at the end of the load, exactly the call we now make on its own.
    static func adoptingPluginStates(_ old: [ObjectPlugin],
                                     _ new: [ObjectPlugin]) -> [ObjectPlugin]? {
        guard old.count == new.count else { return nil }
        var out = old
        for i in old.indices {
            guard old[i].id == new[i].id else { return nil }
            switch (old[i].rack, new[i].rack) {
            case (nil, nil):
                out[i].stateXML = new[i].stateXML
            case let (oldRack?, newRack?):
                guard oldRack.voices.count == newRack.voices.count else { return nil }
                var voices: [[ObjectPlugin]] = []
                for (a, b) in zip(oldRack.voices, newRack.voices) {
                    guard let voice = adoptingPluginStates(a, b) else { return nil }
                    voices.append(voice)
                }
                out[i].rack?.voices = voices
            default:
                return nil   // a rack facing a plugin: another chain
            }
        }
        return out
    }

    /// The leaves whose state has really moved between the live chain and the one to restore, with
    /// the state to re-apply. Empty for every gesture that does not touch a plugin — which is most
    /// of them, and the reason this is computed rather than pushing every state on every patch:
    /// re-applying a state to an AU for nothing is a `setStateInformation` for nothing, and on
    /// some plugins that is audible.
    static func changedPluginStates(_ old: SoundObject, _ new: SoundObject) -> [(id: UUID, xml: String)] {
        var out: [(id: UUID, xml: String)] = []
        func walk(_ a: [ObjectPlugin], _ b: [ObjectPlugin]) {
            for (x, y) in zip(a, b) {
                if let rackA = x.rack, let rackB = y.rack {
                    for (va, vb) in zip(rackA.voices, rackB.voices) { walk(va, vb) }
                } else if x.stateXML != y.stateXML, let xml = y.stateXML, !xml.isEmpty {
                    out.append((id: y.id, xml: xml))
                }
            }
        }
        walk(old.plugins, new.plugins)
        walk(old.instruments, new.instruments)
        return out
    }

    /// Pushes to the engine the differences of an object declared recoverable by `isPatchable`.
    /// Volume / pan / mute are not there: `refreshAudibility()` already recomposes them for the
    /// WHOLE project higher up in `applySnapshot`.
    ///
    /// The automation CURVES, on the other hand, are: they follow the geometry (relative time → edit time) and
    /// the undone gesture may be the editing of the curve itself. `syncPosition` already pushes
    /// some for the cases that go through it; the final call covers the others (a group, whose
    /// children are walked by hand) and costs nothing when it duplicates one.
    ///
    /// `live` is what the engine is playing — the same object as `isPatchable` was given as `old`.
    /// It is only there to say WHICH plugin states have moved; absent, none is re-applied.
    func pushPatch(_ object: SoundObject, live: SoundObject? = nil) {
        defer { pushAutomationTree(object) }
        if let live {
            for change in Self.changedPluginStates(live, object) {
                engine?.applyPluginStateXML(change.xml, forPlugin: change.id.uuidString)
            }
        }
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
            // The live children are paired POSITIONALLY: `isPatchable` has already required the
            // two groups to have the same composition, in the same order.
            let liveChildren: [SoundObject] = {
                if case .group(let c, _) = live?.kind { return c }
                return []
            }()
            for (i, child) in children.enumerated() {
                pushPatch(child, live: liveChildren.indices.contains(i) ? liveChildren[i] : nil)
            }
            engine?.setLane(object.lane, forID: object.id.uuidString)
            syncGroupWindow(object)
        }
    }
}
