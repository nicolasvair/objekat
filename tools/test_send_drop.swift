import Foundation

// Standalone test of the send drag-and-drop table (INC 2, step 2.10).
//
//     swiftc -parse-as-library -o /tmp/t_senddrop \
//         ../objekat/Inspector/Synoptic/SynopticGraph.swift \
//         ../objekat/Inspector/Synoptic/SynopticWidthFlow.swift \
//         ../objekat/Inspector/Synoptic/SendDrop.swift test_send_drop.swift && /tmp/t_senddrop

import SwiftUI
func L(_ key: String, _ args: CVarArg...) -> String { key }

var failures = 0, total = 0
func check(_ ok: Bool, _ what: String) { total += 1; if !ok { failures += 1; print("FAIL: \(what)") } }

@main
struct Main {
    static func main() {
        // The plan's table, row by row.
        check(SendDrop.decide(.trunk(index: 2)) == .move(.chain(2), .takenHere), "a trunk insert point -> chain(i), 'taken here'")
        check(SendDrop.decide(.trunk(index: 0)) == .move(.chain(0), .takenHere), "the head insert point -> chain(0)")
        check(SendDrop.decide(.trunk(index: -3)) == .move(.chain(0), .takenHere), "a negative index is clamped")
        check(SendDrop.decide(.slot(.input)) == .move(.input, .takenAtInput), "input slot")
        check(SendDrop.decide(.slot(.preFader)) == .move(.preFader, .takenBeforeFader), "pre-fader slot")
        check(SendDrop.decide(.slot(.postFader)) == .move(.postFader, .takenAfterFader), "post-fader slot")
        check(SendDrop.decide(.parallelBranch) == .refuse(.refusedParallel), "a parallel branch refuses")
        check(SendDrop.decide(.fxBlock) == .refuse(.refusedFXLink), "an FX link refuses")
        check(SendDrop.decide(.elsewhere) == .refuse(.refusedElsewhere), "another object / strip / timeline / aux / Main refuses")

        check(SendDrop.decide(.sendBox) == .refuse(.refusedSendBox), "another send's box refuses a send card (INC 3)")

        // The signal view rework (§B.6): knowing the trunk's size, its head '+' IS the input and its tail
        // '+' the pre-fader slot; the middle ones stay chain(i); everything else is the plain table.
        check(SendDrop.decide(.trunk(index: 0), trunkCount: 3) == .move(.input, .takenAtInput), "head '+' -> input")
        check(SendDrop.decide(.trunk(index: -2), trunkCount: 3) == .move(.input, .takenAtInput), "before the head -> input")
        check(SendDrop.decide(.trunk(index: 1), trunkCount: 3) == .move(.chain(1), .takenHere), "a middle '+' -> chain(1)")
        check(SendDrop.decide(.trunk(index: 2), trunkCount: 3) == .move(.chain(2), .takenHere), "a middle '+' -> chain(2)")
        check(SendDrop.decide(.trunk(index: 3), trunkCount: 3) == .move(.preFader, .takenBeforeFader), "tail '+' -> pre-fader")
        check(SendDrop.decide(.trunk(index: 9), trunkCount: 3) == .move(.preFader, .takenBeforeFader), "past the tail -> pre-fader")
        check(SendDrop.decide(.trunk(index: 0), trunkCount: 0) == .move(.input, .takenAtInput), "an empty trunk's one '+' -> input")
        check(SendDrop.decide(.slot(.postFader), trunkCount: 3) == .move(.postFader, .takenAfterFader), "a slot is unchanged")
        check(SendDrop.decide(.fxBlock, trunkCount: 3) == .refuse(.refusedFXLink), "a refusal is unchanged")
        check(SendDrop.decide(.parallelBranch, trunkCount: 3) == .refuse(.refusedParallel), "a branch still refuses")

        // Every refusal is a refusal and says so; every acceptance is not.
        let aims: [SendDropAim] = [.trunk(index: 1), .slot(.input), .slot(.preFader), .slot(.postFader),
                                   .parallelBranch, .fxBlock, .sendBox, .elsewhere]
        for a in aims {
            let d = SendDrop.decide(a)
            check(d.isRefusal == d.banner.isRefusal, "decision and banner agree for \(a)")
        }
        // Four acceptance lines, four refusal lines (INC 3 added the send box), each with its own key.
        let all: [SendDropBanner] = [.takenHere, .takenAtInput, .takenBeforeFader, .takenAfterFader,
                                     .refusedParallel, .refusedFXLink, .refusedElsewhere, .refusedSendBox]
        check(Set(all.map(\.titleKey)).count == all.count, "one catalogue key per banner")
        check(all.filter(\.isRefusal).count == 4, "four refusal banners")

        // INC 3: a PLUGIN refused by a send's box. Two reasons have a line; any other has none.
        check(SendBoxPluginRefusal.titleKey(reason: "send_chain_leaves_only") == "hud.pluginDrop.send.leavesOnly",
              "leaves only: its line")
        check(SendBoxPluginRefusal.titleKey(reason: "chainFull") == "hud.pluginDrop.send.full", "full: its line")
        check(SendBoxPluginRefusal.titleKey(reason: "dropped on itself") == nil, "any other refusal: the cursor alone")

        // The payload round-trips and is NOT a plugin payload (the doors that take plugins ignore it).
        struct PluginLike: Codable { let sourceObjectID: UUID; let pluginID: UUID }
        let p = SendDragPayload(sendSender: UUID(), sendAux: UUID())
        let data = try! JSONEncoder().encode(p)
        check((try? JSONDecoder().decode(SendDragPayload.self, from: data)) == p, "payload round trip")
        check((try? JSONDecoder().decode(PluginLike.self, from: data)) == nil, "a send payload does not decode as a plugin payload")
        let plug = try! JSONEncoder().encode(PluginLike(sourceObjectID: UUID(), pluginID: UUID()))
        check((try? JSONDecoder().decode(SendDragPayload.self, from: plug)) == nil, "a plugin payload does not decode as a send payload")

        print("\(total - failures)/\(total) send drop checks passed")
        exit(failures == 0 ? 0 : 1)
    }
}
