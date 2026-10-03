import Foundation

#if DEBUG

// MARK: - The ORACLE of the multiple selection's caches (DEBUG only)
//
// `parentIDMap()`, `allAuxes`, `sendScope(forSenders:)` and `multiSelectionSnapshot` replaced
// per-call walks of the whole tree. What they replaced is kept HERE, word for word, as the
// reference they must agree with: no cache, no index, no map — a plain recursive walk of `items`
// for everything. `debug.selection_send_scope` (and `tools/scenario_selection_send_scope.py`) puts
// the two side by side after every kind of mutation that has to invalidate a cache.
// Not present in Release builds.

extension EditViewModel {

    /// A walk of the tree, no index (the reference for `find(id:)`'s cache).
    func _referenceFind(id: UUID) -> SoundObject? {
        func search(in arr: [SoundObject]) -> SoundObject? {
            for item in arr {
                if item.id == id { return item }
                if case .group(let children, _) = item.kind, let found = search(in: children) { return found }
            }
            return nil
        }
        return search(in: items)
    }

    func _referenceAllAuxes() -> [SoundObject] { allClips.filter(\.isAux) }

    /// `canRouteSend` as it was before the parent map: two `parentGroup` walks.
    func _referenceCanRouteSend(from objectID: UUID, to auxID: UUID) -> Bool {
        guard objectID != auxID,
              let sender = _referenceFind(id: objectID), !sender.isAux,
              let aux = _referenceFind(id: auxID), aux.isAux
        else { return false }
        let senderGroup = referenceParentGroup(for: objectID)
        guard senderGroup?.id == referenceParentGroup(for: auxID)?.id else { return false }
        guard senderGroup == nil else { return true }
        let auxStem = aux.stemID ?? mainStemID
        return auxStem == mainStemID || auxStem == (sender.stemID ?? mainStemID)
    }

    /// `overlappingAuxes(for:)` as it was: a filter over every aux, one `canRouteSend` each.
    func _referenceOverlappingAuxes(for objectID: UUID) -> [SoundObject] {
        guard let obj = _referenceFind(id: objectID) else { return [] }
        let oStart = obj.startTime
        let oEnd   = obj.startTime + obj.duration
        return _referenceAllAuxes()
            .filter { aux in
                guard _referenceCanRouteSend(from: objectID, to: aux.id) else { return false }
                if aux.isInfiniteBus { return true }
                return aux.startTime < oEnd && (aux.startTime + aux.duration) > oStart
            }
            .sorted { $0.startTime < $1.startTime }
    }

    /// `selectionSendAuxes()` as it was (sorted by display lane alone — a tie there was left to the
    /// iteration order of a `Set`, so a comparison reads the LANES, not the order inside a lane).
    func _referenceSelectionSendAuxes() -> [SoundObject] {
        let senders = selectedIDs.compactMap { _referenceFind(id: $0) }.filter { !$0.isAux }
        var seen = Set<UUID>()
        var result: [SoundObject] = []
        for s in senders {
            for aux in _referenceOverlappingAuxes(for: s.id) where seen.insert(aux.id).inserted {
                result.append(aux)
            }
        }
        func laneOf(_ id: UUID) -> Int {
            laneEntries.first { $0.item.id == id }?.displayLane ?? (_referenceFind(id: id)?.lane ?? 0)
        }
        return result.sorted { laneOf($0.id) < laneOf($1.id) }
    }

    /// `selectedSenders(toAux:)` as it was.
    func _referenceSelectedSenders(toAux auxID: UUID) -> [UUID] {
        selectedIDs.compactMap { _referenceFind(id: $0) }
            .filter { !$0.isAux && _referenceOverlappingAuxes(for: $0.id).contains { $0.id == auxID } }
            .map(\.id)
    }

    /// The whole comparison, for the live selection: every line of the answer is one thing the
    /// cached path said that the reference did not (an empty `mismatches` is agreement).
    /// - `parentSample`: how many objects have their `parentGroup(for:)` compared with the walk
    ///   (every one when the project is small; a spread sample plus every selected object otherwise).
    func _selectionSendScopeAudit(parentSample: Int) -> (mismatches: [String], info: [String: Int], newMs: Double, referenceMs: Double) {
        var bad: [String] = []
        var info: [String: Int] = [:]

        // --- the cached path ---------------------------------------------------------------
        let t0 = CFAbsoluteTimeGetCurrent()
        let snap = multiSelectionSnapshot
        let newAuxes = selectionSendAuxes()
        var newSenders: [UUID: Set<UUID>] = [:]
        for a in newAuxes { newSenders[a.id] = Set(selectedSenders(toAux: a.id)) }
        var newOverlap: [UUID: [UUID]] = [:]
        for o in snap.objects { newOverlap[o.id] = overlappingAuxes(for: o.id).map(\.id) }
        let newMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000

        // --- the reference ------------------------------------------------------------------
        let t1 = CFAbsoluteTimeGetCurrent()
        let refAuxes = _referenceSelectionSendAuxes()
        var refSenders: [UUID: Set<UUID>] = [:]
        for a in refAuxes { refSenders[a.id] = Set(_referenceSelectedSenders(toAux: a.id)) }
        var refOverlap: [UUID: [UUID]] = [:]
        for id in selectedIDs { refOverlap[id] = _referenceOverlappingAuxes(for: id).map(\.id) }
        let refMs = (CFAbsoluteTimeGetCurrent() - t1) * 1000

        // The selection itself.
        let refObjects = selectedIDs.compactMap { _referenceFind(id: $0) }
        if Set(snap.objects.map(\.id)) != Set(refObjects.map(\.id)) { bad.append("snapshot objects differ from the selection") }
        for (a, b) in zip(snap.objects, snap.objects.dropFirst()) where a.startTime > b.startTime {
            bad.append("snapshot objects not sorted by start"); break
        }

        // The auxes and who reaches them.
        if Set(newAuxes.map(\.id)) != Set(refAuxes.map(\.id)) { bad.append("selectionSendAuxes: different set of auxes") }
        let newLanes = newAuxes.map { a in laneEntries.first { $0.item.id == a.id }?.displayLane ?? (find(id: a.id)?.lane ?? 0) }
        let refLanes = refAuxes.map { a in laneEntries.first { $0.item.id == a.id }?.displayLane ?? (_referenceFind(id: a.id)?.lane ?? 0) }
        if newLanes != refLanes { bad.append("selectionSendAuxes: lane order \(newLanes) vs \(refLanes)") }
        if newSenders != refSenders { bad.append("selectedSenders(toAux:) differ") }
        for id in selectedIDs where newOverlap[id] ?? [] != refOverlap[id] ?? [] {
            bad.append("overlappingAuxes(for: \(id.uuidString)) \(newOverlap[id] ?? []) vs \(refOverlap[id] ?? [])")
        }
        if Set(refOverlap.compactMap { $0.value.isEmpty ? nil : $0.key })
            != Set(snap.auxesBySender.keys) { bad.append("snapshot auxesBySender keys differ") }

        // The cached flat list of auxes.
        if allAuxes.map(\.id) != _referenceAllAuxes().map(\.id) { bad.append("allAuxes cache is stale") }

        // The uniform values, as the view used to compute them from `selectedObjects`.
        func uniform<T: Equatable>(_ v: [T]) -> T? {
            guard let f = v.first, v.allSatisfy({ $0 == f }) else { return nil }
            return f
        }
        let sounds = refObjects.filter(\.isClip)
        if uniform(refObjects.map(\.volume)) != snap.uniformVolume { bad.append("uniformVolume") }
        if uniform(refObjects.map(\.pan)) != snap.uniformPan { bad.append("uniformPan") }
        if uniform(refObjects.map { $0.stemID ?? mainStemID }) != snap.uniformStemID { bad.append("uniformStemID") }
        if uniform(sounds.map(\.isReversed)) != snap.uniformReversed { bad.append("uniformReversed") }
        let refSemis: Double? = {
            let vals = sounds.map(\.speedRatio)
            guard let f = vals.first, vals.allSatisfy({ abs($0 - f) < 1e-6 }) else { return nil }
            return 12 * log2(f)
        }()
        if refSemis != snap.uniformSemis { bad.append("uniformSemis") }
        if snap.mutedCount != refObjects.filter(\.isMuted).count { bad.append("mutedCount") }
        if snap.volumeSignature != Dictionary(refObjects.map { ($0.id, $0.volume) }, uniquingKeysWith: { a, _ in a }) {
            bad.append("volumeSignature")
        }
        if snap.panSignature != Dictionary(refObjects.map { ($0.id, $0.pan) }, uniquingKeysWith: { a, _ in a }) {
            bad.append("panSignature")
        }

        // The parent map against the walk.
        var all: [UUID] = []
        func collect(_ arr: [SoundObject]) {
            for o in arr {
                all.append(o.id)
                if case .group(let children, _) = o.kind { collect(children) }
            }
        }
        collect(items)
        var sample = Set(selectedIDs)
        let step = max(1, all.count / max(1, parentSample))
        for i in stride(from: 0, to: all.count, by: step) { sample.insert(all[i]) }
        var parentChecked = 0
        for id in sample {
            parentChecked += 1
            if parentGroup(for: id)?.id != referenceParentGroup(for: id)?.id {
                bad.append("parentGroup(for: \(id.uuidString)) differs from the walk")
            }
            if parentIDMap()[id] != referenceParentGroup(for: id)?.id {
                bad.append("parentIDMap()[\(id.uuidString)] differs from the walk")
            }
        }
        // The map must hold NOTHING for an id that is gone, nor miss one that is there.
        let map = parentIDMap()
        let expectedParents = all.count - items.count   // everything but the top level has a parent
        if map.count != expectedParents { bad.append("parentIDMap has \(map.count) entries, the tree has \(expectedParents) children") }

        info = ["selected": selectedIDs.count, "auxes_in_scope": newAuxes.count,
                "aux_total": allAuxes.count, "objects_total": all.count,
                "parents_checked": parentChecked]
        return (bad, info, newMs, refMs)
    }
}

#endif
