import Foundation

// MARK: - Relinking a missing file (the repair itself)
//
// `EditViewModel+MissingFiles` says WHAT is broken and `PathRelink` says what one repair teaches
// about the next; this is the file that actually mends something. It owns three gestures and one
// mechanism.
//
// **THE MECHANISM, and it is the whole reason this file is not three lines long: a relink CREATES
// the engine clip, it does not correct a path.** A file the engine cannot open makes
// `addSoundObject` give up BEFORE the clip exists (@see OBJEngineCore.mm, addSoundObject:withID:),
// so an object whose file went missing is a GHOST down there — no clip, no chain, no fades, no
// sends, no plugins. Writing a new path into the model would therefore mend the drawing and
// nothing else: the object would still be silent, and silently so. What has to happen is the
// birth of the whole object on the new file, which is exactly the gesture `applyDefinitionWave`
// makes when a sound object is re-baked onto another wave (@see EditViewModel+Objects):
// removeFromEngine → rewrite the kind → engineAddClip → reattach to the group or the stem →
// syncSends → updateFade → pushAutomation. `rebuildClip` is that sequence, plus the fade SHAPES
// (they live in the ObjWindowFade plugin, which is reborn with the object) — and the plugins come
// back for free, `engineAddClip` calling `syncPlugins` for any object whose chain is not empty.
// The model's `stateXML` is what they are rebuilt from, and it has survived: a ghost has no live
// plugin for `withCapturedPluginStates` to overwrite it with.
//
// **THE THREE GESTURES, and the line between them is a design decision (@see CONTRACTS, 1-2):**
//   - `replaceSource(of:with:)` — the file is THERE and another one is wanted (a sound re-edited
//     outside). Deliberate, available when nothing is missing at all, and the unit is the OBJECT:
//     the objects NAMED change and no other placement of the file does. Naming several is the
//     hand's business (the sound list's selection), and so is the question "and the others?",
//     which the dialog puts from `objectsSharingSource` — nothing propagates by itself here.
//   - `relinkPath(_:to:)` / `repairPath(_:to:propagate:)` — a file is GONE. The unit is the PATH,
//     not the object: one file lost breaks the N objects that name it, and putting it back mends
//     all N in ONE undo point. Accidents come by packets, so a repair can propagate what it
//     learned to the other broken paths.
//   - `relinkFromFolder(_:)` — here is a folder, find what you can in it.
//
// **ONE undo point per gesture, whatever it touches**, which is what forces every public door here
// to be `pushUndo()` + one private core that pushes nothing: two doors each pushing their own
// would make ⌘Z give back half a repair, and a half-repaired session is worse than a broken one
// because nothing says which half. A gesture that ends up changing nothing takes its entry back
// (`undoStack.popLast()`), the project's convention since `cut`.
//
// **And every repair ends with `rescanMissingFiles()`** — without it the red stays on an object
// that plays perfectly well, which is the one bug that makes a user stop trusting the colour.

extension EditViewModel {

    /// What one repair did. `objects` is the figure a human counts ("four sounds mended"),
    /// `paths` the figure the repair actually works in, and `substitution` what the pair taught —
    /// non-nil even when nothing else needed it, since it is what the modal offers to propagate.
    struct RelinkReport {
        let objects: Int
        let paths: Int
        let substitution: PathRelink.Substitution?
    }

    // MARK: - A file's size

    /// The size in bytes of the file at `path`, or nil if it cannot be read. Reads the DISK, so it
    /// belongs at the doors where a file is laid down or repaired — never in a view body, for the
    /// reason spelled out at the head of EditViewModel+MissingFiles.
    nonisolated static func fileSize(atPath path: String) -> Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? NSNumber else { return nil }
        return size.int64Value
    }

    /// The size RECORDED for a path, read from whichever object still remembers it.
    ///
    /// **By path and never by object, and that is not a convenience — it is what makes the field
    /// survive at all.** The sites that copy a clip (a split, an overlap resolution, the
    /// clipboard) build a FRESH `SoundObject` field by field, and a top-level `fileSize` is
    /// exactly the kind of field such a rebuild drops. Asking the PATH means one surviving
    /// object is enough for the whole path to keep its size, and a relink is an operation on the
    /// path anyway. nil = nobody recorded it (every session written before format 14).
    func recordedSize(forPath path: String) -> Int64? {
        guard !path.isEmpty else { return nil }
        for clip in allClips {
            guard case .clip(let p, _, _, _, _) = clip.kind, p == path else { continue }
            if let size = clip.fileSize { return size }
        }
        return nil
    }

    // MARK: - Replacing the source of N objects

    /// Points one object at another file. The contract door (`object.replace_source`), and the
    /// single-object reading of the one just below.
    @discardableResult
    func replaceSource(of id: UUID, with url: URL) -> Bool {
        replaceSource(of: [id], with: url)
    }

    /// Points N objects at another file, in ONE undo point. The deliberate gesture: no
    /// propagation, no question, and available whether or not anything is missing — "I have
    /// re-edited that sound outside" is not an accident to repair, it is an edit.
    ///
    /// The unit here is the OBJECT and not the path, which is exactly what tells this gesture from
    /// a repair (@see the head of this file): the objects named are the ones that change, and no
    /// other placement of the same file is touched unless it was named too. Offering the others is
    /// the caller's business — it is a question, and this file never asks one (@see
    /// `objectsSharingSource`, which the dialog reads to put it).
    ///
    /// Refuses an INSTANCE of a sound object (`definitionID != nil`): its content is not its own,
    /// it reads the definition's current wave, and the next re-bake would silently put that wave
    /// back — a gesture undone by something the user did not do is worse than one refused. An id
    /// that cannot take the file is DROPPED rather than failing the batch: a selection holding one
    /// instance among ten sounds must still replace the ten.
    @discardableResult
    func replaceSource(of ids: [UUID], with url: URL) -> Bool {
        let path = url.path
        guard FileManager.default.fileExists(atPath: path) else { return false }
        // Deduplicated, the callers being free to hand over a selection plus the objects sharing
        // its files — the two lists can overlap, and rebuilding one object twice would cost it its
        // window a second time.
        var seen = Set<UUID>()
        let targets = ids.filter { id in
            guard seen.insert(id).inserted,
                  let object = find(id: id), case .clip(let oldPath, _, _, _, _) = object.kind,
                  object.definitionID == nil, oldPath != path else { return false }
            return true
        }
        guard !targets.isEmpty else { return false }

        // The file is read ONCE however many objects take it, exactly as `rebuildClips` does for
        // a repair: N objects on one take must not cost N reads.
        pushUndo()
        let length = audioFileDuration(url)
        let size = Self.fileSize(atPath: path)
        var done = 0
        for id in targets {
            if rebuildClip(id: id, onFile: path, fileLength: length, size: size) { done += 1 }
        }
        guard done > 0 else {
            _ = undoStack.popLast()
            return false
        }
        // A replacement can mend a missing file as much as break one (pointing at a file that is
        // itself about to go): the scan is what keeps the red honest either way.
        rescanMissingFiles()
        isDirty = true
        return true
    }

    /// The objects that read one of `paths` and are NOT in `excluding` — what "replace the others
    /// too?" is asked about, and what it replaces when the answer is yes.
    ///
    /// The counterpart of `propagationTargets` for the deliberate gesture, and it counts OBJECTS
    /// where that one counts paths: the sentence says "N other sounds use this file", and here
    /// several placements of one take are several sounds to the eye. Only what `replaceSource`
    /// would really accept is returned (an instance of a sound object is left out), so the figure
    /// offered is a figure of things that will change. Sorted by nothing but the tree's own order
    /// — `allClips` walks it — which is what makes a headless assertion repeatable.
    func objectsSharingSource(_ paths: Set<String>, excluding: Set<UUID>) -> [UUID] {
        guard !paths.isEmpty else { return [] }
        return allClips.compactMap { clip -> UUID? in
            guard case .clip(let p, _, _, _, _) = clip.kind,
                  paths.contains(p), !excluding.contains(clip.id),
                  clip.definitionID == nil else { return nil }
            return clip.id
        }
    }

    // MARK: - Repairing a PATH

    /// Repairs every object naming `oldPath`, in one undo point. Returns how many objects were
    /// mended. The contract door: `repairPath` is the same gesture with the propagation available.
    @discardableResult
    func relinkPath(_ oldPath: String, to url: URL) -> Int {
        repairPath(oldPath, to: url, propagate: false).objects
    }

    /// Repairs `oldPath`, and — if `propagate` — every OTHER missing path that the substitution
    /// this pair teaches resolves onto a file that really exists. **One undo point for the lot**,
    /// which is the point of doing it here rather than by calling the two doors in turn.
    ///
    /// The targets are computed BEFORE anything is written: a repair does not move the other
    /// broken paths, but reading the list first means the answer cannot depend on the order the
    /// repairs happen to take.
    @discardableResult
    func repairPath(_ oldPath: String, to url: URL, propagate: Bool) -> RelinkReport {
        let newPath = url.path
        guard !oldPath.isEmpty, oldPath != newPath,
              FileManager.default.fileExists(atPath: newPath) else {
            return RelinkReport(objects: 0, paths: 0, substitution: nil)
        }

        let learned = PathRelink.learnedSubstitution(from: oldPath, to: newPath)
        var targets: [(old: String, new: String)] = []
        if propagate, let learned { targets = propagationTargets(learned, excluding: oldPath) }

        pushUndo()
        var objects = rebuildClips(onPath: oldPath, to: newPath)
        var paths = objects > 0 ? 1 : 0
        for target in targets {
            let mended = rebuildClips(onPath: target.old, to: target.new)
            if mended > 0 { objects += mended; paths += 1 }
        }
        guard objects > 0 else {
            _ = undoStack.popLast()
            return RelinkReport(objects: 0, paths: 0, substitution: learned)
        }
        rescanMissingFiles()
        isDirty = true
        return RelinkReport(objects: objects, paths: paths, substitution: learned)
    }

    // MARK: - Propagating what one repair taught

    /// What the pair (`oldPath` → `newPath`) would mend BESIDES `oldPath` itself. Computes and
    /// changes NOTHING: it is what the modal reads to ask "N other missing files are in the same
    /// place — relink those too?".
    ///
    /// At most one entry, the substitution this one pair teaches; the dictionary shape is the
    /// contract's, the count being what is said out loud. **Empty when the count would be zero**,
    /// so a caller has one test to make rather than two: a propagation offered over nothing is a
    /// question with only one answer.
    ///
    /// The count is of PATHS and not of objects, because that is what the sentence says — "N other
    /// files" — and because only the paths that resolve onto a file that EXISTS are counted. A
    /// substitution that merely applies to a path proves nothing: relinking onto the wrong file is
    /// worse than leaving it missing (@see PathRelink).
    func resolvableByPropagation(from oldPath: String,
                                 to newPath: String) -> [PathRelink.Substitution: Int] {
        guard let sub = PathRelink.learnedSubstitution(from: oldPath, to: newPath) else { return [:] }
        let count = propagationTargets(sub, excluding: oldPath).count
        return count > 0 ? [sub: count] : [:]
    }

    /// Applies a learned substitution to every missing path it resolves onto an existing file, in
    /// ONE undo point. The "yes" of the propagation prompt, and the door a script drives it by.
    /// Returns how many OBJECTS were mended.
    @discardableResult
    func applyPropagation(_ sub: PathRelink.Substitution) -> Int {
        let targets = propagationTargets(sub, excluding: nil)
        guard !targets.isEmpty else { return 0 }

        pushUndo()
        var objects = 0
        for target in targets { objects += rebuildClips(onPath: target.old, to: target.new) }
        guard objects > 0 else {
            _ = undoStack.popLast()
            return 0
        }
        rescanMissingFiles()
        isDirty = true
        return objects
    }

    /// The missing paths this substitution resolves onto a file that is really there, each with
    /// where it would go. Sorted by the old path — a deterministic order, which is what a headless
    /// assertion and a list shown twice both need.
    ///
    /// `excluding` is the path the repair has just been aimed at by hand: it is no business of the
    /// propagation's, and counting it would make the prompt say one more than it will do.
    func propagationTargets(_ sub: PathRelink.Substitution,
                            excluding: String?) -> [(old: String, new: String)] {
        missingPaths.keys.sorted().compactMap { old -> (old: String, new: String)? in
            guard old != excluding,
                  let new = PathRelink.applying(sub, to: old), new != old,
                  FileManager.default.fileExists(atPath: new) else { return nil }
            return (old: old, new: new)
        }
    }

    // MARK: - Sweeping a folder

    /// How deep below the chosen folder the sweep goes, and how many directories it will open at
    /// all. **Both bounds exist because this runs on the main thread**, like every mutation of the
    /// model — a folder chosen by hand can be `/` or a network share, and an unbounded walk there
    /// is the application hanging with nothing on screen to say why. Eight levels is deeper than
    /// any sample library one POINTS AT (one points at the library, not at its parent), and four
    /// thousand directories is far past the same, so the bounds are reached only by a folder
    /// nobody meant to choose. Hitting either one simply means fewer candidates, never a wrong
    /// one: the sweep mends what it found and leaves the rest red.
    private static let relinkScanMaxDepth = 8
    private static let relinkScanMaxDirectories = 4000

    /// Sweeps `folder` and repairs every missing path whose FILE NAME is found in it, homonyms
    /// settled by `PathRelink.rank` (the recorded size against the candidates') — one undo point
    /// for the whole sweep. Returns how many objects were mended.
    ///
    /// Only a name that matches is ever a candidate, and a path with several of them takes the
    /// best-ranked. `rank`'s order is total, so the same folder swept twice gives the same answer.
    @discardableResult
    func relinkFromFolder(_ folder: URL) -> Int {
        let broken = missingPaths.keys.sorted()
        guard !broken.isEmpty else { return 0 }

        let wantedNames = Set(broken.map { ($0 as NSString).lastPathComponent.lowercased() })
        // Only the names we are looking for are ever kept, so the memory of the sweep depends on
        // what is broken and not on the size of the folder.
        let found = Self.candidates(under: folder, named: wantedNames)
        guard !found.isEmpty else { return 0 }

        pushUndo()
        var objects = 0
        for old in broken {
            let name = (old as NSString).lastPathComponent
            guard let pool = found[name.lowercased()], !pool.isEmpty else { continue }
            let ranked = PathRelink.rank(pool, name: name, size: recordedSize(forPath: old))
            guard let best = ranked.first, best.path != old else { continue }
            objects += rebuildClips(onPath: old, to: best.path)
        }
        guard objects > 0 else {
            _ = undoStack.popLast()
            return 0
        }
        rescanMissingFiles()
        isDirty = true
        return objects
    }

    /// The files under `folder` whose (lower-cased) name is one of `names`, keyed by that name.
    ///
    /// Breadth first with an explicit depth carried on the queue, rather than a `FileManager`
    /// enumerator: the depth is then a fact of the loop instead of something checked after the
    /// fact, which is what a bound has to be. Hidden files are skipped and a PACKAGE is never
    /// entered — an `.app` or a `.logicx` is a file to the user, and the samples inside somebody
    /// else's document are not candidates for this project.
    private static func candidates(under folder: URL,
                                   named names: Set<String>) -> [String: [PathRelink.Candidate]] {
        guard !names.isEmpty else { return [:] }
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .fileSizeKey]
        var out: [String: [PathRelink.Candidate]] = [:]
        var queue: [(url: URL, depth: Int)] = [(url: folder, depth: 0)]
        var opened = 0

        while !queue.isEmpty {
            let (dir, depth) = queue.removeFirst()
            opened += 1
            if opened > relinkScanMaxDirectories { break }
            guard let entries = try? fm.contentsOfDirectory(at: dir,
                                                            includingPropertiesForKeys: Array(keys),
                                                            options: [.skipsHiddenFiles]) else { continue }
            for entry in entries {
                let values = try? entry.resourceValues(forKeys: keys)
                if values?.isDirectory == true {
                    guard values?.isPackage != true, depth < relinkScanMaxDepth else { continue }
                    queue.append((url: entry, depth: depth + 1))
                    continue
                }
                let name = entry.lastPathComponent.lowercased()
                guard names.contains(name) else { continue }
                let size = values?.fileSize.map { Int64($0) }
                out[name, default: []].append(PathRelink.Candidate(path: entry.path, size: size))
            }
        }
        return out
    }

    // MARK: - The repair itself (no undo point, no scan: the callers own both)

    /// Rebuilds every object naming `oldPath` onto `newPath`. The file is read ONCE (its length
    /// and its size) however many objects share it — N clips on one take must not cost N reads.
    @discardableResult
    private func rebuildClips(onPath oldPath: String, to newPath: String) -> Int {
        guard !oldPath.isEmpty, oldPath != newPath else { return 0 }
        // Ids only: `allClips` hands back COPIES with the lane already flattened into absolute
        // terms, so nothing read from it may ever be written back into the model.
        let ids: [UUID] = allClips.compactMap { clip -> UUID? in
            guard case .clip(let p, _, _, _, _) = clip.kind, p == oldPath else { return nil }
            return clip.id
        }
        guard !ids.isEmpty else { return 0 }

        let url = URL(fileURLWithPath: newPath)
        let length = audioFileDuration(url)
        let size = Self.fileSize(atPath: newPath)
        var done = 0
        for id in ids {
            if rebuildClip(id: id, onFile: newPath, fileLength: length, size: size) { done += 1 }
        }
        return done
    }

    /// ONE object laid again on another file: the model rewritten, then the engine object BORN —
    /// see the head of this file for why nothing less will do.
    ///
    /// `fileLength` nil = the length could not be read (a format `AVAudioFile` will not open).
    /// The old length is then kept and nothing is clamped: it is the least destructive answer, and
    /// the engine will say in the log whether it could open the file at all. The size is written
    /// through whatever it is, nil included — a stale size describing the file that went would be
    /// worse than none, since the next sweep would settle homonyms with it.
    @discardableResult
    private func rebuildClip(id: UUID, onFile newPath: String,
                             fileLength: Double?, size: Int64?) -> Bool {
        guard let before = find(id: id),
              case .clip(let oldPath, let sourceOffset, let oldLength, let speed, let reversed) = before.kind,
              oldPath != newPath else { return false }

        var length = oldLength
        if let fileLength, fileLength > 0 { length = fileLength }
        let fitted = Self.fittedWindow(sourceOffset: sourceOffset, duration: before.duration,
                                       speedRatio: speed, fileLength: length)

        removeFromEngine(before)
        update(id: id) { obj in
            obj.kind = .clip(filePath: newPath, sourceOffset: fitted.sourceOffset,
                             fileDuration: length, speedRatio: speed, isReversed: reversed)
            obj.fileSize = size
            guard fitted.duration < obj.duration else { return }
            // The END comes in, so the fades are treated at the door every other shortening goes
            // through: a fade-out starts at a point IN the sound, it keeps that start and ends
            // earlier with the edge (@see fadeOutAnchoredAtStart), and the two clamps below stay
            // the last word — a fade longer than the window would open part-way down its curve.
            var fadeOut = EditViewModel.fadeOutAnchoredAtStart(oldDuration: obj.duration,
                                                              oldFadeOut: obj.fadeOut,
                                                              newDuration: fitted.duration)
            var fadeIn = obj.fadeIn
            if fitted.duration < fadeIn { fadeIn = fitted.duration; fadeOut = 0 }
            else if fitted.duration < fadeIn + fadeOut { fadeOut = fitted.duration - fadeIn }
            obj.duration = fitted.duration
            obj.fadeIn   = fadeIn
            obj.fadeOut  = fadeOut
            // The loop range is left alone on purpose: it is held in WINDOW time and clamped
            // against the file on every push (@see clipLoopFileBounds), so a shorter file narrows
            // what is heard without the model losing what was asked for.
        }
        guard let after = find(id: id) else { return false }

        // From here on it is `applyDefinitionWave`'s sequence, word for word — the object is born,
        // then put back where it belongs, then given back everything the birth does not carry.
        engineAddClip(after, lane: carrierLane(for: id, fallback: after.lane))
        if let parent = parentGroup(for: id) {
            engine?.assignObject(id.uuidString, toGroupFolder: parent.id.uuidString)
        } else if let sid = after.stemID {
            engine?.assignObjects([id.uuidString], toStemID: sid.uuidString)
        }
        syncSends(after)
        engine?.updateFade(in: after.fadeIn, fadeOut: after.fadeOut, forID: id.uuidString)
        // The fade SHAPES travel beside the lengths and for the same reason the automation does:
        // they live in the ObjWindowFade plugin, which was reborn a few lines above knowing
        // nothing but two durations (@see pushFadeCurveTree).
        pushFadeCurveTree(after)
        pushAutomation(after)
        return true
    }

    // MARK: - The clamp

    /// A window (an offset into the file, a length on the timeline) fitted to a file of
    /// `fileLength` seconds.
    struct FittedWindow: Equatable {
        let sourceOffset: Double
        let duration: Double
    }

    /// The shortest length an object may be clamped to. The same floor every crop in the project
    /// stops at: an object of zero length is not an object, it is a hole nobody can grab again.
    static let relinkMinimumDuration: Double = 0.01

    /// **The clamp rule: a repaired object may come out SHORTER, never reading past the end of its
    /// file.** The new file can be shorter than the one that went (a bounce re-exported without
    /// its tail), and a window left hanging over the end reads silence and, worse, reads it
    /// without saying so.
    ///
    /// Two steps, in this order, because they answer two different questions:
    ///   1. the window SLIDES BACK as far as it must to fit — the length the user chose is worth
    ///      more than the exact place it was taken from, and a slid window is still the same sound;
    ///   2. only if the file is shorter than the window itself is the LENGTH cut, the window then
    ///      starting at the very beginning of the file.
    /// Shorter beats reading emptiness, and the whole gesture stays one ⌘Z away from what it was —
    /// which is what lets it be this decisive.
    ///
    /// **One arithmetic for both directions**: the file range a clip consumes is
    /// `[sourceOffset, sourceOffset + duration × speed]` whether it plays forwards or in reverse
    /// (@see windowHeadroom, which reads the same range and only swaps which timeline EDGE each
    /// end belongs to). Reversing decides where the material is heard from, not how much of it
    /// there is, so nothing here needs to know about it. The speed is the third term for the same
    /// reason: a half-speed clip eats half as much file per timeline second (@see
    /// EditViewModel+Crossfade, which converts the same way).
    ///
    /// `fileLength <= 0` — an unknown length says nothing, so nothing is clamped.
    static func fittedWindow(sourceOffset: Double, duration: Double,
                             speedRatio: Double, fileLength: Double) -> FittedWindow {
        guard fileLength > 0 else {
            return FittedWindow(sourceOffset: max(0, sourceOffset), duration: duration)
        }
        let speed = max(1e-6, speedRatio)
        let consumed = max(0, duration) * speed
        if consumed > fileLength {
            return FittedWindow(sourceOffset: 0,
                                duration: max(relinkMinimumDuration, fileLength / speed))
        }
        let offset = min(max(0, sourceOffset), fileLength - consumed)
        return FittedWindow(sourceOffset: offset, duration: duration)
    }
}
