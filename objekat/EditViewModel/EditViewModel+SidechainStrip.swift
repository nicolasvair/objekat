import AppKit
import SwiftUI

/// "Choose object" armed from a plugin editor's Sidechain strip: whose key the next click sets.
struct SidechainPick: Equatable {
    let host: UUID
    let plugin: UUID
}

/// What the Sidechain strip's source picker offers: the stems, and the objects playing at the same
/// time as the host as a TREE — a group is offered itself AND opens onto its children, so that a
/// whole group and one of its members are both one click away. Each entry carries its refusal.
struct SidechainSourceTree {
    struct Node: Identifiable {
        let id: UUID
        let name: String
        let refusal: BridgeScope.Refusal?
        var children: [Node] = []
    }
    var current: UUID?
    var stems: [Node]
    var objects: [Node]

    /// True if `id` is somewhere under `node` (the picker opens the groups holding the current key).
    static func contains(_ id: UUID, under node: Node) -> Bool {
        node.children.contains { $0.id == id || contains(id, under: $0) }
    }
}

/// What the strip says about the current key.
struct SidechainCurrent: Equatable {
    var name: String
    /// nil = the key is live; otherwise why the engine does not apply it.
    var inactiveReason: String?
}

extension EditViewModel {

    // MARK: - The editor's Sidechain strip

    /// True if this plugin's editor gets a Sidechain strip: its live instance has a sidechain input
    /// and it sits in an FX chain (instruments have no strip yet), on a host that is not a closed
    /// consolidated object.
    func showsSidechainStrip(host: UUID, plugin: UUID) -> Bool {
        guard let engine, engine.pluginCanSidechain(plugin.uuidString) else { return false }
        if find(id: host)?.isConsolidateInstance == true { return false }
        return Self.flattenLeaves(chainPlugins(host) ?? []).contains { $0.id == plugin }
    }

    /// The plugin's current key, as the strip says it. nil = none.
    func sidechainCurrent(host: UUID, plugin: UUID) -> SidechainCurrent? {
        guard let leaf = Self.flattenLeaves(chainPlugins(host) ?? []).first(where: { $0.id == plugin }),
              let key = leaf.sidechain else { return nil }
        let name: String
        if let s = stems.first(where: { $0.id == key.sourceID }) { name = s.id == mainStemID ? L("stem.main.name") : s.name }
        else if let o = find(id: key.sourceID) { name = displayName(of: o) }
        else { name = "?" }
        return SidechainCurrent(name: name, inactiveReason: bridgeRouteStatus[plugin].map { Self.sidechainReasonText($0) })
    }

    /// The source picker's content. Objects: those whose span meets the host's (all of them when the
    /// host is a stem or an infinite bus, which play throughout), auxes left out (they cannot be a
    /// source), a group kept when it or one of its descendants qualifies. Ordered as the sound list
    /// orders them (`listOrdered`): the order things happen on the timeline. A child's `startTime`
    /// is already ABSOLUTE (@see SoundListRow.absStart).
    func sidechainSourceTree(host: UUID, plugin: UUID) -> SidechainSourceTree? {
        guard showsSidechainStrip(host: host, plugin: plugin) else { return nil }
        let current = Self.flattenLeaves(chainPlugins(host) ?? []).first { $0.id == plugin }?.sidechain?.sourceID

        // The host's span. nil = the whole timeline (a stem, an infinite bus).
        var span: (lo: Double, hi: Double)? = nil
        if let h = find(id: host), !h.isInfiniteBus { span = (h.startTime, h.startTime + h.duration) }

        struct Raw { let object: SoundObject; let children: [Raw] }
        func build(_ array: [SoundObject], _ laneOffset: Int) -> [Raw] {
            var out: [Raw] = []
            for e in Self.listOrdered(array, displayLaneOffset: laneOffset) where !e.item.isAux {
                let o = e.item
                var kids: [Raw] = []
                if case .group(let children, _) = o.kind { kids = build(children, e.displayLane + 1) }
                let meets = o.isInfiniteBus || span.map { o.startTime < $0.hi && o.startTime + o.duration > $0.lo } ?? true
                if meets || !kids.isEmpty { out.append(Raw(object: o, children: kids)) }
            }
            return out
        }
        let raw = build(items, 0)

        var wanted = Set<UUID>()
        func collect(_ r: [Raw]) { for x in r { wanted.insert(x.object.id); collect(x.children) } }
        collect(raw)
        let stemIDs = stems.filter { $0.id != mainStemID }.map { $0.id }
        wanted.formUnion(stemIDs)
        let verdicts = Dictionary(sidechainCandidates(host: host, plugin: plugin, among: wanted).map { ($0.id, $0.refusal) },
                                  uniquingKeysWith: { a, _ in a })
        // An id the bridge does not know as a node (the host itself among them) cannot be a key.
        func refusal(_ id: UUID) -> BridgeScope.Refusal? {
            if id == host { return .selfSource }
            guard let v = verdicts[id] else { return .unknownSource }
            return v
        }
        func nodes(_ r: [Raw]) -> [SidechainSourceTree.Node] {
            r.map { .init(id: $0.object.id, name: displayName(of: $0.object), refusal: refusal($0.object.id),
                          children: nodes($0.children)) }
        }
        let stemNodes = stemIDs.compactMap { id -> SidechainSourceTree.Node? in
            guard let s = stems.first(where: { $0.id == id }) else { return nil }
            return .init(id: id, name: s.name, refusal: refusal(id))
        }
        return SidechainSourceTree(current: current, stems: stemNodes, objects: nodes(raw))
    }

    /// The object or stem whose FX chain holds this plugin (a built-in's editor knows only the plugin).
    func chainHost(ofPlugin id: UUID) -> UUID? {
        func holds(_ host: UUID) -> Bool { Self.flattenLeaves(chainPlugins(host) ?? []).contains { $0.id == id } }
        func walk(_ array: [SoundObject]) -> UUID? {
            for o in array {
                if holds(o.id) { return o.id }
                if case .group(let children, _) = o.kind, let h = walk(children) { return h }
            }
            return nil
        }
        return walk(items) ?? stems.first { holds($0.id) }?.id
    }

    /// The strip as an AppKit view, for an editor window this app does not draw (JUCE's). nil = this
    /// plugin gets no strip. The JUCE window is dark whatever the app's appearance: the strip is too.
    func sidechainStripView(host: UUID, plugin: UUID) -> NSView? {
        guard showsSidechainStrip(host: host, plugin: plugin) else { return nil }
        let view = NSHostingView(rootView: SidechainStripView(viewModel: self, host: host, plugin: plugin)
            .environment(\.colorScheme, .dark))
        view.appearance = NSAppearance(named: .darkAqua)
        view.frame = NSRect(x: 0, y: 0, width: 400, height: SidechainStripView.height)
        return view
    }

    // MARK: - "Choose object"

    /// Arms the pick and brings the document window forward, so that the very next click lands on
    /// the timeline. Arming it again for the same plugin disarms it (the strip's button toggles).
    func beginSidechainPick(host: UUID, plugin: UUID) {
        let pick = SidechainPick(host: host, plugin: plugin)
        if sidechainPick == pick { sidechainPick = nil; return }
        sidechainPick = pick
        if let window = titledWindow ?? NSApp.mainWindow {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }

    func endSidechainPick() {
        sidechainPick = nil
    }

    /// Why the armed pick would refuse this object (nil = it would take it). Read on hover.
    func sidechainPickRefusal(for objectID: UUID) -> BridgeScope.Refusal? {
        guard let pick = sidechainPick else { return nil }
        if objectID == pick.host { return .selfSource }
        if find(id: objectID)?.isAux == true { return .auxSource }
        return sidechainCandidates(host: pick.host, plugin: pick.plugin, among: [objectID])
            .first { $0.id == objectID }.map { $0.refusal } ?? .unknownSource
    }

    /// The click of the armed pick on an object: sets the key if the object is allowed and leaves the
    /// mode; a refused object leaves the mode armed (the veil already said why).
    @discardableResult
    func commitSidechainPick(objectID: UUID) -> Bool {
        guard let pick = sidechainPick else { return false }
        guard sidechainPickRefusal(for: objectID) == nil else { NSSound.beep(); return false }
        sidechainPick = nil
        do { try setSidechain(host: pick.host, plugin: pick.plugin, source: objectID); return true }
        catch { NSSound.beep(); return false }
    }

    /// The name of what receives the key: the host object or stem.
    func sidechainHostName(_ host: UUID) -> String {
        if let s = stems.first(where: { $0.id == host }) { return s.id == mainStemID ? L("stem.main.name") : s.name }
        return find(id: host).map { displayName(of: $0) } ?? ""
    }

    /// The plugin's display name, for the pick's HUD and veil.
    func sidechainPickPluginName(_ pick: SidechainPick) -> String {
        Self.flattenLeaves(chainPlugins(pick.host) ?? []).first { $0.id == pick.plugin }?.name ?? ""
    }
}
