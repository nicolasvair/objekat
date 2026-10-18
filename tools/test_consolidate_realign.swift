// RE-ALIGNING an instance onto a new wave, and the STAGE an instance opens into: the two pure pieces
// of the instance-level consolidated object, asserted with no screen.
//
//   * SoundObject.realignedInstance(delta:wavePath:waveLength:): the one rule that brings every
//     instance (the edited one and the others) onto a wave whose position 0 moved by `delta` and
//     whose length changed: so' = so - delta, never enlarge, cut the head / the tail where the wave
//     has no material (swapped when reversed), fades bounded, automation / markers / loop shifted
//     by the head cut, and the Q2 case (no material left: place and length kept, silence).
//   * SoundObject.consolidateStage / closedInstance: the open form of an instance (a group holding
//     the content root) and the way back.
//
// Same compile line as `test_consolidate_content_root.swift`, plus the two files under test:
//
//     swiftc -parse-as-library \
//         ../objekat/SoundObject/ConsolidateInstanceStage.swift \
//         ../objekat/SoundObject/ConsolidateRealign.swift \
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
//         ../objekat/SoundObject/ConsolidateContentRoot.swift \
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
//         test_consolidate_realign.swift \
//         -o /tmp/ccra && /tmp/ccra
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

func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }

@main
enum ConsolidateRealignTest {
    static func main() {

        let L = 10.0
        func inst(start: Double = 10, dur: Double = 4, so: Double = 2, spd: Double = 1, rev: Bool = false,
                  fadeIn: Double = 0, fadeOut: Double = 0) -> SoundObject {
            var o = SoundObject(startTime: start, duration: dur, lane: 0, fadeIn: fadeIn, fadeOut: fadeOut,
                                kind: .clip(filePath: "old.wav", sourceOffset: so, fileDuration: L,
                                            speedRatio: spd, isReversed: rev))
            o.consolidateID = UUID()
            return o
        }
        func so(_ o: SoundObject) -> Double {
            if case .clip(_, let s, _, _, _) = o.kind { return s }
            return -1
        }
        func fd(_ o: SoundObject) -> Double {
            if case .clip(_, _, let f, _, _) = o.kind { return f }
            return -1
        }

        // MARK: - delta = 0 and the wave swap

        let base = inst()
        let same = base.realignedInstance(delta: 0, wavePath: "new.wav", waveLength: L)
        check("delta 0, same length: the window is untouched, the clip reads the new file",
              same.startTime == 10 && same.duration == 4 && so(same) == 2 && fd(same) == L
              && same.filePath == "new.wav", "\(same.startTime) \(same.duration) \(so(same))")
        check("delta 0: the instance level is untouched (id, link)",
              same.id == base.id && same.consolidateID == base.consolidateID)

        // MARK: - the zero moves later / earlier

        let later = base.realignedInstance(delta: 1, wavePath: "n.wav", waveLength: L)
        check("zero 1 s later: the material stays opposite the same place (so 2 -> 1), window kept",
              near(so(later), 1) && later.startTime == 10 && later.duration == 4)
        let earlier = base.realignedInstance(delta: -1, wavePath: "n.wav", waveLength: L)
        check("zero 1 s earlier: so 2 -> 3, window kept", near(so(earlier), 3) && earlier.duration == 4)

        // MARK: - the head is cut where the wave has no material

        let head = base.realignedInstance(delta: 3, wavePath: "n.wav", waveLength: L)
        check("zero 3 s later: the head is cut by 1 s (start +1, duration -1, so 0)",
              near(head.startTime, 11) && near(head.duration, 3) && near(so(head), 0),
              "\(head.startTime) \(head.duration) \(so(head))")

        // MARK: - the tail is cut past the end, and the window never grows

        let tail = base.realignedInstance(delta: 0, wavePath: "n.wav", waveLength: 5)
        check("wave shorter (5 s): the tail is cut at the end (duration 3), the start stays",
              tail.startTime == 10 && near(tail.duration, 3) && near(so(tail), 2) && fd(tail) == 5,
              "\(tail.duration)")
        let longer = base.realignedInstance(delta: -5, wavePath: "n.wav", waveLength: 100)
        check("a longer wave never lengthens an instance", longer.duration == 4 && longer.startTime == 10)
        let both = base.realignedInstance(delta: 3, wavePath: "n.wav", waveLength: 2)
        check("head AND tail cut: [-1, 3] over a wave of 2 -> [0, 2]",
              near(both.startTime, 11) && near(both.duration, 2) && near(so(both), 0),
              "\(both.startTime) \(both.duration) \(so(both))")

        // MARK: - speed

        let fast = inst(spd: 2).realignedInstance(delta: 3, wavePath: "n.wav", waveLength: 20)
        check("speed 2: 1 s of wave below 0 is 0.5 s of timeline (start +0.5, duration 3.5)",
              near(fast.startTime, 10.5) && near(fast.duration, 3.5) && near(so(fast), 0),
              "\(fast.startTime) \(fast.duration)")
        let slow = inst(spd: 0.5).realignedInstance(delta: 3, wavePath: "n.wav", waveLength: 20)
        check("speed 0.5: 1 s of wave below 0 is 2 s of timeline (start +2, duration 2)",
              near(slow.startTime, 12) && near(slow.duration, 2) && near(so(slow), 0),
              "\(slow.startTime) \(slow.duration)")

        // MARK: - reversed: the two ends swap their roles

        let rev = inst(rev: true).realignedInstance(delta: 3, wavePath: "n.wav", waveLength: L)
        check("reversed: the material missing below 0 is the TAIL of the window (start kept, duration 3)",
              rev.startTime == 10 && near(rev.duration, 3) && near(so(rev), 0),
              "\(rev.startTime) \(rev.duration)")
        let revEnd = inst(rev: true).realignedInstance(delta: 0, wavePath: "n.wav", waveLength: 5)
        check("reversed: the material missing past the end is the HEAD of the window (start +1, duration 3)",
              near(revEnd.startTime, 11) && near(revEnd.duration, 3), "\(revEnd.startTime) \(revEnd.duration)")

        // MARK: - fades are bounded, in order

        let fades = inst(fadeIn: 2, fadeOut: 2).realignedInstance(delta: 3, wavePath: "n.wav", waveLength: L)
        check("fades after a head cut to 3 s: in 2, out 1 (the sum never exceeds the window)",
              near(fades.fadeIn, 2) && near(fades.fadeOut, 1), "\(fades.fadeIn) \(fades.fadeOut)")
        let squeezed = inst(fadeIn: 2, fadeOut: 2).realignedInstance(delta: 5, wavePath: "n.wav", waveLength: L)
        check("fades after a head cut to 1 s: in 1, out 0",
              near(squeezed.duration, 1) && near(squeezed.fadeIn, 1) && near(squeezed.fadeOut, 0),
              "\(squeezed.duration) \(squeezed.fadeIn) \(squeezed.fadeOut)")

        // MARK: - what is relative to the start follows a head cut

        var rich = inst()
        rich.automation = [AutomationLane(param: .volume,
                                          points: [AutomationPoint(t: 1, v: 0), AutomationPoint(t: 3, v: -6)])]
        rich.markers = [Marker(time: 2, name: "m")]
        rich.loopRangeStart = 1; rich.loopRangeEnd = 3
        let moved = rich.realignedInstance(delta: 3, wavePath: "n.wav", waveLength: L)   // head cut = 1 s
        check("automation, markers and loop range shift by -1 s with the head",
              moved.automation[0].points.map(\.t) == [0, 2] && moved.markers[0].time == 1
              && moved.loopRangeStart == 0 && moved.loopRangeEnd == 2,
              "\(moved.automation[0].points.map(\.t)) \(moved.markers[0].time)")
        let untouched = rich.realignedInstance(delta: 1, wavePath: "n.wav", waveLength: L)   // no cut
        check("no head cut: the relative data are untouched",
              untouched.automation == rich.automation && untouched.markers == rich.markers)

        // MARK: - Q2: no material left

        let gone = base.realignedInstance(delta: 10, wavePath: "n.wav", waveLength: L)
        check("Q2 (content moved away under the window): place, duration and fades kept, silence",
              gone.startTime == 10 && gone.duration == 4 && so(gone) == L && gone.isOutsideConsolidateContent,
              "\(gone.startTime) \(gone.duration) \(so(gone))")
        let past = base.realignedInstance(delta: 0, wavePath: "n.wav", waveLength: 2)
        check("Q2 (content shrank below the window's start): same", past.isOutsideConsolidateContent
              && past.startTime == 10 && past.duration == 4, "\(so(past))")
        check("an instance with material left is NOT outside", !later.isOutsideConsolidateContent)
        var notLinked = gone; notLinked.consolidateID = nil
        check("outside-content is a property of a LINKED instance only", !notLinked.isOutsideConsolidateContent)
        var grp = SoundObject(startTime: 0, duration: 2, lane: 0, kind: .group(children: [], isExpanded: true))
        grp.consolidateID = UUID()
        check("realigning anything but a clip returns it unchanged",
              grp.realignedInstance(delta: 5, wavePath: "n.wav", waveLength: 1) == grp)

        // MARK: - the stage

        var p = inst(start: 10, dur: 4, so: 2, spd: 2, fadeIn: 0.5, fadeOut: 0.25)
        p.volume = -6; p.pan = 0.3; p.isMuted = true; p.label = "kick"; p.colorIndex = 4
        let stem = UUID(); p.stemID = stem
        p.automation = [AutomationLane(param: .volume, points: [AutomationPoint(t: 1, v: 0)])]
        p.markers = [Marker(time: 1, name: "m")]
        let fx = ObjectPlugin(id: UUID(), name: "eq", manufacturer: "Objekat", identifier: "eq",
                              formatName: "TracktionInternal")
        p.plugins = [fx]
        let defID = p.consolidateID!
        var content = SoundObject(startTime: 100, duration: 5, lane: 3, volume: 3, plugins: [],
                                  sends: [AuxSend(auxID: UUID(), levelDb: -3, plugins: [])],
                                  kind: .group(children: [
                                      SoundObject(startTime: 100, duration: 2, lane: 0, kind: .clip(filePath: "a.wav", sourceOffset: 0, fileDuration: 2, speedRatio: 1, isReversed: false)),
                                      SoundObject(startTime: 103, duration: 2, lane: 1, kind: .clip(filePath: "a.wav", sourceOffset: 0, fileDuration: 2, speedRatio: 1, isReversed: false))],
                                                  isExpanded: false))
        content.consolidateID = UUID()   // must be dropped
        let waveZero = p.consolidateWaveZero
        check("the wave's zero is startTime - sourceOffset", near(waveZero, 8))
        let stage = SoundObject.consolidateStage(placement: p, content: content, definitionID: defID,
                                                 waveZero: waveZero)
        guard case .group(let kids, let exp) = stage.kind, kids.count == 1 else {
            check("the stage is a group with ONE child", false); finish(); return
        }
        let a = kids[0]
        check("the stage is a group with exactly one child, expanded", exp)
        check("the stage keeps the placement's identity and link", stage.id == p.id && stage.consolidateID == defID)
        check("the stage keeps the instance level: FX, fader, label, colour, stem",
              stage.plugins == [fx] && stage.volume == -6 && stage.pan == 0.3 && stage.isMuted
              && stage.label == "kick" && stage.colorIndex == 4 && stage.stemID == stem)
        check("the stage's window and fades are scaled by the speed (the content plays at speed 1)",
              near(stage.duration, 8) && near(stage.fadeIn, 1) && near(stage.fadeOut, 0.5)
              && stage.startTime == 10, "\(stage.duration) \(stage.fadeIn) \(stage.fadeOut)")
        check("the stage's automation and markers are stretched by the speed",
              stage.automation[0].points.map(\.t) == [2] && stage.markers[0].time == 2)
        check("the content root starts at the wave's zero, lane 0, no link, no sends, on the instance's stem",
              near(a.startTime, 8) && a.lane == 0 && a.consolidateID == nil && a.sends.isEmpty && a.stemID == stem)
        if case .group(let ch, let e) = a.kind {
            check("the content's descendants moved by the same shift (-92) and sit on the stem; root expanded",
                  e && near(ch[0].startTime, 8) && near(ch[1].startTime, 11) && ch.allSatisfy { $0.stemID == stem })
        }
        check("the stage is not a clip: no file size, no ARA, no infinite flag",
              stage.fileSize == nil && stage.araSource == nil && !stage.isInfinite)

        // MARK: - the way back

        var sameStage = stage
        sameStage.volume = -9                        // the instance's own fader, edited during the session
        let closed = SoundObject.closedInstance(fromStage: sameStage, wavePath: "n.wav", waveLength: L,
                                                waveZero: waveZero, definitionID: defID, automationOpen: false)
        check("closing: a clip on the wave, the stage's fader kept, speed 1, forwards",
              closed.isClip && closed.volume == -9 && closed.speedRatio == 1 && closed.consolidateID == defID,
              "\(closed.speedRatio)")
        check("closing: so = window start - waveZero = 2 and the window is the stage's (8 s at speed 1)",
              near(so(closed), 2) && near(closed.duration, 8) && closed.startTime == 10)
        var dragged = stage
        dragged.startTime = 11                       // the stage's left edge dragged 1 s to the right
        let draggedClosed = SoundObject.closedInstance(fromStage: dragged, wavePath: "n.wav", waveLength: L,
                                                       waveZero: waveZero, definitionID: defID, automationOpen: false)
        check("a window dragged during the session: so follows (3)", near(so(draggedClosed), 3))
        var outside = stage
        outside.startTime = 5                        // dragged BEFORE the wave's zero: so = -3
        let outsideClosed = SoundObject.closedInstance(fromStage: outside, wavePath: "n.wav", waveLength: L,
                                                       waveZero: waveZero, definitionID: defID, automationOpen: false)
        check("before realignment a window dragged outside the content has a negative so (-3)...",
              near(so(outsideClosed), -3))
        let fixed = outsideClosed.realignedInstance(delta: 0, wavePath: "n.wav", waveLength: L)
        check("...and the realignment brings it back inside (head cut by 3 s)",
              near(so(fixed), 0) && near(fixed.startTime, 8) && near(fixed.duration, 5),
              "\(fixed.startTime) \(fixed.duration) \(so(fixed))")

        // A speed-1 instance goes through open + close unchanged.
        let plain = inst(start: 10, dur: 4, so: 2, spd: 1, fadeIn: 0.5, fadeOut: 0.25)
        let openPlain = SoundObject.consolidateStage(placement: plain, content: content,
                                                     definitionID: plain.consolidateID!,
                                                     waveZero: plain.consolidateWaveZero)
        let backPlain = SoundObject.closedInstance(fromStage: openPlain, wavePath: "old.wav", waveLength: L,
                                                   waveZero: plain.consolidateWaveZero,
                                                   definitionID: plain.consolidateID!, automationOpen: false)
            .realignedInstance(delta: 0, wavePath: "old.wav", waveLength: L)
        check("open then close at speed 1 and delta 0 gives the instance back, unchanged",
              backPlain.startTime == plain.startTime && backPlain.duration == plain.duration
              && so(backPlain) == so(plain) && backPlain.fadeIn == plain.fadeIn
              && backPlain.fadeOut == plain.fadeOut && backPlain.id == plain.id)

        finish()
    }

    static func finish() {
        print("\n\(total - fails.count)/\(total) passed")
        if !fails.isEmpty { print("FAILED: \(fails)"); exit(1) }
        print("ALL PASS")
    }
}
