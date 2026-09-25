import Foundation

// MARK: - The progress of a consolidated render
//
// What fills the circle a block wears while it is being consolidated (@see RenderProgressRing).
// The engine counts a bake's progress in its `EditRenderer` handle, as it does an export's; this
// reads it ten times a second, for as long as a render is known to be running, into the one
// store the circles observe.
//
// The poll is armed by the two sets that already SAY a render is running — `bakingIDs` (a bake,
// a commit) and `recomputingConsolidateIDs` (a cascade's automatic re-bake) — through their
// `didSet`, and stops the moment both are empty. So no path that starts or ends a render has to
// remember the circle: the locks it already takes are what drive it. No render running, no timer.

extension EditViewModel {

    /// The poll's period, the same as the export's (@see startExportProgressPolling): a render
    /// lasts seconds, and a pie on a 14 pt circle cannot show a finer step than that anyway.
    static let renderProgressPollInterval: TimeInterval = 0.1

    /// Starts the poll when a render appears, stops it and empties the store when the last one
    /// goes. Idempotent — called from the `didSet` of both sets on every insert and remove.
    func updateRenderProgressPolling() {
        let running = !bakingIDs.isEmpty || !recomputingConsolidateIDs.isEmpty
        if running {
            guard renderProgressTimer == nil else { return }
            let timer = Timer.scheduledTimer(withTimeInterval: Self.renderProgressPollInterval,
                                             repeats: true) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.pollRenderProgress()
                }
            }
            renderProgressTimer = timer
            RunLoop.main.add(timer, forMode: .common)   // goes on beating while a menu is open
        } else {
            renderProgressTimer?.invalidate()
            renderProgressTimer = nil
            renderProgress.replace(with: [:])
        }
    }

    /// One reading of the engine for every render on screen, written into the store in ONE
    /// assignment (and only if it changed — @see RenderProgressStore.replace).
    ///
    /// Rounded to the hundredth: that is already finer than a 14 pt pie can show, and it is what
    /// lets two consecutive readings compare EQUAL while a slow render crawls, so the circles are
    /// not invalidated on ticks that would draw the very same pixels.
    ///
    /// A key the engine answers -1 for (the job not launched yet, or just finished and erased)
    /// keeps the value it last had rather than dropping back to an empty circle — a circle that
    /// empties for one tick at the very end would read as a render starting over.
    func pollRenderProgress() {
        guard let engine else { renderProgress.replace(with: [:]); return }
        var next: [UUID: Double] = [:]
        func read(_ indicatorKey: UUID, engineKey: UUID) {
            let p = engine.renderProgress(forObject: engineKey.uuidString)
            if p >= 0 {
                next[indicatorKey] = (Double(p) * 100).rounded() / 100
            } else if let last = renderProgress.fraction(for: indicatorKey) {
                next[indicatorKey] = last
            }
        }
        // A bake is rendered under the id of the object that wears the veil.
        for id in bakingIDs { read(id, engineKey: id) }
        // A re-bake is rendered under a TEMPORARY's id, and shown on every instance of the
        // definition. @see recomputeRenderKeys
        for (defID, renderID) in recomputeRenderKeys where recomputingConsolidateIDs.contains(defID) {
            read(defID, engineKey: renderID)
        }
        renderProgress.replace(with: next)
    }
}
