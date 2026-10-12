import Foundation

// MARK: - What the relink block of a right-click menu offers
//
// The decision, with no view, no model and no disk behind it — so that the two menus that draw it
// (the sound list's SwiftUI `.contextMenu`, the timeline's `NSMenu`) read ONE answer, and so that it
// can be compiled and asserted alone (`tools/test_relink_menu_rules.swift`).
//
// **A volume that is not mounted does not take the repair away.** It used to: the drive is in a
// drawer, the file is where it has always been, and sending someone hunting through a panel for it
// was judged the wrong thing to say. But the other side of that coin is the drive that will NEVER
// come back (sold, reformatted, a project received from someone else): with the item withheld, the
// only way out was the project-wide folder sweep, which the same menu hides until something is
// missing — and offers no way to say "this one file is HERE now". So the repair is offered whatever
// the reason, and what the offline reason adds is INFORMATION: a disabled line naming the volume,
// kept above the repair, which still answers "why is this red?".
//
// "Replace File…" is a different gesture (an edit, not an accident): it is available on every
// sound, missing or not, and withheld from an INSTANCE of a consolidated object, whose content is
// not its own.

nonisolated enum RelinkMenuRules {

    /// Why a sound's file could not be found at the last scan — the two cases `MissingFiles`
    /// distinguishes, without the view-model's own type, to keep this file free of any dependency.
    enum Cause: Equatable {
        /// The path is reachable and there is nothing there.
        case absent
        /// The path lives on a `/Volumes/<name>` that is not mounted.
        case volumeOffline
    }

    /// The relink items a right click on one object is entitled to.
    struct Items: Equatable {
        /// "Replace File…" — a clip that is not an instance of a consolidated object.
        let canReplace: Bool
        /// "Repair Link…" — whenever the file is missing, for ANY reason, an offline volume included.
        let canRepair: Bool
        /// The disabled line naming the unmounted volume. Information only: it does not exclude
        /// `canRepair`, it sits above it.
        let showsOfflineVolumeLine: Bool
        /// "Repair from a Folder…" — answers to the PROJECT, not to the object aimed at.
        let canSweepFolder: Bool

        /// Nothing at all to draw (the replace item counted, as `MenuPlan.isEmpty` always did).
        var isEmpty: Bool { !canReplace && !canRepair && !showsOfflineVolumeLine && !canSweepFolder }

        /// Anything the TIMELINE's menu draws: it never offers "Replace File…" (that one lives in
        /// the list), so its emptiness is judged without it.
        var drawsRepairBlock: Bool { canRepair || showsOfflineVolumeLine || canSweepFolder }
    }

    /// - `cause`: the object's missing reason, nil when its file is there (or it names none).
    /// - `isClip`, `isConsolidateInstance`: what decides "Replace File…".
    /// - `anythingMissingInProject`: the project-wide count is above zero.
    static func items(cause: Cause?, isClip: Bool, isConsolidateInstance: Bool,
                      anythingMissingInProject: Bool) -> Items {
        Items(canReplace: isClip && !isConsolidateInstance,
              canRepair: cause != nil,
              showsOfflineVolumeLine: cause == .volumeOffline,
              canSweepFolder: anythingMissingInProject)
    }

    /// Where the repair panel opens. The nearest folder of the missing file that still exists is
    /// the natural place — except when the file is on an OFFLINE volume: the walk up would stop at
    /// `/Volumes` itself, which is a list of drives and not a place anything was ever put. Then the
    /// folder of the last relink of the session (files that went together tend to come back
    /// together), failing that the project's folder.
    ///
    /// All three are passed in, already resolved against the disk by the caller; this only ranks.
    static func panelStart(cause: Cause?,
                           nearestExisting: URL?,
                           lastRelinkFolder: URL?,
                           projectFolder: URL?) -> URL? {
        guard cause == .volumeOffline else { return nearestExisting }
        return lastRelinkFolder ?? projectFolder
    }
}
