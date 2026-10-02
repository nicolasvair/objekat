// Opening a file a tab already holds RELOADS it from disk — the decision behind it, asserted with
// no screen. `ReopenSameFile` (`Shared/ReopenSameFile.swift`) has no model behind it at all,
// which is why it can be compiled and run alone, like `CutSelection` / `TabReorder` before it.
//
//     swiftc -parse-as-library \
//         ../objekat/Shared/ReopenSameFile.swift test_reopen_same_file.swift \
//         -o /tmp/reopen && /tmp/reopen
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
enum ReopenSameFileTest {
  static func main() {
    typealias R = ReopenSameFile

    // MARK: - A clean tab reloads, whoever asks, with no question

    check("clean, hand: reload with no dialogue",
          R.decide(blocker: nil, isDirty: false, requester: .hand) == .reload)
    check("clean, script without discard: reload (nothing to lose)",
          R.decide(blocker: nil, isDirty: false, requester: .script(discard: false)) == .reload)
    check("clean, script with discard: reload",
          R.decide(blocker: nil, isDirty: false, requester: .script(discard: true)) == .reload)

    // MARK: - A modified tab: the hand is asked, a script must say discard

    check("dirty, hand: Save / Don't Save / Cancel first",
          R.decide(blocker: nil, isDirty: true, requester: .hand) == .askThenReload)
    check("dirty, script without discard: refused, nothing thrown away",
          R.decide(blocker: nil, isDirty: true, requester: .script(discard: false)) == .refuseDirty)
    check("dirty, script with discard: reload",
          R.decide(blocker: nil, isDirty: true, requester: .script(discard: true)) == .reload)

    // MARK: - A blocking operation refuses BEFORE anything else — dirty or not, hand or script

    let blockers = ["tabs.switch.refused.loading", "tabs.switch.refused.export",
                    "tabs.switch.refused.render", "tabs.switch.refused.consolidateEdit"]
    let requesters: [R.Requester] = [.hand, .script(discard: false), .script(discard: true)]
    for b in blockers {
        for dirty in [false, true] {
            for r in requesters {
                check("blocked by \(b), dirty=\(dirty), \(r): refused with that reason",
                      R.decide(blocker: b, isDirty: dirty, requester: r) == .refuse(reasonKey: b))
            }
        }
    }

    // MARK: - The refusal's wording: same reasons, a reload's own sentence

    check("loading → project.reload.refused.loading",
          R.reloadRefusalKey(forBlocker: "tabs.switch.refused.loading") == "project.reload.refused.loading")
    check("export → project.reload.refused.export",
          R.reloadRefusalKey(forBlocker: "tabs.switch.refused.export") == "project.reload.refused.export")
    check("render → project.reload.refused.render",
          R.reloadRefusalKey(forBlocker: "tabs.switch.refused.render") == "project.reload.refused.render")
    check("consolidateEdit → project.reload.refused.consolidateEdit",
          R.reloadRefusalKey(forBlocker: "tabs.switch.refused.consolidateEdit")
              == "project.reload.refused.consolidateEdit")
    check("an unknown reason → the generic sentence, never a missing key",
          R.reloadRefusalKey(forBlocker: "tabs.switch.refused.somethingNew") == "project.reload.refused.busy")
    check("a key from another family → the generic sentence",
          R.reloadRefusalKey(forBlocker: "export.busy") == "project.reload.refused.busy")

    print("")
    if fails.isEmpty {
        print("ALL PASS (\(total) assertions)")
        exit(0)
    } else {
        print("\(fails.count) FAIL out of \(total)")
        exit(1)
    }
  }
}
