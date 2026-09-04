import Foundation

/// A sound-object editing session (an element of `EditViewModel.objectEditStack`). Opening a
/// nested sound object stacks a child session; closing/cancelling pops it and picks the parent up again.
struct ObjectEditSession: Identifiable {
    /// The definition being edited.
    let defID: UUID
    /// The materialised placement (its content replaces this placement in `items` for the length of the session).
    let placementID: UUID
    /// A snapshot of the baked instance BEFORE materialisation (restored as it is by a cancel).
    var originalPlacement: SoundObject?
    /// A snapshot of the sub-tree materialised AT OPENING (the content, with the plugin state coming from the
    /// sidecar). Used to detect "no modification" at closing → the re-bake is skipped.
    var openedSubtree: SoundObject?
    /// The OTHER instances, turned into live mirrors for the length of the session: for each, the
    /// `.clip` placement from BEFORE (restored on closing as on cancelling). It is also what
    /// serves as the alignment reference on every re-mirroring — the current mirror is a group, it
    /// no longer has a sourceOffset or a speedRatio to question.
    var mirrorSnapshots: [UUID: SoundObject] = [:]
    /// The content's signature at the last mirror laid: laying an identical mirror again would cost an
    /// engine rebuild (hence a re-instantiation of plugins) for nothing.
    var lastMirrorSignature: Data?
    var id: UUID { placementID }
}

extension EditViewModel {

    // MARK: - Sound objects (content reusable in N places)

    /// The project's `samples/objects/` folder (nil as long as the project has not been saved).
    /// A sound object requires a saved project: it needs a stable place on disk
    /// for its baked wave + its sidecar.
    var objectsFolder: URL? {
        projectFolder?.appendingPathComponent("samples", isDirectory: true)
            .appendingPathComponent("objects", isDirectory: true)
    }

    /// The path of the sidecar (the original editable sub-tree) associated with a definition's current wave.
    func objectSidecarURL(forWave wave: String, in folder: URL) -> URL {
        let base = (wave as NSString).deletingPathExtension
        return folder.appendingPathComponent("\(base)_objectstate.json")
    }

    /// An instance's definition, if `definitionID` points at a known entry of the registry.
    func definition(for object: SoundObject) -> ObjectDefinition? {
        guard let did = object.definitionID else { return nil }
        return objectDefinitions[did]
    }

    /// Every placement (top-level + nested in groups) that references `defID`,
    /// `excluding` aside. Used by the propagation (content after a re-bake, synchronised colour).
    func placementIDs(forDefinition defID: UUID, excluding: UUID? = nil) -> [UUID] {
        func walk(_ list: [SoundObject]) -> [UUID] {
            var found: [UUID] = []
            for o in list {
                if o.definitionID == defID, o.id != excluding { found.append(o.id) }
                if case .group(let ch, _) = o.kind { found += walk(ch) }
            }
            return found
        }
        return walk(items)
    }

    /// True if `object` is a sound-object instance LINKED to at least one other placement
    /// (the same definition).
    func hasLinkedSiblings(_ object: SoundObject) -> Bool {
        guard let defID = object.definitionID else { return false }
        return !placementIDs(forDefinition: defID, excluding: object.id).isEmpty
    }

    /// True if the current selection holds at least one sound object linked to other
    /// instances → arms the overlay of purple lines in the timeline (LinkOverlay).
    var hasSelectedLinkedObject: Bool {
        selectedIDs.contains { id in
            guard let o = find(id: id) else { return false }
            return hasLinkedSiblings(o)
        }
    }

    // MARK: - Linked attributes (volume / pan / mute)

    /// True if `attr` (volume/pan/mute) of `obj` follows the common value of its definition:
    /// `obj` is a linked instance AND has not detached that attribute.
    func isAttrSynced(_ obj: SoundObject, _ attr: ObjectAttrLinks) -> Bool {
        obj.isObjectInstance && !obj.independentAttrs.contains(attr)
    }

    /// Propagates `attr` (volume/pan/mute) from the instance `objectID` to its definition and
    /// to every other instance still synchronised for that attribute. To be called AFTER writing
    /// the new value onto `objectID` (the volume/pan/mute setters already do so).
    /// A no-op if `objectID` is not a linked instance synchronised for `attr`.
    func propagateLinkedAttr(_ attr: ObjectAttrLinks, from objectID: UUID) {
        guard let src = find(id: objectID), isAttrSynced(src, attr),
              let defID = src.definitionID, var def = objectDefinitions[defID] else { return }

        switch attr {
        case .volume: def.volume  = src.volume
        case .pan:    def.pan     = src.pan
        case .mute:   def.isMuted = src.isMuted
        default: break
        }
        objectDefinitions[defID] = def

        for tid in placementIDs(forDefinition: defID, excluding: objectID) {
            guard let other = find(id: tid), isAttrSynced(other, attr) else { continue }
            update(id: tid) { o in
                switch attr {
                case .volume: o.volume  = def.volume
                case .pan:    o.pan     = def.pan
                case .mute:   o.isMuted = def.isMuted
                default: break
                }
            }
            pushMix(tid)
        }
    }

    /// Toggles the synced/independent state of `attr` for the instance `id`.
    /// - `synced == false`: detaches the attribute (it keeps its current value, frozen in place).
    /// - `synced == true` : reattaches the attribute → realigns the instance's value on the
    ///   definition's and pushes it to the engine.
    func setAttrSynced(_ attr: ObjectAttrLinks, _ synced: Bool, forPlacement id: UUID) {
        guard let obj = find(id: id), obj.isObjectInstance else { return }
        guard obj.independentAttrs.contains(attr) == synced else { return }   // already in the state wanted
        pushUndo()
        if synced {
            let def = obj.definitionID.flatMap { objectDefinitions[$0] }
            update(id: id) { o in
                o.independentAttrs.remove(attr)
                if let def {
                    switch attr {
                    case .volume: o.volume  = def.volume
                    case .pan:    o.pan     = def.pan
                    case .mute:   o.isMuted = def.isMuted
                    default: break
                    }
                }
            }
            pushMix(id)
        } else {
            update(id: id) { $0.independentAttrs.insert(attr) }
        }
        isDirty = true
    }

    // MARK: - Staleness

    /// Walks `subtree` and its descendants and returns the set of definitions this bake
    /// depends on, at their CURRENT revision: every descendant that is itself a sound-object
    /// instance (`definitionID`). Called at bake time — see EditViewModel+Bake.
    func collectObjectDependencies(_ subtree: SoundObject) -> [ObjectDependency] {
        var revisionByID: [UUID: Int] = [:]
        func record(_ defID: UUID, _ revision: Int) {
            revisionByID[defID] = max(revisionByID[defID] ?? 0, revision)
        }
        func walk(_ o: SoundObject) {
            if let defID = o.definitionID, let rev = objectDefinitions[defID]?.revision {
                record(defID, rev)
            }
            if case .group(let ch, _) = o.kind { ch.forEach(walk) }
        }
        walk(subtree)
        return revisionByID.map { ObjectDependency(definitionID: $0.key, revision: $0.value) }
    }

    /// True if the instance `id` captures a content whose source definition has since been
    /// updated — its baked wave no longer reflects the current content. Drives the display
    /// of a badge in the timeline.
    func isStale(_ id: UUID) -> Bool {
        guard let obj = find(id: id), let defID = obj.definitionID,
              let def = objectDefinitions[defID] else { return false }
        return def.dependsOn.contains { dep in
            (objectDefinitions[dep.definitionID]?.revision ?? dep.revision) > dep.revision
        }
    }

    /// Refreshes a STALE instance (its DEFINITION itself holds another sound object
    /// that has since been updated — the recursive case, an object inside an object). Opens the definition
    /// (materialising with an already refreshed content, see `openObject`) then closes it
    /// immediately, with no intervention from the user. No effect on an up-to-date instance.
    func refreshStalePlacement(_ placementID: UUID) {
        guard let placement = find(id: placementID), placement.isObjectInstance,
              isStale(placementID), !isEditingObject else { return }
        let defID = placement.definitionID
        openObject(viaPlacementID: placementID)
        guard editingDefinitionID == defID else { return }
        closeObject()
    }

    /// Recursively refreshes the filePath/fileDuration of `subtree` and of every one of its descendants
    /// that references a definition, so that they reflect its CURRENT revision.
    /// Used by the restoration from a sidecar (opening, detaching, mirroring), which
    /// may hold references to a revision now out of date.
    func refreshObjectReferences(in subtree: SoundObject) -> SoundObject {
        var o = subtree
        if let defID = o.definitionID, let def = objectDefinitions[defID],
           let folder = objectsFolder, case .clip(_, let so, _, let sr, let rev) = o.kind {
            let wav = folder.appendingPathComponent(def.wave)
            let waveLen = audioFileDuration(wav) ?? 0
            o.kind = .clip(filePath: wav.path, sourceOffset: so, fileDuration: waveLen,
                           speedRatio: sr, isReversed: rev)
        }
        if case .group(let children, let isExpanded) = o.kind {
            o.kind = .group(children: children.map { refreshObjectReferences(in: $0) }, isExpanded: isExpanded)
        }
        return o
    }

    // MARK: - Automatic transitive recomputation (a cascade of background re-bakes)
    //
    // When a definition gains a revision (creation, or closing after an edit), every
    // definition that holds it (directly or transitively: A in B in C) becomes
    // out of date. Rather than a manual "Refresh" action, the whole chain of dependants is
    // re-baked AUTOMATICALLY in the background, with a simple indicator. It proceeds by FIXED POINT over
    // freshness: at each re-bake a parent definition may in turn become out of date
    // (it was not while its dependency had not moved) → it is re-evaluated until
    // nothing out of date is left. The "dependencies first" order is guaranteed: a definition is only
    // re-baked if none of ITS dependencies is itself still out of date.

    /// True if the definition `defID` is out of date: at least one captured dependency points at a
    /// revision lower than that dependency's CURRENT revision. A dependency that has gone is
    /// ignored (no ghosts). The "definition" version of `isStale` (which works on a placement).
    func isDefinitionStale(_ defID: UUID) -> Bool {
        guard let def = objectDefinitions[defID] else { return false }
        return def.dependsOn.contains { dep in
            guard let cur = objectDefinitions[dep.definitionID]?.revision else { return false }
            return cur > dep.revision
        }
    }

    /// Launches (if not already under way) the fixed-point re-bake cascade of every out-of-date
    /// definition. A no-op during an editing session (a materialised/watched definition is not
    /// touched) — it will be relaunched when the stack empties. Idempotent.
    func cascadeRebakeStaleFixpoint() {
        guard !isEditingObject, !isCascadingRebake, objectsFolder != nil else { return }
        isCascadingRebake = true
        cascadeFailedDefs.removeAll()
        cascadeRebakeCount = 0
        processNextStaleRebake()
    }

    /// How long the transient "resynchronised" ✓ is shown on a placement, after a re-bake.
    private static let resyncedBadgeDuration: TimeInterval = 15

    /// Marks `defID` as recently resynchronised → a transient ✓ on its placements for
    /// `resyncedBadgeDuration`, then cleared automatically. Called after every successful re-bake
    /// (a transitive cascade or a closing propagated to the other instances). Robust to
    /// overlapping markings: the deadline is pushed back and the clearing only happens once it is reached
    /// (otherwise a re-bake during the display would cut the ✓ short).
    func markDefinitionResynced(_ defID: UUID) {
        let deadline = Date().addingTimeInterval(Self.resyncedBadgeDuration)
        resyncedBadgeDeadline[defID] = deadline
        recentlyResyncedDefinitionIDs.insert(defID)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.resyncedBadgeDuration + 0.05) { [weak self] in
            guard let self, let due = self.resyncedBadgeDeadline[defID], Date() >= due else { return }
            self.resyncedBadgeDeadline[defID] = nil
            self.recentlyResyncedDefinitionIDs.remove(defID)
        }
    }

    /// Ends the cascade cleanly (empties the indicator + the guards).
    private func endCascadeRebake() {
        recomputingDefinitionIDs.removeAll()
        cascadeFailedDefs.removeAll()
        isCascadingRebake = false
    }

    /// Picks the next out-of-date definition to re-bake (none of its dependencies is still
    /// out of date = the deepest first), re-bakes it, then calls itself again until exhaustion.
    private func processNextStaleRebake() {
        // An editing session has (re)opened during the cascade → it is suspended cleanly; the
        // next emptying of the stack will relaunch the fixed point.
        guard !isEditingObject else { endCascadeRebake(); return }
        // A safety ceiling against loops (abnormal cyclic dependencies).
        guard cascadeRebakeCount < max(8, objectDefinitions.count * 3) else {
            NSLog("[OBJECT] cascade: iteration ceiling reached — stopping")
            endCascadeRebake(); return
        }
        // Those out of date and still workable (the failures are excluded so as not to loop).
        let stale = objectDefinitions.keys.filter { isDefinitionStale($0) && !cascadeFailedDefs.contains($0) }
        // "Dependencies first": only re-bake a definition if none of its dependencies is
        // still out of date (otherwise it would be re-baked with a stale child). An anti-deadlock fallback:
        // if only mutually dependent out-of-date ones are left (a cycle — abnormal), the first is taken.
        let next = stale.first { defID in
            let deps = objectDefinitions[defID]?.dependsOn.map(\.definitionID) ?? []
            return !deps.contains { isDefinitionStale($0) && !cascadeFailedDefs.contains($0) }
        } ?? stale.first
        guard let target = next else { endCascadeRebake(); return }
        cascadeRebakeCount += 1
        recomputingDefinitionIDs.insert(target)
        rebakeDefinitionInBackground(target) { [weak self] ok in
            guard let self else { return }
            self.recomputingDefinitionIDs.remove(target)
            if !ok { self.cascadeFailedDefs.insert(target) }   // no longer picked again: avoids the loop
            // The fixed point: re-baking `target` may have made its parents out of date → re-evaluate.
            self.processNextStaleRebake()
        }
    }

    /// A HEADLESS re-bake of a definition (no materialised placement required): instantiates its
    /// editable sub-tree (from the sidecar, with the child refs refreshed) in the ENGINE alone,
    /// renders it into a new wave, updates the definition (revision+1, a new
    /// wave/sidecar/dependsOn) and propagates to all of its placements. The engine temporary is muted
    /// (its ObjGain fader at -96, bypassed at render time) so as to stay silent in live playback, then
    /// taken down. Asynchronous: `completion(true)` on success.
    private func rebakeDefinitionInBackground(_ defID: UUID, completion: @escaping (Bool) -> Void) {
        guard let engine, let def = objectDefinitions[defID], let folder = objectsFolder else {
            completion(false); return
        }
        let sidecar = objectSidecarURL(forWave: def.wave, in: folder)
        let original: SoundObject
        do {
            let data = try Data(contentsOf: sidecar)
            original = try decodedObjectSidecar(data, projectFolder: projectFolder)
        } catch {
            NSLog("[OBJECT] headless rebake \(defID): unreadable sidecar (\(sidecar.lastPathComponent)) — skipped")
            completion(false); return
        }

        // Fresh ids (zero timeline collision) + child refs pointing at the CURRENT waves.
        let restored = refreshObjectReferences(in: deepFreshCopy(original))

        // Instantiates in the engine ALONE (not in `items`) and mutes so as to stay silent live.
        syncAdd(restored)
        engine.updateVolume(-96, pan: restored.pan, forID: restored.id.uuidString)

        let nextRevision = def.revision + 1
        let base = "\(bakeSafeName(def.name))_\(defID.uuidString.prefix(8))_v\(nextRevision)"
        let wav  = folder.appendingPathComponent("\(base).wav")

        let renderStart: Double, renderEnd: Double
        if restored.isGroup {
            let range = bakeRenderRange(restored); renderStart = range.start; renderEnd = range.end
        } else {
            renderStart = restored.startTime; renderEnd = restored.startTime + restored.duration
        }

        let finish: (Bool) -> Void = { [weak self] ok in
            guard let self else { completion(false); return }
            self.removeFromEngine(restored)   // takes the engine temporary down
            // The project was closed/changed during the render → give up (do not write into another registry).
            guard self.objectsFolder == folder, self.objectDefinitions[defID] != nil else {
                completion(false); return
            }
            guard ok else {
                NSLog("[OBJECT] headless rebake \(defID): render failed")
                completion(false); return
            }
            // The new sidecar (child refs up to date; the original ids/plugins preserved).
            let newSidecar = self.objectSidecarURL(forWave: wav.lastPathComponent, in: folder)
            do {
                try self.encodedObjectSidecar(self.refreshObjectReferences(in: original),
                                              projectFolder: self.projectFolder)
                    .write(to: newSidecar, options: .atomic)
            } catch {
                NSLog("[OBJECT] headless rebake \(defID): sidecar write failed — \(error.localizedDescription)")
                try? FileManager.default.removeItem(at: wav)
                completion(false); return
            }
            let waveLen = self.audioFileDuration(wav) ?? (renderEnd - renderStart)
            let prev = self.objectDefinitions[defID]
            self.objectDefinitions[defID] = ObjectDefinition(
                id: defID, name: prev?.name ?? restored.displayName, wave: wav.lastPathComponent,
                revision: nextRevision, wasGroup: prev?.wasGroup ?? restored.isGroup,
                volume: prev?.volume ?? restored.volume, pan: prev?.pan ?? restored.pan,
                isMuted: prev?.isMuted ?? restored.isMuted,
                dependsOn: self.collectObjectDependencies(restored))
            // Propagates the new wave to ALL the placements of this definition (model + engine).
            self.propagateDefinitionUpdate(defID: defID, exceptPlacementID: UUID())
            self.markDefinitionResynced(defID)   // a transient ✓ on the resynchronised placements
            self.isDirty = true
            NSLog("[OBJECT] headless rebake \(defID) → \(wav.lastPathComponent) (revision \(nextRevision))")
            completion(true)
        }
        if restored.isGroup {
            engine.renderGroup(toFileAsync: restored.id.uuidString, filePath: wav.path,
                               start: renderStart, end: renderEnd, completion: finish)
        } else {
            engine.renderClip(toFileAsync: restored.id.uuidString, filePath: wav.path,
                              start: renderStart, end: renderEnd, completion: finish)
        }
    }

    // MARK: - Creating a sound object ("make object")

    /// Turns an existing GROUP into a sound object, IN THE BACKGROUND: the submix is rendered into a
    /// wave (the fader/window bypassed, the user FX baked — @see EditViewModel+Bake), an
    /// `ObjectDefinition` is recorded in the project registry and
    /// the object is replaced IN PLACE (the same id) by a placement referencing it
    /// (`definitionID`). The fader/pan/window/fades stay LIVE on the instance. The
    /// original sub-tree (FX included) goes into the definition's sidecar — that is what
    /// OPENING the object (`openObject`) re-edits.
    /// `alsoLinkIDs`: other objects (a multiple selection with IDENTICAL CONTENT) to turn into
    /// instances of the SAME definition, without re-baking them (see `replaceSelectionWithObjects`).
    func makeObject(fromGroupID groupID: UUID, alsoLinkIDs: [UUID] = []) {
        guard let engine, let group = find(id: groupID), group.isGroup,
              !group.isObjectInstance else { return }
        guard !isBaking(groupID) else { return }
        guard let folder = objectsFolder else {
            bakeAlert(L("object.error.saveFirst.title"),
                        L("object.error.saveFirst.info"))
            return
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            bakeAlert(L("object.error.makeFailed.title"),
                        L("object.error.folderFailed.info", error.localizedDescription))
            return
        }

        let original = withCapturedPluginStates(group)
        let defID = UUID()
        let base  = "\(bakeSafeName(group.displayName))_\(defID.uuidString.prefix(8))"
        let wav   = folder.appendingPathComponent("\(base).wav")

        let range        = bakeRenderRange(group)
        let renderStart  = range.start
        let renderEnd    = range.end
        let sourceOffset = max(0, group.startTime - renderStart)

        bakingIDs.insert(groupID)
        engine.renderGroup(toFileAsync: groupID.uuidString, filePath: wav.path,
                           start: renderStart, end: renderEnd) { [weak self] ok in
            guard let self else { return }
            self.bakingIDs.remove(groupID)
            self.finishMakeObject(objectID: groupID, ok: ok, wav: wav, folder: folder,
                                            defID: defID, original: original,
                                            sourceOffset: sourceOffset,
                                            renderStart: renderStart, renderEnd: renderEnd,
                                            alsoLinkIDs: alsoLinkIDs)
        }
    }

    /// Turns an existing plain CLIP into a sound object (the same machinery as
    /// `makeObject(fromGroupID:)`, see that method).
    func makeObject(fromClipID clipID: UUID) {
        guard let engine, let clip = find(id: clipID), (clip.isClip || clip.isMIDI),
              !clip.isObjectInstance else { return }
        guard !isBaking(clipID) else { return }
        guard let folder = objectsFolder else {
            bakeAlert(L("object.error.saveFirst.title"),
                        L("object.error.saveFirst.info"))
            return
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            bakeAlert(L("object.error.makeFailed.title"),
                        L("object.error.folderFailed.info", error.localizedDescription))
            return
        }

        let original = withCapturedPluginStates(clip)
        let defID = UUID()
        let base  = "\(bakeSafeName(clip.displayName))_\(defID.uuidString.prefix(8))"
        let wav   = folder.appendingPathComponent("\(base).wav")
        let renderStart = clip.startTime
        let renderEnd   = clip.startTime + clip.duration

        bakingIDs.insert(clipID)
        engine.renderClip(toFileAsync: clipID.uuidString, filePath: wav.path,
                          start: renderStart, end: renderEnd) { [weak self] ok in
            guard let self else { return }
            self.bakingIDs.remove(clipID)
            self.finishMakeObject(objectID: clipID, ok: ok, wav: wav, folder: folder,
                                            defID: defID, original: original,
                                            sourceOffset: 0, renderStart: renderStart, renderEnd: renderEnd)
        }
    }

    /// "Create a sound object" on a LONE CLIP/MIDI: a design decision — a sound object is
    /// ALWAYS a group. So the clip is first wrapped in a group of one (the existing grouping
    /// primitive, which preserves the nesting: a sub-group if the clip is already inside
    /// a group, a top-level group otherwise), and then that group is turned into a sound object.
    func makeObjectWrappingClip(clipID: UUID, alsoLinkIDs: [UUID] = []) {
        guard let clip = find(id: clipID), (clip.isClip || clip.isMIDI),
              !clip.isObjectInstance, !isBaking(clipID) else { return }
        guard objectsFolder != nil else {
            bakeAlert(L("object.error.saveFirst.title"),
                        L("object.error.saveFirst.info"))
            return
        }
        // A LONE object: its fade must live ON the sound object (group level, live/editable) and
        // not stay baked into the wav from the clip. Rendering the group bypasses the group's
        // window/fade (→ not baked, it stays live on the placement) but bakes the fade of a CHILD clip.
        // So the fade is moved clip → wrapper group BEFORE the render. (In a multiple selection, the
        // creation goes through makeObject(fromGroupID:) and the clips' fades stay
        // inside — unchanged behaviour.)
        let fadeIn  = clip.fadeIn
        let fadeOut = clip.fadeOut
        // Sends: the SAME logic as the fades. The send lives on the CLIP; left there, it
        // is lost in the transformation — the child clip is baked into the wav and its routing to
        // the aux destroyed (rendering the submix does not capture the aux send). So it is moved onto the
        // wrapper group BEFORE the render: the placement will inherit a LIVE send from it (rewired by
        // syncSends in finishMakeObject). The wrapper's window matches the clip's →
        // the aux stays overlapped, and the send keeps its meaning.
        let sends = clip.sends

        // Wrapping in a group of one (an internal pushUndo, rebuilds the engine).
        createGroupFromSelection([clipID])
        // The clip is now a child of the freshly created group: it is found again to be shared.
        guard let wrapper = parentGroup(for: clipID), wrapper.isGroup else { return }

        if fadeIn > 0 || fadeOut > 0 {
            // Removes the child clip's fade (→ a "clean" rendered submix, the fade not baked)…
            updateFadeIn(id: clipID, fadeIn: 0)
            updateFadeOut(id: clipID, fadeOut: 0)
            // …and carries it over onto the wrapper group: the placement will inherit a live fade from it.
            updateFadeIn(id: wrapper.id, fadeIn: fadeIn)
            updateFadeOut(id: wrapper.id, fadeOut: fadeOut)
        }

        if !sends.isEmpty {
            // Removes the child clip's sends (the engine routing cut + the model emptied)…
            for s in sends {
                engine?.removeSend(clipID.uuidString, toAux: s.auxID.uuidString)
            }
            update(id: clipID) { $0.sends.removeAll() }
            // …and carries them over onto the wrapper group (model + engine wiring of the active sends).
            update(id: wrapper.id) { $0.sends = sends }
            if let w = find(id: wrapper.id) { syncSends(w) }
        }

        makeObject(fromGroupID: wrapper.id, alsoLinkIDs: alsoLinkIDs)
    }

    // MARK: - Creating N sound objects from a multiple selection

    /// The elements of a multiple selection on which "Create a sound object" makes sense:
    /// clips, MIDI and groups, never an object instance (already an object), never an
    /// infinite bus (no window to render), and never an element ALREADY CONTAINED in another
    /// selected element — that one leaves with its parent, and baking it separately would duplicate it.
    /// A stable order (left → right, then lane) so that the render queue is predictable.
    func objectCreationTargets() -> [UUID] {
        let objs = selectedIDs.compactMap { find(id: $0) }
        let eligible = objs.filter { o in
            (o.isGroup || o.isClip || o.isMIDI) && !o.isObjectInstance && !o.isInfiniteBus
        }
        let ids = Set(eligible.map(\.id))
        return eligible
            .filter { o in !ids.contains(where: { $0 != o.id && isSelfOrDescendant(o.id, of: $0) }) }
            .sorted { $0.startTime != $1.startTime ? $0.startTime < $1.startTime : $0.lane < $1.lane }
            .map(\.id)
    }

    /// "Create N sound objects": ONE sound object per selected element, each with ITS
    /// own definition. To be distinguished from `replaceSelectionWithObjects`, reserved for strictly
    /// identical copies, which bakes once and links the others to the same definition.
    ///
    /// The renders follow one another IN SERIES, never in parallel: each bake clones the Edit and
    /// rewrites the tree on completion (wrapping in a group, swapping to a placement). Launching the
    /// next before the previous has finished would have it work on a tree in the middle of changing.
    func makeObjectsFromSelection() async {
        guard objectsFolder != nil else {
            bakeAlert(L("object.error.saveFirst.title"),
                        L("object.error.saveFirst.info"))
            return
        }
        for id in objectCreationTargets() {
            // Re-resolved on each round: the previous round may have moved/wrapped the element.
            guard let o = find(id: id), !o.isObjectInstance, !isBaking(id) else { continue }
            if o.isGroup {
                makeObject(fromGroupID: id)
            } else if o.isClip || o.isMIDI {
                makeObjectWrappingClip(clipID: id)
            } else {
                continue
            }
            await waitForBakesToSettle()
        }
    }

    /// Waits until no object render is under way any more. Bounded in time: a render that
    /// fails without calling its completion back must not block the queue for ever.
    private func waitForBakesToSettle(timeout: Double = 300) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !bakingIDs.isEmpty, Date() < deadline {
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
    }

    // MARK: - Replacing an identical multiple selection with N sound objects

    /// The case of a plain wav copy-and-paste: returns N if the selection (≥ 2) is a batch of strictly
    /// identical AUDIO clips (the same file, the same trim/speed/direction, the same volume / pan /
    /// mute / fades / stem / colour / sends, with no plugin). The position (startTime / lane) may
    /// differ — that is precisely what marks them out as copies. nil otherwise → the option is hidden.
    func uniformClipSelectionForObject() -> Int? {
        guard objectsFolder != nil else { return nil }
        let objs = selectedIDs.compactMap { find(id: $0) }
        guard objs.count >= 2, objs.count == selectedIDs.count, let ref = objs.first else { return nil }

        // Plain audio clips only, with no processing, not already instances.
        func eligible(_ o: SoundObject) -> Bool {
            o.isClip && !o.isObjectInstance
                && o.plugins.isEmpty && o.instruments.isEmpty
                && o.chainInGainDb == 0 && o.chainOutGainDb == 0
        }
        guard objs.allSatisfy(eligible), objs.allSatisfy({ identicalClipContent($0, ref) }) else { return nil }
        return objs.count
    }

    /// True if two clips have EXACTLY the same content and the same settings (position aside).
    private func identicalClipContent(_ a: SoundObject, _ b: SoundObject) -> Bool {
        guard case .clip(let fpA, let soA, let fdA, let srA, let revA) = a.kind,
              case .clip(let fpB, let soB, let fdB, let srB, let revB) = b.kind else { return false }
        return fpA == fpB && soA == soB && fdA == fdB && srA == srB && revA == revB
            && a.duration == b.duration
            && a.volume == b.volume && a.pan == b.pan && a.isMuted == b.isMuted
            && a.fadeIn == b.fadeIn && a.fadeOut == b.fadeOut
            && a.stemID == b.stemID && a.colorIndex == b.colorIndex
            && a.sends == b.sends
    }

    /// "Replace with N sound objects": bakes ONE of the clips into a definition, and turns
    /// the others into linked instances (with no re-bake). Does nothing if the selection is no longer a batch
    /// of identical clips (it is re-checked).
    func replaceSelectionWithObjects() {
        guard uniformClipSelectionForObject() != nil else { return }
        let ordered = selectedIDs.compactMap { find(id: $0) }.sorted {
            $0.startTime != $1.startTime ? $0.startTime < $1.startTime : $0.lane < $1.lane
        }
        guard let source = ordered.first else { return }
        let others = ordered.dropFirst().map(\.id)
        makeObjectWrappingClip(clipID: source.id, alsoLinkIDs: Array(others))
    }

    /// The common completion (group or clip), on the main thread: sidecar + recording the
    /// definition + taking down the live version + swapping to a referencing placement (the SAME id).
    private func finishMakeObject(objectID: UUID, ok: Bool, wav: URL, folder: URL,
                                            defID: UUID, original: SoundObject,
                                            sourceOffset: Double, renderStart: Double, renderEnd: Double,
                                            alsoLinkIDs: [UUID] = []) {
        guard let engine else { return }
        guard ok else {
            bakeAlert(L("object.error.renderFailed.title"), L("object.error.seeConsole.info"))
            return
        }
        guard let live = find(id: objectID), !live.isObjectInstance else {
            NSLog("[OBJECT] object \(objectID) gone during the render — orphan wave")
            try? FileManager.default.removeItem(at: wav)
            return
        }

        let sidecar = objectSidecarURL(forWave: wav.lastPathComponent, in: folder)
        do {
            try encodedObjectSidecar(original, projectFolder: projectFolder)
                .write(to: sidecar, options: .atomic)
        } catch {
            bakeAlert(L("object.error.makeFailed2.title"),
                        L("object.error.sidecarWrite.info", error.localizedDescription))
            try? FileManager.default.removeItem(at: wav)
            return
        }

        pushUndo()
        removeFromEngine(live)

        let waveLen = audioFileDuration(wav) ?? (renderEnd - renderStart)
        objectDefinitions[defID] = ObjectDefinition(
            id: defID, name: live.displayName, wave: wav.lastPathComponent,
            revision: 0, wasGroup: live.isGroup,
            volume: live.volume, pan: live.pan, isMuted: live.isMuted,
            dependsOn: collectObjectDependencies(original))

        // Automation: what the render has BAKED IN goes with the content (the children's curves
        // leave with them into the sidecar, those of the root's user FX are in the wave);
        // what the render BYPASSES — fader, pan, trims, sends — stays alive on the placement and
        // therefore keeps its curve, otherwise the sound would change at the transformation.
        // @see SoundObject.automationSurvivingBake
        var placement = SoundObject(
            id: live.id, startTime: live.startTime, duration: live.duration,
            lane: live.lane, volume: live.volume, pan: live.pan,
            fadeIn: live.fadeIn, fadeOut: live.fadeOut, isMuted: live.isMuted,
            stemID: live.stemID, plugins: [],
            label: live.label ?? live.displayName, colorIndex: live.colorIndex,
            sends: live.sends, baseBPM: nil,
            definitionID: defID,
            automationTouchOrder: live.automationTouchOrder,
            kind: .clip(filePath: wav.path, sourceOffset: sourceOffset, fileDuration: waveLen,
                        speedRatio: 1.0, isReversed: false))
        placement.automation     = live.automationSurvivingBake
        placement.automationOpen = live.automationOpen && !placement.automation.isEmpty

        update(id: live.id) { $0 = placement }
        engineAddClip(placement, lane: carrierLane(for: placement.id, fallback: placement.lane))
        if let parent = parentGroup(for: placement.id) {
            engine.assignObject(placement.id.uuidString, toGroupFolder: parent.id.uuidString)
        } else if let sid = placement.stemID {
            engine.assignObjects([placement.id.uuidString], toStemID: sid.uuidString)
        }
        syncSends(placement)
        // The curves that survived the render write themselves onto the baked clip — after the sends,
        // the only carriers of a send curve (@see pushAutomation).
        pushAutomation(placement)

        // A multiple selection with identical content (a copy-and-paste): the OTHER objects become
        // instances of the SAME definition, with no re-bake (their content is already identical). Each
        // keeps its own position/lane/gain/pan/fades/sends — only the deep content is shared.
        var linked: [UUID] = [placement.id]
        for oid in alsoLinkIDs where oid != placement.id {
            guard let other = find(id: oid), !other.isObjectInstance else { continue }
            removeFromEngine(other)
            var inst = SoundObject(
                id: other.id, startTime: other.startTime, duration: other.duration,
                lane: other.lane, volume: other.volume, pan: other.pan,
                fadeIn: other.fadeIn, fadeOut: other.fadeOut, isMuted: other.isMuted,
                stemID: other.stemID, plugins: [],
                label: other.label ?? other.displayName, colorIndex: other.colorIndex,
                sends: other.sends, baseBPM: nil,
                definitionID: defID,
                automationTouchOrder: other.automationTouchOrder,
                kind: .clip(filePath: wav.path, sourceOffset: sourceOffset, fileDuration: waveLen,
                            speedRatio: 1.0, isReversed: false))
            // Those objects are NOT rendered (their content is deemed identical to the baked one):
            // they go through the same sharing all the same, their internal FX disappearing with
            // the content they replace.
            inst.automation     = other.automationSurvivingBake
            inst.automationOpen = other.automationOpen && !inst.automation.isEmpty
            update(id: other.id) { $0 = inst }
            engineAddClip(inst, lane: carrierLane(for: inst.id, fallback: inst.lane))
            if let parent = parentGroup(for: inst.id) {
                engine.assignObject(inst.id.uuidString, toGroupFolder: parent.id.uuidString)
            } else if let sid = inst.stemID {
                engine.assignObjects([inst.id.uuidString], toStemID: sid.uuidString)
            }
            syncSends(inst)
            pushAutomation(inst)
            linked.append(inst.id)
        }

        selectedIDs = Set(linked)
        isDirty = true
        NSLog("[OBJECT] object \(objectID) turned into the sound object \(defID) → \(wav.lastPathComponent)"
              + (linked.count > 1 ? " (+\(linked.count - 1) linked instances)" : ""))
    }

    // MARK: - Opening / closing a sound object

    /// True if at least one sound object is OPEN (a non-empty session stack).
    var isEditingObject: Bool { !objectEditStack.isEmpty }

    /// True if `id` is the placement of an editing session (at any level of the stack).
    func isInObjectEditStack(_ id: UUID) -> Bool {
        objectEditStack.contains { $0.placementID == id }
    }

    /// True if `id` is an instance in a live MIRROR: it follows an origin edited elsewhere and
    /// has no life of its own for the length of the session. Neither editable nor detachable — both
    /// would start from its content, which will be rewritten at the next mirroring pass.
    func isLiveMirror(_ id: UUID) -> Bool {
        objectEditStack.contains { $0.mirrorSnapshots[id] != nil }
    }

    /// OPENS the sound object referenced by `placementID`: it leaves
    /// the baked regime and moves to the LIVE regime. Its sub-tree (from the sidecar) is
    /// materialised in the place of THIS placement, and the other instances become
    /// mirrors of it — they stop reading the wave and play the same content, put back in their own place. The
    /// return to the wave happens at CLOSING (`closeObject`, a new bake) or at
    /// the cancel (`cancelObjectEdit`, with the wave unchanged). If a session is already running,
    /// editing a NESTED sound object stacks a child session (the mirrors always follow
    /// the top of the stack).
    func openObject(viaPlacementID placementID: UUID) {
        guard let placement = find(id: placementID), let defID = placement.definitionID,
              let def = objectDefinitions[defID] else { return }
        guard let folder = objectsFolder else { return }
        guard !isBaking(placementID) else { return }
        // Nesting is allowed, but a placement already present in the stack is not reopened — nor is
        // a mirrored instance, which is only the reflection of an origin already open.
        guard !isInObjectEditStack(placementID), !isLiveMirror(placementID) else { return }

        let sidecar = objectSidecarURL(forWave: def.wave, in: folder)
        let original: SoundObject
        do {
            let data = try Data(contentsOf: sidecar)
            original = try decodedObjectSidecar(data, projectFolder: projectFolder)
        } catch {
            bakeAlert(L("object.error.editFailed.title"),
                        L("object.error.sidecarRead.info", sidecar.lastPathComponent, error.localizedDescription))
            return
        }

        // A sound-object descendant of the sub-tree may have a definition more recent than the one
        // captured at the last bake of THIS definition (staleness) → it is reopened on the UP-TO-DATE
        // content for editing.
        var restored = refreshObjectReferences(in: restoredSubtree(from: original, alignedTo: placement))

        // The baked content may carry plugins absent from this machine: materialising it would
        // remove them (compileRack) and the object would be heard without its effects. We warn BEFORE
        // opening — hence before the pushUndo, since the cancel must leave nothing behind it.
        guard confirmMissingPluginsBeforeOpening(
            restored, what: L("object.missingPlugins.what", placement.displayName)) else { return }

        // Perf: t0 AFTER the guards and the reading of the sidecar — what is wanted is
        // the cost of the gesture, not that of the resolution's I/O. The `[PERF] snapshot` of the pushUndo
        // below already journals itself and counts towards this total.
        let tOpen = CFAbsoluteTimeGetCurrent()

        pushUndo()
        // Opening for editing must make the CONTENT visible and clickable — in particular the
        // NESTED sound objects that will be re-edited in their turn (a child session). A group
        // is created/transformed FOLDED (isExpanded == false, see makeObject) and
        // `restoredSubtree` reproduces that state faithfully → materialised folded, its children do not
        // come out in `laneEntries` (buildLaneEntries only recurses if isExpanded) and so are
        // not hit-testable. So the expansion is forced at opening.
        if case .group(let children, _) = restored.kind {
            restored.kind = .group(children: children, isExpanded: true)
        }

        // Suspends the tracking of the PARENT session (if there is one) before stacking the child:
        // the engine watch only watches one sub-tree at a time → it will be re-installed on
        // the child by `armObjectEditParamWatch`, and reinstalled on the parent when it is popped.
        liveMirrorWorkItem?.cancel(); liveMirrorWorkItem = nil

        // Stacks the session. Captures the state of the plugins BELONGING to the placement (live stateXML) BEFORE
        // the removeFromEngine: the snapshot serves to restore them identically at closing as at
        // a cancel (they belong to the placement, not to the content being edited).
        objectEditStack.append(ObjectEditSession(defID: defID, placementID: placementID,
                                                 originalPlacement: withCapturedPluginStates(placement),
                                                 openedSubtree: restored))

        removeFromEngine(placement)
        update(id: placementID) { $0 = restored }
        syncAdd(restored)
        if let parent = parentGroup(for: placementID) {
            engine?.assignObject(placementID.uuidString, toGroupFolder: parent.id.uuidString)
        }
        if case .clip = restored.kind {
            engine?.updateFade(in: restored.fadeIn, fadeOut: restored.fadeOut, forID: placementID.uuidString)
        }
        // The OTHER instances leave the baked wave and become LIVE mirrors of the content
        // just materialised: from here on, they all refer to the same origin.
        // The arming stays suspended for the length of laying them down — they are born identical to the origin.
        liveMirrorSuppressed = true
        installLiveMirrors()
        selectedIDs = [placementID]
        isDirty = true
        armObjectEditParamWatch()
        UIPerf.measureFrom(tOpen, "open the sound object")
    }

    /// A stable signature of a sub-tree (a JSON encoding with sorted keys) to detect a
    /// modification between the opening and the closing of a sound object. `nil` if
    /// the encoding fails → treated as "different" (we re-bake, on the safe side).
    private func subtreeSignature(_ o: SoundObject) -> Data? {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        // The same amputation as the sidecar: the ROOT's automation belongs to the instance,
        // not to the definition. Without this, setting the instance's gain curve while
        // editing its content would trigger a re-bake — hence one revision and one wave more —
        // for a rigorously identical file.
        return try? enc.encode(o.asObjectDefinition)
    }

    /// Confirms the edit under way: re-bakes the materialised sub-tree (the same pipeline as
    /// `makeObject`), a new revision of the definition (a new wave + sidecar),
    /// then propagates the new content to every OTHER placement that references it. The render is
    /// asynchronous — `editingDefinitionID` stays laid down until the end.
    func closeObject() {
        guard let defID = editingDefinitionID, let placementID = editingPlacementID,
              let engine, let live = find(id: placementID), let def = objectDefinitions[defID] else { return }
        guard let folder = objectsFolder else { return }
        guard !isBaking(placementID) else { return }

        // Perf: covers the SYNCHRONOUS part only. The re-bake that follows
        // is asynchronous and journals itself separately (`[PERF] bake …`), except in the "no
        // modification" case just below, which closes like a cancel.
        let tClose = CFAbsoluteTimeGetCurrent()
        defer { UIPerf.measureFrom(tClose, "close the sound object (synchronous part)") }

        // An optimisation: if the content (structure + internal mix + plugin state) is identical to
        // the one materialised AT OPENING, the official wave already reflects exactly that sub-tree.
        // No point re-rendering → it closes like a cancel (restoring the linked placement on the
        // current wave, with no new revision and no render).
        if let opened = objectEditStack.last?.openedSubtree,
           let sigOpen = subtreeSignature(opened),
           let sigNow = subtreeSignature(withCapturedPluginStates(live)),
           sigOpen == sigNow {
            NSLog("[OBJECT] closed with no modification (def \(defID)) — re-bake avoided")
            // CLOSING is not CANCELLING: the content has not moved, but the ROOT's automation
            // belongs to the instance and may have been edited during the session (it is amputated
            // from the signature, deliberately — @see subtreeSignature). Restoring it from the opening
            // snapshot would give back the curve just erased.
            cancelObjectEdit(keepingRootAutomation: true)
            return
        }

        // Cuts the parameter listening and the pending re-mirroring. The mirrors themselves stay in
        // place for the length of the render (they play the right content); they become baked instances
        // again in finishCloseObject, once the official wave is written.
        teardownLiveMirroring()

        let original = withCapturedPluginStates(live)
        let nextRevision = def.revision + 1
        let base = "\(bakeSafeName(live.displayName))_\(defID.uuidString.prefix(8))_v\(nextRevision)"
        let wav  = folder.appendingPathComponent("\(base).wav")

        let renderStart: Double
        let renderEnd: Double
        let sourceOffset: Double
        if live.isGroup {
            let range = bakeRenderRange(live)
            renderStart = range.start
            renderEnd   = range.end
            sourceOffset = max(0, live.startTime - renderStart)
        } else {
            renderStart = live.startTime
            renderEnd   = live.startTime + live.duration
            sourceOffset = 0
        }

        bakingIDs.insert(placementID)
        let completion: (Bool) -> Void = { [weak self] ok in
            guard let self else { return }
            self.bakingIDs.remove(placementID)
            self.finishCloseObject(defID: defID, placementID: placementID, ok: ok,
                                                  wav: wav, folder: folder, original: original,
                                                  nextRevision: nextRevision, sourceOffset: sourceOffset,
                                                  renderStart: renderStart, renderEnd: renderEnd)
        }
        if live.isGroup {
            engine.renderGroup(toFileAsync: placementID.uuidString, filePath: wav.path,
                               start: renderStart, end: renderEnd, completion: completion)
        } else {
            engine.renderClip(toFileAsync: placementID.uuidString, filePath: wav.path,
                              start: renderStart, end: renderEnd, completion: completion)
        }
    }

    private func finishCloseObject(defID: UUID, placementID: UUID, ok: Bool, wav: URL,
                                                   folder: URL, original: SoundObject, nextRevision: Int,
                                                   sourceOffset: Double, renderStart: Double, renderEnd: Double) {
        guard let engine else { return }
        guard ok else {
            bakeAlert(L("object.error.renderFailed.title"), L("object.error.seeConsole.info"))
            armObjectEditParamWatch()   // the session stays open → the listening is relaunched
            return
        }
        guard let live = find(id: placementID) else {
            NSLog("[OBJECT] placement \(placementID) gone during the render — orphan wave")
            try? FileManager.default.removeItem(at: wav)
            return
        }

        let sidecar = objectSidecarURL(forWave: wav.lastPathComponent, in: folder)
        do {
            try encodedObjectSidecar(original, projectFolder: projectFolder)
                .write(to: sidecar, options: .atomic)
        } catch {
            bakeAlert(L("object.error.closeFailed.title"),
                        L("object.error.sidecarWrite.info", error.localizedDescription))
            try? FileManager.default.removeItem(at: wav)
            armObjectEditParamWatch()   // the same: the session is still open
            return
        }

        // The mirrors become baked instances again BEFORE the undo point: without this,
        // undoing the closing would resurrect N live copies of the content, orphans of
        // any session.
        restoreLiveMirrors()

        pushUndo()

        // The definition's old wave/sidecar: no longer referenced, left on disk (no GC).
        let waveLen = audioFileDuration(wav) ?? (renderEnd - renderStart)
        // Editing the CONTENT does not touch the common mix: the volume/pan/mute of the
        // previous definition are carried over (falling back on the placement if it has gone).
        let prev = objectDefinitions[defID]
        objectDefinitions[defID] = ObjectDefinition(
            id: defID, name: live.displayName, wave: wav.lastPathComponent,
            revision: nextRevision, wasGroup: live.isGroup,
            volume: prev?.volume ?? live.volume, pan: prev?.pan ?? live.pan,
            isMuted: prev?.isMuted ?? live.isMuted,
            dependsOn: collectObjectDependencies(original))

        removeFromEngine(live)
        // The mix (volume/pan/mute), the state of the attribute links AND the plugins belonging to the
        // placement belong to the PLACEMENT, not to the content being edited: they are restored from
        // the snapshot taken when the edit was opened (otherwise the sub-tree's internal volume would be
        // adopted, out of step with the definition — and the placement's plugins were lost,
        // though propagateDefinitionUpdate does keep them on the OTHER
        // placements).
        let snap = editingOriginalPlacement
        var placement = SoundObject(
            id: live.id, startTime: live.startTime, duration: live.duration,
            lane: live.lane, volume: snap?.volume ?? live.volume, pan: snap?.pan ?? live.pan,
            fadeIn: live.fadeIn, fadeOut: live.fadeOut, isMuted: snap?.isMuted ?? live.isMuted,
            stemID: live.stemID, plugins: snap?.plugins ?? [],
            label: live.label ?? live.displayName, colorIndex: live.colorIndex,
            sends: live.sends, baseBPM: nil,
            definitionID: defID,
            independentAttrs: snap?.independentAttrs ?? [],
            automationTouchOrder: live.automationTouchOrder,
            kind: .clip(filePath: wav.path, sourceOffset: sourceOffset, fileDuration: waveLen,
                        speedRatio: 1.0, isReversed: false))
        // The root's automation belongs to THIS instance: it was laid on it at
        // opening (@see restoredSubtree), and it leaves with it. It is the project's invariant
        // — re-editing then re-baking a definition does not erase the instance's own curve.
        // The placement's plugins are restored from the snapshot just above, so a
        // plugin-parameter curve finds its carrier again there; what no longer has one (the FX
        // INTERNAL to the content, now baked into the wave) falls away by itself.
        placement.automation     = live.automationSurvivingBake
        placement.automationOpen = (snap?.automationOpen ?? false) && !placement.automation.isEmpty

        update(id: live.id) { $0 = placement }
        engineAddClip(placement, lane: carrierLane(for: placement.id, fallback: placement.lane))
        if let parent = parentGroup(for: placement.id) {
            engine.assignObject(placement.id.uuidString, toGroupFolder: parent.id.uuidString)
        } else if let sid = placement.stemID {
            engine.assignObjects([placement.id.uuidString], toStemID: sid.uuidString)
        }
        syncSends(placement)
        pushAutomation(placement)   // the instance's own automation, on its re-baked clip

        // Pops the current session then propagates the new official wave to the OTHER placements.
        // If a parent session remains (a nested edit), it is picked up again; otherwise everything is cut.
        if !objectEditStack.isEmpty { objectEditStack.removeLast() }
        propagateDefinitionUpdate(defID: defID, exceptPlacementID: placement.id)
        markDefinitionResynced(defID)   // a transient ✓ on the OTHER resynchronised instances
        resumeParentObjectEditAfterPop()

        selectedIDs = [placement.id]
        isDirty = true
        NSLog("[OBJECT] definition \(defID) re-baked → \(wav.lastPathComponent) (revision \(nextRevision))")
    }

    /// Cancels the edit under way: restores the materialised placement to its linked state from BEFORE
    /// the edit (the exact snapshot taken at opening), whatever was modified during
    /// the session. Writes nothing (no new revision).
    ///
    /// `keepingRootAutomation`: keep the ROOT's curves as they are NOW.
    /// False for a real cancel (✕), where everything goes back. True for a CLOSING
    /// with no modification of the content, which comes through here to avoid a pointless re-bake: those
    /// curves belong to the instance, not to the content being edited, and giving them back their
    /// opening state would resurrect an automation just erased.
    func cancelObjectEdit(keepingRootAutomation: Bool = false) {
        // Cuts the listening and the pending re-mirroring, then gives the other instances back their
        // baked clip: their snapshot IS the state from before the session, there is nothing to recompute.
        let defID = editingDefinitionID
        let tCancel = CFAbsoluteTimeGetCurrent()   // perf, @see UIPerf
        defer { UIPerf.measureFrom(tCancel, "cancel the sound object's opening") }
        teardownLiveMirroring()
        restoreLiveMirrors()

        guard let placementID = editingPlacementID,
              let originalPlacement = editingOriginalPlacement,
              let engine, let current = find(id: placementID) else {
            // An inconsistent session: at least put the other instances back on the official wave
            // (a mirror may have resisted the restoration), pop and pick the parent up again.
            if let defID { propagateDefinitionUpdate(defID: defID, exceptPlacementID: editingPlacementID ?? UUID()) }
            if !objectEditStack.isEmpty { objectEditStack.removeLast() }
            resumeParentObjectEditAfterPop()
            return
        }

        // The same boundary as at closing with a render (@see finishCloseObject): what survives the
        // wave leaves with the instance, the rest falls with the content that carried it.
        var restored = originalPlacement
        if keepingRootAutomation {
            restored.automation          = current.automationSurvivingBake
            restored.automationTouchOrder = current.automationTouchOrder
            restored.automationOpen      = current.automationOpen && !restored.automation.isEmpty
        }

        removeFromEngine(current)
        update(id: placementID) { $0 = restored }
        engineAddClip(restored, lane: carrierLane(for: placementID, fallback: restored.lane))
        if let parent = parentGroup(for: placementID) {
            engine.assignObject(placementID.uuidString, toGroupFolder: parent.id.uuidString)
        } else if let sid = restored.stemID {
            engine.assignObjects([placementID.uuidString], toStemID: sid.uuidString)
        }
        syncSends(restored)
        engine.updateFade(in: restored.fadeIn, fadeOut: restored.fadeOut,
                          forID: placementID.uuidString)
        pushAutomation(restored)
        // The other instances have already gone back to their baked clip (restoreLiveMirrors, at the head).

        // Pops the current session; picks the parent up again (a nested edit) or cuts everything.
        if !objectEditStack.isEmpty { objectEditStack.removeLast() }
        resumeParentObjectEditAfterPop()
        selectedIDs = [placementID]
        isDirty = true
    }

    /// After popping a session (a closing/cancel), picks the PARENT session up again if the stack
    /// is not empty — otherwise cuts the whole apparatus. The teardown of the popped session (the end
    /// of the listening + the pending re-mirroring cancelled) has already happened in the caller.
    private func resumeParentObjectEditAfterPop() {
        guard isEditingObject else {
            // No session left: future arming is allowed again.
            liveMirrorSuppressed = false
            // The closing that has just finished may have made out of date the definitions holding
            // the one edited (A in B in C) → an automatic transitive recomputation in the background.
            cascadeRebakeStaleFixpoint()
            return
        }
        // A parent session takes over: its content may have changed through the nested edit
        // just closed → the listening is reinstalled and its mirrors are laid again.
        armObjectEditParamWatch()
        scheduleLiveMirror()
    }

    /// Refreshes the content (filePath/fileDuration) of every OTHER placement that
    /// references `defID` after a re-bake. No audio recomputation: only the engine clip is
    /// recreated on the new file (as free as reading a different wav — that is
    /// the whole point of sharing).
    private func propagateDefinitionUpdate(defID: UUID, exceptPlacementID: UUID) {
        guard let def = objectDefinitions[defID], let folder = objectsFolder else { return }
        let wav = folder.appendingPathComponent(def.wave)
        let waveLen = audioFileDuration(wav) ?? 0
        applyDefinitionWave(defID: defID, waveURL: wav, waveLen: waveLen, excluding: exceptPlacementID)
    }

    /// The lane of the TRACK carrying an object: that of its group if it is nested (its own lane is
    /// relative to the group), its own otherwise. A lane = a track: a clip created on the
    /// wrong lane is born on a neighbour's track before being moved into its container.
    func carrierLane(for id: UUID, fallback: Int) -> Int {
        parentGroup(for: id)?.lane ?? fallback
    }

    /// Recreates the engine clip of the OTHER instances of `defID` on `waveURL` (duration `waveLen`),
    /// and writes it into the model. No audio recomputation: reading another wave is as free
    /// as a normal read — that is the whole point of the baked regime.
    /// The instances still in a live mirror are ignored (they are not `.clip`s):
    /// `restoreLiveMirrors` has normally already given them back their clip before the call.
    private func applyDefinitionWave(defID: UUID, waveURL: URL, waveLen: Double, excluding: UUID?) {
        guard let engine else { return }
        for tid in placementIDs(forDefinition: defID, excluding: excluding) {
            guard let obj = find(id: tid),
                  case .clip(_, let so, _, let sr, let rev) = obj.kind else { continue }
            removeFromEngine(obj)
            var refreshed = obj
            refreshed.kind = .clip(filePath: waveURL.path, sourceOffset: so, fileDuration: waveLen,
                                   speedRatio: sr, isReversed: rev)
            update(id: tid) { $0 = refreshed }
            engineAddClip(refreshed, lane: carrierLane(for: tid, fallback: refreshed.lane))
            if let parent = parentGroup(for: tid) {
                engine.assignObject(tid.uuidString, toGroupFolder: parent.id.uuidString)
            } else if let sid = refreshed.stemID {
                engine.assignObjects([tid.uuidString], toStemID: sid.uuidString)
            }
            syncSends(refreshed)
            engine.updateFade(in: refreshed.fadeIn, fadeOut: refreshed.fadeOut, forID: tid.uuidString)
            // The engine clip is new: this instance's OWN automation (which the new
            // wave does not touch) has to be rewritten into it, otherwise a re-bake of the definition
            // would silence it on every instance except the one just edited.
            pushAutomation(refreshed)
        }
    }

    // MARK: - The live mirror (the other instances play the content being edited)
    //
    // A sound object has two regimes. CLOSED, it is baked: all of its instances read the same
    // wave, and N instances cost only one file read each. OPEN for editing, it
    // is LIVE: the content is materialised on the instance being edited, and the OTHERS become
    // mirrors of it — the same sub-tree, put back at their position, with their mix. So they all
    // refer to the same origin, with no render taking place.
    //
    // It is the ContainerClip that makes this regime possible: a group is ONE clip, hence a content
    // that can be laid identically elsewhere. The CPU cost does not blow up because only
    // one sound object is open at a time, and because each track's CombiningNode only handles a
    // container where it crosses the current block.
    //
    // A mirror is FOLDED: it is looked at, not edited. `buildLaneEntries` only descends
    // into open groups, so its content is not hit-testable and nothing in it is modified
    // behind the origin's back.

    /// The wait before laying the mirrors again. Frankly longer than a display debounce:
    /// laying a mirror rebuilds its engine sub-tree (hence re-instantiates its plugins), and we
    /// would rather do it once at the end of a gesture than at every notch.
    private static let liveMirrorDelay: TimeInterval = 0.6

    /// The keys (uuidString) of the sub-tree: the object + all of its descendants. Used to install
    /// the parameter listening on the FX of the whole content being edited (group → children included).
    private func subtreeObjectKeys(_ obj: SoundObject) -> [String] {
        var keys = [obj.id.uuidString]
        if case .group(let children, _) = obj.kind {
            for c in children { keys += subtreeObjectKeys(c) }
        }
        return keys
    }

    /// (Re)installs the engine parameter listening for the current session: a LIVE knob
    /// movement does not go through the model, so it would never arm the re-mirroring without this.
    /// Idempotent (called again when plugins have been added).
    private func armObjectEditParamWatch() {
        guard let placementID = editingPlacementID, let live = find(id: placementID) else { return }
        engine?.onObjectEditParamChanged = { [weak self] in
            // The engine's parameter listeners fire on the message thread (= main); we
            // go back through the main queue to hop the actor cleanly.
            DispatchQueue.main.async {
                guard let self else { return }
                self.scheduleLiveMirror()
            }
        }
        engine?.beginObjectEditParamWatch(subtreeObjectKeys(live))
        liveMirrorSuppressed = false
    }

    /// Arms (or re-arms) the re-mirroring debounce. Called by the `isDirty` hook and by the engine
    /// parameter callback. A no-op outside a session or if the arming is suspended (an opening/closing/cancel
    /// under way).
    func scheduleLiveMirror() {
        guard isEditingObject, !liveMirrorSuppressed else { return }
        liveMirrorWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refreshLiveMirrors() }
        liveMirrorWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.liveMirrorDelay, execute: work)
    }

    /// The instances to bring alive as mirrors: the definition's other placements, minus those
    /// that live INSIDE a content being edited. Those are not separate occurrences
    /// — they ARE content being edited, and mirroring them would duplicate that content in
    /// place (and, for an instance nested inside its own mirror, endlessly).
    private func liveMirrorTargets(defID: UUID, origin: UUID) -> [UUID] {
        // The roots whose content is already driven by a session: the placements being edited, and the
        // mirrors already laid (rewritten on each pass). An instance lodged under one of them has
        // no existence of its own. `$0 != tid`: a mirror stays its own target, otherwise it would
        // never be refreshed again.
        var roots = objectEditStack.map(\.placementID)
        roots += objectEditStack.flatMap { $0.mirrorSnapshots.keys }
        return placementIDs(forDefinition: defID, excluding: origin).filter { tid in
            !roots.contains { $0 != tid && isSelfOrDescendant(tid, of: $0) }
        }
    }

    /// Turns the other instances into live mirrors, when the session opens. Their state
    /// from before (the baked clip, with its own FX) is set aside in the session: that is what
    /// will be given back to them at closing as at a cancel.
    private func installLiveMirrors() {
        guard !objectEditStack.isEmpty,
              let defID = editingDefinitionID,
              let placementID = editingPlacementID,
              let live = find(id: placementID) else { return }

        var snapshots: [UUID: SoundObject] = [:]
        for tid in liveMirrorTargets(defID: defID, origin: placementID) {
            guard let target = find(id: tid), case .clip = target.kind else { continue }
            snapshots[tid] = withCapturedPluginStates(target)
        }
        guard !snapshots.isEmpty else { return }

        objectEditStack[objectEditStack.count - 1].mirrorSnapshots = snapshots
        // Perf: each mirror laid redoes a removeFromEngine +
        // syncAdd, hence rebuilds an engine sub-tree. It is linear in the number
        // of instances — the item to watch when a definition is heavily placed.
        let tMirrors = CFAbsoluteTimeGetCurrent()
        for (tid, snap) in snapshots {
            applyLiveMirror(to: tid, alignedTo: snap, from: live, defID: defID)
        }
        let mirrorsMs = (CFAbsoluteTimeGetCurrent() - tMirrors) * 1000
        objectEditStack[objectEditStack.count - 1].lastMirrorSignature =
            subtreeSignature(withCapturedPluginStates(live))
        NSLog("[OBJECT] session \(defID): \(snapshots.count) instance(s) in a live mirror")
        if mirrorsMs >= 1 {
            NSLog("[PERF] laying %d mirror(s): %.0f ms (%.0f ms / mirror)",
                  snapshots.count, mirrorsMs, mirrorsMs / Double(snapshots.count))
        }
    }

    /// Lays the mirrors again on the origin's current content (a debounced pass).
    private func refreshLiveMirrors() {
        liveMirrorWorkItem = nil
        guard isEditingObject, !liveMirrorSuppressed, !objectEditStack.isEmpty,
              let defID = editingDefinitionID,
              let placementID = editingPlacementID,
              let engine, let live = find(id: placementID) else { return }

        // An instance may have been born during the session (copy-and-paste of a linked instance): it
        // joins the mirroring, with its own starting snapshot.
        var snapshots = objectEditStack[objectEditStack.count - 1].mirrorSnapshots
        let known = snapshots.count
        for tid in liveMirrorTargets(defID: defID, origin: placementID) where snapshots[tid] == nil {
            guard let target = find(id: tid), case .clip = target.kind else { continue }
            snapshots[tid] = withCapturedPluginStates(target)
        }
        guard !snapshots.isEmpty else { return }

        // The binary state of external plugins only goes down into their ValueTree on request:
        // without this flush, the signature would not see a setting made with the mouse in a native
        // editor, and the mirrors would stay behind.
        engine.flushObjectEditPluginStates()
        let captured  = withCapturedPluginStates(live)
        let signature = subtreeSignature(captured)

        // Nothing has moved and there is no new instance: laying the mirrors again would rebuild their
        // engine sub-tree (and re-instantiate their plugins) for an identical result.
        if snapshots.count == known,
           let sig = signature,
           sig == objectEditStack[objectEditStack.count - 1].lastMirrorSignature {
            return
        }

        // Laying the mirrors mutates the model and the engine: without this suspension, the `isDirty` hook and the
        // parameter listeners called back along the way would re-arm the pass being
        // carried out — a 0.6 s turnstile that never converges.
        liveMirrorSuppressed = true
        defer { liveMirrorSuppressed = false }

        objectEditStack[objectEditStack.count - 1].mirrorSnapshots = snapshots
        for (tid, snap) in snapshots {
            applyLiveMirror(to: tid, alignedTo: snap, from: live, defID: defID)
        }
        objectEditStack[objectEditStack.count - 1].lastMirrorSignature = signature
    }

    /// Lays (or lays again) the origin's content onto `targetID`, aligned on `snapshot` — the
    /// position, the window and the mix of THAT instance. The alignment is always on the snapshot and
    /// never on the target's current state: once mirrored it is a group, it no longer has
    /// a `sourceOffset` or a `speedRatio` to question, and the alignment would drift on each
    /// pass.
    private func applyLiveMirror(to targetID: UUID, alignedTo snapshot: SoundObject,
                                 from live: SoundObject, defID: UUID) {
        guard let engine else { return }

        var mirror = refreshObjectReferences(in: restoredSubtree(from: live, alignedTo: snapshot))
        // `restoredSubtree` cuts the link (that is what detaching expects); here the instance
        // stays an instance — a link halo, synchronised attributes, a return to the wave at closing.
        mirror.definitionID = defID
        // The FX belonging to the instance apply AFTER the content, as when detaching.
        mirror.plugins = mirror.plugins + snapshot.plugins
        if case .group(let children, _) = mirror.kind {
            mirror.kind = .group(children: children, isExpanded: false)
        }

        if let current = find(id: targetID) { removeFromEngine(current) }
        update(id: targetID) { $0 = mirror }
        syncAdd(mirror)
        if let parent = parentGroup(for: targetID) {
            engine.assignObject(targetID.uuidString, toGroupFolder: parent.id.uuidString)
        } else if let sid = mirror.stemID {
            engine.assignObjects([targetID.uuidString], toStemID: sid.uuidString)
        }
        syncSends(mirror)
    }

    /// Gives the mirrored instances back their baked clip from before the session (model + engine).
    /// Called at closing as at a cancel, BEFORE the undo point: without this, undoing a
    /// closing would resurrect N live copies of the content, orphans of any session.
    private func restoreLiveMirrors() {
        guard let engine, !objectEditStack.isEmpty else { return }
        let snapshots = objectEditStack[objectEditStack.count - 1].mirrorSnapshots
        guard !snapshots.isEmpty else { return }

        let tRestore = CFAbsoluteTimeGetCurrent()   // perf, @see UIPerf
        for (tid, snap) in snapshots {
            // An instance deleted during the session: do not resurrect it on the engine side.
            guard let current = find(id: tid) else { continue }
            removeFromEngine(current)
            update(id: tid) { $0 = snap }
            engineAddClip(snap, lane: carrierLane(for: tid, fallback: snap.lane))
            if let parent = parentGroup(for: tid) {
                engine.assignObject(tid.uuidString, toGroupFolder: parent.id.uuidString)
            } else if let sid = snap.stemID {
                engine.assignObjects([tid.uuidString], toStemID: sid.uuidString)
            }
            syncSends(snap)
            engine.updateFade(in: snap.fadeIn, fadeOut: snap.fadeOut, forID: tid.uuidString)
            pushAutomation(snap)   // the instance finds its baked clip again AND its own curve
        }
        let restoreMs = (CFAbsoluteTimeGetCurrent() - tRestore) * 1000
        if restoreMs >= 1 {
            NSLog("[PERF] %d mirror(s) back to the baked clip: %.0f ms",
                  snapshots.count, restoreMs)
        }
        objectEditStack[objectEditStack.count - 1].mirrorSnapshots  = [:]
        objectEditStack[objectEditStack.count - 1].lastMirrorSignature = nil
    }

    /// Cuts the parameter listening and the pending re-mirroring. Does NOT touch the mirrors already laid:
    /// it is `restoreLiveMirrors` that decides when they become baked clips again.
    private func teardownLiveMirroring() {
        liveMirrorSuppressed = true
        liveMirrorWorkItem?.cancel(); liveMirrorWorkItem = nil
        engine?.onObjectEditParamChanged = nil
        engine?.endObjectEditParamWatch()
    }

    /// Cuts all sound-object session activity. To be called on a project reset/close
    /// (the editing state is already reset by the caller, the mirrors leave with `items`).
    func resetObjectEditSession() {
        teardownLiveMirroring()
        liveMirrorSuppressed = false
        // Cuts any re-bake cascade under way (the renders in flight will finish but
        // `processNextStaleRebake` will stop: nothing out of date in the new registry).
        recomputingDefinitionIDs.removeAll()
        recentlyResyncedDefinitionIDs.removeAll()
        resyncedBadgeDeadline.removeAll()
        cascadeFailedDefs.removeAll()
        isCascadingRebake = false
        cascadeRebakeCount = 0
    }

    // MARK: - Detaching

    /// Detaches an instance from its definition by RE-MATERIALISING it to its original
    /// editable content (clip / group / MIDI, from the definition's sidecar) — like
    /// opening an edit, but with NO session: the object becomes an ordinary clip/group/MIDI
    /// again, fully modifiable, with no link. The other instances go on sharing
    /// the definition normally. The user can then "Create a sound object" again
    /// if they wish. The inverse of the link created by `makeObject` / copy-and-pasting an instance.
    func detachFromDefinition(placementID: UUID) {
        guard let engine, let placement = find(id: placementID), placement.isObjectInstance,
              let defID = placement.definitionID, let def = objectDefinitions[defID] else { return }
        guard let folder = objectsFolder else { return }
        // Detaching a nested instance DURING the editing of a parent is allowed (it is a
        // plain modification of the parent's content); only detaching a placement that
        // is itself an editing session under way is forbidden.
        guard !isBaking(placementID), !isInObjectEditStack(placementID),
              !isLiveMirror(placementID) else { return }

        let sidecar = objectSidecarURL(forWave: def.wave, in: folder)
        let original: SoundObject
        do {
            let data = try Data(contentsOf: sidecar)
            original = try decodedObjectSidecar(data, projectFolder: projectFolder)
        } catch {
            bakeAlert(L("object.error.detachFailed.title"),
                        L("object.error.sidecarRead.info", sidecar.lastPathComponent, error.localizedDescription))
            return
        }

        // The same warning as at opening for editing: detaching materialises the content, hence
        // loses the plugins this machine has not got (see confirmMissingPluginsBeforeOpening).
        guard confirmMissingPluginsBeforeOpening(
            original, what: L("object.missingPlugins.what", placement.displayName)) else { return }

        pushUndo()
        // The plugins BELONGING to the placement (added after the transformation, applying to the baked
        // submix) → to be carried over AFTER the restored internal plugins, as with the mirror.
        let wrapperPlugins = withCapturedPluginStates(placement).plugins

        // The original sub-tree aligned on the placement's LIVE window/position, fresh ids everywhere,
        // internal references refreshed (a sound-object descendant may have been updated
        // since the last bake). `restoredSubtree` already sets definitionID to nil on the
        // result.
        var restored = refreshObjectReferences(in: restoredSubtree(from: original, alignedTo: placement))
        restored.plugins = restored.plugins + wrapperPlugins

        removeFromEngine(placement)
        update(id: placementID) { $0 = restored }
        syncAdd(restored)
        if let parent = parentGroup(for: placementID) {
            engine.assignObject(placementID.uuidString, toGroupFolder: parent.id.uuidString)
        } else if let sid = restored.stemID {
            engine.assignObjects([placementID.uuidString], toStemID: sid.uuidString)
        }
        if restored.isClip || restored.isMIDI {
            engine.updateFade(in: restored.fadeIn, fadeOut: restored.fadeOut, forID: placementID.uuidString)
        }
        syncSends(restored)
        selectedIDs = [placementID]
        isDirty = true
        NSLog("[OBJECT] placement \(placementID) detached from the definition \(defID) → editable content restored")
    }
}
