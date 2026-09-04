import Foundation

/// Quiescence detection: "has the model finished working?"
///
/// Without it, every script is non-deterministic: the view-model defers a great deal of work
/// (debouncing the sound-object mirror, cascading re-bakes, definition bakes with completion
/// blocks), and a read command issued right after a mutation command would observe an
/// in-between state.
///
/// AN IMPLEMENTATION CHOICE — the plan called for a `beginWork`/`endWork` counter placed in each
/// deferred-work site. On inspection, that counter would have duplicated state that ALREADY
/// EXISTS: the view-model publishes `bakingIDs`, `recomputingDefinitionIDs`, `isCascadingRebake`
/// and `isScanning`, and keeps its debounce `DispatchWorkItem` at hand. We READ them rather than
/// instrument — so zero changes to the hot paths, and above all no risk of an unbalanced
/// counter (one `endWork` forgotten on an error branch would block `wait_idle` for ever, a far
/// more painful failure than the one being solved).
///
/// WHAT THIS DOES NOT COVER — deferred work ON THE ENGINE SIDE is not observable from Swift:
/// `OBJEngineCore` reschedules playback after a 150 ms `dispatch_after` and runs a latency
/// watcher that can rebuild the graph. Exposing those states would mean touching the engine,
/// which is ruled out here. Hence `wait_idle`'s `settle_ms` parameter: an explicit grace period
/// to ask for when the measurement that follows depends on the audio graph and not the model alone.
@MainActor
enum Quiescence {

    /// Polling interval. Short enough not to add any noticeable latency to a run of commands,
    /// long enough not to saturate the main loop during a wait of several seconds.
    private static let pollInterval: Duration = .milliseconds(20)

    /// What is still in flight, in plain words. The list is the content of a `timeout`'s `details`:
    /// a wait that expires without saying what it was waiting for cannot be diagnosed.
    static func inFlight() -> [String] {
        var reasons: [String] = []

        if let vm = CommandContext.shared.viewModel {
            // `bakingIDs` carries an ancestor's name: freezing is no longer a user action (the menu
            // entries were removed), but the RENDER LOCK it introduced still serves — sound objects are
            // what arm it now, for the time of a definition bake or a placement re-bake. So the label
            // says what actually happens: "freeze in progress" would no longer teach anyone anything.
            if !vm.bakingIDs.isEmpty {
                reasons.append("sound object render running (\(vm.bakingIDs.count))")
            }
            if !vm.recomputingDefinitionIDs.isEmpty {
                reasons.append("sound object re-bake (\(vm.recomputingDefinitionIDs.count))")
            }
            if vm.isCascadingRebake {
                reasons.append("cascading re-bake")
            }
            if vm.liveMirrorWorkItem != nil {
                reasons.append("sound object mirror debounce")
            }
            // An export started FROM THE PANEL creates no job: without this test, `wait_idle` would
            // call itself idle while a render is writing a file.
            if vm.exportJob?.isRunning == true {
                reasons.append("export running")
            }
            if vm.isScanning {
                reasons.append("plugin scan")
            }
        }

        let jobs = JobRegistry.shared.runningJobIDs()
        if !jobs.isEmpty {
            reasons.append("jobs running: \(jobs.joined(separator: ", "))")
        }
        return reasons
    }

    static var isIdle: Bool { inFlight().isEmpty }

    /// Hands back when nothing is in flight any more AND one turn of the main loop has passed.
    /// - Parameters:
    ///   - timeoutMs: the total waiting budget.
    ///   - settleMs: a grace period added once inactivity is seen, to leave the engine its
    ///     unobservable deferred work (see the note at the head of this file).
    /// - Throws: a `CommandError` of code `timeout`, with the list of what is still in flight.
    static func waitIdle(timeoutMs: Int, settleMs: Int = 0) async throws -> JSONValue {
        let started = ContinuousClock.now
        let budget = Duration.milliseconds(max(0, timeoutMs))

        while true {
            let pending = inFlight()
            if pending.isEmpty { break }
            guard ContinuousClock.now - started < budget else {
                throw CommandError(code: .timeout,
                                   message: "still busy after \(timeoutMs) ms",
                                   details: .object(["in_flight": .array(pending.map { .string($0) })]))
            }
            try? await Task.sleep(for: pollInterval)
        }

        if settleMs > 0 {
            try? await Task.sleep(for: .milliseconds(settleMs))
        }

        // One turn of the main loop: work posted with `DispatchQueue.main.async` by the last
        // mutation (debounce re-arming, completion callbacks) has had its chance to run BEFORE
        // we declare things calm. Without that turn, `wait_idle` could hand back just before a
        // new piece of work signs itself up.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }

        // That turn may have re-armed something: we say so rather than lie about the calm.
        let residual = inFlight()
        let elapsed = ContinuousClock.now - started
        return .object([
            "idle": .bool(residual.isEmpty),
            "waited_ms": .int(Int(elapsed.components.seconds * 1000
                                  + elapsed.components.attoseconds / 1_000_000_000_000_000)),
            "in_flight": .array(residual.map { .string($0) }),
        ])
    }
}
