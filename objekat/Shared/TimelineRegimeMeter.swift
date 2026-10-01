import Foundation

// Which REGIME each block of the timeline was drawn in, counted from OUTSIDE the drawing rather
// than guessed at with a profile. A block reaches the screen one of two ways: as a row of the
// batched `Canvas` of `TimelineView` (`plainBlocksCanvas`, one node for all of them), or as a rich
// SwiftUI view of its own (`SoundBlockView`, `GroupBlockView`, `InfiniteBusBandView`). The two cost
// very differently — measured on 600 pieces, the rich view's per-block observation tracking and
// graph update is what a selected open group pays for — so "how many of each, right now" is the
// number every perf question about the timeline starts with. `perf.census` reports it
// (`CommandAPI/Commands+Runtime.swift`), `tools/bench_groups.py` prints it beside its setup line.
//
// Same pattern as `WaveformCacheMeter`, and for the same reasons: process-wide statics, a lock
// rather than an actor (the Canvas's renderer closure may run off the main thread, and a script
// reads the counters from the MainActor with no `await` in its way), and the one rule that makes
// it free — every write is PER PASS (one per evaluation of the timeline's blocks layer, one per
// Canvas draw), never per block. The per-block counts are summed in the loop that already walks
// the blocks and handed over once.
//
// WHAT A "PASS" IS: the last evaluation of the blocks layer, i.e. what the last frame that
// re-evaluated it put on screen. Only VISIBLE blocks count (those intersecting the viewport plus
// its 80 px margin, @see `TimelineView.isEntryVisible`): a block culled away costs nothing and is
// not counted in either regime. Nothing is accumulated across passes — a counter that summed
// frames would grow with how long the script waited, which says nothing about the regime.

/// A snapshot — see the file header for what a "pass" is.
nonisolated struct TimelineRegimeStats: Sendable {
    /// Clips drawn as rows of the batched Canvas, last pass.
    var clipsCanvas = 0
    /// Blocks that are NOT groups and went to a rich SwiftUI view (a clip kept rich by a drag
    /// preview, a tool overlay, a rename, a bake…, plus every aux and MIDI clip), last pass.
    var clipsRich = 0
    /// Groups drawn in the Canvas (`GroupBlocksCanvas`). 0 under the Debug A/B switch.
    var groupsCanvas = 0
    /// Groups drawn as a rich view (`GroupBlockView`, or `InfiniteBusBandView` for a group that is
    /// an infinite bus). An infinite AUX is counted with the clips: it is not a group.
    var groupsRich = 0
    /// The inline BANDS of open groups drawn in the Canvas (the tinted rows under a group's
    /// block, its rise and its '+'): one per OPEN group, culled or not — all of them are handed
    /// to the one Canvas, which cuts them to the viewport itself. The production path.
    var groupBandsCanvas = 0
    /// The same bands, drawn as SwiftUI views (one per open group). 0 in production: only the
    /// Debug A/B switch (`DebugRenderSwitches.forceRichBlocks`) puts them back.
    var groupBandsRich = 0
    /// How many times the blocks layer has been evaluated since the last `reset`.
    var passes = 0
    /// How many times the batched Canvas has drawn since the last `reset`.
    var canvasDraws = 0
}

// `nonisolated` for the same reason as `WaveformCacheMeter`: the project defaults every
// declaration to `@MainActor`, and the Canvas's renderer closure may call `recordCanvasDraw()`
// from wherever SwiftUI renders it — a lock, not the actor, is what makes this safe.
enum TimelineRegimeMeter {
    nonisolated private static let lock = NSLock()
    nonisolated(unsafe) private static var stats = TimelineRegimeStats()

    nonisolated static func snapshot() -> TimelineRegimeStats {
        lock.lock(); defer { lock.unlock() }
        return stats
    }

    /// Zeroes the cumulative counters (`passes`, `canvasDraws`); the last-pass counts are kept —
    /// they describe what is on screen now, not a running total.
    nonisolated static func reset() {
        lock.lock(); defer { lock.unlock() }
        stats.passes = 0
        stats.canvasDraws = 0
    }

    /// One evaluation of the blocks layer: the regime counts it ended up with.
    nonisolated static func recordPass(clipsCanvas: Int, clipsRich: Int,
                                       groupsCanvas: Int, groupsRich: Int,
                                       groupBandsCanvas: Int, groupBandsRich: Int) {
        lock.lock(); defer { lock.unlock() }
        stats.clipsCanvas = clipsCanvas
        stats.clipsRich = clipsRich
        stats.groupsCanvas = groupsCanvas
        stats.groupsRich = groupsRich
        stats.groupBandsCanvas = groupBandsCanvas
        stats.groupBandsRich = groupBandsRich
        stats.passes += 1
    }

    /// One draw of the batched Canvas.
    nonisolated static func recordCanvasDraw() {
        lock.lock(); defer { lock.unlock() }
        stats.canvasDraws += 1
    }
}
