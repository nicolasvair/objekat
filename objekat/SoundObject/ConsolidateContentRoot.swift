import Foundation

// The CONTENT ROOT of a consolidated object — the subtree a `*_objectstate.json` sidecar holds, seen
// as what is shared by every instance, and nothing else.
//
// Since format 26 the rule is: the root of the content is ENTIRELY content — its fader, its window
// (trim), its fades, its loop. All of it is baked into the wave and shared. What an instance adds on
// top (its FX, its mix, its window, its fades, its sends, its stem, its automation) lives on the
// instance, never on this root (@see ConsolidateDefinition.rootIsContent).
//
// A sidecar written by an older build does not follow that rule: its root still carried the mix of
// the instance it was baked from (the old render bypassed the fader / window / fades of the target,
// to leave them live on the baked clip, so they were never part of the wave). `contentRoot` turns
// either kind of sidecar into the same thing — a root with nothing of an instance on it — which is
// what makes the first validation of an old consolidated object produce the very wave it already has.
//
// Pure model code (no engine, no I/O): it is unit-tested on its own,
// @see tools/test_consolidate_content_root.swift

extension SoundObject {

    // MARK: - The span a bake renders

    /// The ABSOLUTE time span actually taken up by this object and its whole sub-tree (children,
    /// sub-groups, auxes), its own bounds included. A group's bake renders ALL of it (not just the
    /// window), so the baked clip can reveal the tail / the pre-window by trimming.
    /// `EditViewModel.bakeRenderRange` is this.
    var bakeSpan: (start: Double, end: Double) {
        var minS = startTime
        var maxE = startTime + duration
        func walk(_ obj: SoundObject) {
            minS = min(minS, obj.startTime)
            maxE = max(maxE, obj.startTime + obj.duration)
            if case .group(let ch, _) = obj.kind { for c in ch { walk(c) } }
        }
        if case .group(let ch, _) = kind { for c in ch { walk(c) } }
        return (minS, maxE)
    }

    // MARK: - Reading a sidecar

    /// The root of a consolidated object's CONTENT, from the subtree its sidecar holds.
    ///
    /// Always: the root carries no send (the sends belong to an instance).
    ///
    /// When `def.rootIsContent` — a sidecar written by a build that follows the rule — nothing else
    /// is touched: the fader, the window, the fades and the loop on the root ARE the content's.
    ///
    /// When not (every sidecar written before format 26), the root is brought to what the old
    /// bake actually rendered:
    ///   • the fader is neutral (0 dB, centred, not muted) — the old render bypassed it;
    ///   • the fades are zero — the old render bypassed them (and the clone's container fades are
    ///     held at zero);
    ///   • the window of a group is its FULL EXTENT (`bakeSpan`): the old render opened the
    ///     container's span to the whole render range. A window narrower than that was the INSTANCE's
    ///     framing, which lives on the instance. The root's automation, markers and loop range are
    ///     relative to the root's start (@see AutomationPoint.t), so moving the start earlier shifts
    ///     them by as much: they stay opposite the same material. A clip (or MIDI) root keeps its
    ///     window — it is the clip's own source range, the render covered exactly that — and
    ///     an INFINITE group keeps its (absent) window;
    ///   • the curves that were NOT baked (the fader's volume / pan, the sends') are removed: they
    ///     were the instance's, they are already on the instance (@see automationSurvivingBake).
    ///     What the render carried away (the parameters of the root's user FX) stays;
    ///   • the loop is left as it is. The old bake keeps the container's loop range on the cloned
    ///     container (`openContainer` in OBJEngineCore.mm moves its span and offset, not its loop),
    ///     so a looping group's loop was baked into the wave.
    ///
    /// Idempotent. Never touches the children, the plugins, nor the root's identity (id, name,
    /// stem, colour): the caller decides what to do with those.
    static func contentRoot(fromSidecar sidecar: SoundObject, def: ConsolidateDefinition) -> SoundObject {
        var root = sidecar
        root.sends = []
        guard !def.rootIsContent else {
            // The root's curves aimed at a send are orphans once the sends are gone.
            root.automation = root.automation.filter { root.resolvesAutomationTarget($0.param) }
            return root
        }

        root.volume  = 0
        root.pan     = 0
        root.isMuted = false
        root.fadeIn  = 0
        root.fadeOut = 0

        if root.isGroup && !root.isInfinite {
            let span = root.bakeSpan
            let dt = root.startTime - span.start   // ≥ 0: the span includes the root's own start
            if dt != 0 {
                root.startTime  = span.start
                root.automation = root.automation.shiftedInTime(by: dt)
                root.markers    = root.markers.shiftedInTime(by: dt)
                if let s = root.loopRangeStart { root.loopRangeStart = s + dt }
                if let e = root.loopRangeEnd   { root.loopRangeEnd   = e + dt }
            }
            root.duration = span.end - span.start
        }

        // The sends are gone, so a lane aimed at one resolves no more; the fader's lanes are the
        // instance's; the plugin lanes of the root's own FX are what the render baked.
        root.automation = root.automation.filter { root.automationTargetIsBakedIntoRender($0.param) }
        root.automationTouchOrder = []
        return root
    }

    // MARK: - Writing a sidecar

    /// The subtree as the sidecar of a definition whose `rootIsContent` is TRUE holds it: the root
    /// is content from top to bottom, so it keeps its fader, its window, its fades, its loop and ALL
    /// its automation (volume and pan included) — only the sends are dropped (they belong to an
    /// instance), with the curves aimed at them, and the 'last parameter touched' memory, which is
    /// interface convenience that belongs to whoever touched it.
    ///
    /// The counterpart of `asConsolidateDefinition`, which is the writer of the old rule (the root
    /// is the instance's layer: its sends and its un-baked curves are shared out to the placement).
    var asContentRootDefinition: SoundObject {
        var copy = self
        copy.sends = []
        copy.automation = automation.filter { copy.resolvesAutomationTarget($0.param) }
        copy.automationTouchOrder = []
        return copy
    }
}
