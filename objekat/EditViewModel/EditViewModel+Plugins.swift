import Foundation
import AppKit
import SwiftUI

extension EditViewModel {

    // MARK: - Plugins absent from the machine (before opening baked content)

    /// The display names ("Name [FORMAT]") of the plugins referenced by `objects` and their WHOLE
    /// sub-tree — FX chains, parallel blocks, the virtual instruments of MIDI clips — that are
    /// not installed here. An EMPTY catalogue excuses nothing: no plugin scanned = no
    /// plugin available, so everything the content asks for is missing (user decision, 2026-08-08).
    func missingPluginNames(in objects: [SoundObject]) -> [String] {
        let installed = Set(availablePlugins.map { "\($0.formatName)\u{1}\($0.identifier)" })
        var refs: [ObjectPlugin] = []
        for o in objects { Self.collectPluginRefs(in: o, into: &refs) }
        var seen: Set<String> = []
        var out: [String] = []
        for p in refs where !p.isBuiltIn {   // the Tracktion built-ins are always available
            let key = "\(p.formatName)\u{1}\(p.identifier)"
            guard !installed.contains(key), seen.insert(key).inserted else { continue }
            // A slot that carries a usable trace is NOT missing: that is the whole point of a
            // trace, and warning about it would ask the user to worry about something already
            // handled. @see EditViewModel.playsFromTrace
            guard !playsFromTrace(p) else { continue }
            out.append("\(p.name) [\(p.formatLabel)]")
        }
        return out
    }

    /// Asks for confirmation before opening one or more baked contents with missing
    /// plugins: once materialised, `compileRack` REMOVES them from the model — the sound would be heard
    /// without its effects, and saving afterwards would lose them for good. ONE single alert for the whole
    /// batch. Returns true if we can carry on; asks nothing if nothing is missing.
    func confirmMissingPluginsBeforeOpening(_ subtrees: [SoundObject], what: String) -> Bool {
        let missing = missingPluginNames(in: subtrees)
        guard !missing.isEmpty else { return true }
        return confirm(L("plugins.missing.title"),
                       L("plugins.missing.onBake.info", what,
                         missing.map { "• \($0)" }.joined(separator: "\n")),
                       yes: L("plugins.missing.openAnyway"),
                       no: L("common.cancel"))
    }

    /// Convenience: a single content.
    func confirmMissingPluginsBeforeOpening(_ subtree: SoundObject, what: String) -> Bool {
        confirmMissingPluginsBeforeOpening([subtree], what: what)
    }

    /// Flattens a sub-tree's plugins: the object's FX chain + instruments, the branches of the parallel
    /// blocks, then recursion into a group's children.
    private static func collectPluginRefs(in object: SoundObject, into out: inout [ObjectPlugin]) {
        collectPluginRefs(object.plugins, into: &out)
        collectPluginRefs(object.instruments, into: &out)
        if case .group(let children, _) = object.kind {
            for c in children { collectPluginRefs(in: c, into: &out) }
        }
    }

    private static func collectPluginRefs(_ plugins: [ObjectPlugin], into out: inout [ObjectPlugin]) {
        for p in plugins {
            if let rack = p.rack {
                for v in rack.voices { collectPluginRefs(v, into: &out) }
            } else {
                out.append(p)
            }
        }
    }

    // MARK: - An FX chain host (a timeline object OR a stem/master bus) — INC 2
    //
    // The whole FX pipeline (synoptic rack, chain gains, link, meters) is keyed by UUID on the
    // engine side (userPluginListForKey:). A stem (or the Main) exposes a `pluginList` resolvable by its
    // key → the pipeline is reused as it is. These primitives read/write the host's FX chain,
    // whether the host is a SoundObject (storage = obj.plugins) or a bus (storage = stem.plugins).

    /// The stem's index if `hostID` names a bus (a stem or the Main), otherwise nil (= a timeline object).
    func stemIndex(_ hostID: UUID) -> Int? {
        stems.firstIndex(where: { $0.id == hostID })
    }

    /// True if `hostID` names a bus (a stem or the Main) rather than a timeline object.
    func isStemHost(_ hostID: UUID) -> Bool { stemIndex(hostID) != nil }

    /// The host's plugins (its FX chain). nil if the host does not exist.
    func chainPlugins(_ hostID: UUID) -> [ObjectPlugin]? {
        if let i = stemIndex(hostID) { return stems[i].plugins }
        return find(id: hostID)?.plugins
    }

    /// Mutates the host's FX chain (object or bus). Returns true if the host exists.
    @discardableResult
    func updateChainPlugins(_ hostID: UUID, _ f: (inout [ObjectPlugin]) -> Void) -> Bool {
        if let i = stemIndex(hostID) { f(&stems[i].plugins); isDirty = true; return true }
        return update(id: hostID) { f(&$0.plugins) }
    }

    /// The host's chain start/end gains (0 dB if it cannot be found).
    func chainGains(_ hostID: UUID) -> (inDb: Float, outDb: Float) {
        if let i = stemIndex(hostID) { return (stems[i].chainInGainDb, stems[i].chainOutGainDb) }
        if let o = find(id: hostID) { return (o.chainInGainDb, o.chainOutGainDb) }
        return (0, 0)
    }

    /// Writes a chain gain (start/end) into the host's model.
    func setChainGainModel(_ hostID: UUID, output: Bool, dB: Float) {
        if let i = stemIndex(hostID) {
            if output { stems[i].chainOutGainDb = dB } else { stems[i].chainInGainDb = dB }
            isDirty = true; return
        }
        update(id: hostID) { if output { $0.chainOutGainDb = dB } else { $0.chainInGainDb = dB } }
    }

    // MARK: - Plugins

    func loadCachedPlugins() {
        guard let engine else { return }
        availablePlugins = (engine.availablePlugins() as? [[String: Any]] ?? []).compactMap { d in
            Self.availablePlugin(from: d)
        }
        if !availablePlugins.isEmpty {
            NSLog("[OBJ] \(availablePlugins.count) plugins loaded from the cache")
        }
    }

    /// Parses an entry of the engine catalogue (a heterogeneous dict) into an `AvailablePlugin`.
    private static func availablePlugin(from d: [String: Any]) -> AvailablePlugin? {
        guard let name = d["name"] as? String, let manufacturer = d["manufacturer"] as? String,
              let identifier = d["identifier"] as? String, let format = d["format"] as? String
        else { return nil }
        let isInstrument = (d["isInstrument"] as? NSNumber)?.boolValue ?? false
        return AvailablePlugin(name: name, manufacturer: manufacturer,
                               identifier: identifier, formatName: format,
                               isInstrument: isInstrument)
    }

    func rescanPlugins() {
        engine?.clearPluginCache()
        scanPlugins()
    }

    func diagnosticScanPlugins() {
        engine?.diagnosticScanPlugins()
    }

    func diagnosePlugin(objectID: UUID, pluginID: UUID) {
        guard let obj = find(id: objectID),
              let plug = obj.plugins.first(where: { $0.id == pluginID })
        else { return }
        engine?.diagnosePlugin(plug.identifier, format: plug.formatName, name: plug.name)
    }

    func diagnosticPluginStates(objectID: UUID) {
        func log(_ msg: String) { print("[DIAG] \(msg)") }
        guard let obj = find(id: objectID) else {
            log("diagnosticPluginStates: object \(objectID.uuidString) not found")
            return
        }
        let plugins = obj.plugins
        let label = obj.label ?? objectID.uuidString
        log("── Plugin state of object \(label) ──")
        log("\(plugins.count) plugin(s) in the Swift model")
        for (i, plug) in plugins.enumerated() {
            let state = pluginInstanceState(pluginID: plug.id)
            let stateLabel = ["?", "loading", "READY", "ERROR"][min(state, 3)]
            let err = pluginLoadError(pluginID: plug.id).map { " — '\($0)'" } ?? ""
            log("  [\(i)] \(plug.name) [\(plug.formatName)] id=\(plug.id.uuidString.prefix(8)) state=\(stateLabel)\(err)")
            if state == 3 && plug.formatName == "VST3" {
                engine?.diagnosVST3Load(plug.identifier)
            }
        }
        if plugins.isEmpty { log("  (no plugin on this object)") }
        log("─────────────────────────────────────")
    }

    func scanPlugins() {
        guard let engine, !isScanning else { return }
        isScanning = true
        engine.scanPlugins { [weak self] list in
            let plugins = (list as? [[String: Any]] ?? []).compactMap { d in
                Self.availablePlugin(from: d)
            }
            DispatchQueue.main.async { [weak self] in
                self?.availablePlugins = plugins
                self?.isScanning = false
            }
        }
    }

    // MARK: - The rack compiler (step 2): model → engine
    //
    // The source of truth = the `[ObjectPlugin]` tree (series + `rack` parallel blocks). On EVERY
    // edit the object's engine rack is RECOMPILED: `compileRack` serialises the tree into an NSArray
    // spec and calls `-compileUserRackForObjectID:tree:` (reconciliation by id on the engine side).

    /// Serialises the model tree into the spec the engine compiler expects (recursive over the
    /// voices of a parallel block).
    private func rackSpec(for plugins: [ObjectPlugin]) -> [[String: Any]] {
        plugins.map { p in
            if let rack = p.rack {
                return ["id": p.id.uuidString,
                        "kind": "rack",
                        "voices": rack.voices.map { rackSpec(for: $0) },
                        // The effective gain (silence for muted branches) → the mute survives the recompile.
                        "wetDb": Self.effectiveWetDb(rack).map { Double($0) }]
            }
            var d: [String: Any] = [
                "id":         p.id.uuidString,
                "kind":       "plugin",
                "identifier": p.identifier,
                "format":     p.formatName,
                "name":       p.name,
                "enabled":    p.isEnabled
            ]
            // TRACE. A slot that plays from its trace hands the engine a path instead of an
            // identifier, and the compiler puts a restitution node where the plugin would have
            // gone — same id, same place, same bypass, same ordering. It goes through the SAME
            // spec entry on purpose: a second path would be a second thing to keep in step.
            // @see EditViewModel.playsFromTrace, docs/objekat-capture-trace.md
            if playsFromTrace(p), let ref = p.trace, let url = traceURL(ref) {
                d["tracePath"] = url.path
                d["name"] = ref.pluginName.isEmpty ? p.name : ref.pluginName
            } else if let s = p.stateXML, !s.isEmpty {
                d["stateXML"] = s
            }
            return d
        }
    }

    /// (Re)compiles the object's engine rack from the `plugins` given, then removes from the model
    /// the plugins the engine could not resolve (not found). Returns those ids.
    ///
    /// `retryingTraces` is the recursion guard of the one exception below; callers leave it alone.
    @discardableResult
    func compileRack(objectID: UUID, plugins: [ObjectPlugin],
                     chainInDb: Float, chainOutDb: Float,
                     retryingTraces: Bool = true) -> [UUID] {
        guard let engine else { return [] }
        let failedKeys = engine.compileUserRack(forObjectID: objectID.uuidString,
                                                tree: rackSpec(for: plugins),
                                                chainInDb: chainInDb,
                                                chainOutDb: chainOutDb) as? [String] ?? []
        let failed = Set(failedKeys.compactMap { UUID(uuidString: $0) })

        // A PLUGIN THAT DID NOT RESOLVE BUT HAS A TRACE IS NOT LOST — it switches over to it.
        // This is the case the whole trace feature exists for: the session opens on a machine
        // without the plugin, and it sounds. It has to be caught HERE, on the engine's refusal,
        // rather than by asking the catalogue whether the plugin is installed: an empty or stale
        // catalogue would answer wrongly, and the price of a wrong answer is a slot removed from
        // the model, taking its trace reference with it. A failure to resolve is a fact.
        //
        // One retry only: a trace entry always yields a valid tree, so it cannot come back in
        // `failed`. The guard is there so that a future change cannot turn this into a loop.
        if !failed.isEmpty, retryingTraces {
            let switchable = failed.filter { id in
                EditViewModel.findPlugin(id, in: plugins).flatMap { usableTrace(for: $0) } != nil
            }
            if !switchable.isEmpty {
                for id in switchable {
                    updateChainPlugins(objectID) { list in
                        list = EditViewModel.mappingPlugin(id, in: list) { p in
                            var n = p; n.trace?.forced = true; return n
                        }
                    }
                }
                let refreshed = chainPlugins(objectID) ?? plugins
                return compileRack(objectID: objectID, plugins: refreshed,
                                   chainInDb: chainInDb, chainOutDb: chainOutDb,
                                   retryingTraces: false)
            }
        }

        if !failed.isEmpty {
            // During a load, remembers the name of the plugins that cannot be found (before removing them from the
            // model) for the summary confirmation message — see applyProjectDocument.
            if missingPluginCapture != nil {
                for name in Self.pluginDisplayNames(failed, in: plugins) {
                    missingPluginCapture?.insert(name)
                }
            }
            updateChainPlugins(objectID) { p in p = Self.removingPlugins(failed, from: p) }
        }
        // The chain start/end trims carry the `chainInGain`/`chainOutGain` curves:
        // a compilation makes them anew. No effect for a BUS (stem or master), which is
        // not a sound object and has no automation.
        pushAutomation(objectID)
        return Array(failed)
    }

    /// The variant that reads the plugins + chain gains from the current model (object OR bus).
    @discardableResult
    func compileRack(objectID: UUID) -> [UUID] {
        guard let plugins = chainPlugins(objectID) else { return [] }
        let g = chainGains(objectID)
        return compileRack(objectID: objectID, plugins: plugins,
                           chainInDb: g.inDb, chainOutDb: g.outDb)
    }

    /// The chain start (output:false) / end (output:true) gain in dB: model + the live plugin (cheap).
    /// If the rack does not exist yet (an object with no chain), it is materialised once (compile).
    func setChainGain(objectID: UUID, output: Bool, dB: Float) {
        setChainGainModel(objectID, output: output, dB: dB)
        recordAutomationTouch(objectID, output ? .chainOutGain : .chainInGain)
        let applied = engine?.setChainGain(dB, output: output, objectID: objectID.uuidString) ?? false
        if !applied { compileRack(objectID: objectID) }   // creates the rack + gains from the model
        isDirty = true
    }

    /// The display names ("Name [FORMAT]") of the plugins whose id is in `ids`, looked up
    /// recursively (the voices of parallel blocks included). Used by the "missing plugins" message.
    static func pluginDisplayNames(_ ids: Set<UUID>, in plugins: [ObjectPlugin]) -> [String] {
        var out: [String] = []
        for p in plugins {
            if let rack = p.rack {
                for v in rack.voices { out += pluginDisplayNames(ids, in: v) }
            } else if ids.contains(p.id) {
                out.append("\(p.name) [\(p.formatName)]")
            }
        }
        return out
    }

    /// Recursively removes (voices included) the plugins whose id is in `ids`.
    static func removingPlugins(_ ids: Set<UUID>, from plugins: [ObjectPlugin]) -> [ObjectPlugin] {
        plugins.compactMap { p in
            if let rack = p.rack {
                var np = p
                np.rack?.voices = rack.voices.map { removingPlugins(ids, from: $0) }
                return np
            }
            return ids.contains(p.id) ? nil : p
        }
    }

    func addPlugin(objectID: UUID, available: AvailablePlugin) {
        // Plugins ARE allowed on a sound-object instance: they apply to the baked
        // submix, and stay proper to THAT instance. On opening as on detaching,
        // they are carried over AFTER the restored internal plugins (see openObject / detachFromDefinition).
        guard chainPlugins(objectID) != nil, engine != nil else { return }
        let plug = ObjectPlugin(id: UUID(), name: available.name,
                                manufacturer: available.manufacturer,
                                identifier: available.identifier,
                                formatName: available.formatName)
        pushUndo()
        updateChainPlugins(objectID) { $0.append(plug) }
        if compileRack(objectID: objectID).contains(plug.id) {
            // Not found: compileRack has already removed the entry from the model → purge the catalogue.
            availablePlugins.removeAll { $0.identifier == available.identifier && $0.formatName == available.formatName }
        } else if plug.isBuiltIn {
            openBuiltInPluginEditor(plug: plug)
        } else {
            openPluginEditor(objectID: objectID, pluginID: plug.id)
        }
        isDirty = true
    }

    // MARK: - Instruments (MIDI clips)

    /// (Re)pushes the MIDI clip's instrument to the engine (slot index 0, outside the FX rack). Step A: a
    /// single instrument — the first of `instruments` is taken. Empty ⇒ removes the engine instrument.
    func syncInstruments(_ object: SoundObject) {
        guard let engine else { return }
        if let inst = object.instruments.first {
            var info: [String: Any] = [
                "pluginKey":  inst.id.uuidString,
                "identifier": inst.identifier,
                "format":     inst.formatName,
                "name":       inst.name
            ]
            if let s = inst.stateXML, !s.isEmpty { info["stateXML"] = s }
            // A perf note: each MIDI clip carries ITS instrument, so duplicating / cutting
            // a clip instantiates one more AU (+ restoring its state). It is the second suspect
            // when those gestures drag — the other being the undo snapshot's state capture.
            let t0 = CFAbsoluteTimeGetCurrent()
            engine.setInstrument(info, forObjectID: object.id.uuidString, stateXML: inst.stateXML)
            let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            if ms >= 1 { NSLog("[PERF] instrument \"%@\" instantiated in %.0f ms", inst.name, ms) }
            // A LINKED instrument: the link arms on the instance that has just been born — otherwise a
            // MIDI clip with no FX never went through `syncPlugins`, the only caller of the rewiring,
            // and reopening the project left the link silent. Idempotent, and the siblings not yet
            // instantiated are caught up by the next pass (the same contract as syncPlugins).
            if inst.linkGroupID != nil { rewireLinkGroups() }
        } else {
            engine.removeInstrument(forObjectID: object.id.uuidString)
        }
    }

    /// Assigns a virtual instrument to a MIDI clip (replacing any current one), then pushes it
    /// to the engine. No effect on an object that is not a MIDI clip.
    func setInstrument(objectID: UUID, available: AvailablePlugin) {
        guard let obj = find(id: objectID), obj.isMIDI, engine != nil else { return }
        let inst = ObjectPlugin(id: UUID(), name: available.name,
                                manufacturer: available.manufacturer,
                                identifier: available.identifier,
                                formatName: available.formatName)
        pushUndo()
        update(id: objectID) { $0.instruments = [inst] }
        if let updated = find(id: objectID) { syncInstruments(updated) }
        isDirty = true
    }

    /// Removes a MIDI clip's instrument (model + engine).
    func removeInstrument(objectID: UUID) {
        guard find(id: objectID) != nil, engine != nil else { return }
        pushUndo()
        update(id: objectID) { $0.instruments = [] }
        engine?.removeInstrument(forObjectID: objectID.uuidString)
        isDirty = true
    }

    /// Toggles the bypass of a MIDI clip's INSTRUMENT. It does not live in the FX chain
    /// (`plugins`) but in `instruments`: `togglePluginEnabled`, which looks in the chain,
    /// did not find it and its on/off button stayed inert. On the engine side, on the other hand, it is
    /// an instance like the others, registered in the same `_pluginMap` (@see setInstrument:) —
    /// so the realtime bypass applies to it in exactly the same way, with no recompile.
    func toggleInstrumentEnabled(objectID: UUID, pluginID: UUID) {
        guard let engine,
              let inst = find(id: objectID)?.instruments.first(where: { $0.id == pluginID })
        else { return }
        let newEnabled = !inst.isEnabled
        engine.setPlugin(pluginID.uuidString, enabled: newEnabled, forObjectID: objectID.uuidString)
        update(id: objectID) { o in
            o.instruments = o.instruments.map { p in
                guard p.id == pluginID else { return p }
                var q = p
                q.isEnabled = newEnabled
                return q
            }
        }
        isDirty = true
    }

    /// The object hosting `pluginID` as its instrument, if one does. Used by the drop: an
    /// instrument dropped onto another object does not join its FX chain (it needs MIDI as its
    /// input) but its instrument SLOT — @see transferInstrument.
    func isInstrument(_ pluginID: UUID, of objectID: UUID) -> Bool {
        find(id: objectID)?.instruments.contains { $0.id == pluginID } ?? false
    }

    /// Dragging a MIDI clip's instrument onto another MIDI clip: it takes the place of
    /// the target's instrument (an object hosts only one, @see setInstrument). `copy` (⌥)
    /// leaves the original in place, otherwise the source ends up with no instrument — the same
    /// convention as `copyPlugin` / `movePlugin` for the FX chain. The instance's current state
    /// is captured along the way: the target sounds as the source sounded.
    /// No effect if the target is not a MIDI clip (nothing else has an instrument slot).
    ///
    /// `linked` (⌘): the copy joins the source's LINK GROUP — setting one sets
    /// the other, like two linked FX (@see linkAcrossObjects). Ignored if `copy` is false: a
    /// move has nobody to link itself to, it simply carries the existing group with it.
    func transferInstrument(sourceObjectID: UUID, pluginID: UUID, targetObjectID: UUID,
                            copy: Bool, linked: Bool = false) {
        guard let engine,
              let inst = find(id: sourceObjectID)?.instruments.first(where: { $0.id == pluginID }),
              find(id: targetObjectID)?.isMIDI == true,
              sourceObjectID != targetObjectID else { return }
        let live = engine.getPluginStateXML(pluginID.uuidString)
        let stateXML = (live?.isEmpty == false) ? live : inst.stateXML
        // The link membership of the instance laid down, one per gesture:
        //  • a move — the same logical instance elsewhere: it carries its group, active or
        //    dormant (a detached instrument stays reattachable after a move);
        //  • ⌘ copy+link — it joins the source's group, or the group the source
        //    had LEFT rather than opening another (the same rule as linkAcrossObjects);
        //  • ⌥ copy — an INDEPENDENT instance, no group (the same rule as copyPlugin).
        let gid: UUID?
        let detached: UUID?
        if !copy                { gid = inst.linkGroupID; detached = inst.detachedLinkGroupID }
        else if linked          { gid = inst.effectiveLinkGroupID ?? UUID(); detached = nil }
        else                    { gid = nil; detached = nil }
        // A BRAND-NEW UUID: the engine's `_pluginMap` key is the model's id — reusing the
        // source's would make both slots point at the same entry (@see copiedInstruments).
        let placed = ObjectPlugin(id: UUID(), name: inst.name, manufacturer: inst.manufacturer,
                                  identifier: inst.identifier, formatName: inst.formatName,
                                  isEnabled: inst.isEnabled, stateXML: stateXML,
                                  linkGroupID: gid, detachedLinkGroupID: detached,
                                  colorIndex: inst.colorIndex)
        pushUndo()
        if copy && linked, let gid, inst.linkGroupID == nil {
            // The source was not linked yet: it enters the group with the copy.
            setLinkGroups(objectID: sourceObjectID, pluginID: pluginID, link: gid, detached: nil)
        }
        if !copy {
            update(id: sourceObjectID) { $0.instruments = [] }
            engine.removeInstrument(forObjectID: sourceObjectID.uuidString)
        }
        update(id: targetObjectID) { $0.instruments = [placed] }
        // syncInstruments creates the engine instance: the link can only arm AFTER
        // (setPluginLinkGroup returns doing nothing if the key is not in the `_pluginMap`).
        if let updated = find(id: targetObjectID) { syncInstruments(updated) }
        if let gid {
            if copy && linked {
                engine.setPluginLinkGroup(pluginID.uuidString, groupID: gid.uuidString)
            }
            engine.setPluginLinkGroup(placed.id.uuidString, groupID: gid.uuidString)
        }
        isDirty = true
    }

    func removePlugin(objectID: UUID, pluginID: UUID) {
        guard chainPlugins(objectID) != nil, engine != nil else { return }
        pushUndo()
        // The touch listening RETAINS the plugin: leaving it armed would keep it alive after it has been
        // removed from the chain. And what was known of its parameters is worth nothing any more.
        endPluginParamTouchWatch(pluginID)
        invalidatePluginParamInfos(pluginID)
        // Removes the plugin then folds the tree back (emptied branches removed, a 1-branch parallel inlined).
        updateChainPlugins(objectID) { p in
            p = Self.simplifyTree(Self.removingPlugins([pluginID], from: p))
        }
        compileRack(objectID: objectID)
        isDirty = true
    }

    func togglePluginEnabled(objectID: UUID, pluginID: UUID) {
        // Recursive reads/writes: the plugin may live in a branch of a parallel block.
        guard let plugins = chainPlugins(objectID),
              let plug = Self.flattenLeaves(plugins).first(where: { $0.id == pluginID }),
              let engine else { return }
        let newEnabled = !plug.isEnabled
        // A realtime bypass (honoured in the rack by PluginNode) — no need to recompile.
        engine.setPlugin(pluginID.uuidString, enabled: newEnabled, forObjectID: objectID.uuidString)
        updateChainPlugins(objectID) { p in p = Self.settingEnabled(pluginID, newEnabled, in: p) }
        isDirty = true
    }

    func getPluginParams(pluginID: UUID) -> [(index: Int, name: String, value: Float, min: Float, max: Float, valueString: String)] {
        guard let engine else { return [] }
        let raw = engine.getPluginParams(pluginID.uuidString) as? [[String: Any]] ?? []
        return raw.enumerated().compactMap { idx, d in
            guard let name = d["name"] as? String,
                  let value = d["value"] as? Float,
                  let min   = d["minValue"] as? Float,
                  let max   = d["maxValue"] as? Float,
                  let vs    = d["valueAsString"] as? String
            else { return nil }
            return (index: idx, name: name, value: value, min: min, max: max, valueString: vs)
        }
    }

    func setPluginParam(pluginID: UUID, index: Int, value: Float) {
        engine?.setPluginParam(pluginID.uuidString, index: Int32(index), value: value)
        // This parameter becomes its object's "automation to come" row. The index is translated
        // into a `paramID` — that is what `ParamRef` addresses, and the index of an external plugin is
        // only stable for a given instance.
        if let pid = pluginParamInfos(pluginID).first(where: { $0.value.index == index })?.key {
            recordPluginParamTouch(pluginKey: pluginID, paramID: pid)
        }
        isDirty = true
    }

    func openPluginEditor(objectID: UUID, pluginID: UUID) {
        guard let engine else { return }
        let colorIndex = leafPlugins(objectID: objectID).first(where: { $0.id == pluginID })?.colorIndex ?? 0
        engine.openPluginEditor(pluginID.uuidString, colorHex: ObjekatPalette.pluginHex(colorIndex))
        // The opening is ASYNCHRONOUS (the engine waits for the instance to be loaded); arming
        // the listening straight away is risk-free — it returns by itself if the plugin is not
        // in the `_pluginMap` yet, and the user cannot touch anything before the window
        // exists. The closing, for its part, goes through `onEditorVisibilityChanged`.
        beginPluginParamTouchWatch(pluginID)
    }

    /// Closes a plugin's editor, native or built-in, if it is open.
    func closePluginEditor(plug: ObjectPlugin) {
        if let controller = builtInEditorWindows[plug.id] {
            // `close()` triggers the controller's callback, which cleans up the map, the parameter-touch
            // listening and `openEditorPluginID` — do nothing more here.
            controller.close()
            return
        }
        engine?.closePluginEditor(plug.id.uuidString)
    }

    /// Is this plugin's editor open? (a JUCE window for an external one, a Swift NSWindow
    /// for a built-in). `openEditorPluginID` is not enough: it retains only the LAST
    /// editor opened whereas several can be open at once.
    func isPluginEditorOpen(plug: ObjectPlugin) -> Bool {
        if builtInEditorWindows[plug.id] != nil { return true }
        return engine?.isPluginEditorOpen(plug.id.uuidString) ?? false
    }

    /// Opens the editor, or CLOSES it if it is already open. It is the double-click gesture on
    /// a synoptic card: the same gesture opens and closes, without having to aim at the cross of
    /// the plugin's window.
    func togglePluginEditor(objectID: UUID, plug: ObjectPlugin) {
        if isPluginEditorOpen(plug: plug) {
            closePluginEditor(plug: plug)
        } else if plug.isBuiltIn {
            openBuiltInPluginEditor(plug: plug)
        } else {
            openPluginEditor(objectID: objectID, pluginID: plug.id)
        }
    }

    /// Lowers (false) or restores (true) the "always in front" level of the editors,
    /// native AND built-in. Called by the plugin browser for as long as it is shown: an
    /// AppKit popover lives at the normal level and cannot come in front of a floating window,
    /// so it is the floating windows that come down. Idempotent.
    func setPluginEditorsFloating(_ floating: Bool) {
        engine?.setPluginEditorsFloating(floating)
        for controller in builtInEditorWindows.values {
            controller.window?.level = floating ? .floating : .normal
        }
    }

    /// Opens (or brings back to the front if already open) the editor window of a Tracktion
    /// built-in plugin. The counterpart of `openPluginEditor` for external plugins — the same role
    /// (`openEditorPluginID`), but with a window managed on the Swift side rather than by the JUCE engine
    /// since the built-in UI is already 100% SwiftUI (@see BuiltInPluginEditorWindowController).
    func openBuiltInPluginEditor(plug: ObjectPlugin) {
        if let existing = builtInEditorWindows[plug.id] {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = BuiltInPluginEditorWindowController(plug: plug, viewModel: self) { [weak self] in
            guard let self else { return }
            self.builtInEditorWindows[plug.id] = nil
            if self.openEditorPluginID == plug.id { self.openEditorPluginID = nil }
            self.endPluginParamTouchWatch(plug.id)
        }
        controller.window?.level = .floating
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        builtInEditorWindows[plug.id] = controller
        openEditorPluginID = plug.id
        beginPluginParamTouchWatch(plug.id)
    }

    func pluginInstanceState(pluginID: UUID) -> Int {
        Int(engine?.pluginInstanceState(pluginID.uuidString) ?? 0)
    }

    func pluginLoadError(pluginID: UUID) -> String? {
        engine?.pluginLoadError(pluginID.uuidString)
    }

    /// The audio level measured (0..1) at the output of a plugin in the rack (the synoptic meter).
    func pluginAudioLevel(objectID: UUID, pluginID: UUID) -> Double {
        Double(engine?.audioLevel(forPluginKey: pluginID.uuidString, forObjectID: objectID.uuidString) ?? 0)
    }

    /// The transport playing (so as to poll the meter only during playback).
    var isTransportPlaying: Bool { engine?.isCurrentlyPlaying() ?? false }

    /// Clones the instrument (slot index 0 of a MIDI clip) for a NEW object: a BRAND-NEW
    /// UUID (indispensable — the `_pluginMap` key on the engine side is `ObjectPlugin.id`;
    /// reusing the id would make every paste point at the same entry, so only
    /// the last would stay editable) + the state captured live if the source instance
    /// still exists, otherwise falling back on the `stateXML` already carried by the model (a clipboard
    /// fragment whose original has gone, frozen through `withCapturedPluginStates`).
    func copiedInstruments(of object: SoundObject) -> [ObjectPlugin] {
        object.instruments.map { inst in
            let live = engine?.getPluginStateXML(inst.id.uuidString)
            return ObjectPlugin(id: UUID(), name: inst.name, manufacturer: inst.manufacturer,
                                identifier: inst.identifier, formatName: inst.formatName,
                                isEnabled: inst.isEnabled,
                                stateXML: (live?.isEmpty == false) ? live : inst.stateXML)
        }
    }

    /// Clones an object's plugin list for a NEW object (paste / duplicate /
    /// split): new UUIDs AND the state (`stateXML`) captured live from the engine
    /// when the source instance still exists, otherwise falling back on the `stateXML` already carried
    /// by the model (the case of a clipboard fragment whose original has gone —
    /// frozen at copy/cut time through `withCapturedPluginStates`).
    /// Without this, `syncPlugins` recreates the plugins at their default values.
    ///
    /// LINKED BY DEFAULT: the copy joins the source's link group. If the source
    /// was not linked yet AND it is alive in the model, a group is created
    /// and the source is registered in it too (a backfill) → original + copy become linked.
    /// (For a clipboard fragment whose original has gone, the backfill fails
    /// silently → the copy stays independent: there is nobody to link itself to.)
    func copiedPlugins(of object: SoundObject) -> [ObjectPlugin] {
        // Recursive: it preserves the parallel blocks (a rack carrier clones its voices with
        // new ids). Linking by default (the backfill) applies only to the first-level leaves.
        func copyLeaf(_ p: ObjectPlugin, topLevel: Bool) -> ObjectPlugin {
            let live = engine?.getPluginStateXML(p.id.uuidString)
            let capturedXML = (live?.isEmpty == false) ? live : nil
            var groupID = p.linkGroupID
            let newGroup: UUID? = (topLevel && groupID == nil) ? UUID() : nil

            // ONE write onto the ORIGINAL, for two reasons:
            //  • LINKING BY DEFAULT (the group's backfill, see above);
            //  • the state just re-read from the engine, put back into ITS model. Without this the
            //    source kept a stale `stateXML` — its setting lived only in
            //    the engine instance — and the first recompilation to come along (undo, regrouping,
            //    reloading) brought it back to its factory settings, while the copy, for its part,
            //    left with the right state.
            if newGroup != nil || capturedXML != nil {
                let written = update(id: object.id) { obj in
                    if let newGroup {
                        obj.plugins = Self.settingLinkGroup(p.id, newGroup, in: obj.plugins)
                    }
                    if let xml = capturedXML {
                        obj.plugins = Self.settingStateXML(p.id, xml, in: obj.plugins)
                    }
                }
                if written, let newGroup { groupID = newGroup }
            }
            return ObjectPlugin(id: UUID(), name: p.name, manufacturer: p.manufacturer,
                                identifier: p.identifier, formatName: p.formatName,
                                isEnabled: p.isEnabled,
                                stateXML: capturedXML ?? p.stateXML,
                                linkGroupID: groupID, colorIndex: p.colorIndex)
        }
        func copySeries(_ plugins: [ObjectPlugin], topLevel: Bool) -> [ObjectPlugin] {
            plugins.map { p in
                if let rack = p.rack {
                    return ObjectPlugin(id: UUID(), name: p.name, manufacturer: p.manufacturer,
                                        identifier: p.identifier, formatName: p.formatName,
                                        isEnabled: p.isEnabled,
                                        rack: PluginRack(voices: rack.voices.map { copySeries($0, topLevel: false) },
                                                         wetDb: rack.wetDb,
                                                         voiceMutes: rack.voiceMutes))
                }
                return copyLeaf(p, topLevel: topLevel)
            }
        }
        return copySeries(object.plugins, topLevel: true)
    }

    // MARK: - LINK between plugin instances

    /// The data for the overlay when a plugin's editor is open. Always: the source clip
    /// is highlighted (an "active" halo). If the plugin is linked: the group's other clips
    /// are highlighted too + joined by the star. If not linked: a single clip.
    struct LinkOverlayInfo {
        let sourceObjectID: UUID        // the clip whose editor is open (an emphasised halo)
        let memberObjectIDs: [UUID]     // the clips to highlight (the source included; >1 if linked)
        let color: Color                // the identity colour OF THIS plugin (@see ObjectPlugin.color)
    }

    var linkOverlayInfo: LinkOverlayInfo? {
        guard let pid = openEditorPluginID else { return nil }
        let refs = allPluginRefs()
        guard let src = refs.first(where: { $0.plugin.id == pid }) else { return nil }
        let members: [UUID]
        if let gid = src.plugin.linkGroupID {
            members = Array(Set(refs.filter { $0.plugin.linkGroupID == gid }.map { $0.objectID }))
        } else {
            members = [src.objectID]   // not linked → highlight the single edited clip
        }
        return LinkOverlayInfo(sourceObjectID: src.objectID, memberObjectIDs: members, color: src.plugin.color)
    }

    /// (Re)establishes on the engine side every link the model describes. Idempotent.
    /// Called at the end of `syncPlugins` → covers project loading, paste, split, groups.
    func rewireLinkGroups() {
        guard let engine else { return }
        func walk(_ arr: [SoundObject]) {
            for obj in arr {
                // Instruments included: they live outside the FX chain (`instruments`) but
                // on the engine side they are in the same `_pluginMap`, hence linkable like the FX.
                for p in Self.flattenLeaves(obj.plugins) + obj.instruments where p.linkGroupID != nil {
                    engine.setPluginLinkGroup(p.id.uuidString, groupID: p.linkGroupID!.uuidString)
                }
                if case .group(let children, _) = obj.kind { walk(children) }
            }
        }
        walk(items)
    }

    /// Every (objectID, plugin) instance in the project, flattened (recursively).
    func allPluginRefs() -> [(objectID: UUID, plugin: ObjectPlugin)] {
        var out: [(UUID, ObjectPlugin)] = []
        func walk(_ arr: [SoundObject]) {
            for obj in arr {
                // Flattened leaves: includes the plugins in the parallel branches (excludes the
                // rack carriers). Without this, link/siblings would ignore the nested plugins.
                // The INSTRUMENT slot counts as an instance: it links, unlinks and
                // counts like an FX (@see transferInstrument).
                for p in Self.flattenLeaves(obj.plugins) + obj.instruments { out.append((obj.id, p)) }
                if case .group(let children, _) = obj.kind { walk(children) }
            }
        }
        walk(items)
        return out
    }

    /// An instance carried by a host, an FX chain **or** an instrument slot. The link does not tell
    /// the two apart: on the engine side they are in the same `_pluginMap` (@see setInstrument:).
    func hostedPlugin(_ pluginID: UUID, of hostID: UUID) -> ObjectPlugin? {
        if let p = leafPlugins(objectID: hostID).first(where: { $0.id == pluginID }) { return p }
        return find(id: hostID)?.instruments.first { $0.id == pluginID }
    }

    /// Writes both link memberships of an instance in one go, wherever it lives:
    /// in the host's FX chain (recursive over the branches) or in its instrument slot.
    func setLinkGroups(objectID: UUID, pluginID: UUID, link: UUID?, detached: UUID?) {
        if isInstrument(pluginID, of: objectID) {
            update(id: objectID) { o in
                o.instruments = o.instruments.map { p in
                    guard p.id == pluginID else { return p }
                    var q = p
                    q.linkGroupID         = link
                    q.detachedLinkGroupID = detached
                    return q
                }
            }
        } else {
            updateChainPlugins(objectID) { p in
                p = Self.settingLinkGroup(pluginID, link, in: p)
                p = Self.settingDetachedLinkGroup(pluginID, detached, in: p)
            }
        }
    }

    /// The other instances of `pluginID`'s group, ACTIVE OR DETACHED. A detached member
    /// stays part of the group — that is what makes it countable in the labels and lets it find
    /// its peers again when it comes back (@see ObjectPlugin.detachedLinkGroupID).
    func linkSiblings(of pluginID: UUID) -> [(objectID: UUID, plugin: ObjectPlugin)] {
        guard let gid = allPluginRefs().first(where: { $0.plugin.id == pluginID })?
                            .plugin.effectiveLinkGroupID
        else { return [] }
        return allPluginRefs().filter { $0.plugin.effectiveLinkGroupID == gid && $0.plugin.id != pluginID }
    }

    /// Takes an instance out of its link group — without LOSING the group: its identity is
    /// recorded in `detachedLinkGroupID`, so that a second click on the icon (still
    /// visible, muted) brings it back. @see relinkPlugin
    ///
    /// Dissolution: if the departure leaves fewer than two active members, the last is detached
    /// too — a group of one synchronises nothing. It keeps the same identity, so the
    /// two stay reunitable with each other.
    func unlinkPlugin(objectID: UUID, pluginID: UUID) {
        guard let plug = hostedPlugin(pluginID, of: objectID),
              let gid = plug.linkGroupID else { return }
        pushUndo()
        detachLink(objectID: objectID, pluginID: pluginID, group: gid)
        let remaining = allPluginRefs().filter { $0.plugin.linkGroupID == gid }
        if remaining.count < 2 {
            for r in remaining { detachLink(objectID: r.objectID, pluginID: r.plugin.id, group: gid) }
        }
        isDirty = true
    }

    /// Brings a detached instance back into its group. It ADOPTS the group's settings: it is the one
    /// that aligns on the others, never the reverse — coming back into a group must not
    /// crush what the members who stayed have set in the meantime.
    func relinkPlugin(objectID: UUID, pluginID: UUID) {
        guard let plug = hostedPlugin(pluginID, of: objectID),
              let gid = plug.detachedLinkGroupID else { return }
        pushUndo()
        setLinkGroups(objectID: objectID, pluginID: pluginID, link: gid, detached: nil)
        engine?.relinkPluginAdoptingGroup(pluginID.uuidString, groupID: gid.uuidString)
        isDirty = true
    }

    /// Cuts the synchronisation on the engine side and switches the group from active to "dormant".
    private func detachLink(objectID: UUID, pluginID: UUID, group: UUID) {
        engine?.clearPluginLinkGroup(pluginID.uuidString)
        setLinkGroups(objectID: objectID, pluginID: pluginID, link: nil, detached: group)
    }

    /// An alt-drop: instantiates the SAME plugin on the target object (with the source's current
    /// state) and links it to the source. Creates the group if the source was not linked yet.
    func linkAcrossObjects(sourceObjectID: UUID, sourcePluginID: UUID, targetObjectID: UUID) {
        // Hosts, not objects: the source as well as the target can be a stem BUS, whose
        // chain does not live in `items` (@see chainPlugins/updateChainPlugins). Going through
        // `find`/`update` here left the stem's chain intact — a move from a
        // stem behaved like a copy.
        guard let engine,
              let src = leafPlugins(objectID: sourceObjectID).first(where: { $0.id == sourcePluginID }),
              chainPlugins(targetObjectID) != nil else { return }
        let live = engine.getPluginStateXML(sourcePluginID.uuidString)
        let stateXML = (live?.isEmpty == false) ? live : src.stateXML
        // A DETACHED source: it is put back into ITS group rather than opening another — otherwise
        // it would drag a dormant group around while an active link holds it elsewhere.
        let gid = src.effectiveLinkGroupID ?? UUID()
        let newID = UUID()
        pushUndo()
        if src.linkGroupID == nil {
            updateChainPlugins(sourceObjectID) { p in
                p = Self.settingDetachedLinkGroup(sourcePluginID, nil, in: p)
                p = Self.settingLinkGroup(sourcePluginID, gid, in: p)
            }
        }
        let copy = ObjectPlugin(id: newID, name: src.name, manufacturer: src.manufacturer,
                                identifier: src.identifier, formatName: src.formatName,
                                isEnabled: src.isEnabled, stateXML: stateXML, linkGroupID: gid,
                                colorIndex: src.colorIndex)
        updateChainPlugins(targetObjectID) { $0.append(copy) }
        compileRack(objectID: targetObjectID)   // creates the target instance (its state restored from the stateXML)
        engine.setPluginLinkGroup(sourcePluginID.uuidString, groupID: gid.uuidString)
        engine.setPluginLinkGroup(newID.uuidString, groupID: gid.uuidString)
        isDirty = true
    }

    /// A drag with NO modifier: moves the plugin from one clip to another (removed from the source).
    /// Keeps `linkGroupID` (the same logical plugin, another clip).
    func movePlugin(sourceObjectID: UUID, pluginID: UUID, targetObjectID: UUID) {
        // The source AND the target are chain HOSTS: a sound object or a stem bus (@see
        // linkAcrossObjects, for the same reason).
        guard let engine,
              let plug = leafPlugins(objectID: sourceObjectID).first(where: { $0.id == pluginID }),
              chainPlugins(targetObjectID) != nil,
              sourceObjectID != targetObjectID else { return }
        let live = engine.getPluginStateXML(pluginID.uuidString)
        let stateXML = (live?.isEmpty == false) ? live : plug.stateXML
        let newID = UUID()
        let moved = ObjectPlugin(id: newID, name: plug.name, manufacturer: plug.manufacturer,
                                 identifier: plug.identifier, formatName: plug.formatName,
                                 isEnabled: plug.isEnabled, stateXML: stateXML,
                                 linkGroupID: plug.linkGroupID,
                                 // A detached plugin stays reattachable after a move.
                                 detachedLinkGroupID: plug.detachedLinkGroupID,
                                 colorIndex: plug.colorIndex)
        pushUndo()
        // Removes it from the source (folding the branch back if it empties) then adds it at the end of the target chain.
        updateChainPlugins(sourceObjectID) { p in p = Self.simplifyTree(Self.removingPlugins([pluginID], from: p)) }
        updateChainPlugins(targetObjectID) { $0.append(moved) }
        compileRack(objectID: sourceObjectID)   // removes the source instance from the rack
        compileRack(objectID: targetObjectID)   // creates the target instance (its state restored)
        if moved.linkGroupID != nil { rewireLinkGroups() }
        isDirty = true
    }

    /// A drag with ⌥: an INDEPENDENT copy of the plugin onto the target (a new UUID, no link).
    func copyPlugin(sourceObjectID: UUID, pluginID: UUID, targetObjectID: UUID) {
        guard let engine,
              let plug = leafPlugins(objectID: sourceObjectID).first(where: { $0.id == pluginID }),
              chainPlugins(targetObjectID) != nil else { return }
        let live = engine.getPluginStateXML(pluginID.uuidString)
        let stateXML = (live?.isEmpty == false) ? live : plug.stateXML
        let newID = UUID()
        pushUndo()
        let copy = ObjectPlugin(id: newID, name: plug.name, manufacturer: plug.manufacturer,
                                identifier: plug.identifier, formatName: plug.formatName,
                                isEnabled: plug.isEnabled, stateXML: stateXML, linkGroupID: nil)
        updateChainPlugins(targetObjectID) { $0.append(copy) }
        compileRack(objectID: targetObjectID)
        isDirty = true
    }

    func syncPlugins(_ object: SoundObject) {
        guard engine != nil else { return }
        // Recompiles the rack from the model (project loading, paste, split, groups).
        // The plugins that cannot be found are removed from the model by compileRack. enabled/bypass is
        // applied on the compiler side (setEnabled per leaf during the reconciliation).
        compileRack(objectID: object.id, plugins: object.plugins,
                    chainInDb: object.chainInGainDb, chainOutDb: object.chainOutGainDb)
        // (Re)establishes the links: the instance has just been (re)created, and so have its siblings.
        rewireLinkGroups()
    }
}
