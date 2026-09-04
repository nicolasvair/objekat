import AppKit
import AVFoundation

// The BAKE machinery shared by everything that renders a sub-tree into a wave: creating a sound
// object (`makeObject`), closing an edit (`closeObject`) and the headless re-bake of a
// definition (`rebakeDefinitionInBackground`). Nothing here knows about sound objects — these are
// primitives: the render span, a deep copy with fresh ids, realigning a restored sub-tree
// onto a placement, naming a file, a lock during a render.
// @see EditViewModel+Objects

extension EditViewModel {

    // MARK: - Span and duration

    /// The ABSOLUTE time span actually taken up by a group and its whole sub-tree
    /// (children, sub-groups, auxes), the group's bounds included. Used to render ALL the content
    /// (not just the window) → the baked clip can reveal the tail/the pre-window by trimming.
    func bakeRenderRange(_ group: SoundObject) -> (start: Double, end: Double) {
        var minS = group.startTime
        var maxE = group.startTime + group.duration
        func walk(_ obj: SoundObject) {
            minS = min(minS, obj.startTime)
            maxE = max(maxE, obj.startTime + obj.duration)
            if case .group(let ch, _) = obj.kind { for c in ch { walk(c) } }
        }
        if case .group(let ch, _) = group.kind { for c in ch { walk(c) } }
        return (minS, maxE)
    }

    /// The real duration (in seconds) of an audio file, or nil if it cannot be read.
    func audioFileDuration(_ url: URL) -> Double? {
        guard let f = try? AVAudioFile(forReading: url) else { return nil }
        let sr = f.fileFormat.sampleRate
        return sr > 0 ? Double(f.length) / sr : nil
    }

    // MARK: - A deep copy with fresh ids

    /// A deep copy of a sub-tree with FRESH ids everywhere (objects + plugins), remapping
    /// the internal references: sends pointing at an aux OF the sub-tree, and link groups. Two
    /// instances taken from the same sidecar thus produce independent sub-trees, openable
    /// separately with no id collision. Used to open a sound object, to detach an
    /// instance, to lay a live mirror, and for the headless re-bake of a definition (which
    /// instantiates a sub-tree in the engine with no collision with the timeline).
    func deepFreshCopy(_ root: SoundObject) -> SoundObject {
        var idMap: [UUID: UUID] = [:]
        func collectIDs(_ o: SoundObject) {
            idMap[o.id] = UUID()
            if case .group(let ch, _) = o.kind { ch.forEach(collectIDs) }
        }
        collectIDs(root)

        var linkMap: [UUID: UUID] = [:]
        func freshLink(_ old: UUID?) -> UUID? {
            guard let old else { return nil }
            if let n = linkMap[old] { return n }
            let n = UUID(); linkMap[old] = n; return n
        }

        // Recursive: it preserves the parallel blocks (a rack carrier re-clones its voices) — otherwise
        // the restoration flattens/loses the parallel structure. Ids and links regenerated on the leaves.
        func freshPlugins(_ plugins: [ObjectPlugin]) -> [ObjectPlugin] {
            plugins.map { p in
                if let rack = p.rack {
                    return ObjectPlugin(id: UUID(), name: p.name, manufacturer: p.manufacturer,
                                        identifier: p.identifier, formatName: p.formatName,
                                        isEnabled: p.isEnabled,
                                        rack: PluginRack(voices: rack.voices.map { freshPlugins($0) },
                                                         wetDb: rack.wetDb,
                                                         voiceMutes: rack.voiceMutes))
                }
                return ObjectPlugin(id: UUID(), name: p.name, manufacturer: p.manufacturer,
                                    identifier: p.identifier, formatName: p.formatName,
                                    isEnabled: p.isEnabled, stateXML: p.stateXML,
                                    linkGroupID: freshLink(p.linkGroupID),
                                    // The same correspondence table as the active links: a
                                    // detached member stays reattachable to its peers after a bake.
                                    detachedLinkGroupID: freshLink(p.detachedLinkGroupID),
                                    colorIndex: p.colorIndex)
            }
        }

        func rebuild(_ o: SoundObject) -> SoundObject {
            var n = o
            n.id = idMap[o.id] ?? UUID()
            n.plugins = freshPlugins(o.plugins)
            n.instruments = freshPlugins(o.instruments)   // fresh instrument ids (MIDI clips)
            n.sends = o.sends.map { s in
                var ns = s
                if let mapped = idMap[s.auxID] { ns.auxID = mapped }  // an aux internal to the sub-tree
                return ns
            }
            // The curves name their targets BY IDENTIFIER: a plugin that has just changed
            // id, an aux that has just been copied. Without this remapping, the automation of a shared
            // object pointed, on the second copy, at plugins that are no longer its own —
            // silent, and impossible to reattach. The same positional pairing of the leaves as
            // `derivedCopy` (cloning only reshuffles the ids, the structure is preserved);
            // what does not pair up is dropped rather than kept dangling.
            var pluginRemap = SoundObject.pluginIDRemap(from: o.plugins, to: n.plugins)
            pluginRemap.merge(SoundObject.pluginIDRemap(from: o.instruments, to: n.instruments)) { a, _ in a }
            n.automation = o.automation.compactMap { lane in
                guard let ref = SoundObject.remapping(lane.param, with: pluginRemap) else { return nil }
                return AutomationLane(param: ref.remappingAux(using: idMap), points: lane.points)
            }
            n.automationTouchOrder = o.automationTouchOrder.compactMap {
                SoundObject.remapping($0, with: pluginRemap)?.remappingAux(using: idMap)
            }
            if case .group(let ch, let e) = o.kind {
                n.kind = .group(children: ch.map(rebuild), isExpanded: e)
            }
            // NOTES also have a project identity (selection / editing resolved by id
            // across every clip): two sub-trees taken from the same sidecar must carry
            // distinct notes. @see EditViewModel.freshNoteIDs
            if case .midiClip(let notes, let len) = o.kind {
                n.kind = .midiClip(notes: Self.freshNoteIDs(notes), lengthBeats: len)
            }
            return n
        }
        return rebuild(root)
    }

    // MARK: - Realigning a restored sub-tree

    /// Rebuilds `original` (a sub-tree from a sidecar, with fresh ids) ALIGNED on the window/
    /// position of any LIVE wrapper (`wrapper`: the sound-object placement being opened,
    /// being detached, or an instance being turned into a mirror — only its generic fields
    /// startTime/duration/fades/lane/volume/pan/.../sourceOffset/speedRatio count here, whatever
    /// the mechanism that produced it). See `EditViewModel+Objects.openObject` /
    /// `detachFromObjectDefinition` / `applyLiveMirror` for the callers. Does not touch the result's
    /// `definitionID` (set to nil, to be laid back by the caller if needed) nor its own
    /// `plugins` (to be merged by the caller).
    func restoredSubtree(from original: SoundObject, alignedTo wrapper: SoundObject) -> SoundObject {
        var restored = deepFreshCopy(original)
        restored.id        = wrapper.id
        restored.lane      = wrapper.lane
        restored.volume    = wrapper.volume
        restored.pan       = wrapper.pan
        restored.isMuted   = wrapper.isMuted
        restored.stemID    = wrapper.stemID
        restored.sends     = wrapper.sends
        restored.label     = wrapper.label
        restored.colorIndex = wrapper.colorIndex
        // The ROOT's automation: the two halves of the sharing are GLUED BACK together. The sidecar kept
        // only those the render carries away (the parameters of the root's user FX, baked into
        // the wave); the others — gain, pan, trims, sends, and the plugins belonging to the
        // instance — belong to the placement and arrive with it.
        // @see SoundObject.asObjectDefinition, which carries the rule and its reason.
        //
        // It is this gluing back that holds the invariant: opening, re-editing then re-baking a
        // definition does not lose the own curve of the instance it was entered through — and
        // the other instances, turned into live mirrors, EACH keep their own instead
        // of inheriting the origin's.
        //
        // `automationOpen` is NOT carried over: on a group, the band REPLACES the display of the
        // children (@see SoundObject.showsChildrenInline), and materialising a content just
        // opened for editing with its children hidden would be a contradiction. The open
        // state comes back with the placement, on closing as on cancelling.
        let ownParams = Set(wrapper.automation.map(\.param))
        restored.automation           = restored.automation.filter { !ownParams.contains($0.param) }
                                      + wrapper.automation
        restored.automationTouchOrder = wrapper.automationTouchOrder
        restored.definitionID = nil

        if case .group(var children, let isExpanded) = restored.kind {
            let spd            = wrapper.speedRatio
            let renderStart    = bakeRenderRange(original).start
            let contentLeftAbs = renderStart + wrapper.sourceOffset
            let dStart = wrapper.startTime - contentLeftAbs
            restored.startTime = wrapper.startTime
            restored.duration  = wrapper.duration * spd
            restored.fadeIn    = wrapper.fadeIn   * spd
            restored.fadeOut   = wrapper.fadeOut  * spd
            // The baked one may have been varispeeded: the materialised content lasts `spd` times longer, and
            // the instance's own curves stretch by as much to stay in front of it.
            restored.automation = restored.automation.timeScaled(by: spd)
            if dStart != 0 { EditViewModel.shiftStartTimes(&children, by: dStart) }
            func propagateStem(_ kids: inout [SoundObject]) {
                for i in kids.indices {
                    kids[i].stemID = wrapper.stemID
                    if case .group(var gk, let e) = kids[i].kind {
                        propagateStem(&gk)
                        kids[i].kind = .group(children: gk, isExpanded: e)
                    }
                }
            }
            propagateStem(&children)
            restored.kind = .group(children: children, isExpanded: isExpanded)
        } else {
            restored.startTime = wrapper.startTime
            if case .clip(let fp, let so, let fd, let sr, let rev) = restored.kind {
                let spd = wrapper.speedRatio
                restored.duration = wrapper.duration * spd
                restored.fadeIn   = wrapper.fadeIn  * spd
                restored.fadeOut  = wrapper.fadeOut * spd
                restored.automation = restored.automation.timeScaled(by: spd)   // see the group case
                restored.kind = .clip(filePath: fp, sourceOffset: so + wrapper.sourceOffset * sr,
                                      fileDuration: fd, speedRatio: sr, isReversed: rev)
            } else if case .midiClip = restored.kind {
                // A restored MIDI clip: no varispeed equivalent (the notes are in beats) —
                // the wrapper's window is taken as it is (timeline duration/fades). Without
                // this case, resizing the baked wrapper was ignored on opening.
                restored.duration = wrapper.duration
                restored.fadeIn   = wrapper.fadeIn
                restored.fadeOut  = wrapper.fadeOut
            }
        }
        return restored
    }

    // MARK: - Naming, alert, lock

    /// A safe (alphanumeric) file name derived from an object's name, to christen a baked wave.
    func bakeSafeName(_ s: String) -> String {
        let comp = (s as NSString).lastPathComponent
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        return comp.isEmpty ? "Objet" : comp.joined(separator: "_")
    }

    /// An alert of the "render" family. The body delegates to `notify`: the dialogue policy
    /// applies, and under external driving the message is JOURNALLED instead of blocking the
    /// main loop on a click nobody will make. See EditViewModel+Dialogs.
    func bakeAlert(_ title: String, _ info: String) {
        notify(title, info)
    }

    /// True if a bake (a background render) of this object is under way. A soft lock: the sub-tree stays
    /// live and playable, but creating/opening/detaching/dissolving are blocked for the length of the
    /// render. @see EditViewModel.bakingIDs
    func isBaking(_ id: UUID) -> Bool { bakingIDs.contains(id) }
}
