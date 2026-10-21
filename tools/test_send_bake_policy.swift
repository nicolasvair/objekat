// Q-U6: what becomes of the sends that tap inside a chain when it is baked (SendBakePolicy, PURE).
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
//         ../objekat/SoundObject/SendMarkerAudit.swift \
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
//         ../objekat/Shared/SendBakePolicy.swift \
//         test_send_bake_policy.swift \
//         -o /tmp/test_send_bake_policy && /tmp/test_send_bake_policy
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
enum SendBakePolicyTest {
    static func main() {
        func plugin(_ name: String) -> ObjectPlugin {
            ObjectPlugin(id: UUID(), name: name, manufacturer: "Objekat", identifier: name,
                         formatName: "TracktionInternal")
        }
        func clip(plugins: [ObjectPlugin], sends: [AuxSend],
                  automation: [AutomationLane] = []) -> SoundObject {
            var o = SoundObject(id: UUID(), startTime: 0, duration: 4, lane: 0, plugins: plugins, sends: sends,
                                kind: .clip(filePath: "a.wav", sourceOffset: 0, fileDuration: 4,
                                            speedRatio: 1, isReversed: false))
            o.automation = automation
            return o
        }
        let auxA = UUID(), auxB = UUID(), auxC = UUID(), auxD = UUID()
        let g1 = plugin("G1"), g2 = plugin("G2")

        // A: post (default), B: input, C: chain(1), D: pre-fader
        var o = clip(plugins: [g1, g2],
                     sends: [AuxSend(auxID: auxA, levelDb: -3), AuxSend(auxID: auxB, levelDb: -6),
                             AuxSend(auxID: auxC, levelDb: -9), AuxSend(auxID: auxD, levelDb: -12)],
                     automation: [AutomationLane(param: .send(auxID: auxB)), AutomationLane(param: .send(auxID: auxC)),
                                  AutomationLane(param: .send(auxID: auxD))])
        o = o.settingSendPosition(auxID: auxB, .input)
             .settingSendPosition(auxID: auxC, .chain(1))
             .settingSendPosition(auxID: auxD, .preFader)

        let c = SendBakePolicy.concerned(in: o)
        check("concerned: the input send and the chain send, not post-fader nor pre-fader",
              Set(c.map(\.auxID)) == [auxB, auxC] && c.count == 2, "\(c)")
        check("concerned: positions are reported", c.first(where: { $0.auxID == auxB })?.position == .input
              && c.first(where: { $0.auxID == auxC })?.position == .chain(1))
        check("isConcerned names the four positions",
              SendBakePolicy.isConcerned(.input) && SendBakePolicy.isConcerned(.chain(0))
              && !SendBakePolicy.isConcerned(.preFader) && !SendBakePolicy.isConcerned(.postFader))

        // refuse
        check("refuse changes nothing", SendBakePolicy.resolve(o, choice: .refuse) == o)

        // fold
        let f = SendBakePolicy.resolve(o, choice: .fold)
        check("fold: the input send is post-fader", f.sendPosition(auxID: auxB) == .postFader)
        check("fold: the chain send is post-fader and its marker is gone",
              f.sendPosition(auxID: auxC) == .postFader && ObjectPlugin.topLevelSendMarkers(in: f.plugins).isEmpty)
        check("fold: the plugins are the real ones, in order", f.plugins.map(\.id) == [g1.id, g2.id])
        check("fold: levels are kept", f.sends.map(\.levelDb) == [-3, -6, -9, -12])
        check("fold: the pre-fader send is untouched", f.sendPosition(auxID: auxD) == .preFader)
        check("fold: the curves are kept", f.automation.count == 3)
        check("fold: nothing left that is concerned", SendBakePolicy.concerned(in: f).isEmpty)
        check("fold is idempotent", SendBakePolicy.resolve(f, choice: .fold) == f)
        check("fold leaves a clean audit", SendMarkerAudit.violations(items: [f], stems: []).isEmpty)

        // remove
        let r = SendBakePolicy.resolve(o, choice: .remove)
        check("remove: the concerned sends are gone, the others stay",
              r.sends.map(\.auxID) == [auxA, auxD], "\(r.sends.map(\.auxID))")
        check("remove: no marker is left", ObjectPlugin.topLevelSendMarkers(in: r.plugins).isEmpty)
        check("remove: the curves aimed at them go, the others stay",
              r.automation.map(\.param) == [.send(auxID: auxD)], "\(r.automation.map(\.param))")
        check("remove leaves a clean audit", SendMarkerAudit.violations(items: [r], stems: []).isEmpty)
        check("remove is idempotent", SendBakePolicy.resolve(r, choice: .remove) == r)

        // nothing concerned: every choice is the identity
        let plain = clip(plugins: [g1], sends: [AuxSend(auxID: auxA)])
        check("nothing concerned: fold and remove are the identity",
              SendBakePolicy.resolve(plain, choice: .fold) == plain && SendBakePolicy.resolve(plain, choice: .remove) == plain)

        // an aux never sends: nothing to ask
        let aux = SoundObject(id: UUID(), startTime: 0, duration: 4, lane: 1, plugins: [], sends: [AuxSend(auxID: auxA)],
                              kind: .aux)
        check("an aux has no concerned send", SendBakePolicy.concerned(in: aux).isEmpty)

        // a group: its OWN sends only
        let child = clip(plugins: [g1], sends: [AuxSend(auxID: auxA)]).settingSendPosition(auxID: auxA, .input)
        var grp = SoundObject(id: UUID(), startTime: 0, duration: 4, lane: 0,
                              kind: .group(children: [child], isExpanded: false))
        grp.sends = [AuxSend(auxID: auxB)]
        check("a group: the children's sends are not the group's concern", SendBakePolicy.concerned(in: grp).isEmpty)
        grp = grp.settingSendPosition(auxID: auxB, .input)
        check("a group: its own input send is concerned", SendBakePolicy.concerned(in: grp).map(\.auxID) == [auxB])
        let rg = SendBakePolicy.resolve(grp, choice: .fold)
        if case .group(let kids, _) = rg.kind {
            check("a group: folding leaves the children alone", kids == [child])
        } else { check("a group stays a group", false) }

        // pre-fader: a BLOCKER, never a choice (decided 10 October 2026, "for the moment")
        let blk = SendBakePolicy.preFaderBlockers(in: o)
        check("blockers: only the pre-fader send (not input, not chain, not post-fader)",
              blk.map(\.auxID) == [auxD] && blk.first?.position == .preFader && blk.first?.objectID == o.id, "\(blk)")
        check("blocksBake names the four positions",
              SendBakePolicy.blocksBake(.preFader) && !SendBakePolicy.blocksBake(.input)
              && !SendBakePolicy.blocksBake(.chain(0)) && !SendBakePolicy.blocksBake(.postFader))
        check("the pre-fader send is neither concerned nor resolved: fold and remove leave it (the caller refuses)",
              !SendBakePolicy.concerned(in: o).contains { $0.auxID == auxD }
              && SendBakePolicy.resolve(o, choice: .fold).sendPosition(auxID: auxD) == .preFader
              && SendBakePolicy.resolve(o, choice: .remove).sends.contains { $0.auxID == auxD })
        check("an object with both kinds is reported by both lists (the blocker wins in the caller)",
              !SendBakePolicy.concerned(in: o).isEmpty && !SendBakePolicy.preFaderBlockers(in: o).isEmpty)
        let onlyPost = clip(plugins: [g1], sends: [AuxSend(auxID: auxA)])
        check("no pre-fader send: no blocker", SendBakePolicy.preFaderBlockers(in: onlyPost).isEmpty)
        let onlyPre = clip(plugins: [g1], sends: [AuxSend(auxID: auxA)]).settingSendPosition(auxID: auxA, .preFader)
        check("a lone pre-fader send is a blocker and not a concerned send",
              SendBakePolicy.preFaderBlockers(in: onlyPre).map(\.auxID) == [auxA] && SendBakePolicy.concerned(in: onlyPre).isEmpty)
        check("the list form concatenates, in order",
              SendBakePolicy.preFaderBlockers(in: [onlyPost, onlyPre, o]).map(\.auxID) == [auxA, auxD])
        check("an aux never blocks", SendBakePolicy.preFaderBlockers(in: aux).isEmpty)
        var inst = onlyPre
        inst.consolidateID = UUID()
        check("a placement that is already an instance is not baked, so it never blocks",
              SendBakePolicy.preFaderBlockers(in: inst).isEmpty)
        let preChild = clip(plugins: [g1], sends: [AuxSend(auxID: auxA)]).settingSendPosition(auxID: auxA, .preFader)
        var grpPre = SoundObject(id: UUID(), startTime: 0, duration: 4, lane: 0,
                                 kind: .group(children: [preChild], isExpanded: false))
        grpPre.sends = [AuxSend(auxID: auxB)]
        check("a group: a pre-fader send on a CHILD is not the group's concern (same rule as the chain sends)",
              SendBakePolicy.preFaderBlockers(in: grpPre).isEmpty)
        grpPre = grpPre.settingSendPosition(auxID: auxB, .preFader)
        check("a group: its OWN pre-fader send blocks", SendBakePolicy.preFaderBlockers(in: grpPre).map(\.auxID) == [auxB])

        check("the choices carry the API's names",
              SendBakePolicy.Choice.allCases.map(\.rawValue) == ["refuse", "fold", "remove"])

        // The plugins ON a send (INC 3)
        do {
            let lp = plugin("lp"), sat = plugin("sat")
            func lane(_ p: ParamRef) -> AutomationLane { AutomationLane(param: p, points: [AutomationPoint(t: 0, v: 1)]) }
            let src = clip(plugins: [g1, g2], sends: [AuxSend(auxID: auxB, levelDb: -6, plugins: [lp, sat])],
                           automation: [lane(.plugin(pluginKey: sat.id, paramID: "p")), lane(.send(auxID: auxB)),
                                        lane(.plugin(pluginKey: g1.id, paramID: "p"))])
                .settingSendPosition(auxID: auxB, .chain(1))
            check("a chain send WITH plugins is concerned like any other", SendBakePolicy.concerned(in: src).map(\.auxID) == [auxB])
            let folded = SendBakePolicy.resolve(src, choice: .fold)
            check("fold: the send goes post-fader and KEEPS its plugins",
                  folded.sendPosition(auxID: auxB) == .postFader && folded.sends[0].plugins == [lp, sat])
            check("fold: every lane stays (the send's plugins live on)", folded.automation == src.automation)
            let removed = SendBakePolicy.resolve(src, choice: .remove)
            check("remove: the send goes with its plugins, their lanes and its level's lane",
                  removed.sends.isEmpty && !ObjectPlugin.containsSendMarker(in: removed.plugins, where: { _ in true })
                  && removed.automation.map(\.param) == [.plugin(pluginKey: g1.id, paramID: "p")])
            check("refuse: nothing changes", SendBakePolicy.resolve(src, choice: .refuse) == src)
            let pre = clip(plugins: [g1], sends: [AuxSend(auxID: auxD, plugins: [lp])]).settingSendPosition(auxID: auxD, .preFader)
            check("a pre-fader send WITH plugins blocks the bake just the same",
                  SendBakePolicy.preFaderBlockers(in: pre).map(\.auxID) == [auxD])
            check("... and no choice touches it", SendBakePolicy.resolve(pre, choice: .remove) == pre)
            let post = clip(plugins: [g1], sends: [AuxSend(auxID: auxA, plugins: [lp])])
            check("a post-fader send with plugins: neither concerned nor blocking",
                  SendBakePolicy.concerned(in: post).isEmpty && SendBakePolicy.preFaderBlockers(in: post).isEmpty)
        }

        print("\n\(total - fails.count)/\(total) passed")
        if !fails.isEmpty { print("FAILED: \(fails)"); exit(1) }
    }
}
