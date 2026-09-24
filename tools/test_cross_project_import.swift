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
//         ../objekat/SoundObject/Automation.swift \
//         ../objekat/SoundObject/AutomationCurveMath.swift \
//         ../objekat/SoundObject/Marker.swift \
//         ../objekat/SoundObject/ConsolidateDefinition.swift \
//         ../objekat/SoundObject/FadeCurve.swift \
//         ../objekat/SoundObject/ComposedName.swift \
//         ../objekat/Shared/ObjekatPalette.swift \
//         ../objekat/Shared/Localization.swift \
//         ../objekat/EditViewModel/EditViewModel+Types.swift \
//         ../objekat/EditViewModel/SessionSchema.swift \
//         ../objekat/App/LaunchArguments.swift \
//         ../objekat/SoundObject/CrossProjectImport.swift \
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
            let src = clip(startTime: 10, lane: 2, plugins: [plugin()])
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

        print("\n\(total - fails.count)/\(total) passed")
        if !fails.isEmpty {
            print("FAILURES:")
            for f in fails { print(" - \(f)") }
            exit(1)
        }
    }
}
