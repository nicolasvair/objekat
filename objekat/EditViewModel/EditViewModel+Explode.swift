import Foundation

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
    }

    struct ExplodeResult {
        let groupID: UUID
        let pieces: [ExplodePiece]
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
                 names: [String]? = nil, groupName: String? = nil) throws -> ExplodeResult {
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
            if let names, lanes[i] < names.count { c.label = names[lanes[i]] }
            children.append(c)
            reportPieces.append(ExplodePiece(id: obj.id, start: obj.startTime,
                                             duration: obj.duration, childLane: lanes[i]))
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
        return ExplodeResult(groupID: group.id, pieces: reportPieces)
    }
}
