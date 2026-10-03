import Foundation

// MARK: - What the inspector reads about a MULTIPLE selection
//
// The inspector's multiple-selection column used to recompute everything it shows at every
// SwiftUI pass (four at least per change of selection): the selected objects (a `find` and a sort
// each), the uniform values, the sends in scope (K senders × A auxes, each pair paying two
// `parentGroup` walks of the whole tree) and the tooltip of each of the K blocks. With a 178-object
// selection of a 4 000-object project that was 38 s of frozen main thread.
//
// It is ONE value now, computed once per (items, selectedIDs) and cached on the view-model:
// `items.didSet`, `selectedIDs.didSet` and `rebuildLaneEntries` drop it (the lane order of the
// sends comes from there). The body, `refreshMultiBaselines`, the signatures and the send helpers
// all read it, so a pass costs a dictionary lookup.
//
// The reading is `@ObservationIgnored` state behind a computed property that touches `items`,
// `selectedIDs` and `stems` itself (@see `find(id:)`): a view that reads the snapshot keeps
// depending on what the snapshot was made of, cache hit or not.

/// The multiple selection as the inspector reads it. A plain value: nothing in it refers back to
/// the view-model, so it can be compared, kept and tested alone.
struct MultiSelectionSnapshot {
    /// The main stem at the time it was built: `stemID == nil` means Main, and the scope of a top-level send
    /// depends on it, so a snapshot made under another Main is not this one.
    let mainID: UUID
    /// The selected objects, by start (ties: lane, then id — the order must not depend on how the
    /// `Set` happens to iterate, or the blocks would swap places from one pass to the next).
    let objects: [SoundObject]
    /// The audio clips among them — the only objects with a file to play faster, reverse or tempo.
    let sounds: [SoundObject]
    let mutedCount: Int

    // Shared values (uniform → absolute mode, otherwise → relative mode at 0).
    let uniformVolume: Float?
    let uniformPan: Float?
    /// `stemID == nil` is Main, normalised before comparing.
    let uniformStemID: UUID?
    let uniformSemis: Double?
    let uniformReversed: Bool?
    let uniformBaseBPM: Double?
    let uniformTargetBPM: Double?
    /// Some sound has a base BPM (the wav-BPM field shows '≠' rather than '—' when they differ).
    let anyBaseBPM: Bool
    /// Every sound has a positive base BPM: the target-BPM box exists only then.
    let everySoundHasBase: Bool
    /// What the target-BPM box starts from: the first sound's base × speed.
    let firstTargetBPM: Double?

    /// What the volume / pan boxes compare to tell their own echo from a change made elsewhere.
    let volumeSignature: [UUID: Float]
    let panSignature: [UUID: Float]

    // The sends. A send is offered towards an aux the sender can reach (@see `canRouteSend`).
    /// The auxes at least one selected non-aux object can reach, by display lane top → bottom.
    let sendAuxes: [SoundObject]
    /// Per aux, the selected objects that can reach it, in the selection's order.
    let sendersByAux: [UUID: [SoundObject]]
    /// Per selected sender, the auxes it can reach, by start (the tooltip's order).
    let auxesBySender: [UUID: [SoundObject]]

    /// The level of `sender`'s send towards `auxID` — -∞ when there is no entry.
    static func sendLevel(of sender: SoundObject, toAux auxID: UUID) -> Float {
        sender.sends.first { $0.auxID == auxID }?.levelDb ?? sendMinDb
    }

    /// The user's intention (the toggle) on `sender`'s send towards `auxID`.
    static func isSendEnabled(of sender: SoundObject, toAux auxID: UUID) -> Bool {
        sender.sends.first { $0.auxID == auxID }?.enabled ?? false
    }
}

extension EditViewModel {

    /// The selection, read once. Cached until `items`, `selectedIDs` or the lane entries change
    /// (@see `multiSelectionCache`).
    var multiSelectionSnapshot: MultiSelectionSnapshot {
        // Read through the observable properties, cache or not (@see find(id:)).
        _ = items
        _ = selectedIDs
        let mainID = mainStemID
        if let cached = multiSelectionCache, cached.mainID == mainID { return cached }
        let snapshot = makeMultiSelectionSnapshot(mainID: mainID)
        multiSelectionCache = snapshot
        return snapshot
    }

    private func makeMultiSelectionSnapshot(mainID: UUID) -> MultiSelectionSnapshot {
        let objects = selectedIDs.compactMap { find(id: $0) }.sorted { l, r in
            if l.startTime != r.startTime { return l.startTime < r.startTime }
            if l.lane != r.lane { return l.lane < r.lane }
            return l.id.uuidString < r.id.uuidString
        }
        let sounds = objects.filter(\.isClip)

        func uniform<T: Equatable>(_ values: [T]) -> T? {
            guard let f = values.first, values.allSatisfy({ $0 == f }) else { return nil }
            return f
        }

        // Speed: equal to within a millionth, the box shows semitones.
        let uniformSemis: Double? = {
            let vals = sounds.map(\.speedRatio)
            guard let f = vals.first, vals.allSatisfy({ abs($0 - f) < 1e-6 }) else { return nil }
            return 12 * log2(f)
        }()
        let bases = sounds.map(\.baseBPM)
        let targets = sounds.map { o in o.baseBPM.map { TempoText.rounded($0 * o.speedRatio) } }
        let uniformTarget: Double? = {
            guard let f = targets.first, let v = f, targets.allSatisfy({ $0 == f }) else { return nil }
            return v
        }()
        let uniformBase: Double? = {
            guard let f = bases.first, let v = f, bases.allSatisfy({ $0 == f }) else { return nil }
            return v
        }()
        let everyBase = !sounds.isEmpty
            && sounds.allSatisfy { $0.baseBPM.map { $0 > 0 } ?? false }

        // The sends — ONE batch for the whole selection.
        let scope = sendScope(forSenders: objects)
        var sendersByAux: [UUID: [SoundObject]] = [:]
        var auxByID: [UUID: SoundObject] = [:]
        for sender in objects {
            guard let auxes = scope[sender.id] else { continue }
            for aux in auxes {
                sendersByAux[aux.id, default: []].append(sender)
                auxByID[aux.id] = aux
            }
        }
        // By display lane, top → bottom (the model's own lane for an aux that is not on screen);
        // ties by start, then by position in the project's own list — the old order left a tie to
        // the iteration order of a `Set`.
        var laneOf: [UUID: Int] = [:]
        if !auxByID.isEmpty {
            for e in laneEntries where e.item.isAux && auxByID[e.item.id] != nil {
                laneOf[e.item.id] = e.displayLane
            }
        }
        var position: [UUID: Int] = [:]
        for (i, a) in allAuxes.enumerated() where auxByID[a.id] != nil { position[a.id] = i }
        let sendAuxes = auxByID.values.sorted { l, r in
            let ll = laneOf[l.id] ?? (find(id: l.id)?.lane ?? 0)
            let rl = laneOf[r.id] ?? (find(id: r.id)?.lane ?? 0)
            if ll != rl { return ll < rl }
            if l.startTime != r.startTime { return l.startTime < r.startTime }
            return (position[l.id] ?? 0) < (position[r.id] ?? 0)
        }

        return MultiSelectionSnapshot(
            mainID: mainID,
            objects: objects,
            sounds: sounds,
            mutedCount: objects.reduce(0) { $0 + ($1.isMuted ? 1 : 0) },
            uniformVolume: uniform(objects.map(\.volume)),
            uniformPan: uniform(objects.map(\.pan)),
            uniformStemID: uniform(objects.map { $0.stemID ?? mainID }),
            uniformSemis: uniformSemis,
            uniformReversed: uniform(sounds.map(\.isReversed)),
            uniformBaseBPM: uniformBase,
            uniformTargetBPM: uniformTarget,
            anyBaseBPM: sounds.contains { $0.baseBPM != nil },
            everySoundHasBase: everyBase,
            firstTargetBPM: sounds.first.flatMap { f in f.baseBPM.map { $0 * f.speedRatio } },
            volumeSignature: Dictionary(objects.map { ($0.id, $0.volume) }, uniquingKeysWith: { a, _ in a }),
            panSignature: Dictionary(objects.map { ($0.id, $0.pan) }, uniquingKeysWith: { a, _ in a }),
            sendAuxes: sendAuxes,
            sendersByAux: sendersByAux,
            auxesBySender: scope)
    }
}
