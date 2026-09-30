// `PluginIDUniqueness` — the load-time repair of plugin ids held by two hosts (1 October 2026),
// asserted with no screen. Same model dependencies as `test_cross_project_import.swift`, minus the
// import itself; run from `tools/`:
//
//     swiftc -parse-as-library \
//         ../objekat/SoundObject/SoundObject.swift \
//         ../objekat/SoundObject/Automation.swift \
//         ../objekat/SoundObject/AutomationCurveMath.swift \
//         ../objekat/SoundObject/Marker.swift \
//         ../objekat/SoundObject/ConsolidateDefinition.swift \
//         ../objekat/SoundObject/FadeCurve.swift \
//         ../objekat/SoundObject/ComposedName.swift \
//         ../objekat/SoundObject/ChannelMode.swift \
//         ../objekat/SoundObject/FXLink.swift \
//         ../objekat/Shared/ObjekatPalette.swift \
//         ../objekat/Shared/Localization.swift \
//         ../objekat/EditViewModel/EditViewModel+Types.swift \
//         ../objekat/EditViewModel/SessionSchema.swift \
//         ../objekat/App/LaunchArguments.swift \
//         ../objekat/SoundObject/PluginIDUniqueness.swift \
//         test_plugin_id_uniqueness.swift \
//         -o /tmp/pidu && /tmp/pidu
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
enum PluginIDUniquenessTest {
    static func main() {

        // MARK: - Fixture builders

        func plugin(id: UUID = UUID(), state: String? = "<state/>", linkGroupID: UUID? = nil,
                    enabled: Bool = true, colorIndex: Int = 3) -> ObjectPlugin {
            ObjectPlugin(id: id, name: "EQ", manufacturer: "Objekat", identifier: "eq",
                         formatName: "TracktionInternal", isEnabled: enabled, stateXML: state,
                         linkGroupID: linkGroupID, colorIndex: colorIndex)
        }

        /// An FX link's block entry: its own id, the bin's id, this host's instances.
        func block(id: UUID = UUID(), linkID: UUID, instances: [ObjectPlugin]) -> ObjectPlugin {
            FXLink.blockEntry(linkID: linkID, name: "Bin", instances: instances, id: id)
        }

        func rack(id: UUID = UUID(), voices: [[ObjectPlugin]]) -> ObjectPlugin {
            ObjectPlugin(id: id, name: "Parallel", manufacturer: "", identifier: "", formatName: "",
                         rack: PluginRack(voices: voices), colorIndex: 0)
        }

        func clip(id: UUID = UUID(), plugins: [ObjectPlugin] = [], instruments: [ObjectPlugin] = [],
                  automation: [AutomationLane] = [], touch: [ParamRef] = []) -> SoundObject {
            SoundObject(id: id, startTime: 0, duration: 4, lane: 0,
                        plugins: plugins, instruments: instruments,
                        automation: automation, automationTouchOrder: touch,
                        kind: .clip(filePath: "a.wav", sourceOffset: 0, fileDuration: 4,
                                    speedRatio: 1, isReversed: false))
        }

        func group(id: UUID = UUID(), plugins: [ObjectPlugin] = [], children: [SoundObject]) -> SoundObject {
            SoundObject(id: id, startTime: 0, duration: 4, lane: 0, plugins: plugins,
                        kind: .group(children: children, isExpanded: true))
        }

        func lane(_ key: UUID, _ param: String = "p") -> AutomationLane {
            AutomationLane(param: .plugin(pluginKey: key, paramID: param),
                           points: [AutomationPoint(t: 0, v: 0.5)])
        }

        func stem(plugins: [ObjectPlugin]) -> Stem {
            Stem(id: UUID(), name: "Bus", colorIndex: 0, format: .stereo, plugins: plugins)
        }

        func allIDs(_ items: [SoundObject], _ stems: [Stem]) -> [UUID] {
            PluginIDUniqueness.occurrences(items: items, stems: stems).map(\.id)
        }

        // MARK: 1. A sound project is left strictly alone

        do {
            let groupID = UUID()
            let a = clip(plugins: [plugin(), rack(voices: [[plugin()], [plugin()]])],
                         instruments: [plugin()])
            let b = clip(plugins: [block(linkID: UUID(), instances: [plugin(linkGroupID: groupID)])])
            let g = group(plugins: [plugin()], children: [clip(plugins: [plugin()])])
            let items = [a, b, g]
            let stems = [stem(plugins: [plugin()])]
            let r = PluginIDUniqueness.deduplicated(items: items, stems: stems)
            check("a project with no duplicate yields no repair", r.repairs.isEmpty)
            check("a project with no duplicate is returned strictly equal",
                  r.items == items && r.stems == stems)
            check("the audit finds no duplicate in a sound project",
                  PluginIDUniqueness.duplicates(items: items, stems: stems).isEmpty)
        }

        // MARK: 2. Two hosts, the same FX link instance

        do {
            let bin = UUID()
            let def = UUID()
            let shared = UUID()
            let blockA = UUID(), blockB = UUID()
            let instA = plugin(id: shared, state: "<A/>", linkGroupID: def, enabled: false, colorIndex: 7)
            // The shape found in the user's files: a block entry with a NEW block id but the SAME
            // instance id as the other host's.
            let instB = plugin(id: shared, state: "<B/>", linkGroupID: def, enabled: true, colorIndex: 9)
            let a = clip(plugins: [block(id: blockA, linkID: bin, instances: [instA])])
            let b = clip(plugins: [block(id: blockB, linkID: bin, instances: [instB])])
            let r = PluginIDUniqueness.deduplicated(items: [a, b], stems: [])
            check("two hosts sharing an instance id → exactly one repair", r.repairs.count == 1)
            let fa = r.items[0].plugins[0].fxBlock!.plugins[0]
            let fb = r.items[1].plugins[0].fxBlock!.plugins[0]
            check("the first host keeps the id", fa.id == shared)
            check("the second host gets a fresh id", fb.id != shared)
            check("the repair names old, new and the host",
                  r.repairs[0] == .init(oldID: shared, newID: fb.id, hostID: b.id))
            check("linkGroupID is untouched (the instance stays the bin's mirror)",
                  fa.linkGroupID == def && fb.linkGroupID == def)
            check("stateXML, isEnabled, colorIndex are untouched",
                  fb.stateXML == "<B/>" && fb.isEnabled == true && fb.colorIndex == 9
                  && fa.stateXML == "<A/>" && fa.isEnabled == false && fa.colorIndex == 7)
            check("an already unique block id stays as it was",
                  r.items[0].plugins[0].id == blockA && r.items[1].plugins[0].id == blockB)
            check("the block's linkID is untouched",
                  r.items[1].plugins[0].fxBlock!.linkID == bin)
            check("no duplicate left after the repair",
                  PluginIDUniqueness.duplicates(items: r.items, stems: r.stems).isEmpty)
        }

        // MARK: 3. Automation follows the re-keyed host only, and never loses a reference

        do {
            let shared = UUID(), other = UUID()
            let a = clip(plugins: [plugin(id: shared), plugin(id: other)],
                         automation: [lane(shared)], touch: [.plugin(pluginKey: shared, paramID: "p")])
            let b = clip(plugins: [plugin(id: shared)],
                         automation: [lane(shared, "q"), lane(other, "z"),
                                      AutomationLane(param: .volume, points: [AutomationPoint(t: 1, v: 0)])],
                         touch: [.plugin(pluginKey: shared, paramID: "q"), .volume,
                                 .plugin(pluginKey: other, paramID: "z")])
            let r = PluginIDUniqueness.deduplicated(items: [a, b], stems: [])
            let newID = r.items[1].plugins[0].id
            check("the re-keyed plugin has a fresh id", newID != shared)
            check("host 1's automation is unchanged", r.items[0].automation == a.automation
                  && r.items[0].automationTouchOrder == a.automationTouchOrder)
            check("host 2's curve on the duplicated id points at the NEW id",
                  r.items[1].automation[0].param == .plugin(pluginKey: newID, paramID: "q")
                  && r.items[1].automation[0].points == b.automation[0].points)
            check("host 2's touch order follows too",
                  r.items[1].automationTouchOrder[0] == .plugin(pluginKey: newID, paramID: "q"))
            check("a reference to an unaffected plugin is never dropped",
                  r.items[1].automation[1].param == .plugin(pluginKey: other, paramID: "z")
                  && r.items[1].automationTouchOrder[2] == .plugin(pluginKey: other, paramID: "z"))
            check("non-plugin parameters stay in place",
                  r.items[1].automation[2].param == .volume && r.items[1].automationTouchOrder[1] == .volume)
            check("no lane or touch entry is lost",
                  r.items[1].automation.count == 3 && r.items[1].automationTouchOrder.count == 3)
        }

        // MARK: 3b. The same id twice inside ONE host: the curve stays on the first occurrence

        do {
            let x = UUID()
            // Host alone: the first occurrence keeps the id, the curve stays on it.
            let solo = clip(plugins: [plugin(id: x), plugin(id: x)], automation: [lane(x)])
            let r1 = PluginIDUniqueness.deduplicated(items: [solo], stems: [])
            check("a same-host duplicate is re-keyed once", r1.repairs.count == 1)
            check("the curve stays on the occurrence that kept the id",
                  r1.items[0].plugins[0].id == x && r1.items[0].plugins[1].id != x
                  && r1.items[0].automation[0].param == .plugin(pluginKey: x, paramID: "p"))
            // Both occurrences re-keyed (an earlier host owns x): the curve goes to the FIRST one.
            let earlier = clip(plugins: [plugin(id: x)])
            let twice = clip(plugins: [plugin(id: x), plugin(id: x)], automation: [lane(x)])
            let r2 = PluginIDUniqueness.deduplicated(items: [earlier, twice], stems: [])
            check("two re-keys in one host → two repairs, three distinct ids",
                  r2.repairs.count == 2 && Set(allIDs(r2.items, r2.stems)).count == 3)
            check("the curve follows the FIRST re-keyed occurrence",
                  r2.items[1].automation[0].param == .plugin(pluginKey: r2.items[1].plugins[0].id, paramID: "p"))
        }

        // MARK: 4. Duplicated block id (entry) and rack carrier

        do {
            let blockID = UUID(), rackID = UUID()
            let a = clip(plugins: [block(id: blockID, linkID: UUID(), instances: [plugin()]),
                                   rack(id: rackID, voices: [[plugin()]])])
            let b = clip(plugins: [block(id: blockID, linkID: UUID(), instances: [plugin()]),
                                   rack(id: rackID, voices: [[plugin()]])])
            let r = PluginIDUniqueness.deduplicated(items: [a, b], stems: [])
            check("a duplicated block entry id and a duplicated rack carrier id are both re-keyed",
                  r.repairs.count == 2
                  && r.items[0].plugins[0].id == blockID && r.items[0].plugins[1].id == rackID
                  && r.items[1].plugins[0].id != blockID && r.items[1].plugins[1].id != rackID)
            check("a container's content keeps its own (unique) ids",
                  r.items[1].plugins[1].rack!.voices == b.plugins[1].rack!.voices
                  && r.items[1].plugins[0].fxBlock!.plugins == b.plugins[0].fxBlock!.plugins)
        }

        // MARK: 5. Object vs bus

        do {
            let x = UUID()
            let o = clip(plugins: [plugin(id: x)])
            let s = stem(plugins: [plugin(id: x)])
            let r = PluginIDUniqueness.deduplicated(items: [o], stems: [s])
            check("an object and a bus sharing an id: the bus is re-keyed",
                  r.repairs.count == 1 && r.repairs[0].hostID == s.id
                  && r.items[0].plugins[0].id == x && r.stems[0].plugins[0].id != x)
            check("the bus keeps its other fields", r.stems[0].id == s.id && r.stems[0].name == s.name)
        }

        // MARK: 6. Group child at depth 2, and instruments

        do {
            let x = UUID(), y = UUID()
            let top = clip(plugins: [plugin(id: x)], instruments: [plugin(id: y)])
            let deep = clip(plugins: [plugin(id: x)], instruments: [plugin(id: y)],
                            automation: [lane(x)])
            let inner = group(children: [deep])
            let outer = group(children: [inner])
            let r = PluginIDUniqueness.deduplicated(items: [top, outer], stems: [])
            check("a plugin and an instrument duplicated at depth 2 are both re-keyed",
                  r.repairs.count == 2
                  && Set(r.repairs.map(\.hostID)) == [deep.id])
            guard case .group(let c1, _) = r.items[1].kind, case .group(let c2, _) = c1[0].kind else {
                check("the group structure survives", false); return
            }
            check("the group structure survives", c2.count == 1 && c2[0].id == deep.id)
            check("the deep child's plugin and instrument have fresh ids",
                  c2[0].plugins[0].id != x && c2[0].instruments[0].id != y)
            check("the deep child's automation follows its plugin",
                  c2[0].automation[0].param == .plugin(pluginKey: c2[0].plugins[0].id, paramID: "p"))
            check("the top-level host keeps both ids",
                  r.items[0].plugins[0].id == x && r.items[0].instruments[0].id == y)
            check("no duplicate left", PluginIDUniqueness.duplicates(items: r.items, stems: r.stems).isEmpty)
        }

        // MARK: 6b. A group's own chain versus its child

        do {
            let x = UUID()
            let child = clip(plugins: [plugin(id: x)])
            let g = group(plugins: [plugin(id: x)], children: [child])
            let r = PluginIDUniqueness.deduplicated(items: [g], stems: [])
            guard case .group(let kids, _) = r.items[0].kind else { check("group kind kept", false); return }
            check("the group's own chain is walked before its children: the group keeps the id",
                  r.items[0].plugins[0].id == x && kids[0].plugins[0].id != x && r.repairs.count == 1)
        }

        // MARK: 7. Triple occurrence

        do {
            let x = UUID()
            let items = [clip(plugins: [plugin(id: x)]), clip(plugins: [plugin(id: x)]),
                         clip(plugins: [plugin(id: x)])]
            let r = PluginIDUniqueness.deduplicated(items: items, stems: [])
            check("a triple occurrence costs two re-keys",
                  r.repairs.count == 2 && r.repairs.allSatisfy { $0.oldID == x })
            check("a triple occurrence ends with three distinct ids",
                  Set(allIDs(r.items, r.stems)).count == 3)
            let dups = PluginIDUniqueness.duplicates(items: items, stems: [])
            check("the audit reports the triple with its three hosts",
                  dups.count == 1 && dups[0].id == x && dups[0].hosts == items.map(\.id))
        }

        // MARK: 8. Idempotence

        do {
            let x = UUID(), y = UUID()
            let items = [clip(plugins: [plugin(id: x), plugin(id: y)]),
                         clip(plugins: [plugin(id: x)], instruments: [plugin(id: y)]),
                         group(children: [clip(plugins: [plugin(id: x)])])]
            let stems = [stem(plugins: [plugin(id: y)])]
            let once = PluginIDUniqueness.deduplicated(items: items, stems: stems)
            let twice = PluginIDUniqueness.deduplicated(items: once.items, stems: once.stems)
            check("the first pass repairs", once.repairs.count == 4)
            check("a second pass repairs nothing and changes nothing",
                  twice.repairs.isEmpty && twice.items == once.items && twice.stems == once.stems)
        }

        print("\n\(total - fails.count)/\(total) passed")
        if !fails.isEmpty {
            print("FAILURES:")
            for f in fails { print(" - \(f)") }
            exit(1)
        }
    }
}
