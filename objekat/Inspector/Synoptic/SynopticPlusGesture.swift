import Foundation

// MARK: - The "+" gestures of the signal view (PURE: no view, no layout, no model)
//
// A "+" of the signal view is taken in the hand (docs/plan_synoptic_rework.md §B.2):
//   - let go under `clickThreshold` = a CLICK (the plugin browser, as before);
//   - dragged in one of the eight DIRECTIONS (@see PlusDirection: ±15° each), at one of two LEVELS — NEAR,
//     or FAR from `panMuteThreshold` of travel along the direction's axis (@see PlusLevel) — = the action
//     the user put on that slot (@see PlusShortcutMap, an app preference kept by PlusShortcutStore). An
//     empty far slot does what the near one does. The DEFAULT map is the "+" as it was designed:
//       - RIGHT (0°)          → a gain stage; FAR → gain + pan + mute;
//       - right and DOWN (−30°) → a parallel branch of the element under the "+" (at any distance);
//       - LEFT (180°)          → a send taken at that "+" (the send wires leave the trunk by the left, user
//                                decision of 13 October 2026; at any distance);
//     and the five other directions ask for nothing.
// The near / far cut is the travel ALONG the direction's axis (for the right one: the horizontal travel, a
// vertical line at 80 pt — exactly the historical cut).
//
// The angle is measured from the horizontal, POSITIVE UPWARD — the screen's y grows downwards, so
// the translation's height is negated. Which results a given "+" offers is the caller's (`allowed`, and
// `pluginAllowed` for a plugin's insertion): a result it does not offer comes back as `.none`, which the
// ghost reads as "not here".
//
// Every function takes the map, `.defaults` when none is given — what the tests written before the map
// keep asserting.
//
// This file is compiled by `tools/test_synoptic_plus_gesture.swift` with `SynopticPlusShortcuts.swift`, and
// nothing else: it must stay free of every other type of the app.

/// What a drag started on a "+" asks for.
enum PlusGestureResult: Equatable, Hashable {
    /// Nothing: a click, a drag in no offered direction (a dead angle, a slot mapped to nothing…), or a
    /// result this "+" does not offer.
    case none
    /// A gain stage (one dB box).
    case gain
    /// A gain + pan + mute stage.
    case gainPanMute
    /// A parallel branch of the element under the "+" (the element above, for a series' tail "+").
    case branch
    /// A send taken at this "+".
    case send
    /// This plugin, inserted at this "+" (a slot the user bound to it).
    case plugin(PlusPluginRef)
}

extension PlusAction {
    /// The gesture result this action asks for.
    var gestureResult: PlusGestureResult {
        switch self {
        case .none:          return .none
        case .gain:          return .gain
        case .gainPanMute:   return .gainPanMute
        case .branch:        return .branch
        case .send:          return .send
        case .plugin(let r): return .plugin(r)
        }
    }
}

enum SynopticPlusGesture {

    /// Under this distance (pt) the gesture is a CLICK.
    static let clickThreshold: CGFloat = 6
    /// From this travel (pt) along its direction, a drag is at the FAR level (@see PlusLevel) — the right
    /// direction's historical gain → gain + pan + mute cut.
    static let panMuteThreshold: CGFloat = 80
    /// The direction of the branch in the DEFAULT map (down-right, −`diagonalAngle`), in degrees.
    static let diagonalAngle: Double = 30
    /// The direction of the send in the DEFAULT map: straight LEFT, in degrees from the horizontal.
    static let sendAngle: Double = 180
    /// The tolerance round each direction, in degrees (@see PlusDirection.tolerance).
    static let angleTolerance: Double = PlusDirection.tolerance

    /// Every built-in result a "+" can offer (the trunk's).
    static let everything: Set<PlusGestureResult> = [.gain, .gainPanMute, .branch, .send]

    /// True when the hand travelled less than `clickThreshold`: the gesture is a click.
    static func isClick(_ translation: CGSize) -> Bool {
        hypot(translation.width, translation.height) < clickThreshold
    }

    /// The drag's angle from the horizontal, in degrees, POSITIVE UPWARD (−180…180).
    static func angle(_ translation: CGSize) -> Double {
        atan2(Double(-translation.height), Double(translation.width)) * 180 / .pi
    }

    /// The direction the drag is in (nil = a click, or a dead angle between two sectors).
    static func direction(_ translation: CGSize) -> PlusDirection? {
        guard !isClick(translation) else { return nil }
        return PlusDirection.at(angle: angle(translation))
    }

    /// How far the hand travelled ALONG `direction`'s axis (the projection of the drag on it).
    static func travel(_ translation: CGSize, along direction: PlusDirection) -> CGFloat {
        if direction == .right { return translation.width }      // the historical cut, to the bit
        let a = direction.angle * .pi / 180
        return translation.width * CGFloat(cos(a)) - translation.height * CGFloat(sin(a))
    }

    /// The level the drag reached along `direction`.
    static func level(_ translation: CGSize, along direction: PlusDirection) -> PlusLevel {
        travel(translation, along: direction) < panMuteThreshold ? .near : .far
    }

    /// The slot whose action the drag carries out under `map` (nil = a click or a dead angle): its
    /// direction, at the level it reached — the near slot when the far one is empty.
    static func slot(_ translation: CGSize, map: PlusShortcutMap = .defaults) -> PlusSlot? {
        guard let d = direction(translation) else { return nil }
        return map.effective(d, level(translation, along: d))
    }

    /// What the drag asks for under `map`, whatever the "+" offers.
    static func intent(_ translation: CGSize, map: PlusShortcutMap = .defaults) -> PlusGestureResult {
        guard let s = slot(translation, map: map) else { return .none }
        return map.action(s).gestureResult
    }

    /// Whether a "+" that offers `allowed` (and plugins when `pluginAllowed`) offers `result`.
    static func offers(_ result: PlusGestureResult, allowed: Set<PlusGestureResult>, pluginAllowed: Bool) -> Bool {
        if case .plugin = result { return pluginAllowed }
        return allowed.contains(result)
    }

    /// What the drag does on a "+" that offers `allowed` (and plugins when `pluginAllowed`): its intent, or
    /// `.none` when that "+" does not offer it.
    static func classify(_ translation: CGSize, allowed: Set<PlusGestureResult>,
                         pluginAllowed: Bool = false, map: PlusShortcutMap = .defaults) -> PlusGestureResult {
        let r = intent(translation, map: map)
        return r != .none && offers(r, allowed: allowed, pluginAllowed: pluginAllowed) ? r : .none
    }

    // MARK: The zones drawn round a "+" while it is dragged (§B.2, user request of 13 October 2026)
    //
    // As soon as a drag leaves a "+", the slots it offers are drawn round it, faintly, each with its icon;
    // the one the hand is in lights up. The zones are THIS classifier drawn: every point inside a zone
    // classifies to that zone's result (asserted by tools/test_synoptic_plus_gesture.swift), so what is
    // drawn can never disagree with what letting go does. The near / far cut is the classifier's own: a line
    // ACROSS the direction at `panMuteThreshold` of travel along it (for the right direction, the vertical
    // line at 80 pt), not an arc. A direction whose far slot is empty is ONE zone, from the disc to the end.

    /// Where a zone starts: just outside the "+" disc (its radius is 10 pt).
    static let sectorInnerRadius: CGFloat = 14
    /// Where a zone ends (a far zone runs from the 80 pt line to here).
    static let sectorOuterRadius: CGFloat = 120

    /// The zones a "+" that offers `allowed` (and plugins when `pluginAllowed`) draws under `map` — one per
    /// offered slot (a direction with a far action: near, then far), directions in `PlusDirection.allCases`
    /// order. A slot it does not offer has NO zone (absent, not greyed).
    static func sectors(allowed: Set<PlusGestureResult>, pluginAllowed: Bool = false,
                        map: PlusShortcutMap = .defaults) -> [PlusSector] {
        let tol = angleTolerance, r0 = sectorInnerRadius, r1 = sectorOuterRadius
        var out: [PlusSector] = []
        for d in PlusDirection.allCases {
            let from = d.angle - tol, to = d.angle + tol
            func zone(_ level: PlusLevel, _ inner: PlusSector.Bound, _ outer: PlusSector.Bound) {
                let r = map.action(d, level).gestureResult
                guard r != .none, offers(r, allowed: allowed, pluginAllowed: pluginAllowed) else { return }
                out.append(PlusSector(result: r, direction: d, level: level, fromAngle: from, toAngle: to,
                                      inner: inner, outer: outer))
            }
            if map.action(d, .far) == .none {
                zone(.near, .radius(r0), .radius(r1))
            } else {
                let cut = PlusSector.Bound.across(panMuteThreshold, axis: d.angle)
                zone(.near, .radius(r0), cut)
                zone(.far, cut, .radius(r1))
            }
        }
        return out
    }

    /// The zone a drag of `translation` is in, among `sectors`: the one of its classified result (nil = none —
    /// a click, or a slot nothing is offered in).
    static func highlighted(_ translation: CGSize, in sectors: [PlusSector],
                            map: PlusShortcutMap = .defaults) -> PlusGestureResult? {
        highlightedIndex(translation, in: sectors, map: map).map { sectors[$0].result }
    }

    /// The INDEX of the zone a drag of `translation` is in (nil = none): the zone of the slot the drag
    /// carries out.
    static func highlightedIndex(_ translation: CGSize, in sectors: [PlusSector],
                                 map: PlusShortcutMap = .defaults) -> Int? {
        guard let s = slot(translation, map: map), map.action(s) != .none else { return nil }
        return sectors.firstIndex { $0.direction == s.direction && $0.level == s.level }
    }
}

/// One zone drawn round a "+" (@see SynopticPlusGesture.sectors): an angular range (degrees from the
/// horizontal, POSITIVE UPWARD, as `SynopticPlusGesture.angle`) between an inner and an outer boundary,
/// each a circle round the "+" or a straight line across the zone's direction.
struct PlusSector: Equatable {
    enum Bound: Equatable {
        /// A circle of this radius round the "+".
        case radius(CGFloat)
        /// The straight line ACROSS the direction `axis` (degrees), at this travel along it from the "+" (for
        /// the axis 0°, the vertical line at that horizontal travel, right of the "+").
        case across(CGFloat, axis: Double)

        /// The distance from the "+" to this boundary in the direction `degrees`.
        func distance(at degrees: Double) -> CGFloat {
            switch self {
            case .radius(let r):           return r
            case .across(let x, let axis): return x / CGFloat(cos((degrees - axis) * .pi / 180))
            }
        }
    }

    let result: PlusGestureResult
    /// The direction this zone is drawn in.
    var direction: PlusDirection = .right
    /// The level: near (or the whole direction when its far slot is empty), or far.
    var level: PlusLevel = .near
    /// The angular range, `fromAngle` < `toAngle` (the left one runs 165…195: past 180 is the same as −180…).
    let fromAngle: Double
    let toAngle: Double
    let inner: Bound
    let outer: Bound
    /// False = the action exists but cannot be carried out here (a plugin no longer installed): the zone is
    /// drawn greyed and letting go in it does nothing. Set by the presentation (@see SynopticPlusPresentation).
    var isAvailable: Bool = true

    init(result: PlusGestureResult, direction: PlusDirection = .right, level: PlusLevel = .near,
         fromAngle: Double, toAngle: Double, inner: Bound, outer: Bound, isAvailable: Bool = true) {
        self.result = result
        self.direction = direction
        self.level = level
        self.fromAngle = fromAngle
        self.toAngle = toAngle
        self.inner = inner
        self.outer = outer
        self.isAvailable = isAvailable
    }

    var midAngle: Double { (fromAngle + toAngle) / 2 }

    /// The translation (from the "+") of the point at `degrees`, `distance` away — in the SCREEN's sense
    /// (y grows downward).
    static func offset(_ degrees: Double, _ distance: CGFloat) -> CGSize {
        let a = degrees * .pi / 180
        return CGSize(width: distance * CGFloat(cos(a)), height: -distance * CGFloat(sin(a)))
    }

    /// The zone's outline, as offsets from the "+": the inner boundary from `fromAngle` to `toAngle`, then
    /// the outer one back. `steps` points per boundary.
    func outline(steps: Int = 12) -> [CGSize] {
        let n = max(2, steps)
        func angle(_ i: Int) -> Double { fromAngle + (toAngle - fromAngle) * Double(i) / Double(n - 1) }
        let innerPts = (0..<n).map { i in PlusSector.offset(angle(i), inner.distance(at: angle(i))) }
        let outerPts = (0..<n).reversed().map { i in PlusSector.offset(angle(i), outer.distance(at: angle(i))) }
        return innerPts + outerPts
    }

    /// Where the zone's icon sits (an offset from the "+"): on its middle direction, halfway between its
    /// boundaries.
    var iconOffset: CGSize {
        let a = midAngle
        return PlusSector.offset(a, (inner.distance(at: a) + outer.distance(at: a)) / 2)
    }
}
