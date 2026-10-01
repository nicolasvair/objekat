import AppKit

// MARK: - The plugin drag in flight, readable while it hovers
//
// A system drag session hands a drop target only an `NSItemProvider`, whose payload is loaded
// ASYNCHRONOUSLY — at the instant `dropUpdated` has to answer with a cursor (move, copy, or the
// forbidden sign), nothing has been decoded yet. Yet what a drop would DO now depends on what is
// being carried (a plain card, an instance of an FX link, a whole block) and on where it is aimed,
// and a target that can only learn that after the hand has let go cannot say "no" in time.
//
// So the SOURCE says what it carries, once, synchronously, when the drag begins: `begin` is called
// from the drag provider closure (the one place that builds the payload, @see SynopticBoundView),
// and every target reads `current` — the delegates of the signal view, the timeline and a bus's
// strip — to ask the resolver (`EditViewModel.pluginDropOutcome`) for the cursor and the band.
//
// The lifetime is the drag's, and a drag has no "ended" callback a source can rely on: a session
// cancelled over nothing (Escape, a release outside any window) tells nobody. So the same net as
// `PluginDropHint`: the session is read as ABSENT as soon as no mouse button is down. A drop clears
// it at once (`end`).
//
// A reader must still check that the drag it is looking at IS a plugin drag (`PluginDrop.carries`)
// before consulting `current`: a Finder drag begun after a cancelled plugin drag would otherwise
// meet a stale payload while its own button is down.

@MainActor
final class PluginDragSession {
    static let shared = PluginDragSession()

    private var payload: PluginDragPayload?

    /// A plugin drag has just begun: this is what it carries.
    func begin(_ p: PluginDragPayload) { payload = p }

    /// The drag is over (a drop was made, or it was abandoned).
    func end() { payload = nil }

    /// What the drag in flight carries; nil when there is none — or when no mouse button is down any
    /// more, which means the session died without telling anyone.
    var current: PluginDragPayload? {
        if payload != nil, NSEvent.pressedMouseButtons == 0 { payload = nil }
        return payload
    }
}
