// "What the relink block of a right-click menu offers" — the decision, asserted with no screen.
// `RelinkMenuRules` (`Shared/RelinkMenuRules.swift`) has no view, no model and no disk behind it,
// which is why it can be compiled and run alone, like `ContextMenuPlan` / `CutSelection`. The two
// menus that draw it (the sound list's SwiftUI one, the timeline's AppKit one) cannot be driven
// headless; WHAT THEY DECIDE can.
//
//     swiftc -parse-as-library \
//         ../objekat/Shared/RelinkMenuRules.swift test_relink_menu_rules.swift \
//         -o /tmp/relinkmenu && /tmp/relinkmenu
//
// The rule being pinned (11 October 2026): an offline volume no longer takes "Repair Link…" away.
// A file that is missing is repairable whatever the reason; the offline reason only adds a
// disabled line naming the volume, drawn above the repair. "Replace File…" has its own rule (any
// clip but an instance of a consolidated object) and does not depend on the file being missing.
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
enum RelinkMenuRulesTest {
  static func main() {
    typealias R = RelinkMenuRules

    func items(_ cause: R.Cause?, clip: Bool = true, instance: Bool = false,
               anythingMissing: Bool? = nil) -> R.Items {
        R.items(cause: cause, isClip: clip, isConsolidateInstance: instance,
                anythingMissingInProject: anythingMissing ?? (cause != nil))
    }

    // MARK: - The three states of a clip's file

    let absent = items(.absent)
    check("absent: repair offered", absent.canRepair)
    check("absent: no volume line", !absent.showsOfflineVolumeLine)
    check("absent: the sweep is offered (something is missing)", absent.canSweepFolder)
    check("absent: replace stays offered", absent.canReplace)

    let offline = items(.volumeOffline)
    check("volumeOffline: repair offered too (it used to be withheld)", offline.canRepair)
    check("volumeOffline: the disabled volume line is kept", offline.showsOfflineVolumeLine)
    check("volumeOffline: the sweep is offered", offline.canSweepFolder)
    check("volumeOffline: replace stays offered", offline.canReplace)

    let present = items(nil, anythingMissing: false)
    check("not missing: no repair", !present.canRepair)
    check("not missing: no volume line", !present.showsOfflineVolumeLine)
    check("not missing, nothing missing anywhere: no sweep", !present.canSweepFolder)
    check("not missing: replace is still the deliberate gesture", present.canReplace)
    check("not missing: the timeline's repair block draws nothing", !present.drawsRepairBlock)

    // MARK: - The project-wide sweep answers to the PROJECT, not to the object aimed at

    let healthyAmongBroken = items(nil, anythingMissing: true)
    check("a healthy clip in a project with something missing still gets the sweep",
          healthyAmongBroken.canSweepFolder && !healthyAmongBroken.canRepair)
    check("…and the timeline block draws for it", healthyAmongBroken.drawsRepairBlock)

    // MARK: - Replace

    let instanceOfConsolidated = items(.absent, instance: true)
    check("an instance of a consolidated object: no Replace", !instanceOfConsolidated.canReplace)
    check("…but it can be repaired like any missing clip", instanceOfConsolidated.canRepair)
    let instanceOffline = items(.volumeOffline, instance: true)
    check("an instance on an offline volume: no Replace, repair + volume line",
          !instanceOffline.canReplace && instanceOffline.canRepair
            && instanceOffline.showsOfflineVolumeLine)

    let group = items(nil, clip: false, anythingMissing: false)
    check("a group owns no file: no Replace, no repair, nothing to draw", group.isEmpty)
    let groupInBrokenProject = items(nil, clip: false, anythingMissing: true)
    check("a group in a project with something missing: only the sweep",
          groupInBrokenProject.canSweepFolder && !groupInBrokenProject.canReplace
            && !groupInBrokenProject.canRepair)

    // MARK: - isEmpty / drawsRepairBlock

    check("an absent clip's plan is not empty", !absent.isEmpty)
    check("an offline clip's plan is not empty", !offline.isEmpty)
    check("the offline clip's timeline block draws (volume line + repair)", offline.drawsRepairBlock)

    // MARK: - Where the repair panel opens

    let near = URL(fileURLWithPath: "/Users/n/Sons", isDirectory: true)
    let last = URL(fileURLWithPath: "/Users/n/Relinked", isDirectory: true)
    let proj = URL(fileURLWithPath: "/Users/n/Projet", isDirectory: true)

    check("absent file: the nearest existing folder of the lost file",
          R.panelStart(cause: .absent, nearestExisting: near,
                       lastRelinkFolder: last, projectFolder: proj) == near)
    check("absent file, no surviving ancestor: nothing imposed",
          R.panelStart(cause: .absent, nearestExisting: nil,
                       lastRelinkFolder: last, projectFolder: proj) == nil)
    check("offline volume: the last relink folder of the session wins",
          R.panelStart(cause: .volumeOffline, nearestExisting: URL(fileURLWithPath: "/Volumes"),
                       lastRelinkFolder: last, projectFolder: proj) == last)
    check("offline volume, no relink yet: the project's folder",
          R.panelStart(cause: .volumeOffline, nearestExisting: URL(fileURLWithPath: "/Volumes"),
                       lastRelinkFolder: nil, projectFolder: proj) == proj)
    check("offline volume: never /Volumes, even with nothing else to offer",
          R.panelStart(cause: .volumeOffline, nearestExisting: URL(fileURLWithPath: "/Volumes"),
                       lastRelinkFolder: nil, projectFolder: nil) == nil)
    check("not missing (no cause): the nearest folder, unchanged",
          R.panelStart(cause: nil, nearestExisting: near,
                       lastRelinkFolder: last, projectFolder: proj) == near)

    print("\n\(total) assertions, \(fails.count) failed")
    exit(fails.isEmpty ? 0 : 1)
  }
}
