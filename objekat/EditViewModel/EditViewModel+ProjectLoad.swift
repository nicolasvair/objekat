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
    private func performStructureSetup(_ doc: ProjectDocument) {
        consolidateDefinitions = Dictionary(uniqueKeysWithValues: (doc.consolidateDefinitions ?? []).map { ($0.id, $0) })
        markerLanes = doc.markerLanes ?? []
        comments = doc.comments ?? []
        consolidateEditStack.removeAll()
        resetTransientSessionState()

        isRestoringTransport = true
        if let t = doc.tempo { tempo = t }
        if let n = doc.timeSigNumerator { timeSigNumerator = n }
        if let d = doc.timeSigDenominator { timeSigDenominator = d }
        isRestoringTransport = false
        if let g = doc.gridMode { gridMode = g }
        snapEnabled = doc.snapEnabled ?? true

        if let vp = doc.viewport {
            pixelsPerSecond = max(1, vp.pixelsPerSecond)
            blockHeight     = max(16, vp.blockHeight)
            pendingViewRestore = vp
        }

        if let docStems = doc.stems, !docStems.isEmpty {
            stems = docStems
        } else {
            stems = [Stem(id: UUID(), name: "Main", colorIndex: 0, format: .stereo)]
        }
        engine?.setMasterStemKey(mainStemID.uuidString)

        // Arms the queue: from here on, every `syncAdd` below defers its chain/instrument compiles
        // instead of running them inline (@see EditViewModel+Plugins.scheduleChainCompile).
        deferredChainCompiles = []
        items = doc.items
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
    func runProjectLoad(_ doc: ProjectDocument, displayName: String?) {
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

        performStructureSetup(doc)
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
        lastProjectLoad = ProjectLoadOutcome(path: nil, success: true, durationMs: durationMs)
        loadState = nil
    }

    // MARK: - The breathing path (the menu, and `project.open` once the run loop is confirmed alive)

    /// A continuation resumed from `RunLoop.main.perform(inModes: [.common])` — NOT
    /// `Task.yield()`, which the plan's measurements found insufficient: a yield hands control back
    /// to the concurrency executor, not to AppKit's own run loop, and `ProjectLoadOverlay` needs a
    /// real pass through `.common` to actually get drawn between two engine calls.
    private func breathIfNeeded(_ lastBreath: inout Date) async {
        guard Date().timeIntervalSince(lastBreath) * 1000 > ProjectLoadWeight.breathIntervalMs else { return }
        lastBreath = Date()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            RunLoop.main.perform(inModes: [.common]) { continuation.resume() }
        }
    }

    /// Same phases as `runProjectLoad`, byte for byte — only interleaved with `breathIfNeeded` so
    /// the overlay can be painted and `project.load_status` answered while it runs, and with the
    /// ONE point where cancellation is honoured: between two plugin compiles.
    /// - Returns: `false` on cancellation (the project is then left EMPTY, not half-loaded);
    ///   `true` otherwise. Never throws — a decode failure is the caller's (`loadProjectAsync`).
    @discardableResult
    func runProjectLoadAsync(_ doc: ProjectDocument, displayName: String?,
                             cancellable: Bool = true) async -> Bool {
        let plan = buildLoadPlan(for: doc)
        let startedAt = Date()
        var phaseStart = startedAt
        var done = 0.0
        var lastBreath = Date.distantPast
        loadState = ProjectLoadState(phase: .teardown, fraction: 0,
                                     projectName: displayName ?? projectName, startedAt: startedAt,
                                     cancellable: cancellable)
        engine?.beginBulkLoad()
        // The first breath happens BEFORE the teardown's own (blocking) work — the same reasoning
        // as the export panel's deferred launch (`EditViewModel+Export.runExport`): the veil is laid
        // at once (@see ProjectLoadOverlay), and this breath is what lets it be DRAWN before the old
        // project starts coming apart underneath.
        await breathIfNeeded(&lastBreath)

        performTeardown()
        phaseStart = logLoadPhase(.teardown, since: phaseStart)
        done += ProjectLoadWeight.teardownPerPlugin * Double(plan.oldPluginCount)
        loadState?.phase = .structure
        loadState?.fraction = min(1, done / plan.total)
        await breathIfNeeded(&lastBreath)

        performStructureSetup(doc)
        for item in items {
            addTopLevelItemToEngine(item)
            done += ProjectLoadWeight.structurePerObject * Double(1 + descendantCount(item))
            loadState?.fraction = min(1, done / plan.total)
            await breathIfNeeded(&lastBreath)
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
            await breathIfNeeded(&lastBreath)
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
        await breathIfNeeded(&lastBreath)
        phaseStart = logLoadPhase(.stemsRouting, since: phaseStart)

        loadState?.phase = .finalize
        engine?.endBulkLoad()
        performFinalize()
        done += ProjectLoadWeight.finalize
        _ = logLoadPhase(.finalize, since: phaseStart)

        let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        NSLog("[LOAD] total %d ms", durationMs)
        lastProjectLoad = ProjectLoadOutcome(path: nil, success: true, durationMs: durationMs)
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
