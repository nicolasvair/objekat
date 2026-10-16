import Foundation

// MARK: - The directions of a "+" and what each one asks for (PURE: no view, no store, no model)
//
// A "+" of the signal view is taken in the hand and dragged in a DIRECTION (@see SynopticPlusGesture). Which
// action each direction asks for is the user's to choose — an app preference, never the project's
// (@see PlusShortcutStore, which keeps a `PlusShortcutMap` in UserDefaults). This file is the model of that
// choice: the eight directions, the actions one can put on them, and the map with its defaults.
//
// THE DIRECTIONS ARE FIXED: eight sectors of ±15° each. The three that existed before the map (right 0°,
// down-right −30°, left 180°) keep their exact geometry, boundaries included; the five others sit in the
// angles that asked for nothing until then (up-right +30°, up 90°, up-left 150°, down-left −150°, down −90°),
// so the DEFAULT map asks for exactly what the "+" always did — and draws exactly the same zones, a direction
// mapped to `.none` having no zone at all. Between two sectors there is still dead angle (45°…75°, 105°…135°
// and their mirrors): a drag there asks for nothing.
//
// This file is compiled alone by `tools/test_synoptic_plus_shortcuts.swift` and alongside
// `SynopticPlusGesture.swift` by `tools/test_synoptic_plus_gesture.swift`: it must stay free of every other
// type of the app.

/// One of the eight directions a "+" can be dragged in. `allCases` runs clockwise ON SCREEN from the right
/// — the order the zones are listed in (@see SynopticPlusGesture.sectors).
enum PlusDirection: String, Codable, CaseIterable, Hashable {
    case right, downRight, down, downLeft, left, upLeft, up, upRight

    /// Half the angular width of every sector, in degrees.
    static let tolerance: Double = 15

    /// The direction's axis, in degrees from the horizontal, POSITIVE UPWARD (as `SynopticPlusGesture.angle`).
    var angle: Double {
        switch self {
        case .right:     return 0
        case .downRight: return -30
        case .down:      return -90
        case .downLeft:  return -150
        case .left:      return 180
        case .upLeft:    return 150
        case .up:        return 90
        case .upRight:   return 30
        }
    }

    /// The arrow that names it (a glyph, never translated).
    var arrow: String {
        switch self {
        case .right:     return "→"
        case .downRight: return "↘"
        case .down:      return "↓"
        case .downLeft:  return "↙"
        case .left:      return "←"
        case .upLeft:    return "↖"
        case .up:        return "↑"
        case .upRight:   return "↗"
        }
    }

    /// The angular distance between two angles in degrees (0…180).
    static func distance(_ a: Double, _ b: Double) -> Double {
        let d = abs((a - b).truncatingRemainder(dividingBy: 360))
        return d > 180 ? 360 - d : d
    }

    /// The direction whose sector holds `theta` (degrees, positive upward), nil in the dead angle between two
    /// sectors. The two HORIZONTAL sectors are OPEN at ±15° and the six others CLOSED: a boundary shared by
    /// right and a diagonal (±15°), or by left and a diagonal (±165°), belongs to the diagonal — the very
    /// boundaries the classifier had before the map (right `|θ| < 15`, the branch `−45 ≤ θ ≤ −15`, the send
    /// `|θ| > 165`).
    static func at(angle theta: Double) -> PlusDirection? {
        for d in [PlusDirection.right, .left] where distance(theta, d.angle) < tolerance { return d }
        for d in allCases where d != .right && d != .left && distance(theta, d.angle) <= tolerance { return d }
        return nil
    }
}

/// A plugin as a direction remembers it: the pair that identifies a plugin everywhere the app persists one
/// (`formatName` + `identifier`, @see PluginCategoryStore — NEVER `AvailablePlugin.id`, a UUID regenerated at
/// every scan), plus its name and maker so that a plugin no longer installed can still be NAMED.
/// Two references are the same plugin when their `key`s agree: name and maker are only what is shown.
struct PlusPluginRef: Codable, Hashable {
    var format: String
    var identifier: String
    var name: String
    var manufacturer: String

    init(format: String, identifier: String, name: String, manufacturer: String = "") {
        self.format = format
        self.identifier = identifier
        self.name = name
        self.manufacturer = manufacturer
    }

    /// The stable identity: `format|identifier`, the identifier normalised as `PluginCategoryStore` does it
    /// (an AudioUnit's "AudioUnit:Effects/aufx,SpMd,oDin" and the scan's "aufx,SpMd,oDin" are one plugin).
    var key: String { format + "|" + Self.normalizedIdentifier(format: format, identifier: identifier) }

    /// The same rule as `PluginCategoryStore.normalizedIdentifier` (kept here so this file stays alone).
    static func normalizedIdentifier(format: String, identifier: String) -> String {
        guard format == "AudioUnit", let slash = identifier.lastIndex(of: "/") else { return identifier }
        return String(identifier[identifier.index(after: slash)...])
    }

    static func == (a: PlusPluginRef, b: PlusPluginRef) -> Bool { a.key == b.key }
    func hash(into h: inout Hasher) { h.combine(key) }
}

/// What a direction asks for.
enum PlusAction: Hashable, Codable {
    /// Nothing: the direction has no zone, a drag there asks for nothing.
    case none
    /// A gain stage, then — past `SynopticPlusGesture.panMuteThreshold` of travel along the direction — a
    /// gain · pan · mute stage (the right direction's historical pair).
    case gainStage
    /// A gain stage only (one dB box), at any distance.
    case gain
    /// A gain · pan · mute stage, at any distance.
    case gainPanMute
    /// A parallel branch of the element under the "+".
    case branch
    /// A send taken at the "+".
    case send
    /// This plugin, inserted at the "+".
    case plugin(PlusPluginRef)

    /// The built-in actions, in the order a menu lists them (`.none` first).
    static let builtIns: [PlusAction] = [.none, .gainStage, .gain, .gainPanMute, .branch, .send]

    var pluginRef: PlusPluginRef? {
        if case .plugin(let r) = self { return r }
        return nil
    }

    // A tagged form, `{"kind": "plugin", "plugin": {…}}`, rather than the synthesised one: what a user's
    // preferences hold should read plainly, and an unknown kind (written by a later version) must decode to
    // `.none` instead of failing the whole map.
    private enum CodingKeys: String, CodingKey { case kind, plugin }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch (try? c.decode(String.self, forKey: .kind)) ?? "" {
        case "gainStage":   self = .gainStage
        case "gain":        self = .gain
        case "gainPanMute": self = .gainPanMute
        case "branch":      self = .branch
        case "send":        self = .send
        case "plugin":
            if let r = try? c.decode(PlusPluginRef.self, forKey: .plugin), !r.identifier.isEmpty {
                self = .plugin(r)
            } else {
                self = .none
            }
        default:            self = .none
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .none:            try c.encode("none", forKey: .kind)
        case .gainStage:       try c.encode("gainStage", forKey: .kind)
        case .gain:            try c.encode("gain", forKey: .kind)
        case .gainPanMute:     try c.encode("gainPanMute", forKey: .kind)
        case .branch:          try c.encode("branch", forKey: .kind)
        case .send:            try c.encode("send", forKey: .kind)
        case .plugin(let r):
            try c.encode("plugin", forKey: .kind)
            try c.encode(r, forKey: .plugin)
        }
    }
}

/// Which action each of the eight directions asks for. A pure value: the store persists it, the gesture
/// reads it, the settings and the plugin browser edit it through `assign` / `swap` / `clear`.
///
/// ONE direction per action: assigning an action that another direction already holds MOVES it there, the
/// other direction taking the old action of this one in exchange (a SWAP). So reorganising never loses a
/// built-in that was merely displaced, and a plugin is never bound twice. Assigning over a direction whose
/// action nobody else holds simply replaces it (`reset` brings the defaults back).
struct PlusShortcutMap: Equatable, Codable {

    /// The format version written with the map (a later version may add fields; this one reads what it knows).
    static let version = 1

    private var actions: [PlusDirection: PlusAction]

    /// The "+" as it always was: right = a gain stage (further: gain · pan · mute), down-right = a parallel
    /// branch, left = a send; the five other directions ask for nothing.
    static let defaults = PlusShortcutMap(actions: [.right: .gainStage, .downRight: .branch, .left: .send])

    init(actions: [PlusDirection: PlusAction] = [:]) {
        self.actions = actions.filter { $0.value != .none }
    }

    /// What `direction` asks for.
    func action(_ direction: PlusDirection) -> PlusAction { actions[direction] ?? .none }

    /// The direction holding `action` (nil = none does; always nil for `.none`).
    func direction(of action: PlusAction) -> PlusDirection? {
        guard action != .none else { return nil }
        return PlusDirection.allCases.first { self.action($0) == action }
    }

    /// The plugins bound to a direction, in the directions' order.
    var pluginRefs: [PlusPluginRef] { PlusDirection.allCases.compactMap { action($0).pluginRef } }

    var isDefault: Bool { self == .defaults }

    /// Puts `action` on `direction`. If another direction already holds that action, it takes the action
    /// `direction` had (a swap); `.none` simply clears `direction`.
    mutating func assign(_ action: PlusAction, to direction: PlusDirection) {
        let previous = self.action(direction)
        guard previous != action else { return }
        if let other = self.direction(of: action) { set(previous, other) }
        set(action, direction)
    }

    /// Exchanges the actions of two directions.
    mutating func swap(_ a: PlusDirection, _ b: PlusDirection) {
        guard a != b else { return }
        let (x, y) = (action(a), action(b))
        set(y, a)
        set(x, b)
    }

    /// The direction asks for nothing any more.
    mutating func clear(_ direction: PlusDirection) { set(.none, direction) }

    /// Every direction bound to `plugin` asks for nothing any more.
    mutating func unbind(_ plugin: PlusPluginRef) {
        for d in PlusDirection.allCases where action(d).pluginRef == plugin { set(.none, d) }
    }

    mutating func reset() { self = .defaults }

    private mutating func set(_ action: PlusAction, _ direction: PlusDirection) {
        if action == .none { actions.removeValue(forKey: direction) } else { actions[direction] = action }
    }

    // MARK: Codable — `{"version": 1, "directions": {"right": {"kind": "gainStage"}, …}}`
    //
    // Keyed by the direction's NAME: a direction a later version adds is ignored on the way in, and one the
    // stored map does not mention asks for nothing.

    private enum CodingKeys: String, CodingKey { case version, directions }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decodeIfPresent([String: PlusAction].self, forKey: .directions) ?? [:]
        var map = PlusShortcutMap()
        // A hand-edited file could name one action twice: the first direction (in `allCases` order) keeps it.
        for d in PlusDirection.allCases {
            guard let a = raw[d.rawValue], a != .none, map.direction(of: a) == nil else { continue }
            map.set(a, d)
        }
        self = map
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.version, forKey: .version)
        var raw: [String: PlusAction] = [:]
        for d in PlusDirection.allCases { raw[d.rawValue] = action(d) }
        try c.encode(raw, forKey: .directions)
    }
}
