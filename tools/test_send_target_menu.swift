import Foundation

// Standalone test of the "Send to…" menu builder (INC 2, step 2.11).
//
//     swiftc -parse-as-library -o /tmp/t_sendmenu ../objekat/Shared/SendTargetMenu.swift \
//         test_send_target_menu.swift && /tmp/t_sendmenu

var failures = 0, total = 0
func check(_ ok: Bool, _ what: String) { total += 1; if !ok { failures += 1; print("FAIL: \(what)") } }

func cand(_ name: String, _ tier: Int, refusal: String? = nil, used: Bool = false) -> SendTargetMenu.Candidate {
    .init(id: UUID(), name: name, tier: tier, refusal: refusal, alreadySending: used)
}

@main
struct Main {
    static func main() {
        let used = "already sending"
        // Order of Q-U3 whatever the order given; inside a tier, the order given.
        let given = [cand("M1", 2), cand("S1", 1), cand("G1", 0), cand("M2", 2), cand("G2", 0), cand("S2", 1)]
        let s = SendTargetMenu.sections(given, alreadySendingReason: used)
        check(s.map(\.tier) == [0, 1, 2], "three sections, group / stem / Main")
        check(s.map { $0.entries.map(\.name) } == [["G1", "G2"], ["S1", "S2"], ["M1", "M2"]], "tier order, then the order given")
        check(s.map(\.titleKey) == ["send.menu.tier.group", "send.menu.tier.stem", "send.menu.tier.main"], "title keys")
        check(Set(s.map(\.titleKey)).count == 3, "one key per tier")

        // Empty tiers have no section.
        let only = SendTargetMenu.sections([cand("S", 1)], alreadySendingReason: used)
        check(only.count == 1 && only[0].tier == 1, "an empty tier has no section")
        check(SendTargetMenu.sections([], alreadySendingReason: used).isEmpty, "no candidate, no section")

        // Greyed with the reason: a refusal, an existing send; the refusal wins when both.
        let r = SendTargetMenu.sections([cand("ok", 0), cand("loop", 0, refusal: "loop"),
                                         cand("dup", 0, used: true), cand("both", 0, refusal: "loop", used: true)],
                                        alreadySendingReason: used)[0].entries
        check(r[0].isEnabled && r[0].disabledReason == nil, "an accepted aux is enabled")
        check(!r[1].isEnabled && r[1].disabledReason == "loop", "a refused aux is greyed with the plan's reason")
        check(!r[2].isEnabled && r[2].disabledReason == used, "an aux that already has a send is greyed with that reason")
        check(r[3].disabledReason == "loop", "the refusal wins over 'already sending'")

        // Nothing is dropped: every candidate is in the menu exactly once.
        let many = (0..<30).map { cand("a\($0)", $0 % 3, refusal: $0 % 5 == 0 ? "no" : nil, used: $0 % 7 == 0) }
        let all = SendTargetMenu.sections(many, alreadySendingReason: used)
        check(all.flatMap(\.entries).count == 30 && Set(all.flatMap(\.entries).map(\.id)).count == 30, "every candidate appears once")

        // hasEnabledEntry.
        check(!SendTargetMenu.hasEnabledEntry(SendTargetMenu.sections([cand("x", 0, refusal: "no")], alreadySendingReason: used)),
              "a menu of only greyed entries has nothing to pick")
        check(SendTargetMenu.hasEnabledEntry(all), "a menu with one accepted aux has")
        // Out-of-range tiers are clamped, not lost.
        check(SendTargetMenu.sections([cand("z", 9), cand("n", -1)], alreadySendingReason: used).flatMap(\.entries).count == 2,
              "out-of-range tiers are clamped")

        print("\(total - failures)/\(total) send menu checks passed")
        exit(failures == 0 ? 0 : 1)
    }
}
