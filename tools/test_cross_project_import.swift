// `CrossProjectImport.plan(_:target:)` (tabs INC2) — the pure arithmetic of a cross-project paste,
// asserted with no screen. It has real model types behind it (`SoundObject`/`ObjectPlugin`/
// `ConsolidateDefinition`/`TimelineComment`/`ParamRef`), unlike the smaller geometry units this
// family of test started with, so the compile line pulls in `SoundObject.swift`'s full dependency
// chain rather than a single file — every entry below was needed, in this order, to get past
// "cannot find X in scope": ObjekatPalette (SoundObject's default colorIndex), Localization (`L`),
// ComposedName, AutomationCurveMath (`splitInTime`), and, once EditViewModel+Types.swift is pulled
// in for its OWN `Comparable.clamped(to:)` override (there is also an inaccessible `package`
// SwiftUI one an incomplete file list resolves to instead), the two files that override needs in
// turn: LaunchArguments (SessionSchema's `_readme`) and SessionSchema itself.
//
//     swiftc -parse-as-library \
//         ../objekat/SoundObject/SoundObject.swift \
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
//         ../objekat/SoundObject/SendMarkerAudit.swift \
//         ../objekat/Shared/ObjekatPalette.swift \
//         ../objekat/Shared/ObjectColorChoice.swift \
//         ../objekat/Shared/Localization.swift \
//         ../objekat/SoundObject/GainStage.swift \
//         ../objekat/SoundObject/LegacyGainMigration.swift \
//         ../objekat/EditViewModel/EditViewModel+Types.swift \
//         ../objekat/EditViewModel/SessionSchema.swift \
//         ../objekat/App/LaunchArguments.swift \
//         ../objekat/SoundObject/CrossProjectImport.swift \
//         ../objekat/SoundObject/PluginIDUniqueness.swift \
//         ../objekat/SoundObject/PluginIDReport.swift \
//         ../objekat/Shared/BridgeScope.swift \
//         ../objekat/Shared/ScriptCanvasMemory.swift \
//         test_cross_project_import.swift \
//         -o /tmp/cpi && /tmp/cpi
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
enum CrossProjectImportTest {
    static func main() {

        let originFolder = URL(fileURLWithPath: "/tmp/origin-project")

        // MARK: - Fixture builders

        func clip(id: UUID = UUID(), startTime: Double, lane: Int,
                   plugins: [ObjectPlugin] = [], sends: [AuxSend] = [],
                   automation: [AutomationLane] = [], automationTouchOrder: [ParamRef] = [],
                   consolidateID: UUID? = nil, stemID: UUID? = nil) -> SoundObject {
            SoundObject(id: id, startTime: startTime, duration: 4, lane: lane,
                       stemID: stemID, plugins: plugins,
                       sends: sends, consolidateID: consolidateID,
                       automation: automation, automationTouchOrder: automationTouchOrder,
                       kind: .clip(filePath: "a.wav", sourceOffset: 0, fileDuration: 4,
                                  speedRatio: 1, isReversed: false))
        }

        func group(id: UUID = UUID(), startTime: Double, lane: Int,
                    children: [SoundObject], sends: [AuxSend] = []) -> SoundObject {
            SoundObject(id: id, startTime: startTime, duration: 4, lane: lane, sends: sends,
                       kind: .group(children: children, isExpanded: false))
        }

        func aux(id: UUID = UUID(), startTime: Double, lane: Int) -> SoundObject {
            SoundObject(id: id, startTime: startTime, duration: 4, lane: lane, kind: .aux)
        }

        func plugin(id: UUID = UUID(), stateXML: String? = "<state/>",
                    linkGroupID: UUID? = nil) -> ObjectPlugin {
            ObjectPlugin(id: id, name: "EQ", manufacturer: "Objekat", identifier: "eq",
                        formatName: "TracktionInternal", stateXML: stateXML,
                        linkGroupID: linkGroupID)
        }

        // MARK: - Fresh ids for objects, plugins, notes

        do {
            var src = clip(startTime: 10, lane: 2, plugins: [plugin()])
            src.colorHex = 0xFF2D2D
            let cb = CrossProjectImport.Clipboard(clips: [src], comments: [],
                                                  consolidateDefinitions: [:],
                                                  originFolder: originFolder,
                                                  originTime: 10, originLane: 2)
            let target = CrossProjectImport.PasteTarget(pasteTime: 10, pasteLane: 2)
            let plan = CrossProjectImport.plan(cb, target: target)
            check("a fresh object id is issued", plan.clips[0].id != src.id)
            check("a fresh plugin id is issued", plan.clips[0].plugins[0].id != src.plugins[0].id)
            check("the plugin state travels across, frozen as-is",
                  plan.clips[0].plugins[0].stateXML == "<state/>")
            check("an object's free colour travels across", plan.clips[0].colorHex == 0xFF2D2D)
        }

        do {
            let notes = [MidiNote(pitch: 60, startBeat: 0, lengthBeats: 1),
                         MidiNote(pitch: 64, startBeat: 1, lengthBeats: 1)]
            let src = SoundObject(startTime: 0, duration: 2, lane: 0,
                                  kind: .midiClip(notes: notes, lengthBeats: 4))
            let cb = CrossProjectImport.Clipboard(clips: [src], comments: [],
                                                  consolidateDefinitions: [:],
                                                  originFolder: originFolder,
                                                  originTime: 0, originLane: 0)
            let plan = CrossProjectImport.plan(cb, target: .init(pasteTime: 0, pasteLane: 0))
            guard case .midiClip(let newNotes, let lengthBeats) = plan.clips[0].kind else {
                check("pasted object is still a MIDI clip", false); return
            }
            check("MIDI notes get fresh ids", newNotes[0].id != notes[0].id && newNotes[1].id != notes[1].id)
            check("MIDI musical times are preserved exactly (no tempo conversion)",
                  newNotes[0].startBeat == 0 && newNotes[1].startBeat == 1 && lengthBeats == 4)
        }

        // MARK: - Internal links remapped, never equal to a V1/V2 target's own groups

        do {
            // Simulate the V1/V2 collision the mission names: the SOURCE clip's plugin, and its
            // link group id, happen to share a UUID with something that could exist on the target
            // side. plan() must never reuse that id for the new group.
            let sharedGroupID = UUID()
            let p1 = plugin(linkGroupID: sharedGroupID)
            let p2 = plugin(linkGroupID: sharedGroupID)
            let src1 = clip(startTime: 0, lane: 0, plugins: [p1])
            let src2 = clip(startTime: 0, lane: 1, plugins: [p2])
            let cb = CrossProjectImport.Clipboard(clips: [src1, src2], comments: [],
                                                  consolidateDefinitions: [:],
                                                  originFolder: originFolder,
                                                  originTime: 0, originLane: 0)
            let plan = CrossProjectImport.plan(cb, target: .init(pasteTime: 0, pasteLane: 0))
            let newGroup1 = plan.clips[0].plugins[0].linkGroupID
            let newGroup2 = plan.clips[1].plugins[0].linkGroupID
            check("the two linked plugins share ONE new group", newGroup1 != nil && newGroup1 == newGroup2)
            check("the new group is never the target's own (V1/V2) id", newGroup1 != sharedGroupID)
        }

        do {
            // A plugin with NO link group must not gain one (no "link by default" backfill).
            let src = clip(startTime: 0, lane: 0, plugins: [plugin()])
            let cb = CrossProjectImport.Clipboard(clips: [src], comments: [],
                                                  consolidateDefinitions: [:],
                                                  originFolder: originFolder,
                                                  originTime: 0, originLane: 0)
            let plan = CrossProjectImport.plan(cb, target: .init(pasteTime: 0, pasteLane: 0))
            check("an unlinked plugin stays unlinked (no backfill)",
                  plan.clips[0].plugins[0].linkGroupID == nil)
        }

        // MARK: - Stems forced to Main

        do {
            let stem = UUID()
            let src = clip(startTime: 0, lane: 0, stemID: stem)
            let cb = CrossProjectImport.Clipboard(clips: [src], comments: [],
                                                  consolidateDefinitions: [:],
                                                  originFolder: originFolder,
                                                  originTime: 0, originLane: 0)
            let plan = CrossProjectImport.plan(cb, target: .init(pasteTime: 0, pasteLane: 0))
            check("stemID is forced to nil (everything lands on the Main)",
                  plan.clips[0].stemID == nil)
        }

        // MARK: - Sends: remapped inside the batch, dropped (with their automation) outside it

        do {
            let auxOld = UUID()
            let auxObj = aux(id: auxOld, startTime: 0, lane: 5)
            let src = clip(startTime: 0, lane: 0,
                          sends: [AuxSend(auxID: auxOld, levelDb: -3)],
                          automation: [AutomationLane(param: .send(auxID: auxOld),
                                                      points: [AutomationPoint(t: 0, v: 0.5)])],
                          automationTouchOrder: [.send(auxID: auxOld)])
            let cb = CrossProjectImport.Clipboard(clips: [src, auxObj], comments: [],
                                                  consolidateDefinitions: [:],
                                                  originFolder: originFolder,
                                                  originTime: 0, originLane: 0)
            let plan = CrossProjectImport.plan(cb, target: .init(pasteTime: 0, pasteLane: 0))
            let newAuxID = plan.clips[1].id
            check("a send to an aux INSIDE the batch is remapped",
                  plan.clips[0].sends.first?.auxID == newAuxID)
            check("its automation curve is remapped along with it",
                  plan.clips[0].automation.first?.param == .send(auxID: newAuxID))
        }

        do {
            let danglingAux = UUID() // NOT part of the pasted batch
            let src = clip(startTime: 0, lane: 0,
                          sends: [AuxSend(auxID: danglingAux, levelDb: -3)],
                          automation: [AutomationLane(param: .send(auxID: danglingAux),
                                                      points: [AutomationPoint(t: 0, v: 0.5)])],
                          automationTouchOrder: [.send(auxID: danglingAux)])
            let cb = CrossProjectImport.Clipboard(clips: [src], comments: [],
                                                  consolidateDefinitions: [:],
                                                  originFolder: originFolder,
                                                  originTime: 0, originLane: 0)
            let plan = CrossProjectImport.plan(cb, target: .init(pasteTime: 0, pasteLane: 0))
            check("a send to an aux OUTSIDE the batch is dropped entirely",
                  plan.clips[0].sends.isEmpty)
            check("its automation curve is dropped along with it",
                  plan.clips[0].automation.isEmpty)
            check("its automationTouchOrder entry is dropped along with it",
                  plan.clips[0].automationTouchOrder.isEmpty)
        }

        // MARK: - Send positions travel with their send (INC 2 of the sends rework)

        do {
            let auxOld = UUID()
            let auxObj = aux(id: auxOld, startTime: 0, lane: 5)
            let marker = ObjectPlugin.makeSendMarker(for: auxOld)
            let src = clip(startTime: 0, lane: 0,
                          plugins: [plugin(), marker, plugin()],
                          sends: [AuxSend(auxID: auxOld, levelDb: -3)])
            let pre = clip(startTime: 0, lane: 1, sends: [AuxSend(auxID: auxOld, levelDb: -3, tap: .preFader)])
            let cb = CrossProjectImport.Clipboard(clips: [src, pre, auxObj], comments: [],
                                                  consolidateDefinitions: [:],
                                                  originFolder: originFolder,
                                                  originTime: 0, originLane: 0)
            let plan = CrossProjectImport.plan(cb, target: .init(pasteTime: 0, pasteLane: 0))
            let newAux = plan.clips[2].id
            let p0 = plan.clips[0].plugins
            check("the marker of a send inside the batch stays between its plugins",
                  p0.count == 3 && p0[1].isSendMarker && !p0[0].isSendMarker && !p0[2].isSendMarker)
            check("and names the PASTED aux", p0[1].sendMarker?.auxID == newAux)
            check("with an id of its own", p0[1].id != marker.id)
            check("the position reads chain(1) on the pasted object", plan.clips[0].sendPosition(auxID: newAux) == .chain(1))
            check("a pre-fader tap travels with its send", plan.clips[1].sendPosition(auxID: newAux) == .preFader)
            check("the audit finds nothing", SendMarkerAudit.violations(items: plan.clips).isEmpty,
                  "\(SendMarkerAudit.violations(items: plan.clips))")
        }

        do {
            let outside = UUID()   // an aux that is NOT in the lot
            let src = clip(startTime: 0, lane: 0,
                          plugins: [plugin(), ObjectPlugin.makeSendMarker(for: outside), plugin()],
                          sends: [AuxSend(auxID: outside, levelDb: -3)])
            let cb = CrossProjectImport.Clipboard(clips: [src], comments: [],
                                                  consolidateDefinitions: [:],
                                                  originFolder: originFolder,
                                                  originTime: 0, originLane: 0)
            let plan = CrossProjectImport.plan(cb, target: .init(pasteTime: 0, pasteLane: 0))
            check("a send to an aux OUTSIDE the batch is dropped, and its marker with it",
                  plan.clips[0].sends.isEmpty && plan.clips[0].plugins.count == 2
                  && !plan.clips[0].plugins.contains(where: \.isSendMarker))
            check("the audit finds nothing", SendMarkerAudit.violations(items: plan.clips).isEmpty)
        }

        // MARK: - A consolidated object always becomes a new definition

        do {
            let oldConsolidateID = UUID()
            let dep = ConsolidateDependency(consolidateID: UUID(), revision: 1)
            let def = ConsolidateDefinition(id: oldConsolidateID, name: "Kick", wave: "kick.wav",
                                            revision: 3, wasGroup: false, dependsOn: [dep])
            let src = clip(startTime: 0, lane: 0, consolidateID: oldConsolidateID)
            let cb = CrossProjectImport.Clipboard(clips: [src], comments: [],
                                                  consolidateDefinitions: [oldConsolidateID: def],
                                                  originFolder: originFolder,
                                                  originTime: 0, originLane: 0)
            let plan = CrossProjectImport.plan(cb, target: .init(pasteTime: 0, pasteLane: 0))
            let newID = plan.clips[0].consolidateID
            check("a fresh consolidate id is issued", newID != nil && newID != oldConsolidateID)
            check("exactly one new definition is produced", plan.newConsolidateDefinitions.count == 1)
            check("the new definition carries the fresh id",
                  plan.newConsolidateDefinitions.first?.id == newID)
            check("its dependsOn is recursively remapped, never the old id",
                  plan.newConsolidateDefinitions.first?.dependsOn.first?.consolidateID != dep.consolidateID)
            check("the origin folder is recorded for the new id",
                  plan.consolidateOriginFolders[newID!] == originFolder)
        }

        // MARK: - Comments remapped via the object-id map, dropped if the parent is not found

        do {
            let src = group(startTime: 0, lane: 0, children: [])
            let comment = TimelineComment(startTime: 1, duration: 0, lane: 0, text: "note", parentID: src.id)
            let orphan = TimelineComment(startTime: 1, duration: 0, lane: 0, text: "orphan", parentID: UUID())
            let cb = CrossProjectImport.Clipboard(clips: [src], comments: [comment, orphan],
                                                  consolidateDefinitions: [:],
                                                  originFolder: originFolder,
                                                  originTime: 0, originLane: 0)
            let plan = CrossProjectImport.plan(cb, target: .init(pasteTime: 0, pasteLane: 0))
            check("a comment whose parent is in the batch is kept, remapped", plan.comments.count == 1)
            check("its parentID points at the NEW object id",
                  plan.comments.first?.parentID == plan.clips[0].id)
            check("a comment whose parent is NOT in the batch is dropped", true) // implied by count == 1
        }

        // MARK: - Positioning: dt/laneDelta applied to top-level entries only

        do {
            let child = clip(startTime: 1, lane: 0) // relative to the group
            let src = group(startTime: 10, lane: 2, children: [child])
            let cb = CrossProjectImport.Clipboard(clips: [src], comments: [],
                                                  consolidateDefinitions: [:],
                                                  originFolder: originFolder,
                                                  originTime: 10, originLane: 2)
            let plan = CrossProjectImport.plan(cb, target: .init(pasteTime: 25, pasteLane: 5))
            check("a top-level object is shifted by dt", plan.clips[0].startTime == 25)
            check("a top-level object is shifted by laneDelta", plan.clips[0].lane == 5)
            guard case .group(let newChildren, _) = plan.clips[0].kind else {
                check("pasted object is still a group", false); return
            }
            check("a nested child's RELATIVE start is untouched (not shifted a second time)",
                  newChildren[0].startTime == 1)
        }

        // MARK: - FX links: a pasted block gets a NEW bin

        do {
            // Two objects sharing ONE bin (defs d1, d2), plus a third holding another bin.
            let d1 = plugin(stateXML: "<d1/>"), d2 = plugin(stateXML: "<d2/>")
            let link = FXLink(name: "Bus", colorIndex: 3, plugins: [d1, d2], isEnabled: false)
            func member(_ lane: Int) -> SoundObject {
                let insts = [plugin(stateXML: "<i1/>", linkGroupID: d1.id), plugin(stateXML: "<i2/>", linkGroupID: d2.id)]
                return clip(startTime: 0, lane: lane,
                            plugins: [FXLink.blockEntry(linkID: link.id, name: link.name, instances: insts)])
            }
            let m1 = member(0), m2 = member(1)
            let cb = CrossProjectImport.Clipboard(clips: [m1, m2], comments: [],
                                                  consolidateDefinitions: [:],
                                                  fxLinks: [link.id: link],
                                                  originFolder: originFolder,
                                                  originTime: 0, originLane: 0)
            let plan = CrossProjectImport.plan(cb, target: .init(pasteTime: 0, pasteLane: 0))
            check("one NEW bin for the two members that shared one", plan.newFXLinks.count == 1)
            let nl = plan.newFXLinks[0]
            check("its id is never the source's", nl.id != link.id)
            check("its definition plugins are fresh, same count, same state",
                  nl.plugins.count == 2 && nl.plugins[0].id != d1.id && nl.plugins[1].id != d2.id
                  && nl.plugins[0].stateXML == "<d1/>")
            // (format 25: a bin has no output section — a level is a gain stage among the definitions)
            check("its name, colour and common on/off are the source's",
                  nl.name == "Bus" && nl.colorIndex == 3 && nl.isEnabled == false)
            let b1 = plan.clips[0].plugins[0], b2 = plan.clips[1].plugins[0]
            check("both pasted blocks name the new bin, with fresh block ids",
                  b1.fxBlock?.linkID == nl.id && b2.fxBlock?.linkID == nl.id && b1.id != m1.plugins[0].id)
            let i1 = b1.fxBlock!.plugins, i2 = b2.fxBlock!.plugins
            check("every instance is fresh and names the NEW definition plugin",
                  i1[0].linkGroupID == nl.plugins[0].id && i1[1].linkGroupID == nl.plugins[1].id
                  && i2[0].linkGroupID == nl.plugins[0].id
                  && Set(i1.map(\.id)).isDisjoint(with: Set(i2.map(\.id))))
            check("the source's own definition ids appear nowhere in the paste",
                  !i1.contains { $0.linkGroupID == d1.id || $0.linkGroupID == d2.id })
        }

        do {
            // A bin the clipboard does not carry cannot be recreated: the instances land inline, unlinked.
            let d1 = plugin()
            let insts = [plugin(linkGroupID: d1.id)]
            let src = clip(startTime: 0, lane: 0,
                           plugins: [FXLink.blockEntry(linkID: UUID(), name: "Gone", instances: insts)])
            let cb = CrossProjectImport.Clipboard(clips: [src], comments: [],
                                                  consolidateDefinitions: [:],
                                                  originFolder: originFolder,
                                                  originTime: 0, originLane: 0)
            let plan = CrossProjectImport.plan(cb, target: .init(pasteTime: 0, pasteLane: 0))
            check("a bin absent from the clipboard degrades to plain, unlinked plugins",
                  plan.newFXLinks.isEmpty && plan.clips[0].plugins.count == 1
                  && plan.clips[0].plugins[0].fxBlock == nil && plan.clips[0].plugins[0].linkGroupID == nil)
        }

        // MARK: - Sidechain keys (docs/plan_sidechain.md §5.9)

        do {
            let kick = clip(startTime: 0, lane: 0)
            let outsider = UUID()          // an object of the origin project, not in the batch
            let stem = UUID()              // a stem: everything lands on Main, it can never follow
            func keyed(_ source: UUID) -> ObjectPlugin {
                var p = plugin()
                p.sidechain = SidechainSource(sourceID: source)
                return p
            }
            let bass = clip(startTime: 0, lane: 1, plugins: [keyed(kick.id)])
            let loner = clip(startTime: 0, lane: 2, plugins: [keyed(outsider)])
            let staged = clip(startTime: 0, lane: 3, plugins: [keyed(stem)])
            let cb = CrossProjectImport.Clipboard(clips: [kick, bass, loner, staged], comments: [],
                                                  consolidateDefinitions: [:], originFolder: originFolder,
                                                  originTime: 0, originLane: 0)
            let plan = CrossProjectImport.plan(cb, target: .init(pasteTime: 0, pasteLane: 0))
            let newKick = plan.clips[0].id
            check("a key whose source is in the batch is remapped onto the pasted source",
                  plan.clips[1].plugins[0].sidechain == SidechainSource(sourceID: newKick) && newKick != kick.id)
            check("a key whose source is outside the batch is dropped",
                  plan.clips[2].plugins[0].sidechain == nil)
            check("a key naming a stem is dropped (everything lands on Main)",
                  plan.clips[3].plugins[0].sidechain == nil)
        }

        // MARK: - An ARA source (Melodyne): a fresh plugin id, the archive as frozen at copy time

        do {
            let archive = ARAArchive(data: "QUJD", sourceID: "src-1", modificationID: "mod-1",
                                     documentArchiveID: "com.celemony.ara.test", bytes: 3)
            let srcPlugin = ObjectPlugin(id: UUID(), name: "Melodyne", manufacturer: "Celemony",
                                         identifier: "melodyne-id", formatName: "VST3")
            var araClip = clip(startTime: 0, lane: 0)
            araClip.araSource = ARASource(plugin: srcPlugin, archive: archive)
            var araChild = clip(startTime: 1, lane: 0)
            araChild.araSource = ARASource(plugin: ObjectPlugin(id: UUID(), name: "Melodyne", manufacturer: "Celemony",
                                                                identifier: "melodyne-id", formatName: "VST3"),
                                           archive: archive)
            let g = group(startTime: 0, lane: 1, children: [araChild])
            let cb = CrossProjectImport.Clipboard(clips: [araClip, g], comments: [], consolidateDefinitions: [:],
                                                  originFolder: originFolder, originTime: 0, originLane: 0)
            let plan = CrossProjectImport.plan(cb, target: .init(pasteTime: 5, pasteLane: 0))
            let pasted = plan.clips[0].araSource
            check("a pasted ARA source is still a source", pasted != nil)
            check("... with a NEW plugin id (never shared)", pasted?.plugin.id != srcPlugin.id)
            check("... the archive travels untouched", pasted?.archive == archive)
            check("... and it is never linked", pasted?.plugin.linkGroupID == nil)
            guard case .group(let kids, _) = plan.clips[1].kind else { check("pasted group", false); return }
            check("an ARA source inside a pasted group gets a new id too",
                  kids[0].araSource != nil && kids[0].araSource?.plugin.id != araChild.araSource?.plugin.id
                  && kids[0].araSource?.plugin.id != pasted?.plugin.id)
            check("... and keeps its archive", kids[0].araSource?.archive == archive)
        }

        // MARK: - plan() performs no mutation of anything resembling "the target"

        do {
            let src = clip(startTime: 0, lane: 0)
            let cbBefore = CrossProjectImport.Clipboard(clips: [src], comments: [],
                                                        consolidateDefinitions: [:],
                                                        originFolder: originFolder,
                                                        originTime: 0, originLane: 0)
            let cbAfter = cbBefore
            _ = CrossProjectImport.plan(cbBefore, target: .init(pasteTime: 100, pasteLane: 9))
            check("plan() leaves the clipboard argument itself unmodified (value semantics, pure function)",
                  cbAfter.clips == cbBefore.clips)
        }

        // MARK: - The plugins ON a send (INC 3): cloned with the send, dropped with it

        do {
            let auxObj = aux(startTime: 0, lane: 3)
            let link = UUID()
            let onSend = plugin(linkGroupID: link), onSend2 = plugin()
            let partner = plugin(linkGroupID: link)
            func lane(_ p: ParamRef) -> AutomationLane { AutomationLane(param: p, points: [AutomationPoint(t: 0, v: 1)]) }
            let a = clip(startTime: 0, lane: 0, plugins: [plugin()],
                         sends: [AuxSend(auxID: auxObj.id, levelDb: -6, plugins: [onSend, onSend2])],
                         automation: [lane(.plugin(pluginKey: onSend2.id, paramID: "p"))],
                         automationTouchOrder: [.plugin(pluginKey: onSend.id, paramID: "p")])
            let b = clip(startTime: 0, lane: 1, sends: [AuxSend(auxID: auxObj.id, plugins: [partner])])

            // The aux travels with the batch.
            let cb = CrossProjectImport.Clipboard(clips: [a, b, auxObj], comments: [], consolidateDefinitions: [:],
                                                  originFolder: originFolder, originTime: 0, originLane: 0)
            let plan = CrossProjectImport.plan(cb, target: .init(pasteTime: 0, pasteLane: 0))
            let pa = plan.clips[0], pb = plan.clips[1], paux = plan.clips[2]
            check("send plugins: the send is remapped to the pasted aux, with its mini-chain",
                  pa.sends.count == 1 && pa.sends[0].auxID == paux.id && pa.sends[0].plugins.count == 2 && pa.sends[0].levelDb == -6)
            let oldIDs: Set<UUID> = [onSend.id, onSend2.id, partner.id]
            let newIDs = pa.sends[0].plugins.map(\.id) + pb.sends[0].plugins.map(\.id)
            check("send plugins: every id is fresh and unique", oldIDs.isDisjoint(with: newIDs) && Set(newIDs).count == 3)
            check("send plugins: the pasted batch passes the id audit",
                  PluginIDUniqueness.duplicates(items: plan.clips, stems: []).isEmpty)
            check("send plugins: the state travels frozen", pa.sends[0].plugins.map(\.stateXML) == [onSend.stateXML, onSend2.stateXML])
            let g1 = pa.sends[0].plugins[0].linkGroupID, g2 = pb.sends[0].plugins[0].linkGroupID
            // NO LINK ON A SEND (decision of 10 October 2026): even a link internal to the batch goes.
            check("send plugins: a linked one is pasted INDEPENDENT (no link kept, none created)",
                  g1 == nil && g2 == nil && link != UUID())
            check("send plugins: an unlinked one stays unlinked", pa.sends[0].plugins[1].linkGroupID == nil)
            check("send plugins: no pasted object carries a linked send plugin",
                  plan.clips.allSatisfy { SendChain.linkedSendPlugins(of: $0).isEmpty })
            check("send plugins: the curve follows the plugin's new id",
                  pa.automation.map(\.param) == [.plugin(pluginKey: pa.sends[0].plugins[1].id, paramID: "p")])
            check("send plugins: the touch memory follows too",
                  pa.automationTouchOrder == [.plugin(pluginKey: pa.sends[0].plugins[0].id, paramID: "p")])

            // The aux stays behind: the send goes, and so do its plugins and their curves.
            let cb2 = CrossProjectImport.Clipboard(clips: [a], comments: [], consolidateDefinitions: [:],
                                                   originFolder: originFolder, originTime: 0, originLane: 0)
            let alone = CrossProjectImport.plan(cb2, target: .init(pasteTime: 0, pasteLane: 0)).clips[0]
            check("send plugins: aux outside the batch = the send is dropped with its plugins", alone.sends.isEmpty)
            check("... and no orphan lane or touch memory is left behind",
                  alone.automation.isEmpty && alone.automationTouchOrder.isEmpty)
            check("... the trunk's plugin is still there", alone.plugins.count == 1)

            // A lone linked send plugin (its partner not copied) is unlinked, like a trunk plugin.
            let cb3 = CrossProjectImport.Clipboard(clips: [b, auxObj], comments: [], consolidateDefinitions: [:],
                                                   originFolder: originFolder, originTime: 0, originLane: 0)
            let lone = CrossProjectImport.plan(cb3, target: .init(pasteTime: 0, pasteLane: 0)).clips[0]
            let trunkLone = CrossProjectImport.plan(
                .init(clips: [clip(startTime: 0, lane: 0, plugins: [plugin(linkGroupID: UUID())])], comments: [],
                      consolidateDefinitions: [:], originFolder: originFolder, originTime: 0, originLane: 0),
                target: .init(pasteTime: 0, pasteLane: 0)).clips[0]
            check("send plugins: a lone linked send plugin is unlinked (the trunk's own rule is not this test's business)",
                  lone.sends[0].plugins[0].linkGroupID == nil && trunkLone.plugins.count == 1)

            // Inside a group child.
            let g = group(startTime: 0, lane: 0, children: [a])
            let cb4 = CrossProjectImport.Clipboard(clips: [g, auxObj], comments: [], consolidateDefinitions: [:],
                                                   originFolder: originFolder, originTime: 0, originLane: 0)
            let pg = CrossProjectImport.plan(cb4, target: .init(pasteTime: 0, pasteLane: 0))
            if case .group(let kids, _) = pg.clips[0].kind {
                check("send plugins: a group child's mini-chain is cloned too",
                      kids[0].sends.first?.plugins.count == 2
                      && oldIDs.isDisjoint(with: kids[0].sends[0].plugins.map(\.id))
                      && kids[0].automation.map(\.param) == [.plugin(pluginKey: kids[0].sends[0].plugins[1].id, paramID: "p")])
            } else { check("send plugins: a group child's mini-chain is cloned too", false) }
        }

        print("\n\(total - fails.count)/\(total) passed")
        if !fails.isEmpty {
            print("FAILURES:")
            for f in fails { print(" - \(f)") }
            exit(1)
        }
    }
}
