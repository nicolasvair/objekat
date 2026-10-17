import Foundation

// MARK: - The feature badges an object carries after its name
//
// Six small glyphs drawn at the RIGHT of an object's name — on the timeline's block (its four
// drawings: `SoundBlockView`, `GroupBlockView`, `InfiniteBusBandView`, the batched `Canvas`) and on
// the sound list's row — saying at a glance what the object DOES beyond playing: it carries
// effects, it shares an FX link, it sends to an aux, it keys somebody's sidechain, it receives a key,
// it carries an automation.
// Volume and pan keep their own display (the meta summary); they are never a badge.
//
// This file is the RULE, and only the rule: no view, no view-model, no engine — so it can be compiled
// alone and asserted (`tools/test_object_feature_badges.swift`). The glyphs come from `FeatureIcons`.
//
// The rules, one per badge (the user's, 16 October 2026; the conservative readings are marked):
//
// - FX: the object's OWN chain (the trunk, `plugins`, racks walked down) holds at least one real
//   plugin — enabled or not, third-party or built-in. NOT counted: a gain stage (`objGainStage` /
//   `objGainPanMute` — "on ne compte pas les gains"), a send's marker, the object's volume / pan
//   (not plugins at all), an INSTRUMENT (a MIDI clip's source, not an effect), the ARA source, a
//   send's own plugins (they are the send's, shown by the send badge — conservative reading of "the
//   object's chain"), and any plugin that is part of a link (below).
// - FX link: the trunk holds an FX link bin's block, attached OR detached (a detached block is the
//   host's own copy of the bin, still framed as the bin), or a legacy ⌘-linked plugin
//   (`linkGroupID` set; a plugin merely ABLE to rejoin, `detachedLinkGroupID`, is an independent
//   plugin and counts as FX). Whatever a bin's block holds counts for the link and never for FX —
//   gain stages and plain plugins alike; a bin holding only a gain stage still shows the link.
// - Aux sends: at least one send, whatever its state (off, silent, refused by the scope) — the
//   conservative reading: the send exists, the signal view shows it, so the badge says it.
// - Sidechain send: the object is the KEY SOURCE of at least one plugin's sidechain anywhere in the
//   project (an object's trunk, instruments or send plugins, a stem's chain), active or refused.
//   Computed ONCE per model change (`sidechainSources`) and read here as a set lookup.
// - Sidechain reception: one of the object's plugins — trunk (racks and bins included), instrument
//   or send plugin — has its sidechain key set, active or refused (`ObjectPlugin.sidechain`).
// - Automation (added 17 October 2026, "il manque juste l'icône d'automation"): at least one of the
//   object's OWN curves (`SoundObject.automation`) holds a point — whatever its parameter (volume,
//   pan, a send's level, a plugin's). Never a child's: a group carries it only for its own curves.
//   The glyph is `FeatureIcons.automated`, the one that already says "an automation drives this".
//
// The order is the enum's: FX, FX link, aux sends, sidechain send, sidechain reception, automation.

/// One badge. `rawValue` is the drawing order.
nonisolated enum FeatureBadge: Int, CaseIterable, Comparable, Hashable, Sendable {
    case fx
    case fxLink
    case auxSend
    case sidechainSend
    case sidechainReception
    case automation

    static func < (a: FeatureBadge, b: FeatureBadge) -> Bool { a.rawValue < b.rawValue }

    /// The SF Symbol (@see FeatureIcons).
    var symbol: String {
        switch self {
        case .fx:                 return FeatureIcons.fx
        case .fxLink:             return FeatureIcons.fxLink
        case .auxSend:            return FeatureIcons.auxSend
        case .sidechainSend:      return FeatureIcons.sidechainSend
        case .sidechainReception: return FeatureIcons.sidechainReception
        case .automation:         return FeatureIcons.automated
        }
    }

    /// The catalogue key of its tooltip / accessibility label.
    var labelKey: String {
        switch self {
        case .fx:                 return "featureBadge.fx"
        case .fxLink:             return "featureBadge.fxLink"
        case .auxSend:            return "featureBadge.auxSend"
        case .sidechainSend:      return "featureBadge.sidechainSend"
        case .sidechainReception: return "featureBadge.sidechainReception"
        case .automation:         return "featureBadge.automation"
        }
    }

    /// A short stable text of a badge list, for a cache key (`CanvasLabelCache`).
    static func cacheKey(_ badges: [FeatureBadge]) -> String {
        String(badges.map { Character(UnicodeScalar(UInt8(97 + $0.rawValue))) })
    }
}

enum ObjectFeatureBadges {

    /// The badges of `object`, in drawing order. `sidechainSources` = `sidechainSources(items:stems:)`
    /// of the current model, computed once per model change. O(the object's own plugins): it never
    /// looks at another object, nor into a group's children.
    static func badges(for object: SoundObject, sidechainSources: Set<UUID>) -> [FeatureBadge] {
        var fx = false
        var link = false
        var reception = false

        /// `trunk`: the object's own chain (the only root FX and the legacy link are read from).
        /// `inBin`: below an FX link bin's block.
        func walk(_ chain: [ObjectPlugin], trunk: Bool, inBin: Bool) {
            for p in chain {
                if p.isSendMarker { continue }                  // the place of a send, not a plugin
                if let rack = p.rack {
                    for voice in rack.voices { walk(voice, trunk: trunk, inBin: inBin) }
                    continue
                }
                if let block = p.fxBlock {
                    if trunk { link = true }
                    walk(block.plugins, trunk: trunk, inBin: true)
                    continue
                }
                // A leaf.
                if p.sidechain != nil { reception = true }
                guard trunk, !inBin else { continue }
                if p.linkGroupID != nil { link = true; continue }   // a legacy ⌘-link
                if !p.isGainStage { fx = true }
            }
        }
        walk(object.plugins, trunk: true, inBin: false)
        walk(object.instruments, trunk: false, inBin: false)
        for send in object.sends { walk(send.plugins, trunk: false, inBin: false) }

        var out: [FeatureBadge] = []
        if fx { out.append(.fx) }
        if link { out.append(.fxLink) }
        if !object.sends.isEmpty { out.append(.auxSend) }
        if sidechainSources.contains(object.id) { out.append(.sidechainSend) }
        if reception { out.append(.sidechainReception) }
        if object.automation.contains(where: { !$0.points.isEmpty }) { out.append(.automation) }
        return out
    }

    /// Every object's badges by id, group children included at any depth, the badge-less LEFT OUT
    /// (a lookup that misses means "no badge"). One walk of the project; `sidechainSources` read once.
    static func badgeMap(items: [SoundObject], stems: [Stem]) -> [UUID: [FeatureBadge]] {
        let sources = sidechainSources(items: items, stems: stems)
        var out: [UUID: [FeatureBadge]] = [:]
        func walk(_ objects: [SoundObject]) {
            for o in objects {
                let b = badges(for: o, sidechainSources: sources)
                if !b.isEmpty { out[o.id] = b }
                if case .group(let children, _) = o.kind { walk(children) }
            }
        }
        walk(items)
        return out
    }

    /// Every id that keys at least one plugin's sidechain in the project: the leaves of every
    /// object's three roots (trunk with its racks and bins, instruments, send plugins), group children
    /// included at any depth, and of every stem's chain. A source that no longer exists, or that
    /// the scope refuses, is in the set all the same (the key is written; @see SidechainSource).
    static func sidechainSources(items: [SoundObject], stems: [Stem]) -> Set<UUID> {
        var out = Set<UUID>()
        func leaves(_ chain: [ObjectPlugin]) {
            for p in chain {
                if p.isSendMarker { continue }
                if let rack = p.rack { for voice in rack.voices { leaves(voice) }; continue }
                if let block = p.fxBlock { leaves(block.plugins); continue }
                if let key = p.sidechain { out.insert(key.sourceID) }
            }
        }
        func walk(_ objects: [SoundObject]) {
            for o in objects {
                leaves(o.plugins)
                leaves(o.instruments)
                for send in o.sends { leaves(send.plugins) }
                if case .group(let children, _) = o.kind { walk(children) }
            }
        }
        walk(items)
        for s in stems { leaves(s.plugins) }
        return out
    }
}
