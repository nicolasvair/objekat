import Foundation

// MARK: - Channel width of a plugin (mono / mono→stereo / stereo)
//
// The view-model's half of the channel-width feature: it reads what the engine reports for a plugin's main
// bus (`pluginChannelInfo`), answers the "Channels" submenu of a card, and applies a change as ONE undo step.
// The arithmetic of widths along a chain is `SynopticWidthFlow` (pure); the engine's door is
// `OBJEngineCore.setChannelLayout` (which frees the playback context, so it is refused while playing).
//
// The width is part of the plugin's STATE (the binary `layout` property of its tree), so it persists with the
// `stateXML` the model already keeps, and undoing it goes through the same patch path as any state change
// (`applyPluginStateXML:` restores the layout before the chunk).

/// What the "Channels" submenu of a plugin card shows.
struct ChannelMenuState: Equatable {
    struct Entry: Equatable {
        let variant: ChannelVariant
        /// The instance (and every instance that changes with it) accepts this variant.
        let supported: Bool
        let isCurrent: Bool
    }

    var channels: PluginChannels
    var entries: [Entry]
    /// NO = the `supported` flags are best-effort (a VST3 once the playback context is allocated): a
    /// refusal met at application is remembered by the engine, and the entry is greyed from then on.
    var exact: Bool
    /// Playback runs: the change frees the playback context, so the entries are shown greyed.
    var blockedByPlayback: Bool
    /// How many OTHER instances change with this one (an FX link's mirrors, a manual link's peers).
    var linkedCount: Int
}

/// What a change came to.
enum ChannelChangeOutcome: Equatable {
    case applied(instances: Int)
    case unchanged
    case refused(reason: String)
}

extension EditViewModel {

    // MARK: Reading

    /// A plugin's main bus as the graph reads it; nil for a built-in / in-house plugin (transparent as far as
    /// the view goes), an instance still loading, or an unknown key. One cheap call, no probing.
    func pluginChannels(pluginID: UUID) -> PluginChannels? {
        guard let d = engine?.pluginChannelInfo(pluginID.uuidString, probeVariants: false),
              (d["external"] as? NSNumber)?.boolValue == true,
              (d["loaded"] as? NSNumber)?.boolValue == true,
              let i = (d["inputs"] as? NSNumber)?.intValue,
              let o = (d["outputs"] as? NSNumber)?.intValue
        else { return nil }
        return PluginChannels(inputs: i, outputs: o)
    }

    /// The channels of every plugin in `ids` the engine reports one for (the cache of a signal view).
    func pluginChannels(pluginIDs ids: [UUID]) -> [UUID: PluginChannels] {
        var out: [UUID: PluginChannels] = [:]
        for id in ids { if let c = pluginChannels(pluginID: id) { out[id] = c } }
        return out
    }

    /// The width a chain hosted by `hostID` is fed with: the source file's channel count for an audio clip
    /// (the file is read once per path, @see ClipChannels), a stereo pair for everything else — a group, an
    /// aux, a MIDI clip's instrument, a bus.
    func sourceChannelWidth(hostID: UUID) -> Int {
        guard let o = find(id: hostID), case .clip(let path, _, _, _, _) = o.kind else {
            return SynopticWidthFlow.sourceWidth(fileChannels: nil)
        }
        return SynopticWidthFlow.sourceWidth(fileChannels: ClipChannels.count(atPath: path))
    }

    // MARK: The submenu

    /// The instances that change together with `pluginID`: the OTHER ACTIVE members of its link group (an FX
    /// link's mirrors included — their `linkGroupID` is the definition's id). A detached member is on its own.
    private func channelGroupPeers(of pluginID: UUID, on host: UUID) -> [(plugin: UUID, host: UUID)] {
        guard let me = hostedPlugin(pluginID, of: host), let gid = me.linkGroupID else { return [] }
        return allPluginRefs()
            .filter { $0.plugin.linkGroupID == gid && $0.plugin.id != pluginID }
            .map { (plugin: $0.plugin.id, host: chainHost(holding: $0.plugin.id, on: $0.objectID)) }
    }

    /// The submenu for a card. nil = no submenu at all: a built-in or in-house plugin (nothing to negotiate),
    /// an instrument, or an instance that is not an external plugin. An instance still loading, or one of
    /// the group that is, gives a menu with every entry greyed.
    func channelMenuState(pluginID: UUID, host: UUID) -> ChannelMenuState? {
        guard let engine, chainPlugins(host) != nil || find(id: host) != nil,
              let plug = hostedPlugin(pluginID, of: host), !plug.isBuiltIn,
              !isInstrument(pluginID, of: host),
              let d = engine.pluginChannelInfo(pluginID.uuidString, probeVariants: true),
              (d["external"] as? NSNumber)?.boolValue == true
        else { return nil }

        let loaded = (d["loaded"] as? NSNumber)?.boolValue == true
        guard loaded, let i = (d["inputs"] as? NSNumber)?.intValue,
              let o = (d["outputs"] as? NSNumber)?.intValue
        else {
            // Not loaded yet: the entries are there, none can be taken.
            return ChannelMenuState(channels: PluginChannels(inputs: 0, outputs: 0),
                                    entries: ChannelVariant.allCases.map { .init(variant: $0, supported: false, isCurrent: false) },
                                    exact: true, blockedByPlayback: false, linkedCount: 0)
        }

        var exact = (d["exact"] as? NSNumber)?.boolValue ?? false
        var supported: [ChannelVariant: Bool] = [:]
        for v in (d["variants"] as? [[String: Any]]) ?? [] {
            if let id = v["id"] as? String, let variant = ChannelVariant(rawValue: id) {
                supported[variant] = (v["supported"] as? NSNumber)?.boolValue ?? false
            }
        }

        // An instance of the group that cannot take a variant takes it away from the whole gesture: the
        // mirrors never end up in different widths.
        let peers = channelGroupPeers(of: pluginID, on: host)
        for peer in peers {
            guard let pd = engine.pluginChannelInfo(peer.plugin.uuidString, probeVariants: true),
                  (pd["external"] as? NSNumber)?.boolValue == true,
                  (pd["loaded"] as? NSNumber)?.boolValue == true
            else {
                for v in ChannelVariant.allCases { supported[v] = false }
                continue
            }
            exact = exact && ((pd["exact"] as? NSNumber)?.boolValue ?? false)
            for v in (pd["variants"] as? [[String: Any]]) ?? [] {
                if let id = v["id"] as? String, let variant = ChannelVariant(rawValue: id),
                   (v["supported"] as? NSNumber)?.boolValue != true {
                    supported[variant] = false
                }
            }
        }

        let channels = PluginChannels(inputs: i, outputs: o)
        let current = channels.variant
        return ChannelMenuState(
            channels: channels,
            entries: ChannelVariant.allCases.map {
                .init(variant: $0, supported: supported[$0] ?? false, isCurrent: $0 == current)
            },
            // The OBSERVED running flag first: read in a view's body, it rebuilds the menu at the stop (the
            // engine's own flag is not observable, and alone it left the menu built during playback greyed
            // for ever — the bug of 20 October 2026). The engine is still asked, for a run not started here.
            exact: exact, blockedByPlayback: isTransportRunning || isTransportPlaying, linkedCount: peers.count)
    }

    // MARK: Applying

    /// Puts a plugin — and the instances that change with it — in `variant`, as ONE undo step. The undo
    /// point is taken BEFORE the first modification and dropped again when nothing moved. The engine does
    /// the work on the main thread (@see OBJEngineCore.setChannelLayout); the model then takes the states
    /// back so the new width persists, is saved, copied and undone with the rest of the plugin.
    ///
    /// FX-link decision: the change is applied to EVERY active member of the plugin's link group, or to none
    /// (the menu greys a variant one of them cannot take): a mirror left in another width would make the
    /// bin sound different from one host to the next.
    @discardableResult
    func setChannelVariant(_ variant: ChannelVariant, pluginID: UUID, host: UUID) -> ChannelChangeOutcome {
        guard let engine else { return .refused(reason: "no_engine") }
        guard let menu = channelMenuState(pluginID: pluginID, host: host) else {
            return .refused(reason: "not_external")
        }
        guard let entry = menu.entries.first(where: { $0.variant == variant }) else {
            return .refused(reason: "bad_variant")
        }
        if menu.blockedByPlayback { return .refused(reason: "playing") }
        if entry.isCurrent && menu.linkedCount == 0 { return .unchanged }
        if !entry.supported { return .refused(reason: "unsupported") }

        let members = [(plugin: pluginID, host: host)]
            + channelGroupPeers(of: pluginID, on: host)

        pushUndo()
        let depth = undoStack.count
        var changed = 0
        var failure: String?
        for m in members {
            let r = engine.setChannelLayout(variant: variant.rawValue, forPlugin: m.plugin.uuidString,
                                            forObjectID: engineHostKey(m.host).uuidString)
            if (r["ok"] as? NSNumber)?.boolValue == true {
                if (r["changed"] as? NSNumber)?.boolValue == true { changed += 1 }
            } else {
                failure = (r["reason"] as? String) ?? "refused"
                break
            }
        }

        // The states are taken back for every instance that moved, so the model carries the new width.
        if changed > 0 {
            for m in members {
                guard let xml = engine.getPluginStateXML(m.plugin.uuidString), !xml.isEmpty else { continue }
                updateChainPlugins(m.host) { $0 = Self.settingStateXML(m.plugin, xml, in: $0) }
            }
            // An FX link's DEFINITION carries the width too: a member attached later is born from the
            // definition's state, and would otherwise come in the old width (in the snapshot, so undone
            // with the rest).
            if let def = fxDefinition(ofInstance: pluginID, on: host),
               let i = fxLinks.firstIndex(where: { $0.id == def.linkID }),
               let k = fxLinks[i].plugins.firstIndex(where: { $0.id == def.definitionID }),
               let xml = engine.getPluginStateXML(pluginID.uuidString), !xml.isEmpty {
                fxLinks[i].plugins[k].stateXML = xml
            }
            isDirty = true
        } else if undoStack.count == depth {
            // Nothing moved: the point we took has nothing to bring back.
            undoStack.removeLast()
        }

        if let failure { return .refused(reason: failure) }
        return changed > 0 ? .applied(instances: changed) : .unchanged
    }

    // MARK: Stereo → mono fold

    /// What a stereo signal is folded into for a ONE-input plugin: `left` (as before), `right`, or the sum
    /// (L + R) / 2 (@see `MonoFold`). The same members as the Channels menu — the plugin and its link group
    /// (FX link mirrors, manual link peers), all together — and the FX link's definition, so a member
    /// attached later is born with it. One undo step; none when nothing changes. Unlike a channel layout,
    /// nothing is refused while playing: it is two service plugins laid or removed around the plugin.
    @discardableResult
    func setMonoFold(_ fold: MonoFold, pluginID: UUID, host: UUID) -> ChannelChangeOutcome {
        guard let me = hostedPlugin(pluginID, of: host) else { return .refused(reason: "not_found") }
        guard !me.isContainer, !isInstrument(pluginID, of: host) else { return .refused(reason: "not_leaf") }

        let members = [(plugin: pluginID, host: host)] + channelGroupPeers(of: pluginID, on: host)
        let moving = members.filter { hostedPlugin($0.plugin, of: $0.host)?.monoFold != fold }
        let def = fxDefinition(ofInstance: pluginID, on: host)
        let defMoves: Bool = {
            guard let def, let l = fxLinks.first(where: { $0.id == def.linkID }) else { return false }
            return Self.findPlugin(def.definitionID, in: l.plugins).map { $0.monoFold != fold } ?? false
        }()
        if moving.isEmpty && !defMoves { return .unchanged }

        pushUndo()
        for m in moving {
            updateChainPlugins(m.host) { $0 = Self.settingMonoFold(m.plugin, fold, in: $0) }
        }
        if defMoves, let def, let i = fxLinks.firstIndex(where: { $0.id == def.linkID }) {
            fxLinks[i].plugins = Self.settingMonoFold(def.definitionID, fold, in: fxLinks[i].plugins)
        }
        isDirty = true
        // The engine lays (or removes) the fold's halves at the compile.
        var compiled = Set<UUID>()
        for m in moving where compiled.insert(m.host).inserted {
            compileRack(objectID: m.host)
        }
        return .applied(instances: moving.count)
    }

    /// `plugins` with the leaf `id`'s fold set (recursive).
    static func settingMonoFold(_ id: UUID, _ fold: MonoFold, in plugins: [ObjectPlugin]) -> [ObjectPlugin] {
        plugins.map { p in
            if p.id == id { var np = p; np.monoFold = fold; return np }
            if p.isContainer { return p.mappingChildSeries { settingMonoFold(id, fold, in: $0) } }
            return p
        }
    }

    /// The leaf `id` in `plugins` (recursive).
    static func findPlugin(_ id: UUID, in plugins: [ObjectPlugin]) -> ObjectPlugin? {
        for p in plugins {
            if p.id == id { return p }
            if p.isContainer {
                for v in p.childSeries { if let f = findPlugin(id, in: v) { return f } }
            }
        }
        return nil
    }

    /// The hand's door onto `setChannelVariant`: a refusal is SAID (a dialogue, journalled when headless) rather
    /// than swallowed. The machine's door (`plugin.set_channel_layout`) answers with the reason instead.
    func setChannelVariantFromHand(_ variant: ChannelVariant, pluginID: UUID, host: UUID) {
        guard case .refused(let reason) = setChannelVariant(variant, pluginID: pluginID, host: host) else { return }
        let key: String
        switch reason {
        case "playing":                 key = "channels.refused.playing"
        case "unsupported", "refused":  key = "channels.refused.unsupported"
        case "not_loaded":              key = "channels.refused.notLoaded"
        default:                        key = "channels.refused.generic"
        }
        notify(L("channels.refused.title"), L(key))
    }
}
