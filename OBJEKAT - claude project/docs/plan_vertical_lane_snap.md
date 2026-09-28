# Plan — vertical lane snap (branch `feature/vertical-lane-snap`)

Status: PLAN ONLY, nothing implemented. Written 28 September 2026.

## The request

> Zoom vertically until one lane takes more than 70 % of the available height, and the vertical
> view snaps to the lanes: you move from one lane to the next, the view settles on one. And the
> vertical zoom is clamped at 90 % of the available height. The point: a near-full-height view
> of one file / one lane when working with precision.

Completely independent of the TIME snap (`snapEnabled`, the grid): nothing here reads or writes it.

---

## 1. What exists today (read before touching anything)

| Thing | Where |
|---|---|
| The vertical zoom STATE | `EditViewModel.blockHeight` (`EditViewModel.swift:620`, default 121.5). `laneStep = blockHeight + laneGap` (`TimelineView.swift:259`, `laneGap = 4`). |
| Today's clamp | `TimelineView.maxBlockHeight` (`TimelineView.swift:141`) = `max(120, viewportHeight − rulerHeight − laneGap − 8)` — i.e. ~100 % of the lane area, with a 120 pt floor that can EXCEED the window. `clampBlockHeight` (`:3057`). `minBlockHeight = 16`. |
| The one zoom door that clamps | `TimelineView.applyVerticalZoom` (`:3120`): clamp, session anchor (`vZoomAnchorRelY`, the viewport CENTRE — not the hover), scroll recomputed, `scrollTo`. Session = `vZoomHeld` or `vZoomLastEventTime` within 0.4 s (`zoomSessionIdleGap`). |
| Doors that reach it | ⇧-scroll vertical axis (`TimelineKeyHandler.swift:85`), ⇧R / ⇧T ×1.5 (`:736`, `:745`), the transport pill drag/scroll (`TransportView.swift:455-468`, via `vm.applyVerticalZoom`; falls back to a RAW write when the closure is nil). Pinch is HORIZONTAL only (`registerMagnifyMonitor`) — no vertical pinch exists. |
| Doors that BYPASS the clamp | `view.set block_height` (`Commands+View.swift:48`, raw write); project load `performStructureSetup` (`EditViewModel+ProjectLoad.swift:188`, `max(16, vp.blockHeight)` only); tab restore (`EditViewModel+Tabs.swift:128` → `pendingViewRestore`); the pill's nil-closure fallback. |
| The scroll | SwiftUI `ScrollView([.horizontal, .vertical])` + `ScrollPosition` (`TimelineView.swift:317`, `.scrollPosition($scrollPosition)` `:1063`). Exact offset mirrored into `TimelineScrollAnchor` (`:16`) by `onScrollGeometryChange` (`:1066-1077`), into `vm.viewScrollX/Y` (persisted). `scrollTo(x:y:)` (`:3222`) PRE-SETS the anchor (anti-flicker for zoom). |
| Vertical reveal | `revealDisplayLane` (`:3145`), driven by `vm.pendingLaneReveal` (`:1178`), written by `stepTimeSelectionLanes` / `stepCaretLane` (`EditViewModel+Selection.swift:108`, `:137`) — scrolls the LEAST it takes. |
| Viewport persistence | `ViewportState {pixelsPerSecond, blockHeight, scrollX, scrollY}` (`EditViewModel+Types.swift:78`), applied by `.onChange(of: pendingViewRestore)` (`TimelineView.swift:1159`), one runloop turn late. |
| Plain scroll | NOT handled by the monitor today: `registerScrollMonitor` (`TimelineKeyHandler.swift:10`) consumes ⇧ (zoom), ⌥ over a curve, and the Volume / Pan / Aux tools over their targets; everything else `return event` → the NSScrollView. |
| Header | `rulerHeight = MarkerBandGeometry.headerHeight(visibleLanes:)` — sticky, GROWS with each visible marker row. |
| Rows | Every display row is ONE `laneStep` tall: object lanes, open-group children, automation rows (`automationSpan`, one row = one lane), a piano roll = `pianoRollLaneSpan` (2) rows, headroom rows (`headroomLanes`). The grid is UNIFORM — `rulerHeight + i · laneStep`. |
| API | `view.state` / `view.set` / `input.scroll` / `input.zoom` / `input.key` (`Commands+View.swift`), UI mode only; `waitViewAtRest` (`:466`) = scroll + pps + block height still for 150 ms. |

---

## 2. Design decisions

### D1 — "Available height" and "lane height": one definition

- `available = viewportHeight − rulerHeight` — the lane area under the sticky header, marker rows
  included in the header. Read LIVE (it changes with marker rows shown and with the window).
- The ratio is `blockHeight / available` (the block, not `laneStep`: the 4 pt gap is not "the lane").
- Constants, in ONE pure unit (see §3): `snapEnterRatio = 0.70`, `maxRatio = 0.90`.
- Known imprecision, accepted: with LEGACY (always-visible) scrollbars the horizontal scroller eats
  ~15 pt of `viewportHeight`. Overlay scrollbars (the macOS default) do not. Not worth a second
  measurement path; noted for the eye.

### D2 — The clamp: 90 %, at EVERY door, through one function

`maxBlockHeight = max(minBlockHeight, 0.90 · available)` — the old `max(120, …)` floor goes (it could
exceed the window on a small one). Enforced by ONE function `enforceVerticalZoomBounds()` in
`TimelineView`, called from:

1. `applyVerticalZoom` (already clamps — switch it to the new max);
2. `.onChange(of: viewModel.blockHeight)` — the CATCH-ALL: any door that writes `blockHeight` raw
   (`view.set`, project load, tab restore, the pill's fallback) is re-clamped on the next turn.
   Idempotent: the corrected write triggers one more `onChange` that finds nothing to do;
3. `.onChange(of: geo.size.height)` (window resize) and `.onChange(of: rulerHeight)` (a marker row
   shown / hidden) — see D3 for what happens when the snap is ON;
4. the `pendingViewRestore` handler, BEFORE its scroll is applied (a saved 900 pt lane reopened in a
   600 pt window).

Guard: do nothing until the viewport has been MEASURED (`@State viewportHeight` starts at a fake 400;
a clamp against it at launch would permanently shrink a restored zoom). A `viewportMeasured` flag set
in the GeometryReader's `onAppear`.

`view.set block_height` answers the clamped value (it already returns `view.state` after rest) — a
script asking for 5000 gets `block_height ≈ 0.9·available`, never an error.

### D3 — Resizing while snapped: keep the RATIO (recommended)

Below 70 %: a smaller window only clamps (D2). At/above 70 % (snap active): the lane keeps its
FRACTION of the available height — `blockHeight = ratio · newAvailable` — and the framed lane is
re-framed without animation. Otherwise enlarging the window by 30 % silently drops a 75 % lane under
70 % and the mode switches off under the hand; shrinking would clamp it to 90 % and then keep it
there after re-enlarging. Same rule for a marker row shown / hidden. (Alternative: clamp-only
everywhere; simpler, but the mode is lost by a resize. Ask the user if D3 feels wrong.)

### D4 — What a "lane" is for the snap: every DISPLAY ROW

The grid is uniform (§1), so the snap targets are simply display rows `0 ..< visibleLanes`:
object lanes, open-group children, automation rows, piano-roll rows, the empty headroom rows. No
special case. Consequences, stated:

- a piano roll (2 rows) is walked row by row — you see its upper half, then its lower half;
- an automation row is a lane like any other (it already is, for the caret and ↑/↓);
- the marker band is part of the HEADER, never a target.

### D5 — Framing: CENTRE the lane in the available area (recommended)

`scrollY(i) = clamp(i·laneStep + blockHeight/2 − available/2, 0, maxScrollY)`.

With the 90 % cap that is a 5 % margin above and below (15 % at 70 %): a sliver of the previous AND
the next lane stays visible, which says "there is more, this way". Top-aligned would show the next
lane only, and packs the whole margin below.

The one exception, accepted: lane 0 cannot be centred (`scrollY` clamps at 0) — it rests
TOP-aligned with its double margin below. Framing is ONE constant (`.centre | .top`) in the unit so
switching after the feel test is a one-line change.

Neighbour targets must be DISTINCT to step: at the bottom several rows can clamp onto `maxScrollY`;
"next lane" = the first row whose target is > current + 0.5 pt, otherwise no-op. Headroom rows
(≥ 1 at these heights, `bottomHeadroomFraction` 40 %) guarantee the last OCCUPIED lane is centrable.

"Current lane" (the one framed) = the row whose target is nearest to the current `scrollY`.

### D6 — The scroll gesture: intercept in the monitor, one lane per gesture (recommended)

Two families of solution were weighed:

- **(A, recommended) The `scrollWheel` monitor takes over vertical scrolling while the snap is
  active.** Deterministic, testable with `input.scroll`, same idiom as ⇧-zoom (the codebase already
  left SwiftUI gestures for monitors when it needed control — the pinch). It never FIGHTS momentum:
  it swallows it.
- (B, rejected) SwiftUI `scrollTargetBehavior` with a custom `ScrollTargetBehavior` that rewrites the
  deceleration target (native momentum landing, `context.originalTarget` to cap one lane). Tempting,
  but unverified on macOS for discrete wheel events, in a 2-axis ScrollView, and against the
  synthetic-event path the tests rely on; a spike could revive it later.
- (C, rejected) Free scroll then "snap to nearest" on idle: it is a jump after the fact, not
  "one lane per gesture", and a flick overshoots several lanes before correcting.

Rules of (A), in a new branch AT THE END of `registerScrollMonitor` (after ⇧-zoom, ⌥-curve and the
three tools, which keep priority — a Volume-tool wheel over a block stays a volume wheel):

1. **Only when active** (`blockHeight / available > 0.70`), no modifier held (⌘⇧⌥⌃ intersection
   empty — see the permanent point about arrows/flags), and a hover on the timeline (as today).
2. **Axis lock per gesture**, copied from ⇧-zoom: accumulate |dx|, |dy| over a 3 pt dead zone,
   decide once per gesture (`.began`, or for a phaseless wheel an idle gap). HORIZONTAL-dominant →
   `return event` untouched for the whole gesture (NSScrollView's predominant-axis scrolling keeps
   y still). VERTICAL-dominant → the monitor owns the gesture: every event of it, phase AND momentum,
   returns `nil`.
3. **Trackpad / Magic Mouse** (`hasPreciseScrollingDeltas`): ONE lane per gesture. The step fires
   AS SOON AS the accumulated vertical travel crosses a threshold (recommend 24 pt — responsive,
   not waiting for finger-up); everything after it, momentum included, is swallowed. A new
   `.began` rearms. Direction = AppKit sign (positive `scrollingDeltaY` = previous lane), which is
   what "natural scrolling" already folds in.
4. **Wheel** (no precise deltas, no phase): ONE lane per NOTCH. Notches arriving during the step
   animation ACCUMULATE onto the target (target lane += 1 per notch) and the animation is
   retargeted — a stepped wheel, not a lost notch.
5. **The step** = `frameLane(i, animated: true)`: `withAnimation(.easeOut(duration: 0.18))
   { scrollPosition.scrollTo(y:) }`. The animated variant must NOT pre-set `scrollAnchor.y` the way
   `scrollTo` does: the sticky header reads the anchor, and a pre-set would jump the ruler to the
   target while the content is still animating. Let `onScrollGeometryChange` drive the anchor for
   animated moves; x is unchanged so the cull window is not concerned.
6. State lives in `HoverState` (a plain class, NOT observed — no repaint per event, @see
   polls-that-repaint): `vSnapAxis`, `vSnapAccum`, `vSnapStepped`, `vSnapTargetLane`,
   `vSnapLastEventTime`.

Rejected alternative for (3): one lane per N points of travel. A lane at >70 % is nearly a screen;
a long swipe skipping 2-3 of them is the overshoot the mode exists to prevent. Revisit only if the
feel test asks for it.

### D7 — The safety net: re-snap when the scroll comes to rest off-grid

Other things can leave `scrollY` between two lanes while snapped: dragging the vertical scroller, the
drag-follow scroll during a block drag, a horizontal gesture whose tiny vertical component got
through, a programmatic scroll. `onScrollPhaseChange` (macOS 15, deployment target is 15.6): on
`.idle`, if snap active, no drag in flight, no pending framing and `scrollY` is more than 0.5 pt off
the nearest target → `frameLane(nearest, animated: true)`. Converges in one move (the framed position
is on-grid, `.idle` again finds nothing to do).

### D8 — Crossing 70 % while zooming: frame at the END of the zoom session

Never snap per notch — it would fight the zoom's own anchor. During the session the anchor (viewport
centre, unchanged) keeps the content under the eye. When the session ENDS and the snap is active,
frame the lane under that anchor (the lane at the viewport centre): continuity — what was at the
centre while zooming is what gets framed.

Session end: `endVerticalZoomDrag` (pill), or a debounce (`DispatchWorkItem`, ~0.2 s after the last
vertical zoom notch) for the wheel / ⇧-scroll / ⇧R / ⇧T — the existing 0.4 s idle gap is too long to
feel like a settle. Zooming OUT below 70 % needs nothing: the mode simply stops.

At the 90 % cap, further zoom-in notches are no-ops (`guard clamped != blockHeight`) — the session
still ends and re-frames, which is harmless.

(Possible follow-up, NOT in scope: anchoring the vertical zoom on the HOVER rather than the centre,
so the lane under the pointer is the one that grows into the frame.)

### D9 — ↑ / ↓ (caret, time selection): the view FOLLOWS, framing the lane

`revealDisplayLane` scrolls the least it takes; in snap mode that would bottom-align a lane
partially visible in its sliver — off-grid. In snap mode it FRAMES the lane instead
(`frameLane(lane, animated: true)`), even if the lane is "in sight". So walking the caret or a
selection with ↑/↓ walks the view one lane per press, exactly like the scroll gesture. The model
side (`pendingLaneReveal`) is untouched.

### D10 — Project reopen / tab switch / `view.set`

`pendingViewRestore`: clamp (D2) THEN apply the scroll; if the snap is active afterwards, replace the
saved scrollY by `frameLane(nearest)` (no animation) — the window may not be the size it was saved
at. Nothing new is PERSISTED: the snap state is derived from `blockHeight` and the window. Session
format UNCHANGED.

### D11 — Independence from the time snap

No reference to `snapEnabled` / `effectiveSnapEnabled` / the grid anywhere in the new code; no
toggle, no modifier inversion (⌘ keeps its meaning for the TIME snap). The mode is purely a function
of the zoom. No new visible string → no i18n key (unless a HUD is wanted later).

---

## 3. Files and functions to touch

**New — `objekat/Timeline/VerticalLaneSnap.swift`** (pure, no view, no model — like `SendColumns`,
`PianoRollFraming`): so the arithmetic can be compiled and asserted alone.

```swift
enum VerticalLaneSnap {
    static let enterRatio = 0.70
    static let maxRatio   = 0.90
    enum Framing { case centre, top }
    static let framing: Framing = .centre
    static func maxBlockHeight(available: Double, minBlockHeight: Double) -> Double
    static func isActive(blockHeight: Double, available: Double) -> Bool      // bh/available > 0.70
    static func scrollY(forLane i: Int, blockHeight: Double, laneStep: Double,
                        available: Double, maxScrollY: Double) -> Double
    static func nearestLane(scrollY: Double, …, laneCount: Int) -> Int
    static func neighbour(of lane: Int, direction: Int, …) -> Int?          // nil at an end (D5)
    static func isOnGrid(scrollY: Double, …, tolerance: Double = 0.5) -> Bool
    static func resizedBlockHeight(blockHeight: Double, oldAvailable: Double,
                                   newAvailable: Double, minBlockHeight: Double) -> Double  // D3
}
```

**`objekat/Timeline/TimelineView.swift`**
- `maxBlockHeight` (`:141`) → `VerticalLaneSnap.maxBlockHeight(available:…)`; add
  `availableLaneHeight`, `verticalSnapActive`, `viewportMeasured`.
- `enforceVerticalZoomBounds()` (D2/D3) + the `onChange`s on `viewModel.blockHeight`,
  `geo.size.height` (`:1082`), `rulerHeight`.
- `frameLane(_:animated:)`, `currentFramedLane()`, `stepFramedLane(by:)` (used by the monitor).
- An animated scroll variant that does not pre-set the anchor (D6.5), beside `scrollTo` (`:3222`).
- `applyVerticalZoom` (`:3120`) / `touchVerticalZoomSession` (`:3100`): arm the end-of-session
  debounce (D8); `endVerticalZoomDrag` closure (`:1132`) frames too.
- `revealDisplayLane` (`:3145`): snap branch (D9).
- `pendingViewRestore` handler (`:1159`): clamp then frame (D10).
- `.onScrollPhaseChange` safety net (D7) next to the two `onScrollGeometryChange`.
- `onAppear`: install `viewModel.verticalSnapProbe` (see API) and `viewModel.frameLaneForTesting`
  if a test door is kept (not needed — ↑/↓ and `input.scroll` cover it).

**`objekat/Timeline/TimelineKeyHandler.swift`** — `registerScrollMonitor`: the snap branch at the
end (D6), reading `rulerH`, `vm.blockHeight` LIVE per event as the rest of the monitor does, and
the viewport height through a closure/`HoverState` field (the monitor has no `viewportHeight`; read
it off `self` — `TimelineView` is a struct captured at registration, so pass a reader set in
`onAppear`, NOT a captured value — the same trap `rulerHeight` hit on 14 September).
`HoverState` gains the D6.6 fields.

**`objekat/EditViewModel/EditViewModel.swift`** — `@ObservationIgnored var verticalSnapProbe:
(() -> VerticalSnapProbe)?` beside `applyVerticalZoom` (`:717`); a small struct
`VerticalSnapProbe {availableHeight, maxBlockHeight, laneStep, ratio, active, framedLane?,
onGrid, pendingFraming, rulerHeight, viewportHeight}` (in `EditViewModel+Types.swift`).

**`objekat/CommandAPI/Commands+View.swift`**
- `viewState()` (`:493`) gains `vsnap: {available_h, max_block_height, lane_step, ratio, active,
  lane, on_grid, pending, ruler_h}` (null when the probe is nil).
- `view.set` gains `window_h` (resize the timeline's window content so the lane area changes —
  the only way to test D2.3 / D3 without a hand); the clamped `block_height` comes back in the
  answer (D2).
- `waitViewAtRest` (`:466`): also wait while `pendingFraming` is true — otherwise the 150 ms of
  stillness before the D8 debounce fires reads as "at rest" and the test samples the wrong frame.

**`objekat/App/TransportView.swift`** — no change needed (goes through `applyVerticalZoom`); the
nil-closure fallback is caught by the D2 catch-all.

**Docs** — `command_api.md` ("Synthetic navigation": the `vsnap` block, `window_h`);
`CLAUDE.md` Current state entry after the fact; `validations-en-attente` gets the feel list (§5).

**No change**: session format, `ViewportState`, i18n catalogue, engine.

### Order of commits (each buildable)

1. `VerticalLaneSnap.swift` + `tools/test_vertical_lane_snap.swift`.
2. The 90 % clamp at every door (D2) + `view.state.vsnap` + `view.set window_h` + `waitViewAtRest`.
3. Framing + the resize ratio (D3, D5, D10).
4. The monitor branch (D6) + the idle safety net (D7).
5. End-of-zoom framing (D8) + ↑/↓ follow (D9).
6. `tools/scenario_vertical_snap.py`, docs.

---

## 4. Test plan (to be executed after implementation)

### T0 — Baseline
Fresh `main` Debug build warning count first (last measured **1550**), then this branch — report the
delta (expected 0). `xcodebuild -scheme objekat -configuration Debug` is the only authority.

### T1 — Standalone unit: `tools/test_vertical_lane_snap.swift` (swiftc, no app)
- `maxBlockHeight` = 0.9·available; floor at `minBlockHeight` for a tiny window; never above available.
- `isActive`: false at exactly 0.70, true just above.
- `scrollY(forLane:)` centres (margin = (available − bh)/2 either side); lane 0 → 0; bottom lanes
  clamp to `maxScrollY`.
- `nearestLane` round-trips `scrollY(forLane: i)` for every i; ties resolved consistently.
- `neighbour` returns nil at row 0 going up and when the next target is not distinct at the bottom.
- `isOnGrid` tolerance 0.5 pt.
- `resizedBlockHeight` preserves the ratio and re-clamps at 90 %.
- A sweep over available ∈ {200…1400}, ratio ∈ {0.71…0.90}: consecutive targets strictly increasing
  until the clamp.

### T2 — UI-mode scenario: `tools/scenario_vertical_snap.py <socket>` (NEW)
Launch `objekat --api --no-recent --socket=/tmp/o.sock` (UI mode, NEVER `--headless`; hands off the
trackpad; every gesture must answer `contaminated: false`). Fixture: 12 lanes × 20 `bip.wav`
objects (as `scenario_navigation.py`).

Clamp
1. `view.set block_height=5000` → `block_height == vsnap.max_block_height` and
   `≈ 0.9·available_h` (±0.5).
2. `input.zoom axis=vertical factor=4` (shift_scroll) from 121.5 → capped at max, `achieved_factor`
   < 4. Same with `via: keys` (⇧T ×5).
3. `marker_lane.create` + visible → `ruler_h` grows, `available_h` shrinks, `block_height` re-clamped
   (≤ 0.9·new available). Hide it again → state consistent.
4. `view.set window_h` smaller while ratio < 0.7 but bh > new max → clamped; `window_h` restored.

Below 70 % (free)
5. `block_height = 0.5·available`, `input.scroll direction=down distance_px=137 style=trackpad` →
   `scroll_y` moved ≈ 137 (the ordinary NSScrollView path), `on_grid` NOT required, `active: false`.

Above 70 % (snapped)
6. `block_height = 0.8·available`, `view.set scroll_y` to an off-grid value → after rest, `on_grid`
   (the D7 safety net) and `lane` = nearest.
7. From lane k framed: trackpad swipe down 60 pt WITH momentum → lane k+1 exactly, `on_grid`,
   `scroll_y == expected centring formula` (±0.5). Up → back to k.
8. A long swipe (600 pt, momentum) → still exactly ONE lane.
9. A sub-threshold swipe (10 pt) → no lane change, still on grid.
10. `style: wheel notches=3` → exactly 3 lanes (D6.4).
11. Horizontal swipe (right 400) in snap mode → `scroll_x` moved, `scroll_y` unchanged, `on_grid`.
12. At the first lane going up and at the last reachable lane going down → no change, no error.
13. `group.expand` a group with children → the children rows are walkable lanes (lane index
    advances by one through them).
14. ⇧ held (`modifiers: ["shift"]`) in snap mode still zooms (priority of ⇧-zoom intact).

Zoom across the threshold (D8)
15. From 0.5 ratio, `input.zoom vertical factor=1.8` → after rest `active: true`, `on_grid`,
    `lane` = the lane that was at the viewport centre before the zoom.
16. Zoom out below 70 % → `active: false`, then a free swipe moves continuously again.

Resize (D3)
17. Snapped at 0.8: `view.set window_h` −20 % → ratio still 0.8 (±0.01), `on_grid`, same `lane`.
    +20 % → same. Restore.

↑ / ↓ (D9)
18. `caret.set` on lane k, snapped; `input.key down` ×2 → `lane == k+2`, on grid.
    Same with a time selection (`timesel.set` + `input.key down`).

Persistence (D10)
19. Snapped at 0.8, lane k → `project.save_as` (scratch dir) → `project.open` → `active`, `lane == k`,
    `on_grid`. Also `tab.new` / `tab.select` back → same.

Independence
20. `project.set_snap false` then true → none of the vsnap fields change; repeat 7 with the time
    snap OFF → identical result.

### T3 — Non-regression
- `tools/scenario_navigation.py` in UI mode — ⚠ its vertical zoom assertions start at
  `block_height 121.5` and zoom by factors: check none crosses the new 90 % cap or the 70 % snap
  threshold on the test machine's window; if one does, start it lower rather than loosen the
  assertion, and say so.
- `tools/smoke.jsonl` (`--exec`), `tools/scenario_families.py` (191 OK), `tools/scenario_markers.py`
  (ALL PASS) — headless, fresh instance each.
- `tools/i18n/xcstrings.py check` and `orphans` — unchanged key count, no orphan.
- The standalone Swift suites of `tools/` still pass (they are untouched, a sanity run).
- `CGWindowListCopyWindowInfo` on each headless pid: no window.
- `tools/bench_navigation.py` once, Release, 1 vs 480 objects: the vertical scroll path is now the
  monitor's in snap mode — report numbers, no verdict.

### T4 — Only the user can see / feel (goes into `validations-en-attente`)
- Whether 70 % is the right threshold and 90 % the right cap; whether centring (5 % slivers) reads
  better than top-aligned.
- The trackpad feel: 24 pt threshold, one lane per gesture, momentum swallowed — does a flick feel
  "eaten", does a slow drag feel late? The 0.18 s ease-out.
- The mouse wheel: one lane per notch, fast spinning.
- The ruler/marker header during the animated step (no jump ahead of the content).
- Crossing 70 % while zooming: is the framing at session end a pleasant settle or a surprise jump?
  Is the viewport-centre anchor the right lane, or should it be the hovered one (follow-up)?
- A piano roll walked in two halves; automation rows as lanes.
- Window resize keeping the ratio (D3) vs. just clamping.
- Legacy scrollbars (mouse plugged in): is the 90 % still fully visible?
- Dragging the vertical scroller knob in snap mode → release re-frames (D7): acceptable or annoying?
