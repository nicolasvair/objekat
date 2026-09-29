import Foundation
import AVFoundation

// MARK: - Exploding an object into sub-lanes

/// What a script asked `object.explode` to do: one object, cut at several instants, the pieces
/// distributed onto NAMED sub-lanes of a fresh group — one aller-retour, one undo. Written for
/// the "voice separator" script (@see tools/scripts/separateur-voix), but generic: any "explode
/// an object into sub-lanes" gesture can reuse it.
extension EditViewModel {

    enum ExplodeError: Error {
        case notFound, notAClip, missing, looping, badCuts, badLanes, pieceTooShort
    }

    struct ExplodePiece {
        let id: UUID
        let start: Double
        let duration: Double
        let childLane: Int
        /// The crossfade laid on the cut that OPENS this piece / that CLOSES it, in milliseconds
        /// (0 = a bare edge: the first piece's left edge, the last one's right edge, or `fadeMs`
        /// absent). `fade_applied_ms` in the API is the larger of the two.
        var fadeInMs: Double = 0
        var fadeOutMs: Double = 0
    }

    struct ExplodeResult {
        let groupID: UUID
        let pieces: [ExplodePiece]
        /// One id per sub-lane, in lane order, when `groupLanes` was asked; empty otherwise.
        let laneGroupIDs: [UUID]
    }

    /// The crossfade an internal cut may carry, in seconds: what was asked, capped at a third of
    /// the shorter of its two neighbours (so a fade-in and a fade-out never meet inside a piece).
    /// Pure, and shared by `explode` and its tests.
    static func explodeCrossfade(requested: Double, leftDuration: Double,
                                 rightDuration: Double) -> Double {
        guard requested > 0 else { return 0 }
        return max(0, min(requested, min(leftDuration, rightDuration) / 3))
    }

    /// The minimum a piece may last — below this a cut is not a cut, it is noise
    /// (@see plan_separateur_voix.md, D1).
    static let explodeMinPieceDuration = 0.005

    /// Cuts `id` at every instant of `cuts` (absolute timeline seconds, strictly increasing, each
    /// strictly inside the object) and gathers the `cuts.count + 1` pieces into a fresh group, one
    /// sub-lane per piece as `lanes` says (0-based, relative to the new group — several pieces may
    /// share a sub-lane, they simply follow one another on it since the cuts are ordered).
    /// `names`, when given, is read PER SUB-LANE (its size = the highest lane in `lanes` + 1): a
    /// piece takes the name of the sub-lane it lands on, which is what makes the group's own
    /// composed name ("Voix + Respirations + SS/CH") come out right for free. `groupName`, when
    /// given, is the group's own label; nil leaves it to the composed name.
    ///
    /// `groupLanes`: each sub-lane's pieces are gathered into a group of their own (named after
    /// the sub-lane), so the new group holds a handful of blocks instead of hundreds — what a long
    /// take needs to stay workable (the timeline draws and hit-tests every block of an open group).
    ///
    /// `fadeMs` (default 0 = every internal edge bare, as a cut leaves it): a CROSSFADE of that
    /// length on each internal cut, capped per cut (`explodeCrossfade`). The two neighbours overlap
    /// by `f` around the cut — the left piece grows by `f/2` to the right, the right piece by `f/2`
    /// to the left (source offset moved back to match) — and carry a linear fade-out / fade-in of
    /// `f`, so the sum is unity gain: the group renders the original sample for sample. The first
    /// piece keeps the original's fade-in, the last one its fade-out. A REVERSED clip gets none.
    ///
    /// ONE undo point for the whole thing (`pushUndo()` here, nothing upstream), because each cut
    /// manufactures the id the next one has to aim at — N separate `object.split_at` calls could
    /// not be chained into a single ⌘Z from a script.
    ///
    /// Refuses (the caller turns this into `bad_params` / `invalid_state`): `id` is not a plain
    /// audio clip (a group or a MIDI clip is refused outright — D1 leaves those out of v1), the
    /// file is missing, the object loops, `cuts` is not strictly increasing or has an instant
    /// outside the object, `lanes.count != cuts.count + 1`, or a resulting piece would be shorter
    /// than `explodeMinPieceDuration`.
    @discardableResult
    func explode(id: UUID, cuts: [Double], lanes: [Int],
                 names: [String]? = nil, groupName: String? = nil,
                 groupLanes: Bool = false, fadeMs: Double = 0) throws -> ExplodeResult {
        guard let original = find(id: id) else { throw ExplodeError.notFound }
        guard case .clip = original.kind else { throw ExplodeError.notAClip }
        guard !isMissing(original) else { throw ExplodeError.missing }
        guard !original.loopEnabled else { throw ExplodeError.looping }

        let objStart = original.startTime, objEnd = original.startTime + original.duration
        guard lanes.count == cuts.count + 1 else { throw ExplodeError.badLanes }
        guard !cuts.isEmpty else { throw ExplodeError.badCuts }
        var previous = objStart
        for c in cuts {
            guard c > previous + Self.explodeMinPieceDuration,
                  c < objEnd - 1e-9 else { throw ExplodeError.badCuts }
            previous = c
        }
        guard objEnd - previous >= Self.explodeMinPieceDuration else { throw ExplodeError.pieceTooShort }
        if let names {
            let laneCount = (lanes.max() ?? -1) + 1
            guard names.count == laneCount else { throw ExplodeError.badLanes }
        }

        // A cut lands ON a sample of the source file. At exactly half a sample the clip's rounding
        // and the next object's window can disagree by one ulp and leave a sample at zero (measured
        // 3 cuts out of 5 at 48 kHz); on the grid both read the same integer, whatever the ulp.
        var cuts = cuts
        if case .clip(let path, _, _, _, _) = original.kind,
           let f = try? AVAudioFile(forReading: URL(fileURLWithPath: path)),
           f.fileFormat.sampleRate > 0 {
            let sr = f.fileFormat.sampleRate
            var prev = objStart
            cuts = cuts.map { c in
                let g = (c * sr).rounded() / sr
                let ok = g > prev + Self.explodeMinPieceDuration && g < objEnd - 1e-9
                prev = ok ? g : c
                return ok ? g : c
            }
        }

        let parent = parentGroup(for: id)
        pushUndo()
        engine?.beginPlaybackEdit()
        defer { engine?.endPlaybackEdit() }

        // The chain of splits: each cut targets the RIGHT half the previous one just produced,
        // in increasing order, so that ids stay resolvable (@see EditViewModel+Cut, `cut`).
        var pieceIDs: [UUID] = []
        var currentID = id
        for c in cuts {
            guard let newID = _splitInternal(id: currentID, atTime: c) else {
                _ = undoStack.popLast()
                throw ExplodeError.badCuts
            }
            pieceIDs.append(currentID)
            currentID = newID
        }
        pieceIDs.append(currentID)
        guard pieceIDs.count == lanes.count else {
            _ = undoStack.popLast()
            throw ExplodeError.badLanes
        }

        // Captures each piece BEFORE it is torn out of the engine (withCapturedPluginStates,
        // as createGroup/createGroupFromTimeSelection already do) — the sub-lane and the optional
        // label are the only things this function changes on top of what the split left behind:
        // the fades, the fresh cut curves, the source offsets are already right.
        var children: [SoundObject] = []
        var reportPieces: [ExplodePiece] = []
        for (i, pid) in pieceIDs.enumerated() {
            guard let obj = find(id: pid) else {
                _ = undoStack.popLast()
                throw ExplodeError.badCuts
            }
            var c = withCapturedPluginStates(obj)
            c.lane = lanes[i]
            if !groupLanes, let names, lanes[i] < names.count { c.label = names[lanes[i]] }
            children.append(c)
            reportPieces.append(ExplodePiece(id: obj.id, start: obj.startTime,
                                             duration: obj.duration, childLane: lanes[i]))
        }

        // The crossfades, on the COPIES and before the group reaches the engine: every fade lives
        // in the object's window plugin, which the group's creation lays down from the model.
        // Cap and overlap read the piece durations the splits left, BEFORE any extension.
        if fadeMs > 0, !original.isReversed, children.count > 1 {
            let baseDur = children.map(\.duration)
            let ratio = max(original.speedRatio, 0.0001)
            for k in 0..<(children.count - 1) {
                let f = Self.explodeCrossfade(requested: fadeMs / 1000,
                                              leftDuration: baseDur[k], rightDuration: baseDur[k + 1])
                let h = f / 2
                // No negative source offset: an offset that could not go back by `h` shrinks it.
                let hR = min(h, children[k + 1].sourceOffset / ratio)
                let fk = min(f, hR * 2)
                guard fk > 0 else { continue }
                let hk = fk / 2
                // Left piece: grows to the right, fades out.
                children[k].duration += hk
                children[k].fadeOut = fk
                children[k].fadeOutCurve = Self.freshCutCurve
                // Right piece: grows to the left, fades in; its frame of reference moves with it.
                children[k + 1].startTime -= hk
                children[k + 1].duration += hk
                children[k + 1].sourceOffset -= hk * ratio
                children[k + 1].automation = children[k + 1].automation.shiftedInTime(by: hk)
                children[k + 1].markers = children[k + 1].markers.shiftedInTime(by: hk)
                children[k + 1].fadeIn = fk
                children[k + 1].fadeInCurve = Self.freshCutCurve
                reportPieces[k].fadeOutMs = fk * 1000
                reportPieces[k + 1].fadeInMs = fk * 1000
            }
            for k in children.indices {
                let old = reportPieces[k]
                reportPieces[k] = ExplodePiece(id: old.id, start: children[k].startTime,
                                               duration: children[k].duration, childLane: old.childLane,
                                               fadeInMs: old.fadeInMs, fadeOutMs: old.fadeOutMs)
            }
        }

        for pid in pieceIDs { if let obj = find(id: pid) { removeFromEngine(obj) } }
        if let parent {
            _ = update(id: parent.id) { obj in
                guard case .group(let ch, let e) = obj.kind else { return }
                obj.kind = .group(children: ch.filter { !pieceIDs.contains($0.id) }, isExpanded: e)
            }
        } else {
            items.removeAll { pieceIDs.contains($0.id) }
        }
        selectedIDs.subtract(pieceIDs)
        pruneScriptOverlays()

        var laneGroupIDs: [UUID] = []
        if groupLanes {
            // One collapsed group per sub-lane, on that sub-lane, holding its pieces on row 0.
            // Children keep their absolute times, as in the single-group case.
            var byLane: [Int: [SoundObject]] = [:]
            for var c in children {
                let lane = c.lane
                c.lane = 0
                byLane[lane, default: []].append(c)
            }
            children = byLane.keys.sorted().map { lane in
                let members = byLane[lane] ?? []
                let lo = members.map(\.startTime).min() ?? objStart
                let hi = members.map { $0.startTime + $0.duration }.max() ?? objEnd
                var label: String? = nil
                if let names, lane < names.count { label = names[lane] }
                let g = SoundObject(startTime: lo, duration: hi - lo, lane: lane,
                                    stemID: original.stemID, label: label,
                                    kind: .group(children: members, isExpanded: false))
                laneGroupIDs.append(g.id)
                return g
            }
        }

        var group = SoundObject(
            startTime: objStart, duration: objEnd - objStart,
            lane: original.lane,
            stemID: original.stemID,
            label: groupName,
            kind: .group(children: children, isExpanded: false)
        )

        if let parent {
            addChild(group, toGroupID: parent.id)
            group = find(id: group.id) ?? group
        } else {
            items.append(group)
            syncAdd(group)
        }
        resyncAllSends()
        selectedIDs = [group.id]
        isDirty = true
        return ExplodeResult(groupID: group.id, pieces: reportPieces, laneGroupIDs: laneGroupIDs)
    }
}
