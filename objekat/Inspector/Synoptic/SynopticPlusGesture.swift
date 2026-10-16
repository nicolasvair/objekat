import Foundation

// MARK: - The "+" gestures of the signal view (PURE: no view, no layout, no model)
//
// A "+" of the signal view is taken in the hand (docs/plan_synoptic_rework.md §B.2):
//   - let go under `clickThreshold` = a CLICK (the plugin browser, as before);
//   - dragged in one of the eight DIRECTIONS (@see PlusDirection: ±15° each) = the action the user put on
//     that direction (@see PlusShortcutMap, an app preference kept by PlusShortcutStore). The DEFAULT map is
//     the "+" as it was designed:
//       - RIGHT (0°)          → a gain stage; past `panMuteThreshold` of travel → gain + pan + mute;
//       - right and DOWN (−30°) → a parallel branch of the element under the "+";
//       - LEFT (180°)          → a send taken at that "+" (the send wires leave the trunk by the left, user
//                                decision of 13 October 2026);
//     and the five other directions ask for nothing.
// The gain / gain + pan + mute cut of a `.gainStage` direction is the travel ALONG that direction's axis
// (for the right one: the horizontal travel, a vertical line at 80 pt — exactly the historical cut).
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
    /// Nothing: a click, a drag in no offered direction (a dead angle, a direction mapped to nothing…), or a
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
    /// This plugin, inserted at this "+" (a direction the user bound to it).
    case plugin(PlusPluginRef)
}

enum SynopticPlusGesture {

    /// Under this distance (pt) the gesture is a CLICK.
    static let clickThreshold: CGFloat = 6
    /// From this travel (pt) along its direction, a `.gainStage` direction asks for gain + pan + mute instead
    /// of gain.
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

    /// What the drag asks for under `map`, whatever the "+" offers.
    static func intent(_ translation: CGSize, map: PlusShortcutMap = .defaults) -> PlusGestureResult {
        guard let d = direction(translation) else { return .none }
        switch map.action(d) {
        case .none:            return .none
        case .gainStage:       return travel(translation, along: d) < panMuteThreshold ? .gain : .gainPanMute
        case .gain:            return .gain
        case .gainPanMute:     return .gainPanMute
        case .branch:          return .branch
        case .send:            return .send
        case .plugin(let r):   return .plugin(r)
        }
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
    // As soon as a drag leaves a "+", the directions it offers are drawn round it, faintly, each with its
    // icon; the one the hand is in lights up. The zones are THIS classifier drawn: every point inside a zone
    // classifies to that zone's result (asserted by tools/test_synoptic_plus_gesture.swift), so what is
    // drawn can never disagree with what letting go does. The gain / gain + pan + mute cut of a `.gainStage`
    // direction is the classifier's own: a line ACROSS the direction at `panMuteThreshold` of travel along it
    // (for the right direction, the vertical line at 80 pt), not an arc.

    /// Where a zone starts: just outside the "+" disc (its radius is 10 pt).
    static let sectorInnerRadius: CGFloat = 14
    /// Where a zone ends (the gain + pan + mute zone runs from the 80 pt line to here).
    static let sectorOuterRadius: CGFloat = 120

    /// The zones a "+" that offers `allowed` (and plugins when `pluginAllowed`) draws under `map` — one per
    /// offered direction (two for a `.gainStage` one: gain, then gain + pan + mute), directions in
    /// `PlusDirection.allCases` order. A direction it does not offer has NO zone (absent, not greyed).
    static func sectors(allowed: Set<PlusGestureResult>, pluginAllowed: Bool = false,
                        map: PlusShortcutMap = .defaults) -> [PlusSector] {
        let tol = angleTolerance, r0 = sectorInnerRadius, r1 = sectorOuterRadius
        var out: [PlusSector] = []
        for d in PlusDirection.allCases {
            let from = d.angle - tol, to = d.angle + tol
            func zone(_ r: PlusGestureResult, _ inner: PlusSector.Bound = .radius(r0),
                      _ outer: PlusSector.Bound = .radius(r1)) {
                guard offers(r, allowed: allowed, pluginAllowed: pluginAllowed) else { return }
                out.append(PlusSector(result: r, direction: d, fromAngle: from, toAngle: to, inner: inner, outer: outer))
            }
            switch map.action(d) {
            case .none:           break
            case .gainStage:
                let cut = PlusSector.Bound.across(panMuteThreshold, axis: d.angle)
                zone(.gain, .radius(r0), cut)
                zone(.gainPanMute, cut, .radius(r1))
            case .gain:           zone(.gain)
            case .gainPanMute:    zone(.gainPanMute)
            case .branch:         zone(.branch)
            case .send:           zone(.send)
            case .plugin(let r):  zone(.plugin(r))
            }
        }
        return out
    }

    /// The zone a drag of `translation` is in, among `sectors`: the one of its classified result (nil = none —
    /// a click, or a direction nothing is offered in).
    static func highlighted(_ translation: CGSize, in sectors: [PlusSector],
                            map: PlusShortcutMap = .defaults) -> PlusGestureResult? {
        highlightedIndex(translation, in: sectors, map: map).map { sectors[$0].result }
    }

    /// The INDEX of the zone a drag of `translation` is in (nil = none). By direction AND result: two
    /// directions may carry the same result (a `.gainStage` one and a `.gain` one both make gains), and only
    /// the one the hand is in lights up.
    static func highlightedIndex(_ translation: CGSize, in sectors: [PlusSector],
                                 map: PlusShortcutMap = .defaults) -> Int? {
        guard let d = direction(translation) else { return nil }
        let r = intent(translation, map: map)
        guard r != .none else { return nil }
        return sectors.firstIndex { $0.direction == d && $0.result == r }
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
    /// The angular range, `fromAngle` < `toAngle` (the left one runs 165…195: past 180 is the same as −180…).
    let fromAngle: Double
    let toAngle: Double
    let inner: Bound
    let outer: Bound
    /// False = the action exists but cannot be carried out here (a plugin no longer installed): the zone is
    /// drawn greyed and letting go in it does nothing. Set by the presentation (@see SynopticPlusPresentation).
    var isAvailable: Bool = true

    init(result: PlusGestureResult, direction: PlusDirection = .right, fromAngle: Double, toAngle: Double,
         inner: Bound, outer: Bound, isAvailable: Bool = true) {
        self.result = result
        self.direction = direction
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
