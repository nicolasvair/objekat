import Foundation

// The STAGE of a consolidated instance — the instance seen as a GROUP, with its content inside.
//
// A consolidated object has two layers (plan_consolidate_instance_level): the CONTENT, shared by every
// instance and baked into one wave (@see ConsolidateContentRoot), and the INSTANCE LEVEL, which each
// placement keeps for itself — its FX, its fader / pan / mute, its window, its fades, its sends, its
// stem, its automation, its colour. Closed, the instance is a clip on the wave and carries both. OPEN
// for editing, the two layers separate:
//
//     stage  (a group: id = the placement's, window / fades / FX / mix / sends / stem of THE INSTANCE)
//       └─ A (the content root: its own fader, window, fades, FX, children — all of it content)
//
// The stage is the parent of the content, so the content's bake never sees it (an ancestor is made
// transparent by the render), and the instance's FX are heard while the content is edited but are
// never baked into the shared wave.
//
// The same construction serves three callers, which is why it is a pure function of its inputs:
// opening an instance for editing, laying a live mirror of the content on another instance, and
// de-consolidating (the stage then keeps no link, `consolidateID` nil, and no session ever closes it).
//
// Pure model code (no engine, no I/O): unit-tested on its own, @see tools/test_consolidate_realign.swift

extension SoundObject {

    /// `self` and every descendant moved by `dt` seconds. A group's children keep ABSOLUTE start
    /// times (the group's window is a frame onto them), so moving the content means moving all of it.
    func movedInTime(by dt: Double) -> SoundObject {
        guard dt != 0 else { return self }
        var o = self
        o.startTime += dt
        if case .group(let children, let e) = kind {
            o.kind = .group(children: children.map { $0.movedInTime(by: dt) }, isExpanded: e)
        }
        return o
    }

    /// `self` and every descendant put on stem `stem` — the content of an instance lives on the
    /// instance's stem, whatever stem it was baked from.
    func onStem(_ stem: UUID?) -> SoundObject {
        var o = self
        o.stemID = stem
        if case .group(let children, let e) = kind {
            o.kind = .group(children: children.map { $0.onStem(stem) }, isExpanded: e)
        }
        return o
    }

    /// The edit-time instant at which the wave an instance reads has its position 0: the instance
    /// shows the wave from `sourceOffset` at its own `startTime`. This is what the CONTENT is aligned
    /// on when the instance is opened (the content root starts exactly there — @see `consolidateStage`).
    /// Seconds of the wave, so the speed does not enter: a window `d` long at speed `s` shows `d·s`
    /// seconds of wave, but its first instant is at `sourceOffset` all the same.
    var consolidateWaveZero: Double { startTime - sourceOffset }

    /// The OPEN form of the closed instance `placement`: a group (the stage) holding `content`.
    ///
    /// `content` is the content root as `contentRoot(fromSidecar:def:)` returns it, with FRESH ids
    /// (the caller made the deep copy), still in the sidecar's own timeline. It is moved so that its
    /// root starts at `waveZero` — the edit-time instant of the wave's position 0 — which is exactly
    /// where the wave the instance reads starts; its lane is 0 (relative to the stage), its sends gone,
    /// and it and every descendant sit on the instance's stem.
    ///
    /// The stage takes everything that is the instance's, from `placement`:
    ///   • identity (id), lane, stem, label, colour;
    ///   • fader (volume / pan / mute), FX (`plugins`, the caller captured their states), sends;
    ///   • window and fades (× the speed: the content plays at speed 1 for the length of the session,
    ///     so a window `d` long at speed `s` becomes `d·s` long; the placement's automation, markers and
    ///     loop range are stretched by as much, to stay opposite the same material);
    ///   • automation and its touch memory, markers, loop. NOT `automationOpen`: on a group the band
    ///     REPLACES the display of the children, which would hide the very content being opened.
    ///
    /// `definitionID`: the link kept while a session (or a mirror) is on, nil for a de-consolidation.
    ///
    /// The stage is expanded (the content has to be visible and clickable), and so is the content root.
    static func consolidateStage(placement p: SoundObject, content: SoundObject,
                                 definitionID: UUID?, waveZero: Double) -> SoundObject {
        var a = content.movedInTime(by: waveZero - content.startTime).onStem(p.stemID)
        a.lane = 0
        a.consolidateID = nil
        a.sends = []
        if case .group(let ch, _) = a.kind { a.kind = .group(children: ch, isExpanded: true) }

        let spd = p.isClip ? max(p.speedRatio, 0.0001) : 1.0
        var s = p
        s.duration       = p.duration * spd
        s.fadeIn         = p.fadeIn   * spd
        s.fadeOut        = p.fadeOut  * spd
        s.automation     = p.automation.timeScaled(by: spd)
        s.markers        = p.markers.timeScaled(by: spd)
        s.loopRangeStart = p.loopRangeStart.map { $0 * spd }
        s.loopRangeEnd   = p.loopRangeEnd.map   { $0 * spd }
        s.automationOpen = false
        s.consolidateID  = definitionID
        // What only a clip has.
        s.fileSize       = nil
        s.araSource      = nil
        s.channelMode    = .lr
        s.isInfinite     = false
        s.kind           = .group(children: [a], isExpanded: true)
        return s
    }

    /// The CLOSED instance a stage stands for, on the wave `wavePath` (length `waveLength`).
    ///
    /// The inverse of `consolidateStage` for everything that is the instance's: the stage's fader, FX,
    /// sends, fades, stem, label, colour, automation, markers and loop go back onto a clip (speed 1,
    /// forwards — the session played at speed 1), whose `sourceOffset` makes the wave line up with the
    /// stage's window: `window start − waveZero`. That offset is expressed against the wave the stage
    /// was OPENED on (`waveZero` = the edit-time instant of its position 0): it can be negative or run
    /// past the wave when the window was dragged outside the content, and the caller then brings it
    /// back inside through `realigned(instance:…)`, which is the one place that clamps.
    ///
    /// `automationOpen`: the band's state comes from the caller (the snapshot taken at opening) —
    /// the stage's is always false.
    static func closedInstance(fromStage s: SoundObject, wavePath: String, waveLength: Double,
                               waveZero: Double, definitionID: UUID,
                               automationOpen: Bool) -> SoundObject {
        var c = s
        c.consolidateID   = definitionID
        c.automationOpen  = automationOpen && !s.automation.isEmpty
        c.kind = .clip(filePath: wavePath, sourceOffset: s.startTime - waveZero, fileDuration: waveLength,
                       speedRatio: 1.0, isReversed: false)
        return c
    }

    /// True for an instance whose window no longer overlaps the content it reads (Q2 of the plan):
    /// the content moved or shrank under it, so what it shows is silence. It keeps its place and its
    /// length (nothing is ever taken from the user's arrangement), and the timeline flags it.
    /// Represented by a source offset AT the end of the wave: the window then reads past it.
    var isOutsideConsolidateContent: Bool {
        guard consolidateID != nil, case .clip(_, let so, let fd, _, _) = kind, fd > 0 else { return false }
        return so >= fd - 1e-6
    }
}
