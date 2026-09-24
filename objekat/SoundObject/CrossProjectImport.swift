import Foundation

/// Cross-project paste (tabs INC 2 — @see `project_multi_project_tabs_plan`, memory).
///
/// `CrossProjectImport.plan(_:target:)` is a PURE function: it reads only its two arguments,
/// touches no engine, and mutates nothing that could be "the target" — it hands back a plan the
/// caller applies through the EXISTING `add`/`addChild`/`resyncAllSends`/`resolveOverlaps`
/// primitives (@see `EditViewModel+CrossProjectPaste.swift`). It exists because the intra-project
/// clipboard (`EditViewModel+Clipboard.swift`) is unsafe to reuse as-is across two DIFFERENT
/// projects: a Save-As-derived project version can share object/plugin UUIDs with its sibling
/// (the "V1/V2" case), and `copiedPlugins`/`copiedInstruments` (`EditViewModel+Plugins.swift`)
/// read the LIVE engine by a clipboard object's UUID and `update(id:)` the CURRENT view-model —
/// both of which, aimed at a clipboard object whose UUID happens to already exist in the TARGET
/// project, would silently read or corrupt the wrong object. This file never does either: every
/// plugin clone is "cold", built only from `ObjectPlugin.stateXML` already frozen into the
/// clipboard by `withCapturedPluginStates` at COPY time, in the SOURCE tab while its own engine
/// was still live.
///
/// Rules this function encodes (the full list is the INC2 spec, memory `project_multi_project_tabs_plan`):
/// - every object, plugin/instrument and MIDI note gets a FRESH id;
/// - a plugin `linkGroupID` is remapped to a NEW group, but ONLY within the pasted batch — never
///   attached to a group that exists on the target side, and never invented for a plugin that had
///   none (no "link by default" backfill);
/// - `stemID` is always forced to `nil` (INC2 rule: everything pasted lands on the Main);
/// - a send whose aux exists inside the batch is remapped; a send to an aux NOT in the batch is
///   DROPPED, automation curve (and `automationTouchOrder` entry) included, rather than left
///   dangling on an aux id that means nothing in the target;
/// - a consolidated object ALWAYS becomes a brand new `ConsolidateDefinition` (fresh id, its
///   `dependsOn` remapped recursively) — never shares a definition with anything already in the
///   target, even if the ids happened to collide;
/// - the file(s) a consolidated definition or a plain clip point at are NEVER copied — they stay
///   at the clipboard's `originFolder`, which is why `CrossProjectPastePlan` also hands back a
///   `consolidateOriginFolders` map for the caller to fold into its own resolver
///   (`ConsolidateFolders.resolve(..., extraDirs:)`);
/// - MIDI note musical times (`startBeat`/`lengthBeats`) are copied AS-IS — no tempo conversion,
///   by design (INC2 rule: keep musical measures/beats, not wall-clock time).
enum CrossProjectImport {

    /// The frozen, self-contained record of what the user copied — hoisted, at copy time, out of
    /// the normal `EditViewModel.clipboard`/`consolidateDefinitions` into something that can
    /// survive the origin tab going away or changing under it.
    struct Clipboard {
        var clips: [SoundObject]
        var comments: [TimelineComment]
        /// Every `ConsolidateDefinition` any clip (or nested child) in `clips` points to,
        /// keyed by its ORIGINAL id — a superset is harmless, `plan()` only ever looks up what a
        /// clip actually references.
        var consolidateDefinitions: [UUID: ConsolidateDefinition]
        /// The source project's own folder — where its media and consolidated waves live, and
        /// where they are read from AFTER the paste too (media is never copied).
        var originFolder: URL
        /// Where the copy was taken from, in the source's own timeline frame.
        var originTime: Double
        var originLane: Int
    }

    /// What the destination side of the paste decided, in ITS OWN timeline frame — mirrors the
    /// positioning `EditViewModel.paste()` already computes from `timeSelection`/`cursorPosition`/
    /// `caretLane` for the intra-project case.
    struct PasteTarget {
        var pasteTime: Double
        var pasteLane: Int
    }

    /// Everything the caller needs to actually place the batch — ids all fresh, positions already
    /// shifted into the target's frame, nothing left for the caller to invent.
    struct Plan {
        var clips: [SoundObject]
        var comments: [TimelineComment]
        var newConsolidateDefinitions: [ConsolidateDefinition]
        var consolidateOriginFolders: [UUID: URL]
    }

    static func plan(_ clipboard: Clipboard, target: PasteTarget) -> Plan {
        // Every object id in the batch, at EVERY level (a send inside a nested group may target
        // an aux that is a SIBLING at the top level, or vice versa) — pre-registered so remapping
        // does not depend on visit order.
        var objectIDMap: [UUID: UUID] = [:]
        func registerIDs(_ o: SoundObject) {
            objectIDMap[o.id] = UUID()
            if case .group(let children, _) = o.kind {
                for c in children { registerIDs(c) }
            }
        }
        for o in clipboard.clips { registerIDs(o) }

        var linkGroupMap: [UUID: UUID] = [:]
        var consolidateMap: [UUID: UUID] = [:]
        var newDefs: [ConsolidateDefinition] = []
        var originFolders: [UUID: URL] = [:]

        func freshConsolidateID(_ old: UUID) -> UUID {
            if let mapped = consolidateMap[old] { return mapped }
            let new = UUID()
            consolidateMap[old] = new
            originFolders[new] = clipboard.originFolder
            if let def = clipboard.consolidateDefinitions[old] {
                var newDef = def
                newDef.id = new
                newDef.dependsOn = def.dependsOn.map { dep in
                    var d = dep
                    d.consolidateID = freshConsolidateID(dep.consolidateID)
                    return d
                }
                newDefs.append(newDef)
            }
            return new
        }

        /// Clones a plugin list with fresh ids, "cold" — built only from what is already frozen
        /// in the clipboard (`stateXML`), never the live engine and never `update(id:)` on
        /// anything (@see the file's own header comment for why). Recursive: a rack carrier
        /// clones its voices with new ids too, and every LEAF's old→new id lands in the same
        /// `pluginIDMap`, rack-nested or not, since a `ParamRef.plugin` automation ref can name
        /// any leaf. A link group is remapped to a NEW, batch-scoped one only when the plugin
        /// ALREADY had one — never invented (no "link by default" backfill, unlike the
        /// intra-project `copiedPlugins`, which does not apply across a paste this cold).
        func clonePlugins(_ plugins: [ObjectPlugin]) -> ([ObjectPlugin], [UUID: UUID]) {
            var pluginIDMap: [UUID: UUID] = [:]
            func cloneLeaf(_ p: ObjectPlugin) -> ObjectPlugin {
                let newID = UUID()
                pluginIDMap[p.id] = newID
                var newGroup: UUID? = nil
                if let g = p.linkGroupID {
                    if let mapped = linkGroupMap[g] {
                        newGroup = mapped
                    } else {
                        newGroup = UUID()
                        linkGroupMap[g] = newGroup
                    }
                }
                return ObjectPlugin(id: newID, name: p.name, manufacturer: p.manufacturer,
                                    identifier: p.identifier, formatName: p.formatName,
                                    isEnabled: p.isEnabled, stateXML: p.stateXML,
                                    linkGroupID: newGroup, colorIndex: p.colorIndex)
            }
            func cloneSeries(_ series: [ObjectPlugin]) -> [ObjectPlugin] {
                series.map { p in
                    if let rack = p.rack {
                        let newID = UUID()
                        pluginIDMap[p.id] = newID
                        return ObjectPlugin(id: newID, name: p.name, manufacturer: p.manufacturer,
                                            identifier: p.identifier, formatName: p.formatName,
                                            isEnabled: p.isEnabled,
                                            rack: PluginRack(voices: rack.voices.map(cloneSeries),
                                                             wetDb: rack.wetDb,
                                                             voiceMutes: rack.voiceMutes),
                                            colorIndex: p.colorIndex)
                    }
                    return cloneLeaf(p)
                }
            }
            let cloned = cloneSeries(plugins)
            return (cloned, pluginIDMap)
        }

        func cloneNotes(_ notes: [MidiNote]) -> [MidiNote] {
            notes.map { n in
                MidiNote(pitch: n.pitch, startBeat: n.startBeat, lengthBeats: n.lengthBeats, velocity: n.velocity)
            }
        }

        /// Remaps a `ParamRef` onto the cloned batch, or drops it (`nil`) when it points outside
        /// the batch: a `.plugin` ref whose plugin was not cloned alongside it, or a `.send` ref
        /// whose aux is not part of the pasted batch. Every other case (`.volume`, `.pan`,
        /// `.chainInGain`, `.chainOutGain`) needs no remap at all.
        func remapParamRef(_ ref: ParamRef, pluginIDMap: [UUID: UUID]) -> ParamRef? {
            switch ref {
            case .plugin(let pluginKey, let paramID):
                guard let newKey = pluginIDMap[pluginKey] else { return nil }
                return .plugin(pluginKey: newKey, paramID: paramID)
            case .send(let auxID):
                guard let newAux = objectIDMap[auxID] else { return nil }
                return .send(auxID: newAux)
            default:
                return ref
            }
        }

        func cloneObject(_ o: SoundObject) -> SoundObject {
            var no = o
            no.id = objectIDMap[o.id] ?? UUID()
            no.stemID = nil

            let (newPlugins, pluginIDMap) = clonePlugins(o.plugins)
            no.plugins = newPlugins

            // The instrument slot (index 0 of a MIDI clip) is never linked and never a rack —
            // a fresh id, cold, is enough (mirrors `copiedInstruments`'s shape with no engine read).
            no.instruments = o.instruments.map { inst in
                ObjectPlugin(id: UUID(), name: inst.name, manufacturer: inst.manufacturer,
                            identifier: inst.identifier, formatName: inst.formatName,
                            isEnabled: inst.isEnabled, stateXML: inst.stateXML,
                            colorIndex: inst.colorIndex)
            }

            no.sends = o.sends.compactMap { send -> AuxSend? in
                guard let newAux = objectIDMap[send.auxID] else { return nil }
                var s = send
                s.auxID = newAux
                return s
            }

            no.automation = o.automation.compactMap { lane -> AutomationLane? in
                guard let newRef = remapParamRef(lane.param, pluginIDMap: pluginIDMap) else { return nil }
                var l = lane
                l.param = newRef
                return l
            }
            no.automationTouchOrder = o.automationTouchOrder.compactMap {
                remapParamRef($0, pluginIDMap: pluginIDMap)
            }

            if let cid = o.consolidateID {
                no.consolidateID = freshConsolidateID(cid)
            }

            switch o.kind {
            case .group(let children, let isExpanded):
                no.kind = .group(children: children.map(cloneObject), isExpanded: isExpanded)
            case .midiClip(let notes, let lengthBeats):
                no.kind = .midiClip(notes: cloneNotes(notes), lengthBeats: lengthBeats)
            default:
                break
            }
            return no
        }

        let dt = target.pasteTime - clipboard.originTime
        let laneDelta = target.pasteLane - clipboard.originLane

        // Positioning applies to the TOP-LEVEL entries only, exactly as `copySelected()` stored
        // only the top-level clips' absolute start/lane — a nested child's start/lane is already
        // relative to its parent group and must not be shifted a second time.
        let placedClips: [SoundObject] = clipboard.clips.map { src in
            var clone = cloneObject(src)
            clone.startTime += dt
            clone.lane += laneDelta
            return clone
        }

        let placedComments: [TimelineComment] = clipboard.comments.compactMap { c in
            guard let p = c.parentID, let newParent = objectIDMap[p] else { return nil }
            var copy = c
            copy.id = UUID()
            copy.parentID = newParent
            return copy
        }

        return Plan(clips: placedClips,
                    comments: placedComments,
                    newConsolidateDefinitions: newDefs,
                    consolidateOriginFolders: originFolders)
    }
}
