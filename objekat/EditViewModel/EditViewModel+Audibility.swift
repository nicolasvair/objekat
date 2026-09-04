import Foundation

// MARK: - Composing the listening (object mute, stem mute, solo)
//
// Three layers decide an object's silence, and ONE SINGLE rule composes them — that of
// `AudibilitySnapshot`. The sound and the display both read it: two parallel rules
// would end up diverging, and the UI would lie — a dimmed object that is heard, or the reverse.
//
//     a DIRECT solo         → it is heard, whatever the mutes say
//     object ∨ stem mute    → silence
//     a solo active elsewhere → silence (everything outside the audible closure)
//
// "It is heard, whatever the mutes say" holds all the way down the chain: a group's fader
// is that of its ContainerClip, it MULTIPLIES what it contains. A muted group left at -96 dB
// would therefore stifle the very clip that has just been asked for — hence `soloRootAncestors`,
// which reopens the ancestors of a direct solo. It un-mutes nothing else: the group's other children
// are already silenced by the solo's filtering, and the group stays DISPLAYED muted (its mute still
// holds for them, and it will fall silent again as soon as the solo is lifted).
//
// The two mutes are a DISJUNCTION, not an order: neither of them can un-mute the other,
// so there is nothing to arbitrate between them. The only real arbitration is the solo's, and it
// turns on a distinction: "direct" = the object is itself in the solo's roots (confirmed
// or temporary), it is the gesture "I want to hear THIS object" and it wins over a mute; an
// INHERITED solo — from an ancestor group or a soloed stem — does NOT wake an explicit mute, because
// it is broader and later than the intention it would crush.
//
// The stem mute is not materialised on the objects: it is read from `stems`, as the solo is
// read from its session sets. Copying it into the objects would mean that un-muting a bus
// crushed the clip mutes. (In contrast: `assignStem` PROPAGATES the stemID into the descendants
// — but that is persistent data, not a listening state.)
//
// On the engine side none of these notions exists: -96 dB is pushed onto the object's fader. That fader
// is a post-FX ObjGain, UPSTREAM of the send tap that lives at the end of the chain — an object reduced to
// silence therefore also stops feeding the auxes, the reverb shared at the Main included. That is what
// replaces the FolderTrack mute: cutting at the source rather than at the bus's output. Two
// known costs: -96 dB is not a true zero (enough for the ear, not for a sample-accurate
// bounce), and the bus's FX tail now dies away by itself instead of being
// cut off dead.

/// The listening state frozen into values: what does not depend on the object itself (the solo's roots,
/// the audible closure, the muted stems). A value, and not a call to the view model, because the rendering
/// of a `Canvas` is not MainActor-isolated and cannot query it — without this the rule would be
/// rewritten alongside, and that is exactly what is to be avoided.
struct AudibilitySnapshot {
    /// The objects DIRECTLY soloed (confirmed ∪ temporary) — not the closure by ancestor.
    var soloRoots: Set<UUID> = []
    /// Is any solo filtering the listening?
    var soloActive: Bool = false
    /// The audible closure under that solo (audible leaves + their ancestor groups).
    var soloAudible: Set<UUID> = []
    /// The stems whose bus is muted (the Main cannot be muted).
    var mutedStemIDs: Set<UUID> = []
    /// The ANCESTOR groups of a direct solo: their fader must stay open even if they are muted,
    /// otherwise the container would multiply by zero the descendant that is meant to be heard.
    var soloRootAncestors: Set<UUID> = []

    /// True if the object shows as "muted": a mute — its own or its stem's — that the direct
    /// solo does not lift. The silence due to the solo's FILTERING is not part of it: it has its
    /// own visual language (opacity), @see EditViewModel.isSoloDimmed.
    func isMutedInMix(_ item: SoundObject) -> Bool {
        if soloRoots.contains(item.id) { return false }
        if item.isMuted { return true }
        return item.stemID.map { mutedStemIDs.contains($0) } ?? false
    }

    /// True if the object is reduced to silence, all layers taken together.
    func isSilenced(_ item: SoundObject) -> Bool {
        // The direct solo wins over EVERYTHING: over the mutes (`isMutedInMix` says so again on its own
        // account) as over the filtering on the next line.
        if soloRoots.contains(item.id) { return false }
        // And so does the path leading to it — a muted group must not stifle the soloed descendant that
        // goes through it. Silence only here, not in `isMutedInMix`: the group stays displayed
        // muted, which it still is for all the rest of its content.
        if soloRootAncestors.contains(item.id) { return false }
        if isMutedInMix(item) { return true }
        return soloActive && !soloAudible.contains(item.id)
    }
}

extension EditViewModel {

    /// The "off" level pushed to the engine.
    static let silencedDb: Float = -96

    // MARK: The rule

    /// True if `item` is reduced to silence by the listening composition.
    func isSilenced(_ item: SoundObject) -> Bool { audibility.isSilenced(item) }

    /// True if `item` shows as muted (an object or stem mute, not lifted by a direct solo).
    func isMutedInMix(_ item: SoundObject) -> Bool { audibility.isMutedInMix(item) }

    /// The volume to push to the engine for `item`.
    func engineVolume(for item: SoundObject) -> Float {
        isSilenced(item) ? Self.silencedDb : item.volume
    }

    // MARK: Applying it to the engine

    /// Pushes the composed volume + pan for `id`. EVERY path that touches volume, pan or
    /// mute goes through here: a hard-coded `engine.updateVolume` would contradict the composition —
    /// moving the fader of a muted but soloed clip would send it back to silence.
    func pushMix(_ id: UUID) {
        guard let engine, let obj = find(id: id) else { return }
        engine.updateVolume(engineVolume(for: obj), pan: obj.pan, forID: id.uuidString)
        // The composed silence cannot be read from the fader's value alone when a volume CURVE
        // rules: it would crush it at the next block. `pushAutomation` removes it for as long as
        // the object is reduced to silence, and puts it back when it becomes audible again. Guarded by
        // `automation.isEmpty`: this is the path of a fader drag, it must stay free
        // for objects with no curve (the vast majority).
        if !obj.automation.isEmpty { pushAutomation(obj) }
    }

    /// Pushes the mix of `id` AND of all its descendants. What is needed after a change that
    /// touches the composition without touching the volume — moving an object to another stem, for instance:
    /// entering a muted bus (or leaving one) changes what the engine must hear.
    func pushMixTree(_ id: UUID) {
        guard let obj = find(id: id) else { return }
        pushMix(id)
        if case .group(let children, _) = obj.kind {
            for child in children { pushMixTree(child.id) }
        }
    }

    /// Recomputes the listening snapshot AND THEN pushes it to the engine. The only entry point after a
    /// change of solo or of bus mute, and after a rebuild (loading, undo/redo).
    /// Idempotent. The snapshot holds only what cannot be read from the object — a clip's mute,
    /// for its part, is always fresh, hence the small number of invalidation points.
    func refreshAudibility() {
        let roots = soloRootIDs
        var ancestors: Set<UUID> = []
        for id in roots {
            var anc = parentGroup(for: id)
            while let a = anc, !ancestors.contains(a.id) {
                ancestors.insert(a.id)
                anc = parentGroup(for: a.id)
            }
        }
        audibility = AudibilitySnapshot(
            soloRoots:         roots,
            soloActive:        hasAnySolo,
            soloAudible:       soloAudibleObjectIDs,
            mutedStemIDs:      Set(stems.filter { $0.muted && $0.id != mainStemID }.map(\.id)),
            soloRootAncestors: ancestors
        )
        applyAudibilityToEngine()
    }

    /// Reapplies the composition to ALL the objects — groups and auxes included, their faders are
    /// ObjGains like the others, and a fader left at -96 by a layer lifted since would never
    /// recover.
    func applyAudibilityToEngine() {
        guard let engine else { return }
        for obj in allObjectsFlat {
            engine.updateVolume(engineVolume(for: obj), pan: obj.pan, forID: obj.id.uuidString)
            // As in `pushMix`: a volume curve must disappear (or come back) with the silence.
            if !obj.automation.isEmpty { pushAutomation(obj) }
        }
    }

    /// Every object in the project, flattened, groups included (`allClips` gives only the leaves).
    /// With no lane arithmetic: only the mix and the listening state are read here.
    var allObjectsFlat: [SoundObject] {
        var result: [SoundObject] = []
        func walk(_ arr: [SoundObject]) {
            for o in arr {
                result.append(o)
                if case .group(let children, _) = o.kind { walk(children) }
            }
        }
        walk(items)
        return result
    }
}
