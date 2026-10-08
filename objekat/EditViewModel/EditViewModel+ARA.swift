import Foundation
import AppKit

// ARA (Melodyne) on an audio object — the view-model's half. docs/ara_melodyne_plan.md, step 5.
//
// The MODEL carries `SoundObject.araSource` (plugin + opaque archive); the ENGINE carries the live
// plugin instance, the one that holds the user's notes and their corrections. Two truths, and the rule
// that ties them (decision Q1 of the user): OBJEKAT's undo NEVER touches a live Melodyne retouch —
// the archive in a snapshot only serves to RECREATE a source that no longer lives.
//
//   capture   `liveARAArchive` reads the engine when it says "stale" (a retouch or an end of analysis
//             since the last read) or when nothing was ever read; otherwise it answers from
//             `araArchiveCache`. `capturedPluginStates` calls it, so a save, an undo point, a clipboard
//             copy, a consolidation and a tab parking all freeze the LIVE archive.
//   model     the model's copy lags behind by at most a debounce (`scheduleARAModelRefresh`) and is
//             brought up to date at the head of every undo point (`pushUndo`) — the code that rebuilds
//             an engine clip from a model value (grouping, a paste, a split) reads it there.
//   copies    every site that clones an object for a NEW one asks `copiedARASource(of:)`: a fresh plugin
//             id (never share an instance), the archive read LIVE, never linked.

extension EditViewModel {

    // MARK: - Reading the model

    /// Every object carrying an ARA source, groups descended.
    func araObjects() -> [SoundObject] {
        var out: [SoundObject] = []
        func walk(_ arr: [SoundObject]) {
            for o in arr {
                if o.araSource != nil { out.append(o) }
                if case .group(let children, _) = o.kind { walk(children) }
            }
        }
        walk(items)
        return out
    }

    /// The groups above `id`, nearest first.
    func araAncestors(of id: UUID) -> [SoundObject] {
        var out: [SoundObject] = []
        var cursor = id
        while let parent = parentGroup(for: cursor) {
            out.append(parent)
            cursor = parent.id
        }
        return out
    }

    /// Why `id` may not receive an ARA source, nil if it may (the pure rules of `ARAEligibility`
    /// fed with what only the view-model knows: the ancestors and the state of the file on disk).
    func araEligibilityRefusal(for id: UUID) -> ARARefusal? {
        guard let obj = find(id: id) else { return .notAClip }
        return ARAEligibility.refusal(for: obj, ancestors: araAncestors(of: id), isFileMissing: isMissing(obj))
    }

    // MARK: - Adding / removing the source

    /// Puts `available` (a VST3 declared ARA) in front of the audio object `objectID`. nil = done;
    /// otherwise the reason it was refused, with the model and the undo stack exactly as they were.
    @discardableResult
    func setARASource(objectID: UUID, available: AvailablePlugin) -> ARARefusal? {
        guard engine != nil else { return .setupFailed }
        guard available.formatName == "VST3" else { return .pluginNotARA }   // Q2: no AU, ever
        if let refusal = araEligibilityRefusal(for: objectID) { return refusal }
        let plugin = ObjectPlugin(id: UUID(), name: available.name, manufacturer: available.manufacturer,
                                  identifier: available.identifier, formatName: available.formatName)
        pushUndo()
        let undoDepth = undoStack.count
        update(id: objectID) { $0.araSource = ARASource(plugin: plugin, archive: nil) }
        guard let updated = find(id: objectID) else { return .notAClip }
        syncARASource(updated)
        if let reason = araSyncFailures[objectID] {
            // The engine said no: the model goes back to what it was and the undo point is dropped.
            update(id: objectID) { $0.araSource = nil }
            araForget(objectID)
            if undoStack.count == undoDepth { undoStack.removeLast() }
            return ARARefusal(engineReason: reason)
        }
        isDirty = true
        return nil
    }

    /// Takes the source off. The undo point pushed first holds the CURRENT archive (stale or not:
    /// `currentSnapshot` reads it live), so undoing the removal gives the retouches back.
    func removeARASource(objectID: UUID) {
        guard find(id: objectID)?.araSource != nil else { return }
        pushUndo()
        closeARAEditor(objectID: objectID)
        update(id: objectID) { $0.araSource = nil }
        engine?.removeARASource(forObjectID: objectID.uuidString)
        araForget(objectID)
        isDirty = true
    }

    /// Pushes the model's source to the engine. Called when an engine clip is (re)created
    /// (`engineAddClip`, through `scheduleChainCompile(.ara)`), so every path that rebuilds a clip
    /// gets its source back. A source that cannot be set up (plugin not installed, file refused) leaves
    /// the object playing DRY: the model and its archive stay intact, a save writes them back as they were.
    func syncARASource(_ object: SoundObject) {
        guard let engine, let src = object.araSource else { return }
        let id = object.id
        araSynced.insert(id)
        let info: [String: Any] = ["identifier": src.plugin.identifier, "format": "VST3",
                                   "name": src.plugin.name, "manufacturer": src.plugin.manufacturer]
        var archive: [String: Any]? = nil
        if let a = src.archive {
            archive = ["data": a.data, "sourceID": a.sourceID, "modID": a.modificationID,
                       "docArchiveID": a.documentArchiveID]
        }
        let t0 = CFAbsoluteTimeGetCurrent()
        let reason = engine.setARASource(info, archive: archive, forObjectID: id.uuidString)
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        if let reason, reason != "already_ara" {
            araSyncFailures[id] = reason
            araArchiveCache[id] = nil
            NSLog("[ARA] source \"%@\" not set on %@: %@", src.plugin.name, id.uuidString, reason)
            if missingPluginCapture != nil,
               !availablePlugins.contains(where: { $0.identifier == src.plugin.identifier && $0.formatName == "VST3" }) {
                missingPluginCapture?.insert("\(src.plugin.name) [\(src.plugin.formatLabel)]")
            }
            return
        }
        araSyncFailures[id] = nil
        if reason == nil {
            araArchiveCache[id] = src.archive   // what the engine now holds (nil: fresh analysis)
            if ms >= 1 { NSLog("[PERF] ARA source \"%@\" set up in %.0f ms", src.plugin.name, ms) }
        }
    }

    // MARK: - The interface's door: the "+" of the audio object

    /// Whether Melodyne-like sources are offered for `objectID` in the picker, and why not: nil = the
    /// object may take one. `nil` host (a stem) or a non-audio object: the section is not shown at all.
    func araPickerRefusal(for objectID: UUID) -> ARARefusal? { araEligibilityRefusal(for: objectID) }

    /// True when the picker should show the ARA section for this host (an audio clip, whatever its state).
    func araPickerApplies(to objectID: UUID) -> Bool { find(id: objectID)?.isClip ?? false }

    /// The rows of the picker's ARA section for `objectID`, computed AT THE MOMENT the picker is drawn
    /// from the live catalogue (nothing is kept between two openings): the VST3 the pre-filter marks
    /// ARA, minus those a loaded module has PROVED not to be (`araDisprovedIdentifiers`: only ever fed by
    /// the engine's verdict, never by a failure to judge), one row per module, filtered by `search`.
    func araPickerCandidates(for objectID: UUID, search: String = "") -> [AvailablePlugin] {
        guard araPickerApplies(to: objectID) else { return [] }
        let base = availablePlugins.filter {
            $0.isARA && $0.formatName == "VST3" && !araDisprovedIdentifiers.contains($0.identifier)
        }
        // One row per module: the scan can list the same VST3 bundle twice (an older cache entry).
        var seen = Set<String>()
        let unique = base.filter { seen.insert($0.identifier).inserted }
        guard !search.isEmpty else { return unique }
        return unique.filter {
            $0.name.localizedCaseInsensitiveContains(search) ||
            $0.manufacturer.localizedCaseInsensitiveContains(search)
        }
    }

    /// The picker entry "ARA source": the ONE function that confirms a candidate. The candidate was
    /// marked from files alone (moduleinfo.json, or the factory's name in the binary); the real
    /// `hasARAExtension` is only known once the module is loaded, which `setARASource` does through
    /// `resolveARAPluginInfo` — in this process, exactly as an FX would be loaded by the "+". A false
    /// positive comes back as `.pluginNotARA` — only when the module was LOADED and declares no ARA
    /// (a module the engine could not read comes back as `.setupFailed`, and stays offered) — and is remembered. Presents the refusal itself.
    @discardableResult
    func addARASourceFromPicker(objectID: UUID, available: AvailablePlugin) -> ARARefusal? {
        if let refusal = setARASource(objectID: objectID, available: available) {
            if refusal == .pluginNotARA { araDisprovedIdentifiers.insert(available.identifier) }
            presentARARefusal(refusal, pluginName: available.name)
            return refusal
        }
        // Opened on the spot, as a plugin added by the "+" is (headless: nothing to open).
        if hasInterface { openARAEditor(objectID: objectID) }
        return nil
    }

    func presentARARefusal(_ refusal: ARARefusal, pluginName: String) {
        notify(L("ara.refusal.title", pluginName), refusal.localizedInfo)
    }

    /// Melodyne is still analysing the object's audio (the card shows a spinner).
    func araIsAnalysing(_ id: UUID) -> Bool {
        guard araSynced.contains(id), araSyncFailures[id] == nil, let engine else { return false }
        return (engine.araStatus(forObjectID: id.uuidString)["analysing"] as? NSNumber)?.boolValue ?? false
    }

    /// The engine forgot this object (removed, or its source taken off): so does the view-model.
    func araForget(_ id: UUID) {
        araArchiveCache[id] = nil
        araSynced.remove(id)
        araSyncFailures[id] = nil
    }

    /// `araForget` for a whole sub-tree, called as an object leaves the engine.
    func araForget(tree object: SoundObject) {
        if object.araSource != nil { araForget(object.id) }
        if case .group(let children, _) = object.kind { for c in children { araForget(tree: c) } }
    }

    // MARK: - Capturing the live archive

    /// The freshest archive of `id`: the engine's when it holds a retouch (or an analysis) the last
    /// read did not see, the cache's otherwise. `fallback` = what the model says, used when the
    /// engine has no source for this object (plugin missing, clipboard fragment whose original is
    /// gone): the archive is then returned untouched, never lost.
    func liveARAArchive(for id: UUID, fallback: ARAArchive?) -> ARAArchive? {
        guard let engine, araSynced.contains(id), araSyncFailures[id] == nil else { return fallback }
        let uuid = id.uuidString
        let stale = engine.isARAArchiveStale(forObjectID: uuid)
        if !stale {
            if let cached = araArchiveCache[id] { return cached }
            if let fallback { return fallback }   // loaded from it, nothing happened since
        }
        let t0 = CFAbsoluteTimeGetCurrent()
        guard let d = engine.captureARAArchive(forObjectID: uuid) as? [String: Any],
              let data = d["data"] as? String else { return araArchiveCache[id] ?? fallback }
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        let archive = ARAArchive(data: data,
                                 sourceID: d["sourceID"] as? String ?? "",
                                 modificationID: d["modID"] as? String ?? "",
                                 documentArchiveID: d["docArchiveID"] as? String ?? "",
                                 bytes: (d["bytes"] as? NSNumber)?.intValue ?? 0)
        araArchiveCache[id] = archive
        araCaptureStats.count += 1
        araCaptureStats.totalMs += ms
        araCaptureStats.lastMs = ms
        araCaptureStats.bytes = archive.bytes
        return archive
    }

    /// Reads the archive from the engine NOW, whether or not it says "stale", and brings the cache and
    /// the model up to date (one write, the project marked modified if the archive changed). For the
    /// API and the measurements; the normal paths go through `liveARAArchive`. nil if the object has
    /// no working source.
    func forceCaptureARAArchive(for id: UUID) -> (archive: ARAArchive, ms: Double)? {
        guard let engine, araSynced.contains(id), araSyncFailures[id] == nil else { return nil }
        let t0 = CFAbsoluteTimeGetCurrent()
        guard let d = engine.captureARAArchive(forObjectID: id.uuidString) as? [String: Any],
              let data = d["data"] as? String else { return nil }
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        let archive = ARAArchive(data: data,
                                 sourceID: d["sourceID"] as? String ?? "",
                                 modificationID: d["modID"] as? String ?? "",
                                 documentArchiveID: d["docArchiveID"] as? String ?? "",
                                 bytes: (d["bytes"] as? NSNumber)?.intValue ?? 0)
        araArchiveCache[id] = archive
        araCaptureStats.count += 1
        araCaptureStats.totalMs += ms
        araCaptureStats.lastMs = ms
        araCaptureStats.bytes = archive.bytes
        if find(id: id)?.araSource?.archive != archive {
            update(id: id) { $0.araSource?.archive = archive }
            isDirty = true
        }
        return (archive, ms)
    }

    /// `source` with its archive read live. The plugin entry is returned as it is.
    func capturingARA(_ id: UUID, _ source: ARASource) -> ARASource {
        var s = source
        s.archive = liveARAArchive(for: id, fallback: source.archive)
        return s
    }

    /// The source of `object` for a NEW object: a fresh plugin id, the archive read live. nil if the
    /// object has none. Called wherever `copiedPlugins(of:)` is — paste, duplicate, split, zone drag.
    func copiedARASource(of object: SoundObject) -> ARASource? {
        guard let source = object.araSource else { return nil }
        return capturingARA(object.id, source).copiedForNewObject()
    }

    // MARK: - Keeping the model up to date

    /// Brings the model's archives up to date with what the engine holds, in ONE write of `items`,
    /// and marks the project modified if one changed. A no-op (and cheap) when nothing is stale.
    func refreshARAModelArchives() {
        guard !araSynced.isEmpty, !isLoadingProject else { return }
        var changes: [UUID: ARAArchive] = [:]
        for o in araObjects() {
            guard let src = o.araSource, let fresh = liveARAArchive(for: o.id, fallback: src.archive),
                  fresh != src.archive else { continue }
            changes[o.id] = fresh
        }
        guard !changes.isEmpty else { return }
        updateMany(Set(changes.keys)) { $0.araSource?.archive = changes[$0.id] }
        isDirty = true
    }

    /// A retouch or the end of an analysis arrived: the model catches up once the burst is over.
    func araContentDidChange(objectID: String) {
        araRefreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.refreshARAModelArchives() }
        }
        araRefreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        // An object edited inside an open consolidated session: its other placements follow, like
        // they do for a plugin knob (@see armConsolidateEditParamWatch).
        if isEditingConsolidate { scheduleLiveMirror() }
    }

    /// Wires the engine's ARA callbacks to the view-model. Idempotent; called by the session.
    func installARAHooks() {
        engine?.onARAContentChanged = { [weak self] id in
            MainActor.assumeIsolated { self?.araContentDidChange(objectID: id) }
        }
    }

    // MARK: - Editor

    /// Opens Melodyne's editor on the object. False if the object has no (working) source.
    @discardableResult
    func openARAEditor(objectID: UUID) -> Bool {
        guard hasInterface, let engine, let src = find(id: objectID)?.araSource,
              araSynced.contains(objectID), araSyncFailures[objectID] == nil else { return false }
        engine.openARAEditor(forObjectID: objectID.uuidString, sourceKey: src.plugin.id.uuidString,
                             colorHex: ObjekatPalette.pluginHex(src.plugin.colorIndex))
        return true
    }

    func closeARAEditor(objectID: UUID) {
        engine?.closeARAEditor(forObjectID: objectID.uuidString)
    }

    /// The open editors follow the selection (the last ARA object of the selection wins).
    func notifyARASelectionIfNeeded() {
        guard let engine, !araSynced.isEmpty else { return }
        let ids = selectedIDs.filter { araSynced.contains($0) }.map(\.uuidString)
        if !ids.isEmpty { engine.notifyARASelection(ids) }
    }

    // MARK: - Undo (Q1): the live retouches survive

    /// @see `ARAUndoPolicy.adoptingLive`.
    static func adoptingLiveARA(_ snapshotItems: [SoundObject], live: [SoundObject]) -> [SoundObject] {
        ARAUndoPolicy.adoptingLive(snapshotItems, live: live)
    }

    // MARK: - Guards: what would break a source

    /// Why the speed of `id` may not change (an ARA source needs speed 1), nil if it may.
    func araRefusalForSpeedChange(id: UUID, to ratio: Double) -> ARARefusal? {
        guard find(id: id)?.araSource != nil else { return nil }
        return abs(ratio - 1.0) > ARAEligibility.speedTolerance ? .speedNotOne : nil
    }

    func araRefusalForReverse(id: UUID, reversed: Bool) -> ARARefusal? {
        guard reversed, find(id: id)?.araSource != nil else { return nil }
        return .reversed
    }

    /// Why the loop of `id` may not be turned on: it carries a source, or it is a group holding one.
    func araRefusalForLoop(id: UUID, enabled: Bool) -> ARARefusal? {
        guard enabled, let obj = find(id: id) else { return nil }
        return ARAEligibility.refusalOfLoop(on: obj)
    }
}


extension ARARefusal {
    /// The interface's sentence (the API keeps the English `reason`). One literal key per case, on
    /// purpose: `xcstrings.py orphans` reads the code for key-shaped strings.
    var localizedInfo: String {
        switch self {
        case .notAClip:             return L("ara.refusal.notAClip")
        case .consolidatedInstance: return L("ara.refusal.consolidatedInstance")
        case .alreadySource:        return L("ara.refusal.alreadySource")
        case .speedNotOne:          return L("ara.refusal.speedNotOne")
        case .reversed:             return L("ara.refusal.reversed")
        case .looped:               return L("ara.refusal.looped")
        case .ancestorLooped:       return L("ara.refusal.ancestorLooped")
        case .fileMissing:          return L("ara.refusal.fileMissing")
        case .pluginNotARA:         return L("ara.refusal.pluginNotARA")
        case .setupFailed:          return L("ara.refusal.setupFailed")
        }
    }
}
