import Foundation
import Observation

// MARK: - What a script lays over an object

// A third-party script can SHOW something on an object without touching the project: the words a
// transcription found, the passages a detector marked. It is a layer of presentation and nothing
// else — no undo, no dirty flag, never written to the session file, never in an undo snapshot —
// and it lives exactly as long as the script that laid it (@see ScriptOverlayStore.clear(owner:)).
//
// A store of its own, held by the view-model as a plain `let` and read by the one layer that draws
// it (`ScriptOverlayLayer`): the same arrangement as `RenderProgressStore`, for the same reason. A
// script rewrites its zones at every setting the hand changes, and a property of the view-model
// would be read by `TimelineView` itself — every rewrite would then re-evaluate the whole timeline.
//
// TIMES are in seconds RELATIVE TO THE START OF THE OBJECT — the frame the object's own marks
// live in, so the layer travels with the object for free. Sorted by `start` once, at the door, so
// the drawing can binary-search what is visible instead of walking thousands of words per frame.

/// The palette a zone can take. Deliberately small: a layer over an object has to read against
/// every stem colour and every object pastel, and five hues with an opacity is what a script can
/// ask for without designing a screen.
enum OverlayColor: String, CaseIterable, Sendable {
    case white, red, yellow, green, blue
}

struct OverlayText: Equatable, Sendable {
    let start: Double
    let end: Double
    let text: String
}

struct OverlayZone: Equatable, Sendable {
    let start: Double
    let end: Double
    let color: OverlayColor
    let opacity: Double
}

struct ScriptOverlay: Equatable, Sendable {
    /// The socket connection that laid it (@see CommandCallContext). Its closing clears the layer.
    var owner: UUID
    var rev: Int = 0
    /// Sorted by `start`.
    var texts: [OverlayText] = []
    /// Sorted by `start`.
    var zones: [OverlayZone] = []
    /// The longest span of a zone / a word: what a binary search on the START needs to know to
    /// step back far enough to catch an element that began before the visible window and is still
    /// running through it. Computed once, at the door.
    var maxZoneSpan: Double = 0
    var maxTextSpan: Double = 0
}

@Observable final class ScriptOverlayStore {

    /// A script that sends more than this has a bug, and the drawing would pay for it.
    static let maxElements = 20_000

    private(set) var overlays: [UUID: ScriptOverlay] = [:]

    /// Lays `texts` and / or `zones` on `object`. A field that is nil is KEPT — a script sends only
    /// the zones at every setting, not the thousands of words it laid once. `clearing` names
    /// fields to empty even though no new value comes with them. Returns the overlay as it now is.
    @discardableResult
    func set(object: UUID, owner: UUID,
             texts: [OverlayText]?, zones: [OverlayZone]?, clearing: Set<String>) -> ScriptOverlay {
        var o = overlays[object] ?? ScriptOverlay(owner: owner)
        o.owner = owner
        if clearing.contains("texts") { o.texts = [] }
        if clearing.contains("zones") { o.zones = [] }
        if let texts { o.texts = texts.sorted { $0.start < $1.start } }
        if let zones { o.zones = zones.sorted { $0.start < $1.start } }
        o.maxZoneSpan = o.zones.reduce(0) { max($0, $1.end - $1.start) }
        o.maxTextSpan = o.texts.reduce(0) { max($0, $1.end - $1.start) }
        o.rev += 1
        overlays[object] = o
        return o
    }

    /// Removes one object's overlay. Returns whether there was one.
    @discardableResult
    func clear(object: UUID) -> Bool { overlays.removeValue(forKey: object) != nil }

    /// Removes every overlay `owner` laid — a script that ended, however it ended.
    @discardableResult
    func clear(owner: UUID) -> Int {
        let ids = overlays.filter { $0.value.owner == owner }.map(\.key)
        for id in ids { overlays.removeValue(forKey: id) }
        return ids.count
    }

    @discardableResult
    func clearAll() -> Int {
        let n = overlays.count
        if n > 0 { overlays = [:] }
        return n
    }

    /// Drops the overlays of objects `exists` no longer knows (deleted, undone, exploded).
    func prune(keepingWhere exists: (UUID) -> Bool) {
        let gone = overlays.keys.filter { !exists($0) }
        for id in gone { overlays.removeValue(forKey: id) }
    }
}

// MARK: - Which connection is asking

/// The socket connection a command arrived on, for as long as its handler runs — a task-local, so it
/// survives the handler's own suspensions (a `script.panel.wait` can sit for seconds while other
/// connections' commands run in between). nil for a command that did not come through a socket
/// (`--exec`), which then all share `execOwner`.
enum CommandCallContext {
    @TaskLocal static var connectionID: UUID?
    static let execOwner = UUID()
    static var caller: UUID { connectionID ?? execOwner }
}

// MARK: - Binary search on a sorted-by-start array

extension Array {
    /// The index of the first element whose `start` (read by `key`) is >= `t` — the array being
    /// sorted by that key. `count` when none is.
    func firstIndex(startingAtOrAfter t: Double, key: (Element) -> Double) -> Int {
        var lo = 0, hi = count
        while lo < hi {
            let mid = (lo + hi) / 2
            if key(self[mid]) < t { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}
