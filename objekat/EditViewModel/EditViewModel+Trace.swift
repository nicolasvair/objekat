import AppKit
import CryptoKit
import Foundation

// MARK: - Capturing and playing back a plugin trace
//
// The model side of `docs/objekat-capture-trace.md`. What lives here:
//
//   • WHERE a trace goes — `traces/` in the project folder, referenced by file name so that
//     moving the project moves the trace with it;
//   • WHEN a slot plays from its trace rather than from its plugin — the plugin is missing on
//     this machine, or the user forced it;
//   • WHETHER a trace is still valid — the cheap, continuous check, and what it can and cannot
//     promise;
//   • the capture itself, which is two or three offline renders and therefore asynchronous.
//
// The arithmetic is NOT here. It lives in the engine, in `OBJTrace.h`, where the captures
// already are: shipping tens of megabytes of float32 across the bridge to divide them in Swift
// would buy nothing but a copy.

extension EditViewModel {

    // MARK: - Where traces live

    /// The project's `traces/` folder (nil as long as the project has not been saved). A trace
    /// needs a stable place on disk, exactly as a baked sound object does.
    var tracesFolder: URL? {
        projectFolder?.appendingPathComponent("traces", isDirectory: true)
    }

    /// The absolute path of a trace, or nil if the project has no folder yet.
    func traceURL(_ ref: PluginTraceRef) -> URL? {
        tracesFolder?.appendingPathComponent(ref.fileName)
    }

    // MARK: - Should this slot play its plugin, or its trace?

    /// Is this plugin actually installed on this machine? The Tracktion built-ins always are.
    func isPluginInstalled(_ plugin: ObjectPlugin) -> Bool {
        if plugin.isBuiltIn || plugin.isRack { return true }
        return availablePlugins.contains { $0.identifier == plugin.identifier
                                        && $0.formatName == plugin.formatName }
    }

    /// True when the chain must compile this slot as a TRACE instead of as its plugin.
    ///
    /// Two ways in, and they are not the same thing. The plugin being ABSENT is the feature's
    /// whole point: the session opens and sounds instead of showing an error. `forced` is the
    /// other, and it earns its place by being the only way to hear the trace on a machine that
    /// has the plugin — which is to say the only way to check the restitution at all.
    func playsFromTrace(_ plugin: ObjectPlugin) -> Bool {
        guard let ref = plugin.trace else { return false }
        guard let url = traceURL(ref), FileManager.default.fileExists(atPath: url.path) else {
            return false   // a reference with no file behind it: fall back to the plugin
        }
        return ref.forced || !isPluginInstalled(plugin)
    }

    // MARK: - Is the trace still valid?

    /// The health of a slot's trace, staleness included.
    ///
    /// TWO CHECKS, and it matters not to confuse them.
    ///
    /// The one done HERE is cheap and continuous: a signature of everything upstream of the
    /// plugin in the model — the object's source, its window, the chain's input trim, and every
    /// plugin that comes before this one with its state. Change any of it and the input signal
    /// has changed, so the trace no longer describes it. It costs nothing and it can run on
    /// every redraw.
    ///
    /// It is a PROXY, not the promise. The promise is the fingerprint of `x[n]` in the trace's
    /// own header, and comparing it means capturing `x` again — a whole render. That check is
    /// available on demand (`plugin.trace.verify`), and it is the one that answers for real.
    /// This one answers "something upstream moved", which is enough to colour a badge as a
    /// warning and to stop claiming the reconstruction is guaranteed.
    func traceHealth(_ plugin: ObjectPlugin, on hostID: UUID) -> PluginTraceHealth? {
        guard let ref = plugin.trace else { return nil }
        if let recorded = traceSignatures[plugin.id],
           recorded != upstreamSignature(of: plugin.id, on: hostID) {
            return .stale
        }
        return ref.health
    }

    /// A stable digest of everything that feeds `pluginID` in `hostID`'s chain.
    ///
    /// What goes in is exactly what changes `x[n]`: the host's own content and window, the
    /// chain's input trim, and each plugin ahead of the target — its identity, its bypass and
    /// its saved state. What comes AFTER the target is deliberately left out: it cannot reach
    /// the plugin's input, and folding it in would make the trace go stale every time an
    /// unrelated reverb downstream was touched.
    func upstreamSignature(of pluginID: UUID, on hostID: UUID) -> String {
        var parts: [String] = []

        if let host = find(id: hostID) {
            parts.append("window:\(host.startTime):\(host.duration)")
            parts.append("gain:\(chainGains(hostID).inDb)")
            switch host.kind {
            case .clip(let path, let offset, let dur, let speed, let reversed):
                parts.append("clip:\((path as NSString).lastPathComponent):\(offset):\(dur):\(speed):\(reversed)")
            case .midiClip(let notes, let lengthBeats):
                parts.append("midi:\(notes.count):\(lengthBeats)")
                for n in notes { parts.append("n:\(n.pitch):\(n.startBeat):\(n.lengthBeats):\(n.velocity)") }
                for i in host.instruments { parts.append("inst:\(i.identifier):\(i.isEnabled):\(i.stateXML?.count ?? 0)") }
            case .group(let children, _):
                // A group's input is the sum of its children after their own processing. We take
                // their identity and placement rather than walking their whole chain: a signature
                // that never triggers is useless, one that recurses forever is unaffordable.
                for c in children {
                    parts.append("child:\(c.id):\(c.startTime):\(c.duration):\(c.volume):\(c.pan):\(c.isMuted):\(c.plugins.count)")
                }
            case .aux:
                parts.append("aux")
            }
        } else if let i = stemIndex(hostID) {
            parts.append("stem:\(stems[i].chainInGainDb)")
        }

        // Everything strictly BEFORE the target, in chain order, branches flattened the way the
        // compiler lays them out.
        var reached = false
        func walk(_ plugins: [ObjectPlugin]) {
            for p in plugins where !reached {
                if p.id == pluginID { reached = true; return }
                if let rack = p.rack {
                    parts.append("rack:\(p.id):\(rack.voices.count)")
                    for (i, v) in rack.voices.enumerated() {
                        parts.append("voice:\(i):\(rack.wetDb.indices.contains(i) ? rack.wetDb[i] : 0)")
                        walk(v)
                    }
                } else {
                    parts.append("fx:\(p.identifier):\(p.formatName):\(p.isEnabled):\(p.stateXML ?? "")")
                }
            }
        }
        walk(chainPlugins(hostID) ?? [])

        let joined = parts.joined(separator: "\u{1}")
        let digest = SHA256.hash(data: Data(joined.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Capturing

    /// Captures the trace of one plugin. Asynchronous: two or three offline renders.
    ///
    /// `completion` gets the engine's report — `ok`, and on success the flags and residuals the
    /// panel shows. The model is updated before it is called.
    func captureTrace(hostID: UUID, pluginID: UUID,
                      preRoll: Double = 2.0, tail: Double = 5.0,
                      forced: Bool = false,
                      reportsToUser: Bool = true,
                      completion: (([String: Any]) -> Void)? = nil) {
        guard let engine else { completion?(Self.traceFailure("no_engine")); return }

        guard let folder = tracesFolder else {
            bakeAlert(L("trace.error.saveFirst.title"), L("trace.error.saveFirst.info"))
            completion?(Self.traceFailure("not_saved"))
            return
        }

        guard let plugins = chainPlugins(hostID),
              let plugin = Self.findPlugin(pluginID, in: plugins), !plugin.isRack else {
            completion?(Self.traceFailure("unknown_plugin"))
            return
        }

        // A trace is captured against the LIVE signal, so a capture on a host being baked, or
        // while another capture runs, would describe a graph that is about to change.
        guard !isCapturingTrace, !isBaking(hostID) else {
            completion?(Self.traceFailure("busy"))
            return
        }

        // The region: the object's own window. That is the span the trace claims to cover, and
        // it is also what the capture's gate closes on.
        let region: (start: Double, end: Double)
        if let host = find(id: hostID) {
            region = (host.startTime, host.startTime + host.duration)
        } else {
            completion?(Self.traceFailure("no_region"))
            return
        }

        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            bakeAlert(L("trace.error.folder.title"),
                      L("trace.error.folder.info", error.localizedDescription))
            completion?(Self.traceFailure("no_folder"))
            return
        }

        // The plugin's live settings only reach the ValueTree — and therefore the render clone —
        // once they are flushed. Without this the trace would describe the last SAVED state of an
        // external plugin and not the one being heard.
        engine.flushObjectEditPluginStates()

        let fileName = "\(pluginID.uuidString).objtrace"
        let url = folder.appendingPathComponent(fileName)
        let signature = upstreamSignature(of: pluginID, on: hostID)

        capturingTracePluginID = pluginID
        traceProgress = 0

        engine.capturePluginTrace(pluginID.uuidString,
                                  objectID: hostID.uuidString,
                                  regionStart: region.start,
                                  regionEnd: region.end,
                                  preRoll: preRoll,
                                  tail: tail,
                                  filePath: url.path,
                                  options: nil) { [weak self] report in
            guard let self else { return }
            let dict = report as? [String: Any] ?? [:]
            self.capturingTracePluginID = nil
            self.traceProgress = 0

            if var ref = PluginTraceRef(report: dict, fileName: fileName) {
                ref.forced = forced
                self.updateChainPlugins(hostID) { list in
                    list = Self.settingTrace(ref, on: pluginID, in: list)
                }
                self.traceSignatures[pluginID] = signature
                self.isDirty = true
                self.lastTraceReport = dict
                // Forcing means switching the chain over to the trace right now: recompile so
                // that what is heard from this moment on is the trace and not the plugin.
                if forced { self.compileRack(objectID: hostID) }
            }

            // The report the user gets. It is not a courtesy: a trace is a MEASUREMENT, and its
            // number — the validation residual — is the only thing that says whether the
            // reconstruction can be trusted. Hiding it behind a green tick would leave the
            // interesting cases (a fractional latency, a plugin that turns out to hold
            // randomness) with no way of being noticed. Under external driving `notify`
            // journals instead of blocking, so a script sees it too.
            if reportsToUser { self.notify(Self.traceReportTitle(dict),
                                           self.traceReportBody(dict),
                                           style: Self.traceReportStyle(dict)) }

            completion?(dict)
        }
    }

    /// True while a capture is running (one at a time).
    var isCapturingTrace: Bool { capturingTracePluginID != nil }

    /// Asks the engine to stop the capture under way.
    func cancelTraceCapture() { engine?.cancelTraceCapture() }

    /// Polls the engine's progress (0…1). To be called by whatever draws the indicator.
    func refreshTraceProgress() {
        guard isCapturingTrace, let engine else { return }
        traceProgress = Double(engine.traceCaptureProgress())
    }

    // MARK: - Using and dropping a trace

    /// Switches a slot between "play the plugin" and "play its trace" on a machine that has
    /// both. Recompiles: it is a change of what sits in the chain.
    func setTraceForced(hostID: UUID, pluginID: UUID, forced: Bool) {
        updateChainPlugins(hostID) { list in
            list = Self.mappingPlugin(pluginID, in: list) { p in
                guard p.trace != nil else { return p }
                var n = p
                n.trace?.forced = forced
                return n
            }
        }
        compileRack(objectID: hostID)
        isDirty = true
    }

    /// Drops a slot's trace. The plugin comes back — where it is installed.
    ///
    /// The FILE stays. Dropping a reference is undoable and deleting a file is not: erasing here
    /// would make an undo restore a reference to nothing. The file becomes an orphan, which
    /// `orphanTraces` lists and `purgeOrphanTraces` collects — deleting is then a decision of its
    /// own, taken once, with the size in view.
    func clearTrace(hostID: UUID, pluginID: UUID) {
        updateChainPlugins(hostID) { list in
            list = Self.mappingPlugin(pluginID, in: list) { p in
                var n = p; n.trace = nil; return n
            }
        }
        traceSignatures[pluginID] = nil
        compileRack(objectID: hostID)
        isDirty = true
    }

    /// Every file name a trace reference in this project points at — objects (at any depth,
    /// instruments included) and buses alike.
    func referencedTraceFileNames() -> Set<String> {
        var names: Set<String> = []

        func collect(_ plugins: [ObjectPlugin]) {
            for p in Self.flattenLeaves(plugins) {
                if let ref = p.trace { names.insert(ref.fileName) }
            }
        }
        func walk(_ objects: [SoundObject]) {
            for o in objects {
                collect(o.plugins)
                collect(o.instruments)
                if case .group(let children, _) = o.kind { walk(children) }
            }
        }

        walk(items)
        for stem in stems { collect(stem.plugins) }
        return names
    }

    /// The traces referenced by nothing in the project, and the bytes they hold. A trace weighs
    /// what it weighs — 8 bytes a sample a channel before encoding — and nothing else deletes
    /// them: a slot retraced, a plugin removed, an undone capture all leave their file behind.
    func orphanTraces() -> [(url: URL, bytes: Int)] {
        guard let folder = tracesFolder,
              let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else {
            return []
        }
        let referenced = referencedTraceFileNames()

        return names.filter { $0.hasSuffix(".objtrace") && !referenced.contains($0) }
                    .map { name -> (url: URL, bytes: Int) in
                        let url = folder.appendingPathComponent(name)
                        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
                        return (url, (attributes?[.size] as? Int) ?? 0)
                    }
    }

    /// Deletes the orphans. Returns how many went, and how many bytes came back.
    @discardableResult
    func purgeOrphanTraces() -> (count: Int, bytes: Int) {
        var count = 0, bytes = 0
        for orphan in orphanTraces() where (try? FileManager.default.removeItem(at: orphan.url)) != nil {
            count += 1
            bytes += orphan.bytes
        }
        return (count, bytes)
    }

    // MARK: - Tree helpers (a chain nests: parallel blocks hold plugins)

    static func findPlugin(_ id: UUID, in plugins: [ObjectPlugin]) -> ObjectPlugin? {
        for p in plugins {
            if p.id == id { return p }
            if let rack = p.rack {
                for v in rack.voices { if let found = findPlugin(id, in: v) { return found } }
            }
        }
        return nil
    }

    /// Rebuilds a chain with `transform` applied to the one plugin named, at whatever depth.
    /// (Reading a chain flat is `flattenLeaves`, which the signal view already owns.)
    static func mappingPlugin(_ id: UUID, in plugins: [ObjectPlugin],
                              _ transform: (ObjectPlugin) -> ObjectPlugin) -> [ObjectPlugin] {
        plugins.map { p in
            if p.id == id { return transform(p) }
            guard let rack = p.rack else { return p }
            var n = p
            n.rack = PluginRack(voices: rack.voices.map { mappingPlugin(id, in: $0, transform) },
                                wetDb: rack.wetDb,
                                voiceMutes: rack.voiceMutes)
            return n
        }
    }

    private static func settingTrace(_ ref: PluginTraceRef, on id: UUID,
                                     in plugins: [ObjectPlugin]) -> [ObjectPlugin] {
        mappingPlugin(id, in: plugins) { p in
            var n = p; n.trace = ref; return n
        }
    }

    private static func traceFailure(_ code: String) -> [String: Any] {
        ["ok": false, "error": code]
    }
}

extension EditViewModel {

    /// Retakes the upstream signature of every traced slot in the project.
    ///
    /// Called once at load. A trace saved with its project describes the signal that project
    /// carries, so the answer at opening is "fresh": there is nothing to compare against yet.
    /// From here on, every edit upstream of a traced plugin will move its signature and the slot
    /// will say so. @see traceHealth for what this check does and does not promise.
    func rebuildTraceSignatures() {
        traceSignatures.removeAll()

        func note(_ hostID: UUID, _ plugins: [ObjectPlugin]) {
            for p in Self.flattenLeaves(plugins) where p.trace != nil {
                traceSignatures[p.id] = upstreamSignature(of: p.id, on: hostID)
            }
        }
        func walk(_ objects: [SoundObject]) {
            for o in objects {
                note(o.id, o.plugins)
                note(o.id, o.instruments)
                if case .group(let children, _) = o.kind { walk(children) }
            }
        }

        walk(items)
        for stem in stems { note(stem.id, stem.plugins) }
    }
}

extension EditViewModel {

    // MARK: - What the signal view needs to know

    /// Per plugin id, the state of its trace: what it is worth, and whether it is what plays.
    /// Only traced slots appear — an absent key means "never traced", which is the common case
    /// and the one the card must not decorate at all.
    func traceStates(for plugins: [ObjectPlugin],
                     on hostID: UUID) -> [UUID: (health: PluginTraceHealth, inUse: Bool)] {
        var out: [UUID: (health: PluginTraceHealth, inUse: Bool)] = [:]
        for p in Self.flattenLeaves(plugins) {
            guard let health = traceHealth(p, on: hostID) else { continue }
            out[p.id] = (health, playsFromTrace(p))
        }
        return out
    }

    /// The one line the trace badge shows on hover. It has to answer three things in a breath:
    /// is the plugin or its recording being heard, how good is the reconstruction, and when was
    /// it taken.
    func traceSummary(pluginID: UUID, on hostID: UUID) -> String? {
        guard let plugins = chainPlugins(hostID),
              let plugin = Self.findPlugin(pluginID, in: plugins),
              let ref = plugin.trace,
              let health = traceHealth(plugin, on: hostID) else { return nil }

        let when = DateFormatter.localizedString(from: ref.capturedAt,
                                                 dateStyle: .short, timeStyle: .short)
        let state = playsFromTrace(plugin) ? L("trace.summary.playing") : L("trace.summary.captured")

        switch health {
        case .exact:      return L("trace.summary.exact", state, when)
        case .acceptable: return L("trace.summary.acceptable", state, when,
                                   String(format: "%.0f", ref.validationPeakDb))
        case .problem:    return L("trace.summary.problem", state, when,
                                   String(format: "%.0f", ref.validationPeakDb))
        case .frozen:     return L("trace.summary.frozen", state, when)
        case .stale:      return L("trace.summary.stale", state, when)
        }
    }
}

extension EditViewModel {

    // MARK: - The report shown when a capture ends
    //
    // The spec asks for a validation report, with the residual level. What follows turns the
    // engine's dictionary into it. Three things earn their place in the body, and nothing else
    // does: the residual (can this be trusted?), the mode (is a performance being frozen?), and
    // the weight (a trace is heavy, and the folder will fill).

    static func traceReportTitle(_ report: [String: Any]) -> String {
        guard report["ok"] as? Bool == true else { return L("trace.report.failed.title") }
        switch report["status"] as? String {
        case "exact":      return L("trace.report.exact.title")
        case "acceptable": return L("trace.report.acceptable.title")
        default:           return L("trace.report.problem.title")
        }
    }

    static func traceReportStyle(_ report: [String: Any]) -> NSAlert.Style {
        guard report["ok"] as? Bool == true else { return .warning }
        return (report["status"] as? String) == "exact" ? .informational : .warning
    }

    func traceReportBody(_ report: [String: Any]) -> String {
        guard report["ok"] as? Bool == true else {
            return report["message"] as? String ?? L("trace.report.failed.unknown")
        }

        var lines: [String] = []

        let peak = (report["validation_peak_db"] as? NSNumber)?.doubleValue ?? 0
        let rms  = (report["validation_rms_db"] as? NSNumber)?.doubleValue ?? 0
        lines.append(L("trace.report.residual",
                       String(format: "%.0f", peak), String(format: "%.0f", rms)))

        if report["non_deterministic"] as? Bool == true {
            // The one thing the user has to be told in words rather than shown as a badge: the
            // plugin holds randomness, so what has been captured is ONE performance and it will
            // not vary again. It is not a defect, and it is not something to discover by ear.
            lines.append(L("trace.report.frozen"))
        }
        if (report["status"] as? String) == "problem" {
            lines.append(L("trace.report.diagnosis.alignment",
                           String(format: "%.2f",
                                  (report["correlation_lag"] as? NSNumber)?.doubleValue ?? 0)))
        }
        if report["plugin_was_bypassed"] as? Bool == true {
            lines.append(L("trace.report.bypassed"))
        }
        if report["input_hash"] as? String == "" {
            lines.append(L("trace.report.noFingerprint"))
        }

        let bytes = (report["file_bytes"] as? NSNumber)?.int64Value ?? 0
        let flat  = (report["flat_bytes"] as? NSNumber)?.int64Value ?? 0
        lines.append(L("trace.report.size",
                       ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file),
                       flat > 0 ? String(format: "%.0f", 100.0 * Double(bytes) / Double(flat)) : "?"))

        return lines.joined(separator: "\n\n")
    }
}
