import Foundation

// MARK: - The feature badges, read cheaply
//
// The rule lives in `ObjectFeatureBadges` (pure); this is only where the drawing reads it, and how
// it is kept cheap: ONE memo, `featureBadgeMap`, dropped by every write to `items` and to `stems`
// (the same `didSet`s as the other derived caches) and rebuilt on the next read by ONE walk of the
// project — the sidechain sources gathered once (every chain of every object and stem), then each
// object's own plugins. Never per block, never per frame: between two model changes every reader —
// the four block drawings and the sound list, the batched `Canvas` included — pays a dictionary
// lookup. The `Canvas` takes the whole dictionary as a VALUE once per pass (its nested drawing
// functions are not MainActor-isolated and must not ask the view model anything).
//
// The memo is not observed (`@ObservationIgnored`), on purpose: every reader already depends on
// `items` (the object it draws comes from there) and on `stems` (its stem colour), so a change that
// can move a badge re-evaluates it anyway, and a lookup costs no observation-registrar access.
// ⚠️ As with `displayName(of:)`: only for an item TAKEN FROM `items` / `laneEntries` — the memo is
// keyed by id alone, and a modified copy would be handed the original's badges.
extension EditViewModel {

    /// Every object's badges by id (@see ObjectFeatureBadges.badgeMap); an id missing = no badge.
    var featureBadgeMap: [UUID: [FeatureBadge]] {
        if let featureBadgeMapCache { return featureBadgeMapCache }
        let map = ObjectFeatureBadges.badgeMap(items: items, stems: stems)
        featureBadgeMapCache = map
        return map
    }

    /// The badges drawn after `item`'s name, in order (@see ObjectFeatureBadges).
    func featureBadges(of item: SoundObject) -> [FeatureBadge] {
        featureBadgeMap[item.id] ?? []
    }
}
