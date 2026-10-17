import Foundation

// MARK: - The directions of a "+" and what each one asks for (PURE: no view, no store, no model)
//
// A "+" of the signal view is taken in the hand and dragged in a DIRECTION (@see SynopticPlusGesture). Which
// action each direction asks for is the user's to choose — an app preference, never the project's
// (@see PlusShortcutStore, which keeps a `PlusShortcutMap` in UserDefaults). This file is the model of that
// choice: the eight directions, the actions one can put on them, and the map with its defaults.
//
// THE DIRECTIONS ARE FIXED: eight EQUAL sectors of 45° (±22.5° round 0°, ±45°, ±90°, ±135°, 180°), which
// together cover the whole circle — there is no dead angle (user request of 17 October 2026; the diagonals
// were at ±30° / ±150° with ±15° sectors until then). A direction's NAME is what the stored map keys on, so a
// map stored before keeps every setting: its diagonals simply moved to ±45° / ±135°.
//
// EVERY DIRECTION HAS TWO LEVELS (@see PlusLevel): near, and far beyond a CIRCLE of 80 pt round the "+"
// (@see SynopticPlusGesture.panMuteThreshold) — the right direction's historical gain / gain · pan · mute
// pair, generalised. Each (direction, level) SLOT holds its own action; an empty far slot does what the near
// one does, and an empty near slot does nothing (a drag that does not reach the far circle asks for nothing).
//
// This file is compiled alone by `tools/test_synoptic_plus_shortcuts.swift` and alongside
// `SynopticPlusGesture.swift` by `tools/test_synoptic_plus_gesture.swift`: it must stay free of every other
// type of the app.

/// One of the eight directions a "+" can be dragged in. `allCases` runs clockwise ON SCREEN from the right
/// — the order the zones are listed in (@see SynopticPlusGesture.sectors).
enum PlusDirection: String, Codable, CaseIterable, Hashable {
    case right, downRight, down, downLeft, left, upLeft, up, upRight

    /// Half the angular width of every sector, in degrees (eight sectors of 45°: the whole circle).
    static let tolerance: Double = 22.5

    /// The direction's axis, in degrees from the horizontal, POSITIVE UPWARD (as `SynopticPlusGesture.angle`).
    var angle: Double {
        switch self {
        case .right:     return 0
        case .downRight: return -45
        case .down:      return -90
        case .downLeft:  return -135
        case .left:      return 180
        case .upLeft:    return 135
        case .up:        return 90
        case .upRight:   return 45
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

    /// The direction whose sector holds `theta` (degrees, positive upward). Every angle has one: the sectors
    /// tile the circle. A boundary belongs to the sector that STARTS there, turning counter-clockwise
    /// (22.5° is up-right's, −22.5° right's): each sector is `[axis − 22.5°, axis + 22.5°)`.
    static func at(angle theta: Double) -> PlusDirection {
        // Counter-clockwise from the right, every 45°.
        let ring: [PlusDirection] = [.right, .upRight, .up, .upLeft, .left, .downLeft, .down, .downRight]
        var t = (theta + tolerance).truncatingRemainder(dividingBy: 360)
        if t < 0 { t += 360 }
        return ring[min(7, Int(t / 45))]
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

/// How far a drag went from the "+": NEAR (inside the circle of `SynopticPlusGesture.panMuteThreshold`, 80 pt)
/// or FAR (from that circle on). Every direction has the two levels — the right
/// direction's historical pair, gain then gain · pan · mute, generalised.
enum PlusLevel: String, Codable, CaseIterable, Hashable {
    case near, far
}

/// One assignable place of the map: a direction and a level.
struct PlusSlot: Hashable {
    var direction: PlusDirection
    var level: PlusLevel

    init(_ direction: PlusDirection, _ level: PlusLevel) {
        self.direction = direction
        self.level = level
    }

    /// Every slot, directions in `PlusDirection.allCases` order, near before far.
    static let allCases: [PlusSlot] = PlusDirection.allCases.flatMap { d in PlusLevel.allCases.map { PlusSlot(d, $0) } }
}

/// What a slot asks for.
enum PlusAction: Hashable, Codable {
    /// Nothing. A FAR slot left at nothing is not a hole: its zone does what the NEAR slot does
    /// (@see PlusShortcutMap.effective) — a direction with one action is one zone, at any distance.
    case none
    /// A gain stage (one dB box).
    case gain
    /// A gain · pan · mute stage.
    case gainPanMute
    /// A parallel branch of the element under the "+".
    case branch
    /// A send taken at the "+".
    case send
    /// This plugin, inserted at the "+".
    case plugin(PlusPluginRef)
    /// The plugin browser, opened on this colour category's tab (`PluginCategoryStore`'s colour index): the
    /// plugin chosen there is inserted at the "+".
    case category(Int)

    /// The built-in actions, in the order a palette lists them (`.none` left out: it is the ✕ of a zone).
    static let builtIns: [PlusAction] = [.gain, .gainPanMute, .branch, .send]

    var pluginRef: PlusPluginRef? {
        if case .plugin(let r) = self { return r }
        return nil
    }

    var categoryIndex: Int? {
        if case .category(let i) = self { return i }
        return nil
    }

    // A tagged form, `{"kind": "plugin", "plugin": {…}}`, rather than the synthesised one: what a user's
    // preferences hold should read plainly, and an unknown kind (written by a later version) must decode to
    // `.none` instead of failing the whole map.
    private enum CodingKeys: String, CodingKey { case kind, plugin, category }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = (try? c.decode(String.self, forKey: .kind)) ?? ""
        self = Self.decoded(kind: kind, plugin: try? c.decode(PlusPluginRef.self, forKey: .plugin),
                            category: try? c.decode(Int.self, forKey: .category))
    }

    /// `kind` read back; anything unknown (a plugin with no identifier, a category with no index) is `.none`.
    static func decoded(kind: String, plugin: PlusPluginRef?, category: Int? = nil) -> PlusAction {
        switch kind {
        case "gain":        return .gain
        case "gainPanMute": return .gainPanMute
        case "branch":      return .branch
        case "send":        return .send
        case "plugin":
            if let r = plugin, !r.identifier.isEmpty { return .plugin(r) }
            return .none
        case "category":
            if let i = category, i >= 0 { return .category(i) }
            return .none
        default:            return .none
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .none:            try c.encode("none", forKey: .kind)
        case .gain:            try c.encode("gain", forKey: .kind)
        case .gainPanMute:     try c.encode("gainPanMute", forKey: .kind)
        case .branch:          try c.encode("branch", forKey: .kind)
        case .send:            try c.encode("send", forKey: .kind)
        case .plugin(let r):
            try c.encode("plugin", forKey: .kind)
            try c.encode(r, forKey: .plugin)
        case .category(let i):
            try c.encode("category", forKey: .kind)
            try c.encode(i, forKey: .category)
        }
    }
}

/// Which action each of the sixteen slots (eight directions × near / far) asks for. A pure value: the store
/// persists it, the gesture reads it, the browser's "+" page edits it through `assign` / `swap` / `clear`.
///
/// An action may sit on SEVERAL slots (user decision of 17 October 2026: the page's list is a palette).
/// `assign` replaces what the slot held; `swap` (a zone dragged onto another) exchanges two slots;
/// `reset` brings the defaults back.
struct PlusShortcutMap: Equatable, Codable {

    /// The format version written with the map. 1 = one action per direction (a "gainStage" kind for the
    /// right direction's near/far pair); 2 = one action per SLOT. A v1 map is read and migrated.
    static let version = 2

    private var actions: [PlusSlot: PlusAction]

    /// The "+" as it always was: right = a gain stage, further a gain · pan · mute stage; down-right = a
    /// parallel branch; left = a send (their far slots empty: the same action at any distance); the five
    /// other directions ask for nothing.
    static let defaults = PlusShortcutMap(actions: [
        PlusSlot(.right, .near): .gain, PlusSlot(.right, .far): .gainPanMute,
        PlusSlot(.downRight, .near): .branch,
        PlusSlot(.left, .near): .send,
    ])

    init(actions: [PlusSlot: PlusAction]) {
        self.actions = actions.filter { $0.value != .none }
    }

    /// An empty map: every slot asks for nothing. (Not a `= [:]` default argument: a default argument is
    /// evaluated outside the type's main-actor isolation, where `PlusSlot`'s Hashable cannot be used.)
    init() {
        self.actions = [:]
    }

    /// What `slot` holds (`.none` for an empty far slot, @see effective).
    func action(_ slot: PlusSlot) -> PlusAction { actions[slot] ?? .none }

    func action(_ direction: PlusDirection, _ level: PlusLevel) -> PlusAction { action(PlusSlot(direction, level)) }

    /// The slot whose action a drag of `level` in `direction` carries out: the far slot when it holds
    /// something, the near slot otherwise (an empty far slot extends the near action).
    func effective(_ direction: PlusDirection, _ level: PlusLevel) -> PlusSlot {
        level == .far && action(direction, .far) != .none ? PlusSlot(direction, .far) : PlusSlot(direction, .near)
    }

    /// The FIRST slot holding `action`, in `PlusSlot.allCases` order (nil = none does; always nil for `.none`).
    func slot(of action: PlusAction) -> PlusSlot? {
        guard action != .none else { return nil }
        return PlusSlot.allCases.first { self.action($0) == action }
    }

    /// The plugins bound to a slot, in the slots' order.
    var pluginRefs: [PlusPluginRef] { PlusSlot.allCases.compactMap { action($0).pluginRef } }

    var isDefault: Bool { self == .defaults }

    /// Puts `action` on `slot`, replacing what it held (another slot holding the same action keeps it);
    /// `.none` simply clears `slot`.
    mutating func assign(_ action: PlusAction, to slot: PlusSlot) { set(action, slot) }

    /// Exchanges the actions of two slots.
    mutating func swap(_ a: PlusSlot, _ b: PlusSlot) {
        guard a != b else { return }
        let (x, y) = (action(a), action(b))
        set(y, a)
        set(x, b)
    }

    /// The slot asks for nothing any more.
    mutating func clear(_ slot: PlusSlot) { set(.none, slot) }

    /// Every slot bound to `plugin` asks for nothing any more.
    mutating func unbind(_ plugin: PlusPluginRef) {
        for s in PlusSlot.allCases where action(s).pluginRef == plugin { set(.none, s) }
    }

    mutating func reset() { self = .defaults }

    private mutating func set(_ action: PlusAction, _ slot: PlusSlot) {
        if action == .none { actions.removeValue(forKey: slot) } else { actions[slot] = action }
    }


    // MARK: Codable — v2: `{"version": 2, "slots": {"right": {"near": {"kind": "gain"}, "far": {…}}, …}}`
    //
    // Keyed by the direction's and the level's NAME: one a later version adds is ignored on the way in, and a
    // slot the stored map does not mention asks for nothing. A v1 map (`"directions": {"right": {"kind": …}}`)
    // is migrated: its "gainStage" becomes near = gain, far = gain · pan · mute; any other action goes to the
    // near slot, the far one left empty (the same action at any distance — what v1 did).

    private enum CodingKeys: String, CodingKey { case version, slots, directions }

    /// A v1 action as written (its "gainStage" kind no longer exists as an action).
    private struct V1Action: Decodable {
        var kind: String?
        var plugin: PlusPluginRef?
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var map = PlusShortcutMap()
        if let slots = try c.decodeIfPresent([String: [String: PlusAction]].self, forKey: .slots) {
            for s in PlusSlot.allCases {
                map.set(slots[s.direction.rawValue]?[s.level.rawValue] ?? .none, s)
            }
        } else if let v1 = try c.decodeIfPresent([String: V1Action].self, forKey: .directions) {
            for d in PlusDirection.allCases {
                guard let raw = v1[d.rawValue] else { continue }
                if raw.kind == "gainStage" {
                    map.set(.gain, PlusSlot(d, .near))
                    map.set(.gainPanMute, PlusSlot(d, .far))
                } else {
                    map.set(PlusAction.decoded(kind: raw.kind ?? "", plugin: raw.plugin), PlusSlot(d, .near))
                }
            }
        }
        self = map
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.version, forKey: .version)
        var raw: [String: [String: PlusAction]] = [:]
        for s in PlusSlot.allCases { raw[s.direction.rawValue, default: [:]][s.level.rawValue] = action(s) }
        try c.encode(raw, forKey: .slots)
    }
}
