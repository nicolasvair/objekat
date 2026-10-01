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

/// WHY a block is drawn as a rich SwiftUI view instead of in the batched Canvas — the FIRST rule,
/// in the order `TimelineView.clipRichReason` / `groupRichReason` test them, that sends it there.
/// One reason per rich block, so the histogram adds up to `clipsRich + groupsRich`. The cases are
/// the rules' own conditions, named; adding a rule to the partition means adding a case here.
nonisolated enum RichReason: Int, CaseIterable, Sendable {
    /// The Debug A/B switch `DebugRenderSwitches.forceRichTools` is on: the Volume / Pan / Aux tool
    /// is armed and EVERY block carries its overlay as a rich view (the pre-Canvas regime). Never
    /// in production (and never in Release).
    case tool
    /// The Volume / Pan / Aux tool is armed and the block is AIMED AT: hovered, grabbed by a
    /// drag, or (Aux) holding the send focus. One block at a time.
    case toolHover
    /// The Volume / Pan / Aux tool draws something on this block and the block is cut by a
    /// viewport edge, so its controls follow the EXACT scroll the Canvas does not know
    /// (`LiveScroll.spanIsInvariant` is false). Bounded by the lanes on screen.
    case toolSpan
    /// The Stem tool is armed and the pointer is on this block (its hover veil is a rich layer).
    case stemHover
    /// A drag / trim / resize / fade preview is under way on this block.
    case preview
    /// The neighbour of a spilling fade (`spillPlan`): it moves with the drag without being in
    /// any of its id sets.
    case spill
    /// A MIDI clip (always rich).
    case midi
    /// An aux (always rich).
    case aux
    /// An instance of a consolidated object (its link / freshness badge is a rich view).
    case consolidate
    /// The name is being edited.
    case rename
    /// A bake is running on it.
    case bake
    /// A looping group (the composite repeats and the IN/OUT grips are views).
    case loop
    /// An infinite bus (`InfiniteBusBandView`).
    case infinite
    /// An open consolidated object being edited / previewed (its ✕ and its spinner).
    case editing
    /// Debug A/B switch (`DebugRenderSwitches.forceRichBlocks`) only; never in Release.
    case forceRich

    static let count = allCases.count

    /// The key `perf.census.regimes.rich_reasons` carries.
    var key: String {
        switch self {
        case .tool: return "tool"
        case .toolHover: return "tool_hover"
        case .toolSpan: return "tool_span"
        case .stemHover: return "stem_hover"
        case .preview: return "preview"
        case .spill: return "spill"
        case .midi: return "midi"
        case .aux: return "aux"
        case .consolidate: return "consolidate"
        case .rename: return "rename"
        case .bake: return "bake"
        case .loop: return "loop"
        case .infinite: return "infinite"
        case .editing: return "editing"
        case .forceRich: return "force_rich"
        }
    }
}

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
    /// Why each rich block is rich, last pass: the count per `RichReason` (indexed by `rawValue`).
    /// Sums to `clipsRich + groupsRich`. Counted in the same loop as the partition, with the
    /// partition's own rules — it describes the rule, it never decides anything.
    var richReasons = [Int](repeating: 0, count: RichReason.count)
    /// The element count of each unconditional `ForEach` layer of the timeline's body, last pass
    /// (an element = the root of one SwiftUI subtree, so a layer's cost is paid in proportion to
    /// it). Keyed by layer name; only layers that are evaluated on EVERY pass are recorded, so a
    /// value is never older than the last pass.
    var layerElements: [String: Int] = [:]
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
                                       groupBandsCanvas: Int, groupBandsRich: Int,
                                       richReasons: [Int]) {
        lock.lock(); defer { lock.unlock() }
        stats.richReasons = richReasons
        stats.clipsCanvas = clipsCanvas
        stats.clipsRich = clipsRich
        stats.groupsCanvas = groupsCanvas
        stats.groupsRich = groupsRich
        stats.groupBandsCanvas = groupBandsCanvas
        stats.groupBandsRich = groupBandsRich
        stats.passes += 1
    }

    /// The element count of one `ForEach` layer of the body, this pass (one write per layer per
    /// pass, never per element).
    nonisolated static func recordLayer(_ name: String, elements: Int) {
        lock.lock(); defer { lock.unlock() }
        stats.layerElements[name] = elements
    }

    /// One draw of the batched Canvas.
    nonisolated static func recordCanvasDraw() {
        lock.lock(); defer { lock.unlock() }
        stats.canvasDraws += 1
    }
}
