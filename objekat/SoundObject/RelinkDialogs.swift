import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - The relink, as a hand performs it
//
// `EditViewModel+Relink` knows HOW to mend a sound; this file is the only place that ASKS. It
// carries the three gestures' panels, the two questions and what is said afterwards — once, for
// the two surfaces that offer them: a row of the sound list and a block of the timeline. Two
// menus, one set of actions: an entry worded one way in the panel and another in the canvas would
// be two features as far as anyone using them is concerned. The ONE item that is not on both is
// "Replace File…", which belongs to the list alone (@see addRelinkItems for why).
//
// **THE HEADLESS RULE, and it is the reason every door here is guarded.** An `NSOpenPanel` or an
// `NSAlert.runModal()` reached from a script would put a window on the screen of whoever is
// working, and then wait for a click nobody is there to make — the exact bug `plugin.add` produced
// once by opening an editor as the SIDE EFFECT of something else. The guard is `hasInterface`, and
// following the repo's rule it sits on the FUNCTIONS THAT OPEN (`chooseFile`, `chooseFolder`) as
// well as at the three entry points, not on their callers: a guard at each caller is a guard the
// next caller forgets. Nothing in this file mutates the model before that guard has been passed.
//
// **AND ONE UNDO POINT PER GESTURE.** The propagation is the trap: the repair has already happened
// by the time one could ask about it, so asking afterwards would mean a second call and a ⌘Z that
// gives back half a gesture. It is asked BEFORE, through `resolvableByPropagation`, which reads
// the disk and changes NOTHING — then `repairPath(…, propagate:)` is called ONCE, with the answer.
// `relinkPath` followed by `applyPropagation` is the shape this file exists to avoid.
//
// **WHAT A PATH LOOKS LIKE TO A HUMAN.** A full path in an alert is a wall of slashes that is read
// by nobody past about sixty characters, and the two ends are what carry the meaning: the head
// says which DISK, the tail says which SOUND. So the loud line (an `NSAlert`'s `messageText`, a
// panel's `message`) names the file and at most the folder holding it, and the full path — elided
// in the middle, never at an end — goes in the informative text, where there is room for it and
// where nobody has to read it to act.

@MainActor
enum RelinkUI {

    // MARK: - What a menu may offer

    /// The items a right click on `object` is entitled to, decided ONCE and read by the two menus
    /// that draw them (the list's SwiftUI `.contextMenu`, the timeline's `NSMenu`). The rules:
    ///
    /// - **Replace is always available on a sound**, missing or not: "I have re-edited that file
    ///   outside" is an edit, not an accident (@see CONTRACTS, decision 1). It is withheld from an
    ///   INSTANCE of a sound object, whose content is not its own — `replaceSource` refuses one,
    ///   and an item that can only fail is worse than no item. It is also the one flag only ONE of
    ///   the two menus reads: the item lives in the sound list (@see `addRelinkItems`).
    /// - **Repair only when the file is actually gone**, since there is nothing to repair
    ///   otherwise.
    /// - **An offline volume is not a lost file.** The drive is in a drawer; it comes back on its
    ///   own at the next mount (@see `armMissingFileWatch`). Sending someone hunting through a
    ///   panel for a file that is where it has always been is telling them the wrong thing, so the
    ///   repair item gives way to a disabled line naming the volume — the menu still answers the
    ///   question "why is this red?", which is what one opened it for.
    /// - **The folder sweep answers to the PROJECT** and not to the object aimed at: it mends
    ///   whatever it finds, so it shows as soon as anything at all is missing. That is also what
    ///   makes it reachable from a group's menu, where the three object items say nothing.
    struct MenuPlan {
        let objectID: UUID
        let canReplace: Bool
        let canRepair: Bool
        /// The name of the `/Volumes/<name>` that is not mounted, when that is why the file is
        /// missing. Non-nil excludes `canRepair`.
        let offlineVolume: String?
        let canSweepFolder: Bool

        var isEmpty: Bool { !canReplace && !canRepair && offlineVolume == nil && !canSweepFolder }

        init(vm: EditViewModel, object: SoundObject) {
            objectID = object.id
            let reason = vm.missingReason(for: object)
            let offline = reason == .volumeOffline
            offlineVolume = offline ? RelinkUI.volumeName(of: object.filePath) : nil
            canReplace = object.isClip && object.definitionID == nil
            canRepair = reason != nil && !offline
            canSweepFolder = vm.missingFileCount > 0
        }
    }

    // MARK: - Replacing the source of one sound, or of several

    /// "Replace File…": the sounds NAMED pointed at another file. The deliberate gesture, and its
    /// unit is the object — what is not named does not change (@see CONTRACTS, decision 1).
    ///
    /// **The one question it puts is about the OTHERS**, and it is the propagation's question worn
    /// by the other gesture: the same file is very often laid down in several places, and having
    /// re-edited it outside one almost always means all of them. So when objects the hand did NOT
    /// name read the same file, they are offered — counted, with the two answers spelled out —
    /// and never mentioned when there are none (a question with only one answer is not put).
    ///
    /// It is asked BEFORE anything is written, for the reason `repairLink` is built around: the
    /// answer is folded into ONE call, hence ONE undo point, where asking afterwards would give a
    /// ⌘Z that hands back half a gesture.
    static func replaceSource(vm: EditViewModel, objectIDs: [UUID]) {
        guard vm.hasInterface else { return }
        // Read from the MODEL at the moment of the action and not from the objects the menu was
        // built with: a menu is built, then shown, and what it was built from can have moved.
        let targets = objectIDs.filter { id in
            guard let object = vm.find(id: id) else { return false }
            return object.isClip && object.definitionID == nil && !object.filePath.isEmpty
        }
        guard let first = targets.first, let firstObject = vm.find(id: first) else { return }
        let oldPaths = Set(targets.compactMap { vm.find(id: $0)?.filePath }.filter { !$0.isEmpty })
        let oldPath = firstObject.filePath

        // The loud line names the FILE when there is one, and counts the sounds when the selection
        // spans several: a panel headed with one name while five objects are about to change would
        // be saying the wrong thing.
        // No singular form for the second: several PATHS means at least two objects.
        let message = oldPaths.count == 1
            ? L("relink.panel.replace.message", (oldPath as NSString).lastPathComponent)
            : L("relink.panel.replace.message.many", targets.count)
        guard let url = chooseFile(vm: vm,
                                   title: L("relink.panel.replace.title"),
                                   message: message,
                                   prompt: L("relink.panel.replace.prompt"),
                                   startingAt: nearestExistingDirectory(of: oldPath)) else { return }
        // The same file chosen again is not a failure and not a change: say nothing, do nothing.
        // The paths that will really move are what the question is asked about, so an object
        // already reading the chosen file is counted nowhere — neither among the targets, which
        // `replaceSource` drops on its own, nor among the others, which would make the figure say
        // one more than the "yes" will do.
        let changing = oldPaths.subtracting([url.path])
        guard !changing.isEmpty else { return }

        var ids = targets
        let others = vm.objectsSharingSource(changing, excluding: Set(targets))
        if !others.isEmpty {
            // The count and nothing else: with a selection spanning several files, naming one of
            // them in the question would describe only part of what the "yes" is about.
            if vm.confirm(L("relink.replaceOthers.title"),
                          Ln("relink.replaceOthers.info", others.count, others.count),
                          yes: L("relink.replaceOthers.yes"),
                          no: Ln("relink.replaceOthers.no", targets.count),
                          style: .informational) {
                ids += others
            }
        }

        if !vm.replaceSource(of: ids, with: url) {
            reportFailure(vm: vm, chosen: url)
        }
        // Success says itself: the name, the waveform and the red all change on screen. An alert
        // for what one is already looking at is one more click for no information.
    }

    // MARK: - Repairing a missing link (and what it teaches)

    /// "Repair Link…": the file is gone, here is where it went. The unit of the repair is the
    /// PATH, so every object naming it is mended at once — and the pair may teach where the OTHER
    /// missing files went, which is what the propagation asks about.
    static func repairLink(vm: EditViewModel, objectID: UUID) {
        guard vm.hasInterface else { return }
        guard let object = vm.find(id: objectID), object.isClip else { return }
        let oldPath = object.filePath
        guard !oldPath.isEmpty, vm.missingReason(for: object) != nil else { return }

        guard let url = chooseFile(vm: vm,
                                   title: L("relink.panel.repair.title"),
                                   message: L("relink.panel.repair.message",
                                              (oldPath as NSString).lastPathComponent),
                                   prompt: L("relink.panel.repair.prompt"),
                                   startingAt: nearestExistingDirectory(of: oldPath)) else { return }
        guard url.path != oldPath else { return }

        // **The question comes FIRST**, and this is the whole reason: `resolvableByPropagation`
        // reads the disk and writes nothing, so the answer can be had while the repair is still
        // ahead of us — and the repair then happens ONCE, with the answer folded into it. Asking
        // afterwards would need a second call, hence a second undo point, hence a ⌘Z that gives
        // back half a gesture with nothing to say which half.
        var propagate = false
        if let learned = vm.resolvableByPropagation(from: oldPath, to: url.path).first {
            // N == 0 never reaches here: `resolvableByPropagation` answers empty rather than zero,
            // precisely so that a question with only one answer is never put (@see CONTRACTS, 3).
            let sub = learned.key
            let count = learned.value
            propagate = vm.confirm(L("relink.propagate.title"),
                                   Ln("relink.propagate.info", count, count,
                                      abridgedPath(sub.from), abridgedPath(sub.to)),
                                   yes: L("relink.propagate.yes"),
                                   no: L("relink.propagate.no"),
                                   style: .informational)
        }

        let report = vm.repairPath(oldPath, to: url, propagate: propagate)
        guard report.objects > 0 else {
            reportFailure(vm: vm, chosen: url)
            return
        }
        // Only a propagation is worth reporting. A repair confined to the sound one right-clicked
        // turns red into black under the pointer, which is the message; but a propagation mends
        // objects ELSEWHERE in the project, most of them off screen, so the count is the only
        // trace it leaves.
        if report.paths > 1 {
            vm.notify(L("relink.done.title"),
                      Ln("relink.done.info", report.objects, report.objects),
                      style: .informational)
        }
    }

    // MARK: - Sweeping a folder

    /// "Repair from a Folder…": here is a folder, find what you can in it. Bounded in depth and in
    /// directories opened by `relinkFromFolder` itself — it runs on the main thread, like every
    /// mutation of the model.
    static func repairFromFolder(vm: EditViewModel) {
        guard vm.hasInterface, vm.missingFileCount > 0 else { return }
        guard let folder = chooseFolder(vm: vm,
                                        title: L("relink.panel.folder.title"),
                                        message: L("relink.panel.folder.message"),
                                        prompt: L("relink.panel.folder.prompt")) else { return }

        let mended = vm.relinkFromFolder(folder)
        // Both outcomes are reported here, unlike the two gestures above, and for one reason: a
        // sweep is aimed at the PROJECT, not at anything under the pointer. Nothing on screen
        // necessarily changed where one is looking, so silence would read as "it did nothing"
        // whether it did or not.
        guard mended > 0 else {
            vm.notify(L("relink.none.title"),
                      L("relink.none.folder.info", shortPath(folder.path)),
                      style: .informational)
            return
        }
        vm.notify(L("relink.done.title"), Ln("relink.done.info", mended, mended),
                  style: .informational)
    }

    // MARK: - The panels (the functions that OPEN — hence the guard)

    /// The audio types a repair may be pointed at. `.audio` covers what the system knows; the
    /// repo's OWN list of extensions is added to it because that is the list the sound library and
    /// the drop path already honour, and a format OBJEKAT accepts by drag must not be greyed out
    /// in the panel that repairs it.
    private static let audioTypes: [UTType] = {
        var types: [UTType] = [.audio]
        for ext in SoundLibraryViewModel.audioExts.sorted() {
            if let type = UTType(filenameExtension: ext) { types.append(type) }
        }
        return types
    }()

    private static func chooseFile(vm: EditViewModel, title: String, message: String,
                                   prompt: String, startingAt: URL?) -> URL? {
        guard vm.hasInterface else { return nil }
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = message
        panel.prompt = prompt
        panel.allowedContentTypes = audioTypes
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let startingAt { panel.directoryURL = startingAt }
        // `runModal` and not `begin`: the propagation's question follows this answer immediately,
        // and a gesture that reads top to bottom is a gesture whose undo point is easy to count.
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    private static func chooseFolder(vm: EditViewModel, title: String, message: String,
                                     prompt: String) -> URL? {
        guard vm.hasInterface else { return nil }
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = message
        panel.prompt = prompt
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    // MARK: - Saying it went wrong

    /// One message for the two failures, because there is one fact to state: the sound is still
    /// not linked. Why it failed (a format `AVAudioFile` will not open, an object that turned out
    /// to be an instance) is engine detail the log carries, and guessing at it in an alert would
    /// be telling the user something we do not know.
    private static func reportFailure(vm: EditViewModel, chosen: URL) {
        // The loud line names the file, the line under it says where it was taken from: the same
        // division of labour as the propagation's question, so the two alerts read alike.
        vm.notify(L("relink.failed.title"),
                  L("relink.failed.info", shortPath(chosen.path)) + "\n\n"
                      + abridgedPath(chosen.path),
                  style: .warning)
    }

    // MARK: - Paths a human can read

    /// The file and the folder holding it — what a sound is recognised by, and short enough to sit
    /// in a bold alert line without wrapping.
    static func shortPath(_ path: String) -> String {
        let components = (path as NSString).pathComponents.filter { $0 != "/" }
        guard components.count >= 2 else { return (path as NSString).lastPathComponent }
        return components.suffix(2).joined(separator: "/")
    }

    /// The whole path, elided IN THE MIDDLE when it runs long. Never at an end: the head names the
    /// disk and the tail names the sound, and a path cut at either end stops answering the
    /// question it was shown for.
    static func abridgedPath(_ path: String, limit: Int = 64) -> String {
        guard path.count > limit, path.hasPrefix("/") else { return path }
        let components = (path as NSString).pathComponents.filter { $0 != "/" }
        guard components.count > 4 else { return path }
        return "/" + components.prefix(2).joined(separator: "/")
             + "/…/" + components.suffix(2).joined(separator: "/")
    }

    /// The deepest folder of `path` that still exists, so the panel opens as close to where the
    /// file WAS as the disk allows — a panel landing in the home folder makes one navigate back to
    /// somewhere one has just been told about. nil when nothing along the way is there any more.
    ///
    /// It reads the disk, which is why it lives at a GESTURE's door and not in a view body: the
    /// whole of `MissingFiles` is built around keeping `stat()` out of the drawing pass, and an
    /// unmounted network volume can block for seconds. The walk is bounded by the path's own
    /// depth, plus a belt-and-braces counter — `deletingLastPathComponent` on a malformed path
    /// must not be able to spin.
    private static func nearestExistingDirectory(of path: String) -> URL? {
        var directory = (path as NSString).deletingLastPathComponent
        var steps = 0
        while !directory.isEmpty, directory != "/", steps < 64 {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return URL(fileURLWithPath: directory, isDirectory: true)
            }
            directory = (directory as NSString).deletingLastPathComponent
            steps += 1
        }
        return nil
    }

    /// The name of the `/Volumes/<name>` a path lives on, for the line that says which drive to
    /// plug back in. It re-reads the path rather than asking `MissingFiles`, which keeps the
    /// REASON and has no use for the name — a display concern, and the only one here that never
    /// touches the disk.
    static func volumeName(of path: String) -> String? {
        let components = (path as NSString).pathComponents
        guard components.count >= 3, components[0] == "/", components[1] == "Volumes" else { return nil }
        return components[2]
    }
}

// MARK: - The items, for the timeline's AppKit menu

/// The relink block of the timeline's right-click menu, in the idiom of that menu's other blocks
/// (@see `addObjectMarkerItem`): an `NSMenuItem` per action, each targeting a `MenuActionProxy`
/// the caller keeps alive — an item's target is held weakly, so a proxy that went out of scope
/// would give a menu whose entries do nothing.
///
/// **"Replace File…" is deliberately NOT here**, and it is the one item the two menus differ by.
/// Repairing answers an ACCIDENT and belongs wherever the red is seen, the timeline included;
/// replacing is a deliberate act on a named object, it can now be aimed at several at once, and
/// the place where several objects are named is the left panel's list. So it lives there and only
/// there, and `plan.canReplace` is read here for the separator alone.
@MainActor
func addRelinkItems(menu: NSMenu, proxies: inout [MenuActionProxy],
                    vm: EditViewModel, object: SoundObject) {
    let plan = RelinkUI.MenuPlan(vm: vm, object: object)
    // `isEmpty` counts the replace item this menu does not offer, so the emptiness is recomputed
    // from what is really about to be drawn: without it a sound with nothing missing would open a
    // menu holding one separator and no entry at all.
    guard plan.canRepair || plan.offlineVolume != nil || plan.canSweepFolder else { return }
    if !menu.items.isEmpty { menu.addItem(.separator()) }

    if plan.canRepair {
        addRelinkItem(menu, &proxies, L("menu.context.repairLink")) {
            RelinkUI.repairLink(vm: vm, objectID: plan.objectID)
        }
    }
    if let volume = plan.offlineVolume {
        // Disabled on purpose: it is a STATEMENT, not an action. The menu answers "why is this
        // red?" without offering to go and find a file that will come back by itself.
        let item = NSMenuItem(title: L("menu.context.volumeOffline", volume),
                              action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }
    if plan.canSweepFolder {
        // The sweep is aimed at the PROJECT where the two above are aimed at one sound, so it
        // stands apart — the same separator the SwiftUI side draws, for the same reason.
        if plan.canRepair || plan.offlineVolume != nil {
            menu.addItem(.separator())
        }
        addRelinkItem(menu, &proxies, L("menu.context.repairFromFolder")) {
            RelinkUI.repairFromFolder(vm: vm)
        }
    }
}

@MainActor
private func addRelinkItem(_ menu: NSMenu, _ proxies: inout [MenuActionProxy],
                           _ title: String, _ action: @escaping @MainActor () -> Void) {
    let proxy = MenuActionProxy { Task { @MainActor in action() } }
    proxies.append(proxy)
    let item = NSMenuItem(title: title, action: #selector(MenuActionProxy.run), keyEquivalent: "")
    item.target = proxy
    menu.addItem(item)
}

// MARK: - The same items, for the sound list's SwiftUI menu

/// The list's half of the same menu — plus "Replace File…", which is the list's alone (@see
/// `addRelinkItems`). Both are built from ONE `MenuPlan`, so no OTHER entry can be offered on one
/// side of the window and withheld on the other.
///
/// The repairs name their object EXPLICITLY and read nothing from the selection: a right click in
/// a list does not select, so acting on the selection would mend whichever row happened to be blue
/// rather than the one under the pointer — and a repair works on the PATH anyway, which mends
/// every object naming it whatever is selected.
///
/// **Replacing is the exception, and it follows the app's batch rule** (the plugin cards': a card
/// IN the selection speaks for the whole selection, one outside it speaks for itself). A right
/// click on a row that is part of a multiple selection replaces the file of the WHOLE selection —
/// that is what makes the selection worth making — and a right click anywhere else replaces that
/// row alone. The item says which of the two it is about to do.
struct RelinkContextMenuItems: View {
    var viewModel: EditViewModel
    let object: SoundObject

    /// The objects "Replace File…" is about to act on: the selection when the row is in it, this
    /// row alone otherwise.
    ///
    /// Walked through `allClips` and not through the selection set: a `Set` has no order, and the
    /// panel's own heading reads the FIRST of these (which file it names, which folder it opens
    /// in). The tree's order is the one the list shows.
    private var replaceTargets: [UUID] {
        let selected = viewModel.selectedIDs
        guard selected.count > 1, selected.contains(object.id) else { return [object.id] }
        return viewModel.allClips.compactMap { clip -> UUID? in
            guard selected.contains(clip.id), clip.isClip,
                  clip.definitionID == nil else { return nil }
            return clip.id
        }
    }

    var body: some View {
        let plan = RelinkUI.MenuPlan(vm: viewModel, object: object)
        if plan.canReplace {
            let targets = replaceTargets
            // No singular form: the many-worded item is only ever drawn for two or more.
            Button(targets.count > 1 ? L("menu.context.replaceFile.many", targets.count)
                                     : L("menu.context.replaceFile")) {
                RelinkUI.replaceSource(vm: viewModel, objectIDs: targets)
            }
        }
        if plan.canRepair {
            Button(L("menu.context.repairLink")) {
                RelinkUI.repairLink(vm: viewModel, objectID: plan.objectID)
            }
        }
        if let volume = plan.offlineVolume {
            // Disabled: the drive is in a drawer, not the file lost. @see addRelinkItems.
            Button(L("menu.context.volumeOffline", volume)) { }
                .disabled(true)
        }
        if plan.canSweepFolder {
            if plan.canReplace || plan.canRepair || plan.offlineVolume != nil { Divider() }
            Button(L("menu.context.repairFromFolder")) {
                RelinkUI.repairFromFolder(vm: viewModel)
            }
        }
    }
}
