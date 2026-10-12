import Foundation

// MARK: - The old gains become gain stages (session format 25)
//
// Up to format 24 a chain carried two engine points of its own around its plugins — the pre-FX and
// post-FX trims (`chainInGainDb` / `chainOutGainDb`, on objects AND on stems / the Main) — and an FX
// link carried an OUTPUT SECTION (`FXLink.gainDb / pan / muted`, and a detached block's `local`).
// The user's decision of 12 October 2026 (plan_synoptic_rework D1): "it is just a gain before or
// after the plugins, same dB". At load, each of them becomes an ordinary plugin leaf, a GAIN STAGE
// (@see GainStage.swift), placed where the old point was:
//
//  • trim in  → an `objGainStage` at ARRAY INDEX 0 of the host's `plugins` (before every plugin AND
//               every send marker: a marker that sat after the old trim stays after the stage);
//  • trim out → an `objGainStage` APPENDED at the end of `plugins` (after every trailing marker);
//  • an FX link's output → an `objGainPanMute` DEFINITION leaf at the end of the bin, and in every
//               ATTACHED block an instance of it (fresh id, `linkGroupID` = the definition) at the end
//               of the block — exactly what "add a stage to a bin" does live;
//  • a detached block's `local` → an independent `objGainPanMute` at the end of that block.
//
// A trim's automation (`ParamRef.chainInGain` / `.chainOutGain`) moves to the stage's gain
// (`ParamRef.plugin(stage, "gain")`), each point mapped onto the stage's normalised range, and the
// object's touch memory follows. The old fields are then left NEUTRAL (the bin's common on/off,
// `isEnabled`, is not an output setting and stays where it is).
//
// PRESENCE-DRIVEN and IDEMPOTENT: it acts on what it finds non-neutral, whatever the file's format
// number, and a second run finds nothing. A neutral trim (0 dB, no curve) and a neutral output
// (0 dB, centre, not muted) were inaudible: nothing is laid for them. Every new id is FRESH (never
// derived from an existing id — the plugin-id uniqueness rule). Values outside the stage's range
// (±24 dB) are clamped and COUNTED, never refused.
//
// Pure: no view-model, no engine. Called in ONE funnel per decoder — the session
// (`EditViewModel.decodeProjectDocument`) and a consolidated object's sidecar
// (`EditViewModel.decodedConsolidateSidecar`). The load is NOT marked modified for it: nothing
// changed to the ear.

enum LegacyGainMigration {

    /// What a migration did. All zero = nothing to do (a format-25 file, or a file whose old gains
    /// were all neutral).
    struct Report: Equatable {
        /// Trims turned into a stage (objects, groups, stems, the Main; in and out count one each).
        var trims = 0
        /// FX link output sections turned into a stage: one per bin of the registry, one per
        /// DETACHED block with its own output, one per frozen bin of a sidecar.
        var fxOutputs = 0
        /// Trim automation curves moved onto a stage's gain.
        var automationLanes = 0
        /// Values (a static gain or an automation point) brought back within ±24 dB.
        var clamped = 0

        var isEmpty: Bool { self == Report() }

        static func + (a: Report, b: Report) -> Report {
            Report(trims: a.trims + b.trims, fxOutputs: a.fxOutputs + b.fxOutputs,
                   automationLanes: a.automationLanes + b.automationLanes, clamped: a.clamped + b.clamped)
        }
        static func += (a: inout Report, b: Report) { a = a + b }
    }

    // MARK: - Entry points

    /// A whole session: every object at any depth, the stems and the Main, the FX link registry and
    /// the blocks that refer to it.
    @discardableResult
    static func migrate(_ doc: inout ProjectDocument) -> Report {
        var report = Report()

        // 1. The registry first: a bin whose output was not neutral gains a definition leaf, which
        //    every ATTACHED block then mirrors (step 2).
        var newDefinitionForLink: [UUID: ObjectPlugin] = [:]
        if var links = doc.fxLinks {
            for i in links.indices {
                let out = links[i].output
                guard !isNeutral(out) else { continue }
                let (values, clamped) = stageValues(out)
                report.clamped += clamped
                let def = ObjectPlugin.makeGainStage(face: .gainPanMute, values: values)
                links[i].plugins.append(def)
                links[i].gainDb = 0; links[i].pan = 0; links[i].muted = false
                newDefinitionForLink[links[i].id] = def
                report.fxOutputs += 1
            }
            doc.fxLinks = links
        }

        // 2. Objects (recursively) and their blocks.
        var ctx = Context(definitionForLink: newDefinitionForLink, frozenDefinitionForLink: nil)
        for i in doc.items.indices { migrateObject(&doc.items[i], &ctx, &report) }

        // 3. Stems and the Main: trims and blocks (a stem carries no automation).
        if var stems = doc.stems {
            for i in stems.indices {
                var plugins = stems[i].plugins
                migrateBlocks(in: &plugins, &ctx, &report)
                if let stage = trimStage(stems[i].chainInGainDb, hasCurve: false, &report) {
                    plugins.insert(stage, at: 0)
                }
                if let stage = trimStage(stems[i].chainOutGainDb, hasCurve: false, &report) {
                    plugins.append(stage)
                }
                stems[i].plugins = plugins
                stems[i].chainInGainDb = 0
                stems[i].chainOutGainDb = 0
            }
            doc.stems = stems
        }
        return report
    }

    /// A consolidated object's sidecar: a sub-tree with NO registry. Its attached blocks carry their
    /// bin's output FROZEN into `local` (@see EditViewModel.freezingFXBlocks), which is what the
    /// restoration recreates a bin from (@see EditViewModel.deepFreshCopy: the new bin's definition
    /// is read off the block's INSTANCES). So a frozen output becomes an INSTANCE appended to each
    /// attached block of that bin, all of them naming ONE fresh definition id per bin — the
    /// restoration then builds the definition leaf from it like any other — and the frozen `local`
    /// keeps only its on/off.
    @discardableResult
    static func migrate(_ subtree: inout SoundObject) -> Report {
        var report = Report()
        var ctx = Context(definitionForLink: [:], frozenDefinitionForLink: [:])
        migrateObject(&subtree, &ctx, &report)
        return report
    }

    // MARK: - Objects

    private struct Context {
        /// Registry pass: the stage definition a bin gained (nil entry = the bin was neutral).
        var definitionForLink: [UUID: ObjectPlugin]
        /// Sidecar pass (non-nil): the definition id chosen for each bin met with a frozen output,
        /// so that two members of one bin name the same definition.
        var frozenDefinitionForLink: [UUID: UUID]?
    }

    private static func migrateObject(_ o: inout SoundObject, _ ctx: inout Context, _ report: inout Report) {
        if case .group(var children, let expanded) = o.kind {
            for i in children.indices { migrateObject(&children[i], &ctx, &report) }
            o.kind = .group(children: children, isExpanded: expanded)
        }

        var plugins = o.plugins
        migrateBlocks(in: &plugins, &ctx, &report)

        let inLane  = o.automation.firstIndex { $0.param == .chainInGain }
        let outLane = o.automation.firstIndex { $0.param == .chainOutGain }
        let inHasCurve  = inLane.map  { !o.automation[$0].points.isEmpty } ?? false
        let outHasCurve = outLane.map { !o.automation[$0].points.isEmpty } ?? false

        var retarget: [ParamRef: ParamRef] = [:]
        if let stage = trimStage(o.chainInGainDb, hasCurve: inHasCurve, &report) {
            plugins.insert(stage, at: 0)
            retarget[.chainInGain] = .plugin(pluginKey: stage.id, paramID: GainStageValues.gainParamID)
        }
        if let stage = trimStage(o.chainOutGainDb, hasCurve: outHasCurve, &report) {
            plugins.append(stage)
            retarget[.chainOutGain] = .plugin(pluginKey: stage.id, paramID: GainStageValues.gainParamID)
        }
        o.plugins = plugins
        o.chainInGainDb = 0
        o.chainOutGainDb = 0

        // The curves follow their trim; a lane left with no point is simply dropped ('no point = no
        // automation'), and so is a touch-memory entry naming a trim that no longer exists.
        var lanes: [AutomationLane] = []
        for lane in o.automation {
            guard lane.param == .chainInGain || lane.param == .chainOutGain else { lanes.append(lane); continue }
            guard let target = retarget[lane.param], !lane.points.isEmpty else { continue }
            var moved = AutomationLane(param: target, points: lane.points)
            for j in moved.points.indices {
                let dB = moved.points[j].v
                if !GainStageValues.gainRange.contains(dB) { report.clamped += 1 }
                moved.points[j].v = GainStageValues.normalizedGain(dB)
            }
            lanes.append(moved)
            report.automationLanes += 1
        }
        o.automation = lanes
        o.automationTouchOrder = o.automationTouchOrder.compactMap { ref in
            guard ref == .chainInGain || ref == .chainOutGain else { return ref }
            return retarget[ref]
        }
    }

    /// The stage a trim becomes, nil when the trim was neutral (0 dB and no curve).
    private static func trimStage(_ dB: Float, hasCurve: Bool, _ report: inout Report) -> ObjectPlugin? {
        guard dB != 0 || hasCurve else { return nil }
        if !GainStageValues.gainRange.contains(dB) { report.clamped += 1 }
        report.trims += 1
        return ObjectPlugin.makeGainStage(face: .gain, values: GainStageValues(gainDb: dB).clamped)
    }

    // MARK: - FX link blocks (at any depth of a chain: a rack's branch can hold one)

    private static func migrateBlocks(in plugins: inout [ObjectPlugin], _ ctx: inout Context,
                                      _ report: inout Report) {
        for i in plugins.indices {
            if plugins[i].rack != nil {
                var p = plugins[i]
                if var rack = p.rack {
                    for v in rack.voices.indices { migrateBlocks(in: &rack.voices[v], &ctx, &report) }
                    p.rack = rack
                }
                plugins[i] = p
                continue
            }
            guard var fb = plugins[i].fxBlock else { continue }

            if fb.isDetached {
                // Its own output section, `local` (absent = neutral).
                if let local = fb.local, !isNeutral(local) {
                    let (values, clamped) = stageValues(local)
                    report.clamped += clamped
                    fb.plugins.append(ObjectPlugin.makeGainStage(face: .gainPanMute, values: values))
                    report.fxOutputs += 1
                    fb.local = local.isEnabled ? nil : FXLinkOutput(isEnabled: false)
                }
            } else if var frozen = ctx.frozenDefinitionForLink {
                // A sidecar: the bin's output frozen into `local` (@see migrate(_: inout SoundObject)).
                if let local = fb.local, !isNeutral(local) {
                    let (values, clamped) = stageValues(local)
                    let defID: UUID
                    if let known = frozen[fb.linkID] {
                        defID = known
                    } else {
                        defID = UUID()
                        frozen[fb.linkID] = defID
                        report.fxOutputs += 1
                        report.clamped += clamped
                    }
                    ctx.frozenDefinitionForLink = frozen
                    fb.plugins.append(ObjectPlugin.makeGainStage(face: .gainPanMute, values: values,
                                                                 linkGroupID: defID))
                    fb.local = FXLinkOutput(isEnabled: local.isEnabled)
                }
            } else if let def = ctx.definitionForLink[fb.linkID] {
                // An attached member of a bin that gained a stage: its linked instance.
                fb.plugins.append(ObjectPlugin(id: UUID(), name: def.name, manufacturer: def.manufacturer,
                                               identifier: def.identifier, formatName: def.formatName,
                                               isEnabled: def.isEnabled, stateXML: def.stateXML,
                                               linkGroupID: def.id, colorIndex: def.colorIndex))
            }
            plugins[i].fxBlock = fb
        }
    }

    // MARK: - Values

    private static func isNeutral(_ out: FXLinkOutput) -> Bool {
        out.gainDb == 0 && out.pan == 0 && !out.muted
    }

    /// An output section as a stage's values, and how many of them had to be clamped.
    private static func stageValues(_ out: FXLinkOutput) -> (GainStageValues, Int) {
        let raw = GainStageValues(gainDb: out.gainDb, pan: out.pan, muted: out.muted)
        let v = raw.clamped
        return (v, (v.gainDb != raw.gainDb ? 1 : 0) + (v.pan != raw.pan ? 1 : 0))
    }
}
