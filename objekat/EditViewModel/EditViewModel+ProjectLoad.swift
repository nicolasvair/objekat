import Foundation

// MARK: - Progress of a project load
//
// See `project_load_progress_plan` (memory) for the study this implements: >90% of an opening's
// time is plugin instantiation (an FX chain 150–1170 ms, a VSTi 1.2–5.2 s), all of it synchronous
// on the main thread in a single run-loop turn. The fix has three parts: DEFER the chain/instrument
// compiles instead of running them inline as each object is (re)added (`EditViewModel+Plugins`,
// `scheduleChainCompile`), drain that queue here with the run loop breathed on between entries, and
// inhibit the engine's graph reallocation for the whole load (`OBJEngineCore.beginBulkLoad`/
// `endBulkLoad`) so the queue's hundreds of individual compiles do not each trigger their own
// partial rebuild.

/// One phase of a project load, in the order they run.
enum ProjectLoadPhase: String, Equatable {
    case teardown       // tearing down the previous project's engine state
    case structure      // items = doc.items + syncAdd (chain/instrument compiles DEFERRED)
    case plugins        // draining `deferredChainCompiles` — the expensive phase (FX + VSTi)
    case stemsRouting   // sends, bus gains/FX/routing, audibility
    case finalize       // rescans, the missing-file watch, restarting the transport
}

/// What `ProjectLoadOverlay` and `project.load_status` read while a project is loading. Replaced
/// wholesale at each step (never mutated field by field) so a reader — the API included — never
/// observes a half-written state; `@Observable` already reports the property's own change.
struct ProjectLoadState: Equatable {
    var phase: ProjectLoadPhase
    /// 0...1 over the WHOLE load, monotonically increasing. The weights behind it are FIXED
    /// (`ProjectLoadWeight`) — deliberately never learned or remembered from a previous load (user
    /// decision, 2026-09-24): a slow plugin the first time it loads must not make every later
    /// load's bar lie about what is actually left.
    var fraction: Double
    var pluginIndex: Int = 0
    var pluginTotal: Int = 0
    var currentPluginName: String? = nil
    var projectName: String
    var startedAt: Date
    /// Set by `EditViewModel.requestCancelProjectLoad()` (the overlay's Annuler button, or
    /// `project.cancel_load`); consumed at the next SAFE point, between two plugin compiles —
    /// never mid-compile, an AU half-instantiated being worse than one instantiated for nothing.
    var cancelRequested: Bool = false
    /// False for a load that must run to completion with no way out for the user — a TAB SWITCH
    /// (tabs INC1, `Workspace.select`/`restoreParkedProject`): unlike Cmd+O, there is no "cancel"
    /// that makes sense there, since the tab being switched TO is not a discardable choice, it is
    /// where the hand is going. `ProjectLoadOverlay` hides its Annuler button when this is false,
    /// and `requestCancelProjectLoad` becomes a no-op.
    var cancellable: Bool = true
}

/// The outcome of the last load, kept once `loadState` has gone back to `nil` — the one thing a
/// caller driving `project.open {"async": true}` cannot read off `loadState` itself, since by the
/// time it asks, the load may already be over.
struct ProjectLoadOutcome: Equatable {
    var path: String?
    var success: Bool
    var cancelled: Bool = false
    var errorMessage: String? = nil
    var durationMs: Int
    /// How many plugin ids `PluginIDUniqueness` re-keyed in this load. 0 = nothing was repaired: the
    /// file was sound, OR the repair was not asked for (@see `duplicatePluginIDs`). A load that
    /// re-keyed something leaves the session MODIFIED — @see `settleDirtyAfterLoad`.
    var repairedPluginIDs: Int = 0
    /// What the file held, as it was READ and before any repair: every plugin id carried by more than
    /// one entry, with the places (@see `PluginIDUniqueness.duplicateDetails`). Empty = a sound file.
    /// Filled whether or not the repair was asked for — it is what the alert, the report and
    /// `project.load_status` read.
    var duplicatePluginIDs: [PluginIDUniqueness.DuplicateDetail] = []
}

/// What to do about plugin ids that more than one entry of a file carries, decided BEFORE the load
/// (one load, never two). `.ask` is for a door a hand opened (the menu, ⌘O, the Finder, the recent
/// projects): it shows the alert when — and only when — the file has duplicates. `.repair` and `.keep`
/// are for everything else, a script above all: an API call must never raise a modal.
enum PluginIDRepairChoice {
    case ask
    case repair
    case keep
}

/// Fixed weights for the progress bar's fraction (project_load_progress_plan's own numbers).
private enum ProjectLoadWeight {
    static let teardownPerPlugin: Double = 0.3
    static let structurePerObject: Double = 0.05
    static let fx: Double = 1.0
    static let instrument: Double = 2.0
    static let stemPlugin: Double = 1.0
    static let finalize: Double = 2.0
    /// Below this, nothing here ever breathes: two engine calls in a row cost far less than one
    /// `RunLoop.main.perform` round trip, and breathing on every single one would slow the load
    /// down for a bar nobody can see move that fast anyway.
    static let breathIntervalMs: Double = 30
    /// Work time allowed after a breath, as a multiple of what that breath cost (@see
    /// `breathIfNeeded`): 2 = redrawing takes at most a third of the load.
    static let breathWorkRatio: Double = 2
}

extension EditViewModel {

    // MARK: - Cancelling

    /// Requests that the load in flight stop at its next safe point (between two plugin compiles)
    /// and settle on an empty, coherent project. No effect outside a load, and no effect on the
    /// fully synchronous path (`applyProjectDocument`/`loadProject(from:)`), which never checks it —
    /// there is no run loop turn in which a click could have set it anyway.
    func requestCancelProjectLoad() {
        guard loadState?.cancellable != false else { return }
        loadState?.cancelRequested = true
    }

    // MARK: - Weighing the work (fixed, never learned)

    private struct LoadWeightScan {
        var objectCount = 0
        var fxEntries = 0
        var instrumentEntries = 0
    }

    /// Walks `items` exactly as `syncAdd`/`syncAddGroup` will — every object counts once, and a
    /// group's children are counted too — predicting precisely which objects will queue a
    /// `.plugins` or `.instrument` entry (@see `EditViewModel+Plugins.scheduleChainCompile`), so
    /// the plan's total matches the queue's real length once the structure phase has run.
    private static func scanForWeights(_ items: [SoundObject]) -> LoadWeightScan {
        var w = LoadWeightScan()
        func walk(_ arr: [SoundObject]) {
            for obj in arr {
                w.objectCount += 1
                if obj.needsChainCompile { w.fxEntries += 1 }
                if case .midiClip = obj.kind, obj.instruments.first != nil { w.instrumentEntries += 1 }
                if case .group(let children, _) = obj.kind { walk(children) }
            }
        }
        walk(items)
        return w
    }

    private struct LoadPlan {
        let total: Double
        let stemPluginCount: Int
        let oldPluginCount: Int
    }

    /// Computed ONCE, before the teardown starts: `oldPluginCount` reads `items`/`allPluginRefs()`
    /// as they stand — the project about to be REPLACED — and everything else reads `doc`. Always
    /// > 0 (`finalize` alone is worth 2), so a fraction is always computable.
    private func buildLoadPlan(for doc: ProjectDocument) -> LoadPlan {
        let oldPluginCount = allPluginRefs().count
        let scan = Self.scanForWeights(doc.items)
        let stemPluginCount = (doc.stems ?? []).filter { $0.needsChainCompile }.count
        let total = ProjectLoadWeight.teardownPerPlugin * Double(oldPluginCount)
                  + ProjectLoadWeight.structurePerObject * Double(scan.objectCount)
                  + ProjectLoadWeight.fx * Double(scan.fxEntries)
                  + ProjectLoadWeight.instrument * Double(scan.instrumentEntries)
                  + ProjectLoadWeight.stemPlugin * Double(stemPluginCount)
                  + ProjectLoadWeight.finalize
        return LoadPlan(total: total, stemPluginCount: stemPluginCount, oldPluginCount: oldPluginCount)
    }

    // MARK: - The phases themselves (shared, byte for byte, by the sync and the breathing path)

    /// Everything `applyProjectDocument` used to do before touching `doc` at all. Reuses
    /// `ObjekatSession.stop()` through the hook it installs at `start()` when there is one — fixing
    /// the bug the plan flagged: `engine?.stop()` alone left `session.isPlaying` true although the
    /// sound had actually stopped.
    private func performTeardown() {
        missingPluginCapture = []
        if let hook = projectLoadWillBeginHook { hook() } else { engine?.stop() }
        for stem in stems where stem.id != mainStemID {
            let memberIDs = allClips.filter { $0.stemID == stem.id }.map { $0.id.uuidString }
            engine?.disbandStemBus(stem.id.uuidString, memberIDs: memberIDs)
        }
        for item in items { removeFromEngine(item) }
        items = []
        stems = []
        selectedIDs = []
        undoStack = []
        redoStack = []
    }

    /// Everything from the annotations through arming the deferred-compile queue and replacing
    /// `items` — but NOT the `syncAdd` loop itself, which the caller drives one item at a time so it
    /// can report progress and breathe between them.
    /// `preservingClipboard`: tabs INC2 — a tab SWITCH is not a change of project as far as the
    /// clipboard is concerned (@see Workspace.restoreParkedProject and
    /// `resetTransientSessionState`'s own doc comment): the cross-project clipboard lives on
    /// `Workspace`, outside this state entirely, but the LOCAL `clipboard`/`midiNotesClipboard`
    /// still needs to survive the reload underneath it, or an intra-tab paste right after
    /// switching back would find nothing. Every other caller (a genuine New/Open) leaves this
    /// false: pasting the OLD document's ids into a truly different one is exactly the dangling
    /// stemID/auxID/consolidateID corruption this reset exists to prevent.
    ///
    /// Also the one place a plugin id carried by two hosts is DETECTED (@see `PluginIDUniqueness`):
    /// every load path — Cmd+O, `project.open`, a tab's open or restore, `HeadlessRunner --project` —
    /// goes through here. It always looks, on the document as READ; it re-keys only when
    /// `repairPluginIDs` is true (the decision was taken before the load, @see `PluginIDRepairChoice`).
    /// A repair leaves the project MODIFIED (@see `settleDirtyAfterLoad`), so the next save writes
    /// the repaired model instead of the file's duplicates; without it the duplicates stay in the
    /// model, and the engine copes (@see `OBJEngineCore._pluginOwnerHost`).
    /// - Returns: what `ProjectLoadOutcome` reports: the duplicates the file held and how many ids
    ///   were re-keyed.
    private func performStructureSetup(_ doc: ProjectDocument, preservingClipboard: Bool = false,
                                       repairPluginIDs: Bool = false)
        -> (duplicates: [PluginIDUniqueness.DuplicateDetail], repaired: Int) {
        let docStems = doc.stems ?? []
        let duplicates = PluginIDUniqueness.duplicateDetails(items: doc.items, stems: docStems,
                                                             fxLinks: doc.fxLinks ?? [])
        let fixed = Self.repairedForLoad(items: doc.items, stems: docStems,
                                         duplicates: duplicates, repair: repairPluginIDs)
        consolidateDefinitions = Dictionary(uniqueKeysWithValues: (doc.consolidateDefinitions ?? []).map { ($0.id, $0) })
        fxLinks = doc.fxLinks ?? []
        clearPendingFXSources()
        markerLanes = doc.markerLanes ?? []
        comments = doc.comments ?? []
        consolidateEditStack.removeAll()
        resetTransientSessionState(preservingClipboard: preservingClipboard)

        isRestoringTransport = true
        if let t = doc.tempo { tempo = t }
        if let n = doc.timeSigNumerator { timeSigNumerator = n }
        if let d = doc.timeSigDenominator { timeSigDenominator = d }
        isRestoringTransport = false
        if let g = doc.gridMode { gridMode = g }
        snapEnabled = doc.snapEnabled ?? true

        if let vp = doc.viewport {
            pixelsPerSecond = max(Self.minPixelsPerSecond, vp.pixelsPerSecond)
            blockHeight     = max(16, vp.blockHeight)
            pendingViewRestore = vp
        }

        if !fixed.stems.isEmpty {
            stems = fixed.stems
        } else {
            stems = [Stem(id: UUID(), name: "Main", colorIndex: 0, format: .stereo)]
        }
        engine?.setMasterStemKey(mainStemID.uuidString)

        // Arms the queue: from here on, every `syncAdd` below defers its chain/instrument compiles
        // instead of running them inline (@see EditViewModel+Plugins.scheduleChainCompile).
        deferredChainCompiles = []
        items = fixed.items
        return (duplicates, fixed.repairs.count)
    }

    /// What the dirty flag says once a load has succeeded (the places that used to write
    /// `isDirty = false` there call this instead): clean, UNLESS the load re-keyed plugin ids
    /// (`lastProjectLoad.repairedPluginIDs`) — then the file on disk no longer matches the model,
    /// and the project is marked modified so the next save writes the repaired version. A load that
    /// only DETECTED duplicates leaves the project clean: nothing was changed, and nothing is written
    /// before the hand saves. No alert here: the title's edited mark and the usual "save before
    /// closing?" say it. Only to be called right after a SUCCESSFUL load.
    func settleDirtyAfterLoad() {
        isDirty = (lastProjectLoad?.repairedPluginIDs ?? 0) > 0
    }

    /// Settles a `PluginIDRepairChoice` into "repair or not", from the document as it was READ and
    /// BEFORE the load starts, so there is exactly one load whatever the answer. `.repair` and `.keep`
    /// answer themselves; `.ask` asks only if the file really has duplicated plugin ids.
    func resolvePluginIDRepair(_ choice: PluginIDRepairChoice, doc: ProjectDocument, url: URL) -> Bool {
        switch choice {
        case .repair: return true
        case .keep:   return false
        case .ask:
            // The question itself comes with the alert; until then an `.ask` opens the file as it is.
            return false
        }
    }

    /// `PluginIDUniqueness.deduplicated` when a repair was asked for, with its `[LOAD]` line; or,
    /// for a file with duplicates that is left as it is, the line saying so. Machine-facing, English.
    private static func repairedForLoad(items: [SoundObject], stems: [Stem],
                                        duplicates: [PluginIDUniqueness.DuplicateDetail], repair: Bool)
        -> (items: [SoundObject], stems: [Stem], repairs: [PluginIDUniqueness.Repair]) {
        if duplicates.isEmpty { return (items, stems, []) }
        guard repair else {
            let hosts = Set(duplicates.flatMap { $0.sites.map(\.hostID) }).count
            NSLog("[LOAD] %d plugin id(s) duplicated across %d hosts — NOT repaired",
                  duplicates.count, hosts)
            return (items, stems, [])
        }
        let fixed = PluginIDUniqueness.deduplicated(items: items, stems: stems)
        if !fixed.repairs.isEmpty {
            // Truncated to 8 characters each: a machine-facing line, not a list to read in full.
            let detail = fixed.repairs.prefix(8).map {
                "\($0.oldID.uuidString.prefix(8)) -> \($0.newID.uuidString.prefix(8)) @ \($0.hostID.uuidString.prefix(8))"
            }.joined(separator: ", ")
            let more = fixed.repairs.count > 8 ? ", … (+\(fixed.repairs.count - 8))" : ""
            NSLog("[LOAD] %d plugin id(s) duplicated across hosts — re-keyed: %@%@",
                  fixed.repairs.count, detail, more)
        }
        return fixed
    }

    /// Adds ONE top-level item to the engine — `syncAdd` + its own fade — exactly what the old
    /// monolithic loop did per iteration.
    private func addTopLevelItemToEngine(_ item: SoundObject) {
        syncAdd(item)
        switch item.kind {
        case .clip, .midiClip:
            engine?.updateFade(in: item.fadeIn, fadeOut: item.fadeOut, forID: item.id.uuidString)
        default: break
        }
    }

    /// The object's whole sub-tree counted once (itself excluded) — matches `scanForWeights`'s own
    /// walk, so an item's contribution to `done` exactly equals what `buildLoadPlan` predicted it
    /// would be worth.
    private func descendantCount(_ item: SoundObject) -> Int {
        guard case .group(let children, _) = item.kind else { return 0 }
        return allDescendantEngineIDs(of: children).count
    }

    private func wireStemBuses() {
        for stem in stems.dropFirst() {
            engine?.createStemBus(stem.id.uuidString)
            let clipIDs = allClips.filter { $0.stemID == stem.id }.map { $0.id.uuidString }
            let groupIDs = items.compactMap { item -> String? in
                guard case .group = item.kind, item.stemID == stem.id else { return nil }
                return item.id.uuidString
            }
            let memberIDs = clipIDs + groupIDs
            if !memberIDs.isEmpty {
                engine?.assignObjects(memberIDs, toStemID: stem.id.uuidString)
            }
        }
    }

    /// Drains ONE entry of `deferredChainCompiles` (FIFO — the order `syncAdd` queued them in,
    /// which is the project's own top-to-bottom, depth-first order). `rewireLinks: false`: the
    /// caller calls `rewireLinkGroups()` once, after the LAST entry, never per item.
    /// - Returns: the label for `ProjectLoadState.currentPluginName` and the weight the entry is
    ///   worth, or `nil` if the queue was already empty.
    private func drainOneQueuedCompile() -> (name: String?, weight: Double)? {
        guard var queue = deferredChainCompiles, !queue.isEmpty else { return nil }
        let entry = queue.removeFirst()
        deferredChainCompiles = queue
        applyChainCompile(entry, rewireLinks: false)
        switch entry {
        case .plugins(let object):
            return (object.plugins.first?.name ?? object.displayName, ProjectLoadWeight.fx)
        case .instrument(let object):
            return (object.instruments.first?.name ?? object.displayName, ProjectLoadWeight.instrument)
        }
    }

    private func performStemsRouting() {
        resyncAllSends()
        syncStemGains()
        syncStemPlugins()
        syncStemRouting()
        refreshAudibility()
    }

    private func performFinalize() {
        projectLoadToken &+= 1
        rescanMissingFiles()
        armMissingFileWatch()
        let missing = missingPluginCapture ?? []
        missingPluginCapture = nil
        if !missing.isEmpty {
            // Held, not alerted straight away: the plan asks for the missing-plugins alert to
            // appear only AFTER the overlay has faded out. `ProjectLoadOverlay` flushes this once
            // its own fade-out completes; the fallback below covers headless / no-window / a load
            // too fast to ever show an overlay, so the report is never silently lost.
            pendingMissingPluginsReport = missing
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.flushPendingMissingPluginsReportIfAny()
            }
        }
    }

    /// Alerts about the plugins a load could not resolve, if any are still pending — a no-op the
    /// second time it is called (`ProjectLoadOverlay`'s own flush racing the 0.5 s fallback above).
    func flushPendingMissingPluginsReportIfAny() {
        guard let missing = pendingMissingPluginsReport, !missing.isEmpty else {
            pendingMissingPluginsReport = nil
            return
        }
        pendingMissingPluginsReport = nil
        reportMissingPlugins(missing)
    }

    // MARK: - The synchronous path (HeadlessRunner's `--project`, and the default contract)

    /// No `async`, no `await`, no run-loop dependency of any kind: this is what makes it safe to
    /// call from `HeadlessRunner` BEFORE `app.run()` is ever entered, where nothing would ever
    /// resume a breathed continuation. `loadState` is still set/cleared around the work (so a
    /// concurrent reader — unlikely, but possible from another thread's client — sees SOMETHING),
    /// but nothing here ever yields for it to be caught mid-flight, and cancellation is never
    /// checked (there is no run-loop turn in which a click could have requested one).
    func runProjectLoad(_ doc: ProjectDocument, displayName: String?, repairPluginIDs: Bool = false) {
        let plan = buildLoadPlan(for: doc)
        let startedAt = Date()
        var phaseStart = startedAt
        var done = 0.0
        loadState = ProjectLoadState(phase: .teardown, fraction: 0,
                                     projectName: displayName ?? projectName, startedAt: startedAt)
        engine?.beginBulkLoad()

        performTeardown()
        phaseStart = logLoadPhase(.teardown, since: phaseStart)
        done += ProjectLoadWeight.teardownPerPlugin * Double(plan.oldPluginCount)
        loadState?.phase = .structure
        loadState?.fraction = min(1, done / plan.total)

        let pluginIDCheck = performStructureSetup(doc, repairPluginIDs: repairPluginIDs)
        for item in items {
            addTopLevelItemToEngine(item)
            done += ProjectLoadWeight.structurePerObject * Double(1 + descendantCount(item))
            loadState?.fraction = min(1, done / plan.total)
        }
        wireStemBuses()
        phaseStart = logLoadPhase(.structure, since: phaseStart)

        loadState?.phase = .plugins
        let pluginTotal = deferredChainCompiles?.count ?? 0
        loadState?.pluginTotal = pluginTotal
        var pluginIndex = 0
        while let drained = drainOneQueuedCompile() {
            pluginIndex += 1
            done += drained.weight
            loadState?.pluginIndex = pluginIndex
            loadState?.currentPluginName = drained.name
            loadState?.fraction = min(1, done / plan.total)
        }
        rewireLinkGroups()
        deferredChainCompiles = nil
        phaseStart = logLoadPhase(.plugins, since: phaseStart, count: pluginTotal)

        loadState?.phase = .stemsRouting
        performStemsRouting()
        done += ProjectLoadWeight.stemPlugin * Double(plan.stemPluginCount)
        loadState?.fraction = min(1, done / plan.total)
        phaseStart = logLoadPhase(.stemsRouting, since: phaseStart)

        loadState?.phase = .finalize
        engine?.endBulkLoad()
        performFinalize()
        done += ProjectLoadWeight.finalize
        _ = logLoadPhase(.finalize, since: phaseStart)

        let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        NSLog("[LOAD] total %d ms", durationMs)
        lastProjectLoad = ProjectLoadOutcome(path: nil, success: true, durationMs: durationMs,
                                             repairedPluginIDs: pluginIDCheck.repaired,
                                             duplicatePluginIDs: pluginIDCheck.duplicates)
        loadState = nil
    }

    // MARK: - The breathing path (the menu, and `project.open` once the run loop is confirmed alive)

    /// A continuation resumed from `RunLoop.main.perform(inModes: [.common])` — NOT
    /// `Task.yield()`, which the plan's measurements found insufficient: a yield hands control back
    /// to the concurrency executor, not to AppKit's own run loop, and `ProjectLoadOverlay` needs a
    /// real pass through `.common` to actually get drawn between two engine calls.
    ///
    /// `nextBreath` is the earliest moment the NEXT breath may happen, and it is set when a breath
    /// ENDS, never when it starts. A breath is not cheap: it redraws the whole window (the timeline
    /// stays visible under the veil), ~70 ms on a 1 250-object project in Release. Counted from
    /// its start, a breath longer than the interval made every following step breathe again at
    /// once — the load then spent most of its time redrawing (PERREO WUB 2, Release: 10.7 s →
    /// 3.8 s with both rules). The work allowed between two breaths also grows with what the last one cost
    /// (`breathWorkRatio`), so redrawing never takes more than a third of the load, however heavy
    /// the window gets; the bar still moves several times a second.
    private func breathIfNeeded(_ nextBreath: inout Date) async {
        guard Date() >= nextBreath else { return }
        let started = Date()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            RunLoop.main.perform(inModes: [.common]) { continuation.resume() }
        }
        let ended = Date()
        let cost = ended.timeIntervalSince(started)
        nextBreath = ended.addingTimeInterval(max(ProjectLoadWeight.breathIntervalMs / 1000,
                                                  cost * ProjectLoadWeight.breathWorkRatio))
    }

    /// Same phases as `runProjectLoad`, byte for byte — only interleaved with `breathIfNeeded` so
    /// the overlay can be painted and `project.load_status` answered while it runs, and with the
    /// ONE point where cancellation is honoured: between two plugin compiles.
    /// - Returns: `false` on cancellation (the project is then left EMPTY, not half-loaded);
    ///   `true` otherwise. Never throws — a decode failure is the caller's (`loadProjectAsync`).
    @discardableResult
    func runProjectLoadAsync(_ doc: ProjectDocument, displayName: String?,
                             cancellable: Bool = true,
                             preservingClipboard: Bool = false,
                             repairPluginIDs: Bool = false) async -> Bool {
        let plan = buildLoadPlan(for: doc)
        let startedAt = Date()
        var phaseStart = startedAt
        var done = 0.0
        var nextBreath = Date.distantPast
        loadState = ProjectLoadState(phase: .teardown, fraction: 0,
                                     projectName: displayName ?? projectName, startedAt: startedAt,
                                     cancellable: cancellable)
        engine?.beginBulkLoad()
        // The first breath happens BEFORE the teardown's own (blocking) work — the same reasoning
        // as the export panel's deferred launch (`EditViewModel+Export.runExport`): the veil is laid
        // at once (@see ProjectLoadOverlay), and this breath is what lets it be DRAWN before the old
        // project starts coming apart underneath.
        await breathIfNeeded(&nextBreath)

        performTeardown()
        phaseStart = logLoadPhase(.teardown, since: phaseStart)
        done += ProjectLoadWeight.teardownPerPlugin * Double(plan.oldPluginCount)
        loadState?.phase = .structure
        loadState?.fraction = min(1, done / plan.total)
        await breathIfNeeded(&nextBreath)

        let pluginIDCheck = performStructureSetup(doc, preservingClipboard: preservingClipboard,
                                                  repairPluginIDs: repairPluginIDs)
        for item in items {
            addTopLevelItemToEngine(item)
            done += ProjectLoadWeight.structurePerObject * Double(1 + descendantCount(item))
            loadState?.fraction = min(1, done / plan.total)
            await breathIfNeeded(&nextBreath)
        }
        wireStemBuses()
        phaseStart = logLoadPhase(.structure, since: phaseStart)

        loadState?.phase = .plugins
        let pluginTotal = deferredChainCompiles?.count ?? 0
        loadState?.pluginTotal = pluginTotal
        var pluginIndex = 0
        var cancelled = false
        while !(deferredChainCompiles?.isEmpty ?? true) {
            if loadState?.cancelRequested == true { cancelled = true; break }
            if let drained = drainOneQueuedCompile() {
                pluginIndex += 1
                done += drained.weight
                loadState?.pluginIndex = pluginIndex
                loadState?.currentPluginName = drained.name
                loadState?.fraction = min(1, done / plan.total)
            }
            await breathIfNeeded(&nextBreath)
        }

        if cancelled {
            deferredChainCompiles = nil
            engine?.endBulkLoad()
            loadState = nil
            // No partial project left behind: the queue's remaining entries are simply dropped,
            // and `newProjectDiscardingChanges` brings the model AND the engine back to a known,
            // empty, coherent state — reusing the same teardown "New project" already relies on,
            // rather than inventing a second one for this single caller.
            newProjectDiscardingChanges()
            let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            NSLog("[LOAD] cancelled after %d ms", durationMs)
            lastProjectLoad = ProjectLoadOutcome(path: nil, success: false, cancelled: true,
                                                 durationMs: durationMs)
            return false
        }

        rewireLinkGroups()
        deferredChainCompiles = nil
        phaseStart = logLoadPhase(.plugins, since: phaseStart, count: pluginTotal)

        loadState?.phase = .stemsRouting
        performStemsRouting()
        done += ProjectLoadWeight.stemPlugin * Double(plan.stemPluginCount)
        loadState?.fraction = min(1, done / plan.total)
        await breathIfNeeded(&nextBreath)
        phaseStart = logLoadPhase(.stemsRouting, since: phaseStart)

        loadState?.phase = .finalize
        engine?.endBulkLoad()
        performFinalize()
        done += ProjectLoadWeight.finalize
        _ = logLoadPhase(.finalize, since: phaseStart)

        let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        NSLog("[LOAD] total %d ms", durationMs)
        lastProjectLoad = ProjectLoadOutcome(path: nil, success: true, durationMs: durationMs,
                                             repairedPluginIDs: pluginIDCheck.repaired,
                                             duplicatePluginIDs: pluginIDCheck.duplicates)
        loadState = nil
        return true
    }

    /// One line per phase: `[LOAD] <phase> <ms> ms` (`<phase> <ms> ms, <n> plugins` for the plugin
    /// phase) — the plan's own step 5 requirement, and the only way to see where an open's time
    /// actually goes without instrumenting the engine itself. Machine-facing like every other
    /// `NSLog` here: English, not through `L()` (@see the permanent point on visible strings).
    /// - Returns: `Date()`, so the caller can chain it straight into the next phase's `since:`.
    @discardableResult
    private func logLoadPhase(_ phase: ProjectLoadPhase, since start: Date, count: Int? = nil) -> Date {
        let now = Date()
        let ms = Int(now.timeIntervalSince(start) * 1000)
        if let count {
            NSLog("[LOAD] %@ %d ms, %d plugins", phase.rawValue, ms, count)
        } else {
            NSLog("[LOAD] %@ %d ms", phase.rawValue, ms)
        }
        return now
    }
}
