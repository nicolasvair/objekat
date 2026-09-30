// `PluginIDUniqueness` and `PluginIDReport` — the load-time DETECTION of plugin ids held by two hosts,
// their repair on demand, and the report for a language model (1 October 2026), asserted with no screen. Same model dependencies as `test_cross_project_import.swift`, minus the
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
//         ../objekat/SoundObject/PluginIDReport.swift \
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
                    enabled: Bool = true, colorIndex: Int = 3, name: String = "EQ") -> ObjectPlugin {
            ObjectPlugin(id: id, name: name, manufacturer: "Objekat", identifier: "eq",
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

        // MARK: 9. Detail: no duplicate, nothing to say

        check("duplicateDetails of a sound project is empty",
              PluginIDUniqueness.duplicateDetails(
                items: [clip(plugins: [plugin(), rack(voices: [[plugin()], [plugin()]])],
                             instruments: [plugin()]),
                        group(children: [clip(plugins: [plugin()])])],
                stems: [stem(plugins: [plugin()])], fxLinks: []).isEmpty)

        // MARK: 10. Detail: two hosts sharing a bin instance

        do {
            let bin = FXLink(id: UUID(), name: "DPA", colorIndex: 0, plugins: [])
            let def = UUID(), shared = UUID()
            let a = clip(plugins: [block(linkID: bin.id, instances: [plugin(id: shared, linkGroupID: def)])])
            let b = clip(plugins: [block(linkID: bin.id, instances: [plugin(id: shared, linkGroupID: def)])])
            let details = PluginIDUniqueness.duplicateDetails(items: [a, b], stems: [], fxLinks: [bin])
            check("one shared instance → one detail with two sites",
                  details.count == 1 && details[0].id == shared && details[0].sites.count == 2)
            let sites = details.first?.sites ?? []
            check("sites[0] is the host walked first, sites[1] the other",
                  sites.count == 2 && sites[0].hostID == a.id && sites[1].hostID == b.id
                  && sites.allSatisfy { $0.hostKind == .object })
            check("the JSON paths are exact",
                  sites.count == 2 && sites[0].jsonPath == "items[0].plugins[0].fxBlock.plugins[0]"
                  && sites[1].jsonPath == "items[1].plugins[0].fxBlock.plugins[0]")
            check("the bin's id and name come from the registry",
                  sites.allSatisfy { $0.fxLinkID == bin.id && $0.fxLinkName == "DPA" })
            check("the host and plugin names are carried",
                  sites.count == 2 && sites[0].hostName == a.displayName && sites[0].pluginName == "EQ")
            // A bin the registry does not know keeps its id but has no name.
            let unknown = PluginIDUniqueness.duplicateDetails(items: [a, b], stems: [], fxLinks: [])
            check("a bin absent from the registry has an id and no name",
                  unknown.first?.sites.allSatisfy { $0.fxLinkID == bin.id && $0.fxLinkName == nil } == true)
        }

        // MARK: 11. Detail: paths at depth (group child, rack voice, instrument, stem)

        do {
            let x = UUID(), y = UUID(), z = UUID(), w = UUID()
            let top = clip(plugins: [plugin(), rack(voices: [[plugin()], [plugin(), plugin(id: x)]])],
                           instruments: [plugin(id: y)])
            let child0 = clip(plugins: [plugin()])
            let child1 = clip(plugins: [plugin(id: x), plugin(id: z)], instruments: [plugin(id: y)])
            let g = group(children: [child0, child1])
            let s = stem(plugins: [plugin(), plugin(id: z)])
            // `w` sits twice in the very same stem's chain.
            let s2 = stem(plugins: [plugin(id: w), plugin(id: w)])
            let details = PluginIDUniqueness.duplicateDetails(items: [top, g], stems: [s, s2], fxLinks: [])
            func paths(_ id: UUID) -> [String] { details.first { $0.id == id }?.sites.map(\.jsonPath) ?? [] }
            check("a rack voice and a group child, in file order",
                  paths(x) == ["items[0].plugins[1].rack.voices[1][1]", "items[1].kind.children[1].plugins[0]"],
                  "\(paths(x))")
            check("an instrument, in an object and in a group child",
                  paths(y) == ["items[0].instruments[0]", "items[1].kind.children[1].instruments[0]"],
                  "\(paths(y))")
            check("a stem's chain",
                  paths(z) == ["items[1].kind.children[1].plugins[1]", "stems[0].plugins[1]"], "\(paths(z))")
            check("a stem site is marked as a stem and named after it",
                  details.first { $0.id == z }?.sites.last.map { $0.hostKind == .stem && $0.hostName == s.name
                                                               && $0.hostID == s.id } == true)
            check("the same id twice in one host gives two sites of that host",
                  paths(w) == ["stems[1].plugins[0]", "stems[1].plugins[1]"], "\(paths(w))")
            check("the details come in first-seen order of their ids",
                  details.map(\.id) == [x, y, z, w], "\(details.map(\.id))")
        }

        // MARK: 12. Detail agrees with the repair

        do {
            let x = UUID(), y = UUID(), z = UUID()
            let bin = FXLink(id: UUID(), name: "Bin", colorIndex: 0, plugins: [])
            let items = [clip(plugins: [plugin(id: x), block(linkID: bin.id, instances: [plugin(id: y)])]),
                         clip(plugins: [plugin(id: x), plugin(id: x)],
                              instruments: [plugin(id: y)]),
                         group(children: [clip(plugins: [block(linkID: bin.id, instances: [plugin(id: y)])]),
                                          clip(plugins: [plugin(id: z)])])]
            let stems = [stem(plugins: [plugin(id: z), plugin(id: y)])]
            let details = PluginIDUniqueness.duplicateDetails(items: items, stems: stems, fxLinks: [bin])
            let fixed = PluginIDUniqueness.deduplicated(items: items, stems: stems)
            // Every site after the first of its id = one repair, paired by (id, host), in the same order.
            // Repairs are emitted in walk order, the details by id: compare them as ordered pairs per id.
            let fromDetails = details.flatMap { d in d.sites.dropFirst().map { "\(d.id)/\($0.hostID)" } }
            let fromRepairs = fixed.repairs.map { "\($0.oldID)/\($0.hostID)" }
            check("the sites after the first are exactly the repairs, same count",
                  fromDetails.count == fixed.repairs.count, "\(fromDetails.count) vs \(fixed.repairs.count)")
            check("...and the same (id, host) pairs",
                  Set(fromDetails) == Set(fromRepairs) && fromDetails.sorted() == fromRepairs.sorted())
            // Per id, the repairs come in the order of the sites.
            var sameOrder = true
            for d in details {
                let expected = d.sites.dropFirst().map(\.hostID)
                let got = fixed.repairs.filter { $0.oldID == d.id }.map(\.hostID)
                if expected != got { sameOrder = false }
            }
            check("...and, per id, in the same order", sameOrder)
            check("sites[0] of each id is the occurrence the repair leaves alone",
                  details.allSatisfy { d in
                      let kept = fixed.repairs.filter { $0.oldID == d.id }.count
                      return kept == d.sites.count - 1
                  })
        }

        // MARK: 13. The report for a language model

        do {
            let bin = FXLink(id: UUID(), name: "KANUN \u{00e9}", colorIndex: 0, plugins: [])
            let def = UUID(), shared = UUID(), other = UUID()
            let a = clip(plugins: [block(linkID: bin.id, instances: [plugin(id: shared, linkGroupID: def)])])
            let b = clip(plugins: [block(linkID: bin.id, instances: [plugin(id: shared, linkGroupID: def)])])
            let c = clip(plugins: [plugin(id: other, name: "Pro-Q")])
            let d = clip(plugins: [plugin(id: other, name: "Pro-Q")])
            let e = clip(plugins: [plugin(id: other, name: "Pro-Q")])
            let details = PluginIDUniqueness.duplicateDetails(items: [a, b, c, d, e], stems: [], fxLinks: [bin])
            let path = "/tmp/Projet \u{00e9}t\u{00e9}/x.objekat"
            let text = PluginIDReport.text(filePath: path, details: details)
            check("the report names the file", text.contains("File: \(path)"))
            check("the report states the rule and the count (3 copies, 2 ids, 5 entries)",
                  text.contains("RULE. Every \"id\" in this file must be unique in the whole project.")
                  && text.contains("breaks the rule 3 time(s): 2 plugin id(s)")
                  && text.contains("carried by 5 entries in all"))
            check("the report lists every id", text.contains(shared.uuidString) && text.contains(other.uuidString))
            let lines = text.components(separatedBy: "\n")
            check("one KEEP per id and one FIX per copy",
                  lines.filter { $0.hasPrefix("   KEEP") }.count == 2
                  && lines.filter { $0.hasPrefix("   FIX") }.count == 3)
            check("the paths of the copies are in the report",
                  text.contains("path: items[1].plugins[0].fxBlock.plugins[0]")
                  && text.contains("path: items[3].plugins[0]") && text.contains("path: items[4].plugins[0]"))
            check("a bin's name is shown on its sites", text.contains("fx link \"KANUN"))
            check("the six steps of the fix are there",
                  (1...6).allSatisfy { n in lines.contains { $0.hasPrefix("\(n). ") } })
            check("the report is deterministic",
                  text == PluginIDReport.text(filePath: path, details: details))
            check("no unresolved localisation key", !text.contains("pluginIDs."))
            // Everything but what the user typed (the path, the bin's name) is ASCII.
            let ours = PluginIDReport.text(filePath: "/tmp/x.objekat", details: PluginIDUniqueness
                .duplicateDetails(items: [c, d], stems: [], fxLinks: []))
            check("the report is strictly ASCII apart from typed names", ours.unicodeScalars.allSatisfy { $0.isASCII })
            check("a typed newline cannot break the layout",
                  !PluginIDReport.text(filePath: "/tmp/a\nb.objekat", details: details).contains("a\nb"))
        }

        print("\n\(total - fails.count)/\(total) passed")
        if !fails.isEmpty {
            print("FAILURES:")
            for f in fails { print(" - \(f)") }
            exit(1)
        }
    }
}
