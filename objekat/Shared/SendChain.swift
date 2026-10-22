import Foundation
import CryptoKit

// The PLUGINS of a send — INC 3 of the sends rework (docs/plan_sends_rework.md §D.2.A, session
// format 23). A send can carry a mini-chain (`AuxSend.plugins`): processed on the send's copy of the
// signal, BEFORE the sender's window and fades (which are laid on the copy after them), BEFORE the send's level. The plugins act on what THIS
// object sends to THIS aux, and on nothing else.
//
// THE PERMANENT RULE. An object's plugins have THREE roots: `plugins` (the trunk), `instruments`, and
// each send's `plugins`. Whatever walks, copies, captures, re-keys or purges "the plugins of an
// object" goes through the helpers below, never by hand: a site that forgets the third root is
// SILENT (a state not saved, an id shared by two objects, an undo that rebuilds, an instance
// destroyed with its editor open). An ARA source's plugin is a fourth carrier with rules of its own
// (`SoundObject.araSource`) and is not walked here.
//
// Everything in this file is PURE: no engine, no view-model.

enum SendChain {

    // MARK: - The chain host of a send

    /// The id under which a send's mini-chain is addressed as a CHAIN HOST (the third kind, beside an
    /// object and a stem): derived from the pair, never stored. A copy of the object, a retarget, an
    /// undo all get the right host for free. Deterministic; distinct pairs give distinct ids; never
    /// equal to either id of the pair (a version-5-style UUID: SHA-256 of a namespaced name).
    static func hostID(sender: UUID, aux: UUID) -> UUID {
        let name = "objekat.sendchain|\(sender.uuidString)|\(aux.uuidString)"
        var bytes = Array(SHA256.hash(data: Data(name.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50          // version 5 (name-based)
        bytes[8] = (bytes[8] & 0x3F) | 0x80          // RFC 4122 variant
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    // MARK: - The content rule (v1): leaves only

    /// True if `plugin` may sit in a send's mini-chain as far as its STRUCTURE says: a plain plugin.
    /// A parallel block, an FX link bin's block and a send marker may not (Q-U9, Q-U8; a marker there
    /// would be a send of a send). What an entry IS beyond its structure — an instrument, an ARA
    /// source — is not written on an `ObjectPlugin`: the doors refuse those from the catalogue entry.
    static func accepts(_ plugin: ObjectPlugin) -> Bool { !plugin.isContainer }

    /// `plugins` as a send may hold them: the leaves, in order, each UNLINKED. Idempotent. Called at
    /// decode, by `sanitisingSends`, by every copy (`mapping`) and by every write of a send host's
    /// chain.
    ///
    /// NO LINK ON A SEND (user decision, 10 October 2026, replacing Q-U8 / Q-U8b): a plugin of a
    /// send's mini-chain never carries a `linkGroupID` nor a detached one — no FX link bin.
    /// A bin's instance that is moved or copied into a send arrives unlinked;
    /// a copy of an object copies its sends' plugins INDEPENDENT. Enforced HERE, so that no door, no
    /// copier and no file can keep or create one (`rewireLinkGroups` then has nothing to wire).
    static func sanitised(_ plugins: [ObjectPlugin]) -> [ObjectPlugin] {
        plugins.filter { accepts($0) }.map { unlinked($0) }
    }

    /// `plugin` without any link membership, active or detached.
    static func unlinked(_ plugin: ObjectPlugin) -> ObjectPlugin {
        guard plugin.linkGroupID != nil || plugin.detachedLinkGroupID != nil else { return plugin }
        var p = plugin
        p.linkGroupID = nil
        p.detachedLinkGroupID = nil
        return p
    }

    /// The send plugins of `object` that carry a link membership — always empty in a sound model
    /// (the audit's check, @see debug.send_marker_audit).
    static func linkedSendPlugins(of object: SoundObject) -> [ObjectPlugin] {
        sendPlugins(of: object).filter { $0.linkGroupID != nil || $0.detachedLinkGroupID != nil }
    }

    /// How many plugins a mini-chain holds: the entry limit of the engine list that owns them, its
    /// OWN (measured, probe a of step 3.0) — the object's chain and its 20 entries are not concerned.
    static let capacity = 20

    /// Why a plugin gesture on a send's mini-chain is refused (the machine's reasons, English).
    enum Refusal: String {
        /// A parallel block, an FX link bin, an instrument, a send marker: plain plugins only.
        case leavesOnly = "send_chain_leaves_only"
        /// The mini-chain is full (`capacity`).
        case full = "chainFull"
        /// A send's plugin is never linked (decision of 10 October 2026).
        case neverLinked = "send_plugins_never_linked"
    }

    /// The refusal, if any, of laying `adding` more plain plugins into a mini-chain that holds `count`.
    static func refusal(count: Int, adding: Int, instrument: Bool = false) -> Refusal? {
        if instrument { return .leavesOnly }
        return count + adding > capacity ? .full : nil
    }

    // MARK: - The walk

    /// The plugins of every send of `object`, in the order of `sends` then of each mini-chain: the
    /// THIRD root, alone — for a site that already walks the other two.
    static func sendPlugins(of object: SoundObject) -> [ObjectPlugin] {
        object.sends.flatMap(\.plugins)
    }

    /// Every plugin an object carries, each exactly once: the leaves of its trunk (blocks and bins
    /// flattened in series order, markers skipped), its instruments, then every send's plugins.
    static func allRoots(of object: SoundObject) -> [ObjectPlugin] {
        SoundObject.pluginLeaves(object.plugins) + object.instruments + sendPlugins(of: object)
    }

    /// The send (its aux) whose mini-chain holds the plugin `id`, or nil.
    static func auxID(holding id: UUID, in object: SoundObject) -> UUID? {
        object.sends.first { $0.plugins.contains { $0.id == id } }?.auxID
    }

    // MARK: - The copy

    /// `sends` with each mini-chain replaced by `transform` of it (and sanitised). The ONE way a copy
    /// of an object freshens its sends' plugins: a by-value copy of `sends` would give two objects the
    /// same plugin ids — two hosts claiming one engine instance.
    static func mapping(_ sends: [AuxSend], _ transform: ([ObjectPlugin]) -> [ObjectPlugin]) -> [AuxSend] {
        sends.map { send in
            guard !send.plugins.isEmpty else { return send }
            var s = send
            s.plugins = sanitised(transform(send.plugins))
            return s
        }
    }

    /// `sends` with every mini-chain plugin's id passed through `map` (a cold copy: the caller owns
    /// the table, so that the automation lanes aimed at those plugins follow).
    static func mapPluginIDs(in sends: [AuxSend], _ map: (UUID) -> UUID) -> [AuxSend] {
        mapping(sends) { $0.map { p in var q = p; q.id = map(p.id); return q } }   // `mapping` unlinks
    }

    /// Old id → new id for the mini-chains of two `sends` arrays, paired by aux then by position — the
    /// counterpart of `SoundObject.pluginIDRemap(from:to:)` for the third root. A send whose chain
    /// changed length pairs nothing (we invent nothing).
    static func pluginIDRemap(from old: [AuxSend], to new: [AuxSend]) -> [UUID: UUID] {
        var out: [UUID: UUID] = [:]
        for o in old where !o.plugins.isEmpty {
            guard let n = new.first(where: { $0.auxID == o.auxID }), n.plugins.count == o.plugins.count else { continue }
            for (a, b) in zip(o.plugins, n.plugins) { out[a.id] = b.id }
        }
        return out
    }

    /// `sends` without any plugin (a carrier that keeps the route and its level, not the mini-chain).
    static func strippingPlugins(_ sends: [AuxSend]) -> [AuxSend] {
        sends.map { var s = $0; s.plugins = []; return s }
    }
}
