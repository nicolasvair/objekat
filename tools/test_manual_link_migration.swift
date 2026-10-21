// `LegacyManualLinkMigration` (session format 32) — the single-instance manual link is gone: a plugin
// OUTSIDE every FX link bin loses `linkGroupID` / `detachedLinkGroupID`, the members of a bin (attached
// or detached) keep theirs, whatever the root (chain, rack voice, instruments, a send's plugins, a stem's
// chain, a group's children). Pure, no screen. Run from `tools/`:
//
//     cd tools && swiftc -parse-as-library \
//         ../objekat/SoundObject/SoundObject.swift \
//         ../objekat/Inspector/Synoptic/SynopticGraph.swift \
//         ../objekat/Inspector/Synoptic/SynopticWidthFlow.swift \
//         ../objekat/SoundObject/ChannelPick.swift \
//         ../objekat/Shared/SendChain.swift \
//         ../objekat/SoundObject/Automation.swift \
//         ../objekat/SoundObject/AutomationCurveMath.swift \
//         ../objekat/SoundObject/AutomationCurveShape.swift \
//         ../objekat/SoundObject/Marker.swift \
//         ../objekat/SoundObject/ChannelMode.swift \
//         ../objekat/Shared/LaneEntryIndex.swift \
//         ../objekat/Timeline/ClipEditZonesOverlay.swift \
//         ../objekat/SoundObject/ConsolidateDefinition.swift \
//         ../objekat/SoundObject/FadeCurve.swift \
//         ../objekat/SoundObject/ComposedName.swift \
//         ../objekat/SoundObject/FXLink.swift \
//         ../objekat/SoundObject/SendPosition.swift \
//         ../objekat/Shared/ObjekatPalette.swift \
//         ../objekat/Shared/ObjectColorChoice.swift \
//         ../objekat/Shared/Localization.swift \
//         ../objekat/SoundObject/GainStage.swift \
//         ../objekat/SoundObject/LegacyGainMigration.swift \
//         ../objekat/EditViewModel/EditViewModel+Types.swift \
//         ../objekat/EditViewModel/SessionSchema.swift \
//         ../objekat/App/LaunchArguments.swift \
//         ../objekat/Shared/BridgeScope.swift \
//         ../objekat/Shared/ScriptCanvasMemory.swift \
//         ../objekat/Shared/FeatureIcons.swift \
//         ../objekat/SoundObject/LegacyManualLinkMigration.swift \
//         test_manual_link_migration.swift \
//         -o /tmp/mlm && /tmp/mlm
//
// Exit: 0 if every assertion passes, 1 otherwise.

import Foundation

var fails: [String] = []
var total = 0

func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    total += 1
    if ok { print("ok    " + label) }
    else { fails.append(label); print("FAIL  \(label)  \(detail)") }
}

@main
enum ManualLinkMigrationTest {
    static func main() {

        // MARK: - Fixture builders

        func plugin(id: UUID = UUID(), link: UUID? = nil, detached: UUID? = nil) -> ObjectPlugin {
            ObjectPlugin(id: id, name: "EQ", manufacturer: "FabFilter", identifier: "eq",
                         formatName: "AudioUnit", linkGroupID: link, detachedLinkGroupID: detached,
                         colorIndex: 1)
        }
        func block(instances: [ObjectPlugin], detached: Bool = false) -> ObjectPlugin {
            var b = FXLink.blockEntry(linkID: UUID(), name: "Bin", instances: instances, id: UUID())
            b.fxBlock?.isDetached = detached
            return b
        }
        func rack(_ voices: [[ObjectPlugin]]) -> ObjectPlugin {
            ObjectPlugin(id: UUID(), name: "Parallel", manufacturer: "", identifier: "", formatName: "",
                         rack: PluginRack(voices: voices), colorIndex: 0)
        }
        func clip(plugins: [ObjectPlugin] = [], instruments: [ObjectPlugin] = [],
                  sends: [AuxSend] = []) -> SoundObject {
            var o = SoundObject(id: UUID(), startTime: 0, duration: 4, lane: 0,
                                plugins: plugins, instruments: instruments,
                                kind: .clip(filePath: "a.wav", sourceOffset: 0, fileDuration: 4,
                                            speedRatio: 1, isReversed: false))
            o.sends = sends
            return o
        }
        func group(children: [SoundObject]) -> SoundObject {
            SoundObject(id: UUID(), startTime: 0, duration: 4, lane: 0, plugins: [],
                        kind: .group(children: children, isExpanded: true))
        }
        func stem(plugins: [ObjectPlugin]) -> Stem {
            Stem(id: UUID(), name: "Bus", colorIndex: 0, format: .stereo, plugins: plugins)
        }
        func run(_ items: [SoundObject], _ stems: [Stem] = []) -> ([SoundObject], [Stem], LegacyManualLinkMigration.Report) {
            var i = items, s = stems
            let r = LegacyManualLinkMigration.migrate(items: &i, stems: &s)
            return (i, s, r)
        }

        let g = UUID(), d = UUID()

        // MARK: 1. A manual link alone

        do {
            let p = plugin(link: g)
            let (items, _, r) = run([clip(plugins: [p])])
            let q = items[0].plugins[0]
            check("a linked plugin outside a bin loses its link", q.linkGroupID == nil && q.detachedLinkGroupID == nil)
            check("... and keeps its identity", q.id == p.id && q.name == "EQ" && q.identifier == "eq")
            check("the report counts it", r.unlinkedPlugins == 1 && r.hosts == 1)
        }
        do {
            let (items, _, r) = run([clip(plugins: [plugin(detached: g)])])
            let q = items[0].plugins[0]
            check("a DETACHED manual link (able to rejoin) is cleared too",
                  q.linkGroupID == nil && q.detachedLinkGroupID == nil && r.unlinkedPlugins == 1)
        }
        do {
            let (_, _, r) = run([clip(plugins: [plugin()])])
            check("an unlinked plugin: nothing to do", r.isEmpty)
        }

        // MARK: 2. FX link bins are untouched

        do {
            let inst = plugin(link: d)
            let (items, _, r) = run([clip(plugins: [block(instances: [inst])])])
            let q = items[0].plugins[0].fxBlock?.plugins[0]
            check("an attached bin's instance keeps its link", q?.linkGroupID == d && r.isEmpty)
        }
        do {
            let inst = plugin(detached: d)
            let (items, _, r) = run([clip(plugins: [block(instances: [inst], detached: true)])])
            let q = items[0].plugins[0].fxBlock?.plugins[0]
            check("a DETACHED bin's instance keeps its (detached) link", q?.detachedLinkGroupID == d && r.isEmpty)
        }
        do {
            let (items, _, r) = run([clip(plugins: [plugin(link: g), block(instances: [plugin(link: d)]), plugin(detached: g)])])
            let ps = items[0].plugins
            check("a bin between two manual links: only the manual ones go",
                  ps[0].linkGroupID == nil && ps[2].detachedLinkGroupID == nil
                  && ps[1].fxBlock?.plugins[0].linkGroupID == d && r.unlinkedPlugins == 2 && r.hosts == 1)
        }

        // MARK: 3. The three roots and the rest

        do {
            let rk = rack([[plugin(link: g)], [plugin(detached: g), block(instances: [plugin(link: d)])]])
            let (items, _, r) = run([clip(plugins: [rk])])
            let v = items[0].plugins[0].rack!.voices
            check("a rack's voices are walked (the bin down a voice is not)",
                  v[0][0].linkGroupID == nil && v[1][0].detachedLinkGroupID == nil
                  && v[1][1].fxBlock?.plugins[0].linkGroupID == d && r.unlinkedPlugins == 2)
        }
        do {
            let (items, _, r) = run([clip(instruments: [plugin(link: g)])])
            check("an instrument loses its link", items[0].instruments[0].linkGroupID == nil && r.unlinkedPlugins == 1)
        }
        do {
            var send = AuxSend(auxID: UUID())
            send.plugins = [plugin(link: g)]   // a file may carry what the app no longer writes
            let (items, _, r) = run([clip(sends: [send])])
            check("a send's plugin loses its link", items[0].sends[0].plugins[0].linkGroupID == nil && r.unlinkedPlugins == 1)
        }
        do {
            let (_, stems, r) = run([], [stem(plugins: [plugin(link: g), block(instances: [plugin(link: d)])])])
            check("a stem's chain is walked, its bin is not",
                  stems[0].plugins[0].linkGroupID == nil && stems[0].plugins[1].fxBlock?.plugins[0].linkGroupID == d
                  && r.unlinkedPlugins == 1 && r.hosts == 1)
        }
        do {
            let inner = clip(plugins: [plugin(link: g)], instruments: [plugin(link: g)])
            let (items, _, r) = run([group(children: [inner, clip(plugins: [plugin(link: g)])])])
            if case .group(let kids, _) = items[0].kind {
                check("a group's children are walked at any depth",
                      kids[0].plugins[0].linkGroupID == nil && kids[0].instruments[0].linkGroupID == nil
                      && kids[1].plugins[0].linkGroupID == nil)
            } else { check("a group stays a group", false) }
            check("... three plugins on two hosts", r.unlinkedPlugins == 3 && r.hosts == 2)
        }

        // MARK: 4. Idempotence, and the sidecar door

        do {
            let (items, stems, first) = run([clip(plugins: [plugin(link: g), block(instances: [plugin(link: d)])])],
                                            [stem(plugins: [plugin(detached: g)])])
            let (items2, stems2, second) = run(items, stems)
            check("a second run finds nothing", first.unlinkedPlugins == 2 && second.isEmpty)
            check("... and changes nothing", items2 == items && stems2 == stems)
        }
        do {
            var o = group(children: [clip(plugins: [plugin(link: g)])])
            let r = LegacyManualLinkMigration.migrate(&o)
            if case .group(let kids, _) = o.kind {
                check("a sidecar's sub-tree is migrated too", kids[0].plugins[0].linkGroupID == nil && r.unlinkedPlugins == 1)
            } else { check("a group stays a group", false) }
        }

        print("\n\(total - fails.count)/\(total) assertions passed")
        if !fails.isEmpty { print("FAILED: \(fails)"); exit(1) }
    }
}
