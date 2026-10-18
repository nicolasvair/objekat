import Foundation

// MARK: - Réunir (heal) — the pieces of a cut group become ONE group again
//
// The counterpart of the Cut tool on a group. The Cut tool now cuts a group's WINDOW only (its
// children stay whole in both halves, the right half carrying independent copies); a deep cut
// (zone deletion, isolation, the API's default) distributes the children instead. Either way,
// "group / edit / separate, then repair" needs a way back: that is this file.
//
// THE RULES
//
//   • Input: ≥ 2 groups, same parent, same lane, JOINTIVE (the end of one is the start of the next,
//     to 10 µs). Chains of more than two pieces are healed in one go. A looping group, an infinite
//     bus, a consolidated instance, the stage of an open consolidated object or a group being
//     baked refuses the whole heal (the entry is greyed, with the reason as its tooltip).
//   • Result: ONE group. Its window is the union; it keeps the id, the name, the settings, the
//     plugins and the sends of the LEFT piece; the fade-in is the left's, the fade-out the
//     right-most one's, none at the junctions. The group's own curves are joined (a curve only the
//     right piece carried is dropped: the left one rules).
//   • The CHILDREN of both pieces are first CROPPED to their own piece at the junction (and only
//     there — the outer edges keep whatever overflow they had): a child that a window-only cut
//     duplicated therefore reappears as its two halves, and a child that is wholly outside its
//     piece's window (inaudible there) is dropped. That is what keeps the heal SOUND-PRESERVING
//     even for a child edited after the cut. Then what is jointive is joined:
//       - sub-groups (same lane, same settings, same label): healed recursively;
//       - audio clips: glued into ONE clip if same file, edges touching, source offset continuous
//         (the source offset is in SOURCE seconds — speed is taken into account, and the reverse
//         case has its own relation), same speed and direction, same gain/pan/mute/stem, equivalent
//         plugins and sends, compatible curves; the junction fades go;
//       - MIDI clips: notes concatenated if same instrument and equivalent settings;
//       - auxes: glued under the same conditions as a clip (the senders that aimed at the right
//         one are re-aimed at the left, project-wide);
//       - anything else stays side by side, which is exactly what it sounded like before.
//   • After a window-only cut, healing gives back exactly the original: the same children (the
//     originals' ids), nothing left to glue.
//   • ONE undo point.
//
// The pure parts (cropping, gluing, equivalence, curve and marker joins) work on VALUES; the model
// and the engine are only touched by `performGroupHeal`, which does what case 3 of `_splitInternal`
// does (capture the plugin states, remove the pieces from the engine, put the merged group back).

/// Why a heal is refused.
enum GroupHealRefusal: Error, Equatable {
    /// Fewer than two groups concerned.
    case needTwo
    /// The groups do not share a parent.
    case differentParents
    /// A gap, an overlap, another lane, or a group left alone.
    case notJointive
    /// A looping group, an infinite bus, a consolidated instance, an open session's stage, a bake.
    case special

    /// The sentence the command API answers with (machine contract, English).
    var message: String {
        switch self {
        case .needTwo:          return "at least two groups are needed to join"
        case .differentParents: return "the groups do not share the same parent"
        case .notJointive:      return "the groups are not jointive (same lane, end of one = start of the next)"
        case .special:          return "a looping group, an infinite bus, a consolidated object, an open session or a render under way prevents the join"
        }
    }

    /// The tooltip of the greyed menu entry.
    var tooltipKey: String {
        switch self {
        case .needTwo, .notJointive: return "menu.context.healGroups.refused.notJointive"
        case .differentParents:      return "menu.context.healGroups.refused.parents"
        case .special:               return "menu.context.healGroups.refused.special"
        }
    }
}

/// What a heal will do: the chains of pieces to merge, each ordered by start (≥ 2 ids).
struct GroupHealPlan: Equatable {
    var chains: [[UUID]]
}

/// What a heal did.
struct GroupHealReport: Equatable {
    /// The merged groups (the left piece's id of each chain).
    var mergedIDs: [UUID]
    /// Pieces absorbed (ids that no longer exist).
    var absorbedPieceIDs: [UUID]
    /// Objects that vanished inside the groups (glued into a neighbour, or dropped as wholly
    /// outside their piece's window).
    var goneChildIDs: [UUID]
    /// How many pairs of children were glued / healed into one.
    var gluedCount: Int
}

/// What the recursion accumulates.
struct GroupHealContext {
    /// Object of the right-hand side → the left-hand object it became part of.
    var idMap: [UUID: UUID] = [:]
    /// Every object that vanished (glued, or dropped because wholly outside its piece).
    var gone: [UUID] = []
    var glued = 0
}

extension EditViewModel {

    /// Two edges closer than this (seconds) touch. Below one sample at any rate in use.
    static let healEps: Double = 1e-5
    /// Two source offsets closer than this (source seconds) are continuous.
    static let healSourceEps: Double = 1e-6

    // MARK: - Planning (what the menu asks)

    /// Can these objects be healed, and into which chains? `ids` may hold anything — only the
    /// groups count. `zone`: the time selection's range; a junction counts only if the range
    /// COVERS it (and a group of the range that has no partner is simply not concerned); without
    /// one (a selection of objects) every group selected must belong to a chain.
    ///
    /// Pure read of the model — nothing is touched.
    func planGroupHeal(ids: [UUID], zone: ClosedRange<Double>? = nil) -> Result<GroupHealPlan, GroupHealRefusal> {
        var seen = Set<UUID>()
        var groups: [SoundObject] = []
        for id in ids {
            guard seen.insert(id).inserted, let o = find(id: id), o.isGroup else { continue }
            groups.append(o)
        }
        guard groups.count >= 2 else { return .failure(.needTwo) }
        for g in groups {
            if g.isInfiniteBus || g.consolidateID != nil || isLoopedGroupPorthole(g)
                || isSessionScaffold(g.id) || isBaking(g.id) {
                return .failure(.special)
            }
        }
        let parents = Set(groups.map { parentGroup(for: $0.id)?.id })
        guard parents.count == 1 else { return .failure(.differentParents) }

        let eps = Self.healEps
        var chains: [[SoundObject]] = []
        var strays = 0
        for (_, members) in Dictionary(grouping: groups, by: \.lane) {
            let sorted = members.sorted { $0.startTime < $1.startTime }
            var run: [SoundObject] = [sorted[0]]
            for g in sorted.dropFirst() {
                let prev = run[run.count - 1]
                let junction = prev.startTime + prev.duration
                let touching = abs(junction - g.startTime) <= eps
                let covered = zone.map { $0.lowerBound < junction && junction < $0.upperBound } ?? true
                if touching && covered {
                    run.append(g)
                } else {
                    if run.count >= 2 { chains.append(run) } else { strays += 1 }
                    run = [g]
                }
            }
            if run.count >= 2 { chains.append(run) } else { strays += 1 }
        }
        guard !chains.isEmpty else { return .failure(.notJointive) }
        if zone == nil && strays > 0 { return .failure(.notJointive) }

        // A looping or consolidated group straddling a junction cannot be cropped: refuse now,
        // rather than half way through.
        for chain in chains {
            for k in 0..<(chain.count - 1) {
                let junction = chain[k + 1].startTime
                for piece in [chain[k], chain[k + 1]] {
                    if Self.healChildren(of: piece).contains(where: { healStraddlerBlocks($0, at: junction) }) {
                        return .failure(.special)
                    }
                }
            }
        }
        chains.sort { ($0[0].lane, $0[0].startTime) < ($1[0].lane, $1[0].startTime) }
        return .success(GroupHealPlan(chains: chains.map { $0.map(\.id) }))
    }

    /// True if `obj` straddles `junction` and could not be cropped there (a looping or consolidated
    /// group, a looping or ARA clip), looking inside the groups that will be healed in turn.
    private func healStraddlerBlocks(_ obj: SoundObject, at junction: Double) -> Bool {
        let eps = Self.healEps
        guard !obj.isInfiniteBus else { return false }
        let start = obj.startTime, end = obj.startTime + obj.duration
        guard start < junction - eps, end > junction + eps else { return false }
        switch obj.kind {
        case .clip, .midiClip:
            return obj.loopEnabled || obj.araSource != nil
        case .aux:
            return false
        case .group(let children, _):
            if isLoopedGroupPorthole(obj) || obj.consolidateID != nil { return true }
            return children.contains { healStraddlerBlocks($0, at: junction) }
        }
    }

    static func healChildren(of obj: SoundObject) -> [SoundObject] {
        if case .group(let children, _) = obj.kind { return children }
        return []
    }

    // MARK: - Doors

    /// Heals the groups among the selection (the menu's `.objects` scope, `group.heal`).
    @discardableResult
    func healGroups(ids: [UUID]) -> Result<GroupHealReport, GroupHealRefusal> {
        switch planGroupHeal(ids: ids) {
        case .failure(let why): return .failure(why)
        case .success(let plan): return performGroupHeal(plan)
        }
    }

    /// Heals the groups the time selection crosses whose junction it covers (the menu's `.zone`
    /// scope, `timesel.heal`).
    @discardableResult
    func healGroups(inZone sel: TimeSelection) -> Result<GroupHealReport, GroupHealRefusal> {
        let ids = timeSelectionTargets(sel).map(\.item.id)
        switch planGroupHeal(ids: ids, zone: sel.timeRange) {
        case .failure(let why): return .failure(why)
        case .success(let plan): return performGroupHeal(plan)
        }
    }

    /// The object menu's entry, or nil when the scope holds fewer than two groups (nothing to
    /// join, nothing to say). Greyed, with the reason as its tooltip, when they cannot be joined.
    func healMenuEntry(scope: ObjectActionScope, targetIDs: [UUID]) -> ObjectMenuEntry? {
        var groups = 0
        var seen = Set<UUID>()
        for id in targetIDs where seen.insert(id).inserted {
            if find(id: id)?.isGroup == true { groups += 1 }
        }
        guard groups >= 2 else { return nil }
        let zone: ClosedRange<Double>?
        if case .zone(let sel) = scope { zone = sel.timeRange } else { zone = nil }
        switch planGroupHeal(ids: targetIDs, zone: zone) {
        case .success:
            return ObjectMenuEntry(action: .healGroups, title: L("menu.context.healGroups"),
                                   toolTip: L("menu.context.healGroups.help"))
        case .failure(let why):
            return ObjectMenuEntry(action: .healGroups, title: L("menu.context.healGroups"),
                                   isEnabled: false, toolTip: L(why.tooltipKey))
        }
    }

    // MARK: - Execution (model + engine)

    /// Merges every chain of the plan. ONE undo point, popped if nothing could be done. A chain
    /// that fails half way (it cannot, the plan has checked, but a value-level refusal is
    /// possible) leaves its pieces untouched and the others go on.
    func performGroupHeal(_ plan: GroupHealPlan) -> Result<GroupHealReport, GroupHealRefusal> {
        engine?.beginPlaybackEdit()           // @see cut(ids:atTime:keeping:)
        defer { engine?.endPlaybackEdit() }
        pushUndo()

        var report = GroupHealReport(mergedIDs: [], absorbedPieceIDs: [], goneChildIDs: [], gluedCount: 0)
        var projectMap: [UUID: UUID] = [:]
        var soloPairs: [(from: UUID, to: UUID)] = []
        var refusal: GroupHealRefusal? = nil

        for chain in plan.chains {
            let live = chain.compactMap { find(id: $0) }
            guard live.count == chain.count, live.count >= 2 else { continue }
            let parent = parentGroup(for: live[0].id)
            // The plugin states, frozen BEFORE the engine instances are destroyed: the children
            // keep their ids and their `stateXML`, so the re-sync restores their settings.
            let pieces = live.map { withCapturedPluginStates($0) }

            var ctx = GroupHealContext()
            var merged = pieces[0]
            do {
                for k in 1..<pieces.count {
                    merged = try healPairValues(merged, pieces[k], ctx: &ctx)
                }
            } catch {
                refusal = (error as? GroupHealRefusal) ?? .special
                continue
            }
            merged = Self.remappingSends(merged, using: ctx.idMap)

            // The pieces leave the engine, then the model; the merged group takes their place.
            for p in live { removeFromEngine(p) }
            let gone = Set(chain)
            if let parent {
                update(id: parent.id) { obj in
                    guard case .group(let pChildren, let pExpanded) = obj.kind else { return }
                    obj.kind = .group(children: pChildren.filter { !gone.contains($0.id) },
                                      isExpanded: pExpanded)
                }
                addChild(merged, toGroupID: parent.id)
            } else {
                items.removeAll { gone.contains($0.id) }
                items.append(merged)
                syncAdd(merged)
            }

            report.mergedIDs.append(merged.id)
            report.absorbedPieceIDs.append(contentsOf: chain.dropFirst())
            report.goneChildIDs.append(contentsOf: ctx.gone)
            report.gluedCount += ctx.glued
            for (from, to) in ctx.idMap { projectMap[from] = to }
            for piece in chain.dropFirst() { soloPairs.append((piece, chain[0])) }
            for (from, to) in ctx.idMap { soloPairs.append((from, to)) }
        }

        guard !report.mergedIDs.isEmpty else {
            _ = undoStack.popLast()
            return .failure(refusal ?? .notJointive)
        }

        // What outside the groups aimed at an object that was glued into a neighbour (a send to an
        // aux, a sidechain key, a curve on a send) now aims at the survivor.
        if !projectMap.isEmpty {
            items = items.map { Self.remappingSends($0, using: projectMap) }
        }
        resyncAllSends()
        inheritSolo(soloPairs)
        forgetSolo(report.absorbedPieceIDs + report.goneChildIDs)
        selectedIDs = Set(report.mergedIDs)
        let vanished = Set(report.absorbedPieceIDs + report.goneChildIDs)
        if let xf = selectedCrossfade, vanished.contains(xf.left) || vanished.contains(xf.right) {
            selectedCrossfade = nil
        }
        pruneAnnotationSelection()
        isDirty = true
        return .success(report)
    }

    // MARK: - Healing two groups (values)

    /// ONE group out of `l` and `r`, consecutive pieces of the same lane (`r` starts where `l`
    /// ends). Neither is modified; nothing is touched in the model or the engine.
    func healPairValues(_ l: SoundObject, _ r: SoundObject, ctx: inout GroupHealContext) throws -> SoundObject {
        guard case .group(let lch, let lexp) = l.kind, case .group(let rch, let rexp) = r.kind else {
            throw GroupHealRefusal.special
        }
        let eps = Self.healEps
        let junction = r.startTime

        // 1. Each piece's children are cropped to the piece, at the junction only.
        var left: [SoundObject] = []
        for c in lch {
            if let kept = try healCropped(c, lo: nil, hi: junction) { left.append(kept) } else { ctx.gone.append(c.id) }
        }
        var right: [SoundObject] = []
        for c in rch {
            if let kept = try healCropped(c, lo: junction, hi: nil) { right.append(kept) } else { ctx.gone.append(c.id) }
        }

        // 2. What touches at the junction is joined: auxes, then sub-groups, then clips and MIDI —
        //    in that order, because a sub-group's recursion and a clip's sends both read the table
        //    of auxes already joined.
        var consumed = Set<Int>()
        for pass in 0..<3 {
            for ri in right.indices where !consumed.contains(ri) {
                let rObj = right[ri]
                let wantsPass = rObj.isAux ? 0 : (rObj.isGroup ? 1 : 2)
                guard wantsPass == pass else { continue }

                // An infinite aux has no edge: its twin on the left is the same bus.
                if rObj.isInfiniteBus {
                    guard rObj.isAux,
                          let li = left.firstIndex(where: {
                              $0.isAux && $0.isInfiniteBus && $0.lane == rObj.lane
                                  && Self.healMixEquivalent($0, rObj, ctx.idMap) }) else { continue }
                    consumed.insert(ri)
                    ctx.idMap[rObj.id] = left[li].id
                    ctx.gone.append(rObj.id)
                    ctx.glued += 1
                    continue
                }
                guard abs(rObj.startTime - junction) <= eps else { continue }

                for li in left.indices {
                    let lObj = left[li]
                    guard lObj.lane == rObj.lane, !lObj.isInfiniteBus,
                          abs(lObj.startTime + lObj.duration - junction) <= eps else { continue }
                    var merged: SoundObject? = nil
                    switch (lObj.kind, rObj.kind) {
                    case (.clip, .clip):
                        merged = healGlueClip(lObj, rObj, map: ctx.idMap)
                    case (.midiClip, .midiClip):
                        merged = healGlueMidi(lObj, rObj, map: ctx.idMap)
                    case (.aux, .aux):
                        merged = healGlueAux(lObj, rObj, map: ctx.idMap)
                    case (.group, .group):
                        guard Self.healSubgroupsMatch(lObj, rObj, ctx.idMap),
                              !isLoopedGroupPorthole(lObj), !isLoopedGroupPorthole(rObj) else { break }
                        var sub = ctx
                        if let m = try? healPairValues(lObj, rObj, ctx: &sub) {
                            merged = m
                            ctx = sub
                        }
                    default:
                        break
                    }
                    if let merged {
                        left[li] = merged
                        consumed.insert(ri)
                        ctx.idMap[rObj.id] = lObj.id
                        ctx.gone.append(rObj.id)
                        ctx.glued += 1
                        break
                    }
                }
            }
        }
        var children = left
        for ri in right.indices where !consumed.contains(ri) { children.append(right[ri]) }

        // 3. The group itself: the LEFT piece's identity, the union of the windows.
        let leftDuration = junction - l.startTime
        var m = l
        m.duration = (r.startTime + r.duration) - l.startTime
        m.fadeIn = min(l.fadeIn, m.duration)
        m.fadeOut = min(r.fadeOut, m.duration)
        m.fadeOutCurve = r.fadeOutCurve
        let remap = Self.healPluginRemap(from: r, to: l)
        m.automation = Self.healJoinedAutomation(l.automation, r.automation, leftDuration: leftDuration,
                                                 pluginRemap: remap, auxMap: ctx.idMap, strict: false)
            ?? l.automation
        m.markers = Self.healJoinedMarkers(l.markers, r.markers, leftDuration: leftDuration)
        m.kind = .group(children: children, isExpanded: lexp || rexp)
        return m
    }

    // MARK: - Cropping a child to its piece

    /// `obj` restricted to `[lo, hi]` (either bound may be nil = no limit): nil if nothing of it
    /// is inside. The ids and the plugins are kept — it is the same object, shorter. A piece cut
    /// off at an edge is born bare on that side, like a cut (@see `freshCutCurve`).
    func healCropped(_ obj: SoundObject, lo: Double?, hi: Double?) throws -> SoundObject? {
        guard !obj.isInfiniteBus else { return obj }
        let eps = Self.healEps
        var o = obj
        if let hi, o.startTime + o.duration > hi + eps {
            if o.startTime >= hi - eps { return nil }
            o = try healKeepLeft(o, at: hi)
        }
        if let lo, o.startTime < lo - eps {
            if o.startTime + o.duration <= lo + eps { return nil }
            o = try healKeepRight(o, at: lo)
        }
        return o
    }

    /// Cropping something that straddles the junction cannot be done for these: refuse.
    private func healAssertCroppable(_ o: SoundObject) throws {
        switch o.kind {
        case .clip, .midiClip:
            if o.loopEnabled || o.araSource != nil { throw GroupHealRefusal.special }
        case .aux:
            break
        case .group:
            if isLoopedGroupPorthole(o) || o.consolidateID != nil { throw GroupHealRefusal.special }
        }
    }

    /// `o` without what follows `t` (absolute): the LEFT half of a cut, same id.
    private func healKeepLeft(_ o: SoundObject, at t: Double) throws -> SoundObject {
        try healAssertCroppable(o)
        let rel = t - o.startTime
        var n = o
        n.duration = rel
        n.fadeIn = min(o.fadeIn, rel)
        n.fadeOut = 0
        n.fadeOutCurve = Self.freshCutCurve
        n.automation = o.automation.splitInTime(at: rel).left
        n.markers = o.markers.splitInTime(at: rel).left
        switch o.kind {
        case .clip:
            n.sourceOffset = splitSourceOffsets(of: o, at: t).left
        case .midiClip(let notes, let lengthBeats):
            let splitBeat = beatsFromSeconds(rel)
            n.kind = .midiClip(notes: Self.splitMidiNotes(notes, atBeat: splitBeat).left,
                               lengthBeats: max(0.01, min(lengthBeats, splitBeat)))
        case .aux, .group:
            break   // a window: its content (a group's children) is not cut here
        }
        return n
    }

    /// `o` without what precedes `t` (absolute): the RIGHT half of a cut, same id.
    private func healKeepRight(_ o: SoundObject, at t: Double) throws -> SoundObject {
        try healAssertCroppable(o)
        let rel = t - o.startTime
        let newDuration = o.duration - rel
        var n = o
        n.startTime = t
        n.duration = newDuration
        n.fadeIn = 0
        n.fadeInCurve = Self.freshCutCurve
        n.fadeOut = min(o.fadeOut, newDuration)
        n.automation = o.automation.splitInTime(at: rel).right
        n.markers = o.markers.splitInTime(at: rel).right
        switch o.kind {
        case .clip:
            n.sourceOffset = splitSourceOffsets(of: o, at: t).right
        case .midiClip(let notes, let lengthBeats):
            let splitBeat = beatsFromSeconds(rel)
            n.kind = .midiClip(notes: Self.splitMidiNotes(notes, atBeat: splitBeat).right,
                               lengthBeats: max(0.01, lengthBeats - splitBeat))
        case .aux, .group:
            break
        }
        return n
    }

    // MARK: - Gluing two neighbours into one

    /// ONE audio clip out of `a` then `b`, or nil if they are not the same matter, continuous.
    func healGlueClip(_ a: SoundObject, _ b: SoundObject, map: [UUID: UUID]) -> SoundObject? {
        guard case .clip(let fa, let soa, let fda, let sra, let ra) = a.kind,
              case .clip(let fb, let sob, let fdb, let srb, let rb) = b.kind,
              fa == fb, ra == rb, abs(sra - srb) < 1e-9, abs(fda - fdb) < 1e-6,
              a.lane == b.lane,
              abs((a.startTime + a.duration) - b.startTime) <= Self.healEps,
              Self.healMixEquivalent(a, b, map) else { return nil }
        // The source offset is in SOURCE seconds: a piece of `d` timeline seconds consumes
        // `d × speed` of the file. Forward: the right one starts where the left one stops. In
        // reverse the roles of the two edges swap (@see WaveformShaping.retrimmedSourceOffset).
        let mergedOffset: Double
        if !ra {
            guard abs(sob - (soa + a.duration * sra)) <= Self.healSourceEps else { return nil }
            mergedOffset = soa
        } else {
            guard abs(soa - (sob + b.duration * sra)) <= Self.healSourceEps else { return nil }
            mergedOffset = sob
        }
        guard let auto = Self.healJoinedAutomation(a.automation, b.automation, leftDuration: a.duration,
                                                   pluginRemap: Self.healPluginRemap(from: b, to: a),
                                                   auxMap: map, strict: true) else { return nil }
        var m = a
        healExtend(&m, by: b, automation: auto)
        m.sourceOffset = mergedOffset
        return m
    }

    /// ONE MIDI clip out of `a` then `b`: the notes concatenated, if the instrument and the
    /// settings are the same.
    func healGlueMidi(_ a: SoundObject, _ b: SoundObject, map: [UUID: UUID]) -> SoundObject? {
        guard case .midiClip(let na, let la) = a.kind,
              case .midiClip(let nb, let lb) = b.kind,
              a.lane == b.lane,
              abs((a.startTime + a.duration) - b.startTime) <= Self.healEps,
              Self.healMixEquivalent(a, b, map) else { return nil }
        let beatsA = beatsFromSeconds(a.duration)
        // A clip whose content is shorter than its window leaves a silence the join would eat.
        guard la >= beatsA - 1e-6 else { return nil }
        guard let auto = Self.healJoinedAutomation(a.automation, b.automation, leftDuration: a.duration,
                                                   pluginRemap: Self.healPluginRemap(from: b, to: a),
                                                   auxMap: map, strict: true) else { return nil }
        var m = a
        healExtend(&m, by: b, automation: auto)
        let shifted = nb.map { n -> MidiNote in var q = n; q.startBeat += beatsA; return q }
        m.kind = .midiClip(notes: na + shifted, lengthBeats: beatsA + lb)
        return m
    }

    /// ONE aux out of `a` then `b`: the return stays continuous.
    func healGlueAux(_ a: SoundObject, _ b: SoundObject, map: [UUID: UUID]) -> SoundObject? {
        guard a.isAux, b.isAux, !a.isInfinite, !b.isInfinite,
              a.lane == b.lane,
              abs((a.startTime + a.duration) - b.startTime) <= Self.healEps,
              Self.healMixEquivalent(a, b, map) else { return nil }
        guard let auto = Self.healJoinedAutomation(a.automation, b.automation, leftDuration: a.duration,
                                                   pluginRemap: Self.healPluginRemap(from: b, to: a),
                                                   auxMap: map, strict: true) else { return nil }
        var m = a
        healExtend(&m, by: b, automation: auto)
        return m
    }

    /// `m` (the left piece) stretched over `b` (the right one): the window is the union, the
    /// fade-in stays the left's and the fade-out becomes the right's — the junction keeps none.
    private func healExtend(_ m: inout SoundObject, by b: SoundObject, automation: [AutomationLane]) {
        let leftDuration = m.duration
        m.duration = (b.startTime + b.duration) - m.startTime
        m.fadeOut = b.fadeOut
        m.fadeOutCurve = b.fadeOutCurve
        m.automation = automation
        m.markers = Self.healJoinedMarkers(m.markers, b.markers, leftDuration: leftDuration)
    }

    // MARK: - Equivalence (pure)

    /// The plugin ids of `b` → the ones of `a`, by position (the lists are equivalent, hence the
    /// same shape). The three roots: the chain, the instruments, the sends' mini-chains.
    static func healPluginRemap(from b: SoundObject, to a: SoundObject) -> [UUID: UUID] {
        var remap = SoundObject.pluginIDRemap(from: b.plugins, to: a.plugins)
        remap.merge(SoundObject.pluginIDRemap(from: b.instruments, to: a.instruments)) { x, _ in x }
        remap.merge(SendChain.pluginIDRemap(from: b.sends, to: a.sends)) { x, _ in x }
        return remap
    }

    /// A plugin's state without the identifiers a rebuilt engine reassigns (`id="…"`).
    static func healNormalisedState(_ xml: String?) -> String? {
        guard let xml, !xml.isEmpty else { return nil }
        return xml.replacingOccurrences(of: #"\sid="[^"]*""#, with: "", options: .regularExpression)
    }

    static func healPluginsEquivalent(_ x: [ObjectPlugin], _ y: [ObjectPlugin], _ map: [UUID: UUID],
                                      ignoringState: Bool = false) -> Bool {
        guard x.count == y.count else { return false }
        for (a, b) in zip(x, y) where !healPluginEquivalent(a, b, map, ignoringState: ignoringState) { return false }
        return true
    }

    /// Same plugin, same setting: identity (never the ids), on/off, link, sidechain key (through
    /// `map`) and — unless `ignoringState` — the saved state. The instances of an ATTACHED bin
    /// are mirrors of its definition, so their states are not compared.
    static func healPluginEquivalent(_ a: ObjectPlugin, _ b: ObjectPlugin, _ map: [UUID: UUID],
                                     ignoringState: Bool = false) -> Bool {
        if let ma = a.sendMarker {
            guard let mb = b.sendMarker else { return false }
            return ma.auxID == (map[mb.auxID] ?? mb.auxID)
        }
        if b.sendMarker != nil { return false }
        if let fa = a.fxBlock {
            guard let fb = b.fxBlock, fa.linkID == fb.linkID, fa.isDetached == fb.isDetached,
                  fa.local == fb.local, a.isEnabled == b.isEnabled else { return false }
            return healPluginsEquivalent(fa.plugins, fb.plugins, map, ignoringState: !fa.isDetached)
        }
        if b.fxBlock != nil { return false }
        if let ra = a.rack {
            guard let rb = b.rack, ra.wetDb == rb.wetDb, ra.voiceMutes == rb.voiceMutes,
                  ra.voices.count == rb.voices.count else { return false }
            for (x, y) in zip(ra.voices, rb.voices)
            where !healPluginsEquivalent(x, y, map, ignoringState: ignoringState) { return false }
            return true
        }
        if b.rack != nil { return false }
        guard a.identifier == b.identifier, a.formatName == b.formatName, a.name == b.name,
              a.manufacturer == b.manufacturer, a.isEnabled == b.isEnabled,
              a.linkGroupID == b.linkGroupID, a.detachedLinkGroupID == b.detachedLinkGroupID else { return false }
        if let sa = a.sidechain {
            guard let sb = b.sidechain, sa.sourceID == (map[sb.sourceID] ?? sb.sourceID) else { return false }
        } else if b.sidechain != nil {
            return false
        }
        if ignoringState { return true }
        return healNormalisedState(a.stateXML) == healNormalisedState(b.stateXML)
    }

    static func healSendsEquivalent(_ x: [AuxSend], _ y: [AuxSend], _ map: [UUID: UUID]) -> Bool {
        guard x.count == y.count else { return false }
        for (a, b) in zip(x, y) {
            guard a.auxID == (map[b.auxID] ?? b.auxID), a.levelDb == b.levelDb, a.enabled == b.enabled,
                  a.tap == b.tap, healPluginsEquivalent(a.plugins, b.plugins, map) else { return false }
        }
        return true
    }

    /// Two objects that would sound the same side by side as joined: same fader, pan, mute, bus,
    /// channel mode, instance link, tempo reference, plugins, instruments and sends; none of them
    /// looping or carrying an ARA source. `map` aims the right-hand side's aux ids at the left's.
    static func healMixEquivalent(_ a: SoundObject, _ b: SoundObject, _ map: [UUID: UUID]) -> Bool {
        a.volume == b.volume && a.pan == b.pan && a.isMuted == b.isMuted && a.stemID == b.stemID
            && a.channelMode == b.channelMode && a.consolidateID == b.consolidateID
            && a.baseBPM == b.baseBPM && a.isInfinite == b.isInfinite
            && !a.loopEnabled && !b.loopEnabled && a.araSource == nil && b.araSource == nil
            && healPluginsEquivalent(a.plugins, b.plugins, map)
            && healPluginsEquivalent(a.instruments, b.instruments, map)
            && healSendsEquivalent(a.sends, b.sends, map)
    }

    /// Two sub-groups that are the same group cut in two: the same settings AND the same name.
    static func healSubgroupsMatch(_ a: SoundObject, _ b: SoundObject, _ map: [UUID: UUID]) -> Bool {
        a.isGroup && b.isGroup && a.label == b.label && a.consolidateID == nil
            && healMixEquivalent(a, b, map)
    }

    // MARK: - Joining curves and marks (pure)

    /// The curves of `l` (a piece ending at `leftDuration`, relative time) and of `r` (rebased on
    /// its own start) as the curves of ONE object. The left curve's points at or after the
    /// junction are replaced by the right one's (a cut leaves its interpolated point on both
    /// sides). `r`'s parameters are carried over onto `l`'s plugins through `pluginRemap` and onto
    /// its auxes through `auxMap`.
    ///
    /// `strict`: nil if the two do not curve the same parameters (the clips are then left side by
    /// side — a curve that exists on one side only would change what the other side sounds like).
    /// Not strict (a group's own curves): the left piece rules — a parameter only the right one
    /// curves is dropped.
    static func healJoinedAutomation(_ l: [AutomationLane], _ r: [AutomationLane], leftDuration: Double,
                                     pluginRemap: [UUID: UUID], auxMap: [UUID: UUID],
                                     strict: Bool) -> [AutomationLane]? {
        var rr: [AutomationLane] = []
        for lane in r where !lane.points.isEmpty {
            guard let ref = SoundObject.remapping(lane.param, with: pluginRemap) else {
                if strict { return nil }
                continue
            }
            rr.append(AutomationLane(param: ref.remappingAux(using: auxMap), points: lane.points))
        }
        var out: [AutomationLane] = []
        var used = Set<ParamRef>()
        for lane in l {
            if let m = rr.first(where: { $0.param == lane.param }) {
                used.insert(lane.param)
                let head = lane.sortedPoints.filter { $0.t < leftDuration - 1e-9 }
                let tail = m.shifted(by: leftDuration).sortedPoints
                out.append(AutomationLane(param: lane.param, points: head + tail))
            } else {
                if strict && !lane.points.isEmpty { return nil }
                out.append(lane)
            }
        }
        if strict && rr.contains(where: { !used.contains($0.param) }) { return nil }
        return out
    }

    /// The marks of `l` and of `r` (rebased on its own start) as the marks of ONE object. A region
    /// a cut divided in two — it ends where the other begins, same name, same hue — is mended.
    static func healJoinedMarkers(_ l: [Marker], _ r: [Marker], leftDuration: Double) -> [Marker] {
        var out = l
        var rest = r.map { m -> Marker in var q = m; q.time += leftDuration; return q }
        for i in out.indices where out[i].isRegion && abs(out[i].endTime - leftDuration) <= 1e-6 {
            if let j = rest.firstIndex(where: {
                $0.isRegion && abs($0.time - leftDuration) <= 1e-6
                    && $0.name == out[i].name && $0.colorIndex == out[i].colorIndex }) {
                out[i].duration += rest[j].duration
                rest.remove(at: j)
            }
        }
        return out + rest
    }
}
