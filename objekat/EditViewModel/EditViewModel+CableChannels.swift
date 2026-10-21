import Foundation

// MARK: - A channel choice on each cable (session format 31)
//
// The view-model's half of the cable pick (@see ChannelPick.swift for the model and its one place of
// reading, `SynopticWidthFlow` for the widths): what every cable of a chain carries, and how a choice is
// written on one — as ONE undo step, on the cable's own series, through the bin's definition when the
// cable is inside an attached bin.
//
// The signal view and the command API read the SAME numbers: `widthFlow(host:root:channels:)` is the one
// computation of the widths along a chain (it used to sit in the bound view's body), and `cableInfos`
// the one reading of what each cable point says and offers.

// MARK: - Reading

/// What one cable point of a chain says: its place, the width of the signal arriving there, the choice in
/// force, and the choices a hand may make.
struct CableInfo: Equatable {
    var location: SeriesLocation
    var point: CablePoint
    /// The channels of the signal arriving at this cable point, before the choice written there. The head
    /// of a stereo clip's chain is the audio FILE's own width.
    var widthIn: Int
    /// The choice in force: the pick of this cable, else (for a cable that enters a one-input plugin) that
    /// plugin's inherited fold, else Stereo. At the head of a stereo clip it is the file's own choice.
    var choice: CableChoice
    /// A choice is WRITTEN here (a pick, the file's channel mode, or an inherited `monoFold` key).
    var explicit: Bool
    /// What a hand may choose. Empty on a mono cable; Left / Right / Sum (no Stereo) on a cable that enters
    /// a one-input plugin, which cannot receive a pair; the four elsewhere.
    var offered: [CableChoice]
    /// The model id of the pick standing on this cable, if any.
    var pickID: UUID?
    /// The cable is the head of a STEREO audio clip: its choice is the file's own channel mode
    /// (`SoundObject.channelMode`, one menu — a pick never stands there).
    var fileLevel: Bool
    /// A pick stands here on a cable that is already mono (an upstream change made it so): kept silently,
    /// no effect, back in force if the cable becomes stereo again.
    var inert: Bool
    /// The card this cable enters (nil at the tail of a series), and whether it is a one-input plugin.
    var entering: UUID?
    var intoOneInput: Bool
}

extension ChannelMode {
    /// The file's choice as the width arithmetic reads it.
    var asSourceChoice: SourceChannelChoice {
        switch self {
        case .lr: return .both
        case .l:  return .left
        case .r:  return .right
        case .c:  return .sum
        }
    }

    /// The same choice as a cable's: nil = LR, the file as it is.
    var asFold: MonoFold? {
        switch self {
        case .lr: return nil
        case .l:  return .left
        case .r:  return .right
        case .c:  return .sum
        }
    }

    init(fold: MonoFold?) {
        switch fold {
        case nil:      self = .lr
        case .left?:   self = .l
        case .right?:  self = .r
        case .sum?:    self = .c
        }
    }
}

extension SeriesLocation {
    /// The reverse of `key` (`root`, `voice-<block uuid>-<index>`, `block-<block uuid>`).
    init?(key: String) {
        if key == "root" { self = .root; return }
        if key.hasPrefix("block-"), let id = UUID(uuidString: String(key.dropFirst("block-".count))) {
            self = .block(blockID: id); return
        }
        if key.hasPrefix("voice-") {
            let rest = key.dropFirst("voice-".count)
            if let dash = rest.lastIndex(of: "-"),
               let id = UUID(uuidString: String(rest[rest.startIndex..<dash])),
               let vi = Int(rest[rest.index(after: dash)...]) {
                self = .voice(blockID: id, voiceIndex: vi); return
            }
        }
        return nil
    }
}

extension EditViewModel {

    /// The width of the signal along host `hostID`'s chain (@see SynopticWidthFlow): what the file feeds it
    /// (an audio clip's channel count, a stereo pair for everything else), the file's own channel choice,
    /// each plugin's inherited fold and every pick written on a cable. `channels` holds the main bus of
    /// the external plugins the engine reports one for (@see `pluginChannels(pluginIDs:)`); the bound view
    /// keeps its own polled copy of it, the API asks the engine.
    func widthFlow(host hostID: UUID, root: SynopticNode, channels: [UUID: PluginChannels]) -> SynopticWidthFlow {
        let obj = find(id: hostID)
        var folds = Self.monoFolds(chainPlugins(hostID) ?? [])
        if let obj { folds.merge(Self.monoFolds(of: obj)) { a, _ in a } }
        let choice: SourceChannelChoice? = obj.flatMap {
            ($0.isClip && !$0.isConsolidateInstance && canChooseChannelMode($0)) ? $0.channelMode.asSourceChoice : nil
        }
        return SynopticWidthFlow.compute(root: root, sourceWidth: sourceChannelWidth(hostID: hostID),
                                         sourceChoice: choice, channels: channels, folds: folds)
    }

    /// Every cable point of host `hostID`'s chain, in series order (the root first, then each branch and
    /// each bin as met): nil for an unknown host, empty for a send's mini-chain (it takes no choice).
    func cableInfos(host hostID: UUID, channels given: [UUID: PluginChannels]? = nil) -> [CableInfo]? {
        guard let model = chainPlugins(hostID) else { return nil }
        if find(id: hostID) == nil && isSendChainHost(hostID) { return [] }
        let (root, _) = SynopticMapping.build(model, objectID: hostID, fxLinkInfo: { [self] in synopticFXInfo($0) })
        let channels = given ?? pluginChannels(pluginIDs: Self.flattenLeaves(model).map(\.id))
        let flow = widthFlow(host: hostID, root: root, channels: channels)
        let obj = find(id: hostID)
        // The head of a stereo audio clip's chain: the file's own channel choice is the one menu there.
        let fileMode: ChannelMode? = obj.flatMap {
            ($0.isClip && !$0.isConsolidateInstance && canChooseChannelMode($0)) ? $0.channelMode : nil
        }

        var out: [CableInfo] = []
        func collect(_ series: [ObjectPlugin], seriesID: UUID, location: SeriesLocation) {
            for i in 0...ChannelPicks.visibleCount(series) {
                let point = CablePoint(seriesID: seriesID, index: i)
                let card = ChannelPicks.card(atVisible: i, in: series)
                let pick = ChannelPicks.pick(atVisible: i, in: series)
                let atRoot: Bool = { if case .root = location { return true } else { return false } }()
                let fileLevel = fileMode != nil && i == 0 && atRoot
                let width = fileLevel ? flow.sourceWidth : (flow.widthAt[point] ?? 2)
                let oneInput = card.map { !$0.isContainer && channels[$0.id]?.inputs == 1 } ?? false
                let mono = width <= 1

                var choice = CableChoice.stereo
                var explicit = false
                var inert = false
                if fileLevel, let fm = fileMode, fm != .lr {
                    choice = CableChoice(fm.asFold); explicit = true
                } else if let pk = pick?.channelPick {
                    choice = CableChoice(pk.mode); explicit = true; inert = mono
                } else if !mono, oneInput, let card {
                    choice = CableChoice(MonoFold.played(card.monoFold)); explicit = card.monoFold != nil
                }
                let offered: [CableChoice] = fileLevel ? CableChoice.allCases
                    : (mono ? [] : (oneInput ? [.left, .right, .sum] : CableChoice.allCases))
                out.append(CableInfo(location: location, point: point, widthIn: width, choice: choice,
                                     explicit: explicit, offered: offered, pickID: pick?.id,
                                     fileLevel: fileLevel, inert: inert, entering: card?.id,
                                     intoOneInput: oneInput))
            }
            for p in series {
                if let rack = p.rack {
                    for (vi, voice) in rack.voices.enumerated() {
                        collect(voice, seriesID: SynopticMapping.voiceSeriesID(blockID: p.id, voiceIndex: vi),
                                location: .voice(blockID: p.id, voiceIndex: vi))
                    }
                } else if let block = p.fxBlock {
                    collect(block.plugins, seriesID: p.id, location: .block(blockID: p.id))
                }
            }
        }
        collect(model, seriesID: hostID, location: .root)
        return out
    }

    /// The engine's own mode for each pick of the host (`left` / `right` / `sum`), by the pick's id, as the
    /// compile laid it. What a script compares with the model.
    func enginePickModes(host hostID: UUID) -> [UUID: String] {
        guard let raw = engine?.engineChain(forObjectID: engineHostKey(hostID).uuidString) else { return [:] }
        var out: [UUID: String] = [:]
        func walk(_ entries: [[String: Any]]) {
            for e in entries {
                if e["role"] as? String == "pick", let k = e["key"] as? String, let id = UUID(uuidString: k),
                   let m = e["mode"] as? String { out[id] = m }
                for b in (e["branches"] as? [[[String: Any]]]) ?? [] { walk(b) }
            }
        }
        walk(raw.compactMap { $0 as? [String: Any] })
        return out
    }

    /// The pick standing on the cable that enters plugin `pluginID` of host `hostID`, if any (what
    /// `plugin.channel_layouts` reports as the plugin's fold once a pick says better).
    func enteringCablePick(of pluginID: UUID, on hostID: UUID) -> MonoFold? {
        guard let chain = chainPlugins(hostID), let (loc, i) = Self.locate(pluginID, in: chain),
              let series = Self.seriesEntries(loc, in: chain) else { return nil }
        return ChannelPicks.pick(atVisible: i, in: series)?.channelPick?.mode
    }

    // MARK: - Writing

    /// Writes `choice` on the cable point (`location`, `index`) of host `hostID`'s chain, as ONE undo step
    /// (none when nothing changes). Stereo takes the pick away; Left / Right / Sum put one there (a pick
    /// already there keeps its id and its place). Refusals, by `reason`: `not_found` (host),
    /// `send_chain` (a send's mini-chain takes no choice), `no_such_series`, `out_of_range`,
    /// `mono_cable` (nothing to choose on one wire), `not_offered` (Stereo into a one-input plugin).
    ///
    /// A cable that enters a ONE-INPUT plugin hands that plugin's `monoFold` over to the pick: the pick is
    /// written and the plugin's own key cleared, so the choice has one home. The head of a stereo audio
    /// clip's chain is the file's own channel choice: `channelMode` is written there, never a pick.
    /// A cable inside an ATTACHED bin is the bin's: the definition is written and every member follows; a
    /// detached bin's cable is the host's own. A manual ⌘-link does not carry a cable's choice (the cable
    /// belongs to its host's chain). Nothing is refused while playing: it is a service plugin laid or
    /// removed.
    @discardableResult
    func setCableChannels(host hostID: UUID, location: SeriesLocation, index: Int, choice: CableChoice,
                          channels: [UUID: PluginChannels]? = nil) -> ChannelChangeOutcome {
        guard let model = chainPlugins(hostID) else { return .refused(reason: "not_found") }
        if find(id: hostID) == nil && isSendChainHost(hostID) { return .refused(reason: "send_chain") }
        guard let series = Self.seriesEntries(location, in: model) else { return .refused(reason: "no_such_series") }
        guard index >= 0, index <= ChannelPicks.visibleCount(series) else { return .refused(reason: "out_of_range") }
        guard let info = cableInfos(host: hostID, channels: channels)?
            .first(where: { $0.location == location && $0.point.index == index })
        else { return .refused(reason: "no_such_series") }
        if info.offered.isEmpty { return .refused(reason: "mono_cable") }
        if !info.offered.contains(choice) { return .refused(reason: "not_offered") }

        let entering = ChannelPicks.card(atVisible: index, in: series)
        // The plugin that gives its fold up to this choice (a one-input plugin keeping a key of its own).
        let clearing: UUID? = (choice != .stereo && info.intoOneInput && entering?.monoFold != nil) ? entering?.id : nil

        // Nothing to write?
        if info.fileLevel {
            let current = obj(hostID)?.channelMode ?? .lr
            if current == ChannelMode(fold: choice.fold) && clearing == nil { return .unchanged }
        } else if choice == .stereo {
            if info.pickID == nil { return .unchanged }
        } else if let pk = ChannelPicks.pick(atVisible: index, in: series)?.channelPick,
                  pk.mode == choice.fold, clearing == nil {
            return .unchanged
        }

        pushUndo()
        var hosts: Set<UUID> = [hostID]

        if info.fileLevel {
            let mode = ChannelMode(fold: choice.fold)
            update(id: hostID) { $0.channelMode = mode }
            engine?.updateChannelMode(mode.engineCode, forID: hostID.uuidString)
            if let pid = clearing {
                updateChainPlugins(hostID) { $0 = Self.clearingMonoFold(of: pid, in: $0) }
                compileRack(objectID: hostID)
            }
            isDirty = true
            return .applied(instances: 1)
        }

        if case .block(let blockID) = location, let block = Self.findBlock(blockID, in: model)?.fxBlock,
           !block.isDetached, let li = fxLinkIndex(block.linkID) {
            // The bin's cable: write the DEFINITION (the instances stand at the same visible indices), hand
            // the fold of the plugin it enters over to the pick, and let every member follow.
            let definition = fxLinks[li].plugins
            let enteringDef = ChannelPicks.card(atVisible: index, in: definition)
            var written = ChannelPicks.setting(choice.fold, atVisible: index, in: definition)
            if clearing != nil, let ed = enteringDef { written = Self.clearingMonoFold(of: ed.id, in: written) }
            fxLinks[li].plugins = written
            let members = fxLinkAttachedMembers(block.linkID)
            if clearing != nil, let ed = enteringDef {
                // The reconcile reuses the members' existing instances as they are: their own key goes here.
                for m in members {
                    updateChainPlugins(m.hostID) { chain in
                        chain = Self.updatingBlock(m.block.id, in: chain) { b in
                            let current = b.fxBlock?.plugins ?? []
                            b.fxBlock?.plugins = current.map { inst in
                                guard inst.linkGroupID == ed.id else { return inst }
                                var q = inst; q.monoFold = nil; return q
                            }
                        }
                    }
                }
            }
            hosts = Set(members.map(\.hostID))
            isDirty = true
            reconcileFXLinkMembers(block.linkID)
            return .applied(instances: max(1, hosts.count))
        }

        updateChainPlugins(hostID) { chain in
            chain = Self.mappingSeries(location, in: chain) { s in
                var out = ChannelPicks.setting(choice.fold, atVisible: index, in: s)
                if let pid = clearing { out = Self.clearingMonoFold(of: pid, in: out) }
                return out
            }
        }
        isDirty = true
        compileRack(objectID: hostID)
        return .applied(instances: hosts.count)
    }

    /// `plugins` with the leaf `id`'s own `monoFold` key taken away (recursive).
    static func clearingMonoFold(of id: UUID, in plugins: [ObjectPlugin]) -> [ObjectPlugin] {
        plugins.map { p in
            if p.id == id { var q = p; q.monoFold = nil; return q }
            if p.isContainer { return p.mappingChildSeries { clearingMonoFold(of: id, in: $0) } }
            return p
        }
    }

    private func obj(_ id: UUID) -> SoundObject? { find(id: id) }
}
